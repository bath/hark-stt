-- Hark: private, low-latency local dictation for macOS.
-- Installed as ~/.hammerspoon/hark/init.lua and loaded with require("hark").
--
-- A persistent native helper prepares a stopped Core Audio HAL input unit, and
-- a local whisper-server keeps the Whisper model loaded. The microphone remains
-- inactive until the start hotkey, then releases again before transcription.
--
-- whisper-server is owned by launchd (LaunchAgent com.hark-stt.server,
-- installed by install.sh) with KeepAlive, so it restarts on its own if it dies.
-- This module never launches the server; it polls /health and reconnects.

-- ---- config -----------------------------------------------------------------
local VERSION        = "1.2.0"
local HOME           = os.getenv("HOME")
local HARK_DIR       = HOME .. "/.hammerspoon/hark"
local RECORDER       = HARK_DIR .. "/bin/hark-recorder"
local CURL           = "/usr/bin/curl"
local MIC            = nil -- nil = built-in Mac mic; or an exact name such as ":Studio Display Microphone"
local LANG           = "en"
local WAV            = "/tmp/hark-take.wav"
local SERVER_HOST    = "127.0.0.1"
local SERVER_PORT    = 8178
local SOUND_DIR      = HARK_DIR .. "/sounds" -- built by sounds/generate.py
local STATUS_FILE    = HARK_DIR .. "/status.json" -- read by `hark doctor`
local HOTKEYS = {
  { {},       "f18"   },
  { {"alt"},  "space" },
}
-- -----------------------------------------------------------------------------

local SERVER_URL = "http://" .. SERVER_HOST .. ":" .. tostring(SERVER_PORT)
local phase = "warming"
local recorderReady = false
local serverReady = false
local recorderTask = nil
local transcriptionTask = nil
local recorderOutput = ""
local recorderRetries = 0
local serverPollGeneration = 0
local serverWatchdog = nil
local statusTimer = nil
local resetServer -- forward declaration; defined in the server section
local shuttingDown = false
local stopRequestedNs = nil
local transcriptionStartedNs = nil
local lastMetrics = {}
local microphoneActive = false

local menu = hs.menubar.new()
local function setIcon(icon) if menu then menu:setTitle(icon) end end
setIcon("⏳")

local function statusText()
  if phase == "warming" then
    local waiting = {}
    if not recorderReady then table.insert(waiting, "recorder") end
    if not serverReady then table.insert(waiting, "Whisper") end
    return "Warming " .. table.concat(waiting, " + ")
  end
  if phase == "ready" then return "Ready" end
  if phase == "recording" then return "Recording" end
  if phase == "transcribing" then return "Transcribing" end
  return phase
end

local function refreshReadyState(showAlert)
  if recorderReady and serverReady and phase == "warming" then
    phase = "ready"
    setIcon("🎙")
    if showAlert then hs.alert.show("Hark is ready") end
  end
end

-- ---- settings ---------------------------------------------------------------
local SETTINGS_PREFIX = "hark."

-- Carry settings over from the whisper-dictation name.
if hs.settings then
  for _, key in ipairs({ "soundPack", "soundVolume", "notchIsland" }) do
    local old = hs.settings.get("whisperDictation." .. key)
    if old ~= nil and hs.settings.get(SETTINGS_PREFIX .. key) == nil then
      hs.settings.set(SETTINGS_PREFIX .. key, old)
    end
    if old ~= nil then hs.settings.clear("whisperDictation." .. key) end
  end
end

local function getSetting(key, default)
  local value = hs.settings and hs.settings.get(SETTINGS_PREFIX .. key)
  if value == nil then return default end
  return value
end

local function setSetting(key, value)
  if hs.settings then hs.settings.set(SETTINGS_PREFIX .. key, value) end
end

-- ---- sounds -----------------------------------------------------------------
-- Each pack has one sound per transition: start, stop, done (text pasted) and
-- error. packs.json lists them in menu order.
local soundPacks = {}
local soundPackById = {}
local defaultSoundPack = "pop"
local loadedSounds = {}
local previewTimers = {}

local function loadSoundPacks()
  local file = io.open(SOUND_DIR .. "/packs.json", "r")
  if not file then return end
  file:close()
  local ok, index = pcall(function() return hs.json.read(SOUND_DIR .. "/packs.json") end)
  if not ok or type(index) ~= "table" or type(index.packs) ~= "table" then return end
  defaultSoundPack = index.default or defaultSoundPack
  for _, pack in ipairs(index.packs) do
    local files = {}
    for transition, path in pairs(pack.files or {}) do
      files[transition] = path:sub(1, 1) == "/" and path or (SOUND_DIR .. "/" .. path)
    end
    pack.files = files
    table.insert(soundPacks, pack)
    soundPackById[pack.id] = pack
  end
end

local function playSound(transition)
  if not hs.sound then return end
  local pack = soundPackById[getSetting("soundPack", defaultSoundPack)]
  local path = pack and pack.files[transition]
  if not path then return end
  local sound = loadedSounds[path]
  if sound == nil then
    sound = hs.sound.getByFile(path) or false
    loadedSounds[path] = sound
  end
  if not sound then return end
  sound:stop()
  sound:volume(getSetting("soundVolume", 0.6))
  sound:play()
end

local function previewSounds()
  for _, timer in ipairs(previewTimers) do timer:stop() end
  previewTimers = {}
  for i, transition in ipairs({ "start", "stop", "done", "error" }) do
    table.insert(previewTimers, hs.timer.doAfter((i - 1) * 0.9, function() playSound(transition) end))
  end
end

loadSoundPacks()

-- ---- notch island -------------------------------------------------------------
-- While recording, the MacBook notch grows sideways into a black pill: a red
-- dot and a timer on the left, voice bars on the right. Then it shows
-- "Transcribing" with a spinner, then a green check and "Pasted" (or what went
-- wrong) before it shrinks back into the notch. A screen with no notch gets
-- the same pill dropping from the top center. It appears on the screen that
-- has the mouse pointer.
local ISLAND_WINGS = { recording = 64, transcribing = 96, done = 72, error = 84 } -- growth past each side, in points
local ISLAND_CORE = 16   -- empty center of the pill on screens with no notch
local ISLAND_BARS = 5
local ISLAND_HOLD = { done = 1.2, error = 1.6 } -- seconds a result stays before the pill closes
local RED = { red = 1, green = 0.27, blue = 0.23 }
local GREEN = { red = 0.19, green = 0.82, blue = 0.35 }

local island = {
  mode = "idle", rec = 0, proc = 0, done = 0, err = 0, level = 0, targetLevel = 0, levelAt = 0,
  recStart = 0, elapsed = 0, message = "", bands = {}, w = { x = 0, v = 0 }, h = { x = 0, v = 0 },
}
for i = 1, ISLAND_BARS do island.bands[i] = 0 end
local notchByScreen = {}
local screenWatcher = nil

local function clamp(x) return math.max(0, math.min(1, x)) end
local function nowSeconds() return hs.timer.absoluteTime() / 1e9 end
local function screenKey(x, w, h)
  return string.format("%d:%d:%d", math.floor(x + 0.5), math.floor(w + 0.5), math.floor(h + 0.5))
end

-- hs.screen does not expose the notch, so ask AppKit for each screen's safe area.
local function readNotches()
  notchByScreen = {}
  if not hs.osascript then return end
  local ok, result = hs.osascript.javascript([[
    ObjC.import("AppKit");
    var screens = $.NSScreen.screens, out = [];
    for (var i = 0; i < screens.count; i++) {
      var s = screens.objectAtIndex(i), f = s.frame;
      out.push([f.origin.x, f.size.width, f.size.height,
        s.auxiliaryTopLeftArea.size.width, s.auxiliaryTopRightArea.size.width,
        s.safeAreaInsets.top].join(","));
    }
    out.join(";");
  ]])
  if not ok or type(result) ~= "string" then return end
  for entry in result:gmatch("[^;]+") do
    local x, w, h, left, right, top = entry:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
    left, right = tonumber(left) or 0, tonumber(right) or 0
    if left > 0 and right > 0 then
      notchByScreen[screenKey(tonumber(x), tonumber(w), tonumber(h))] = {
        left = left, width = tonumber(w) - left - right, height = tonumber(top),
      }
    end
  end
end

local function islandGeometry(screen)
  local full = screen:fullFrame()
  local notch = notchByScreen[screenKey(full.x, full.w, full.h)]
  if notch then
    return { full = full, cx = notch.left + notch.width / 2, restW = notch.width, restH = notch.height,
             core = notch.width, height = notch.height }
  end
  local bar = screen:frame().y - full.y
  if bar < 20 then bar = 24 end -- auto-hidden menu bar
  return { full = full, cx = full.w / 2, restW = 0, restH = 0, core = ISLAND_CORE, height = bar + 6 }
end

local function spring(s, target, dt, stiffness, zeta)
  local damping = 2 * zeta * math.sqrt(stiffness)
  local steps = math.max(1, math.ceil(dt / 0.008))
  local h = dt / steps
  for _ = 1, steps do
    s.v = s.v + (stiffness * (target - s.x) - damping * s.v) * h
    s.x = s.x + s.v * h
  end
end

local function islandHide()
  if island.timer then island.timer:stop(); island.timer = nil end
  if island.canvas then island.canvas:hide() end
end

local function rgba(color, alpha)
  return { red = color.red, green = color.green, blue = color.blue, alpha = alpha }
end

local function islandLabel(elements, text, right, cy, alpha)
  table.insert(elements, {
    type = "text", frame = { x = right - 100, y = cy - 8, w = 100, h = 16 }, text = text,
    textFont = ".AppleSystemUIFontDemi", textSize = 12, textAlignment = "right",
    textColor = { white = 1, alpha = alpha },
  })
end

local function islandDraw(t)
  local g, canvas = island.geometry, island.canvas
  local W, H = math.max(0, island.w.x), math.max(0, island.h.x)
  local cw = canvas:frame().w
  local x0, x1, cy = cw / 2 - W / 2, cw / 2 + W / 2, H / 2
  local left, right = x0 + 20, x1 - 14
  local elements = {}
  if W > 1 and H > 1 then
    local r = math.min(14, H / 2)
    -- The rectangle starts above the screen edge, so only its bottom corners show.
    table.insert(elements, {
      type = "rectangle", action = "fill", fillColor = { white = 0, alpha = 1 },
      frame = { x = x0, y = -r, w = W, h = H + r }, roundedRectRadii = { xRadius = r, yRadius = r },
    })
    local open = clamp((W - g.restW) / 80)
    local a = open * clamp(math.max(island.rec, island.proc, island.done, island.err) * 1.3 - 0.15)
    if a > 0.02 then
      if island.rec > 0.01 then
        local blink = 0.5 + 0.5 * math.cos(t * 2 * math.pi)
        table.insert(elements, {
          type = "circle", action = "fill", center = { x = left - 2, y = cy }, radius = 4,
          fillColor = rgba(RED, a * island.rec * (0.55 + 0.45 * blink)),
        })
        local seconds = math.floor(island.elapsed)
        table.insert(elements, {
          type = "text", frame = { x = left + 8, y = cy - 8, w = 44, h = 16 },
          text = string.format("%d:%02d", seconds // 60, seconds % 60),
          textFont = ".AppleSystemUIFontDemi", textSize = 12, textColor = { white = 1, alpha = a * island.rec },
        })
        for i = 1, ISLAND_BARS do
          local bh = 3 + island.bands[i] * (H - 16)
          table.insert(elements, {
            type = "rectangle", action = "fill", fillColor = rgba(RED, a * island.rec),
            frame = { x = right - 6 - (i - 1) * 5, y = cy - bh / 2, w = 2.6, h = bh },
            roundedRectRadii = { xRadius = 1.3, yRadius = 1.3 },
          })
        end
      end
      if island.proc > 0.01 then
        local start = (t * 340) % 360
        table.insert(elements, {
          type = "arc", action = "stroke", arcRadii = false, center = { x = left, y = cy }, radius = 6,
          startAngle = start, endAngle = start + 250, strokeWidth = 1.8, strokeCapStyle = "round",
          strokeColor = { white = 1, alpha = a * island.proc },
        })
        islandLabel(elements, "Transcribing", right, cy, a * island.proc * 0.92)
      end
      if island.done > 0.01 then
        table.insert(elements, {
          type = "segments", action = "stroke", closed = false, strokeWidth = 2.2,
          strokeCapStyle = "round", strokeJoinStyle = "round", strokeColor = rgba(GREEN, a * island.done),
          coordinates = { { x = left - 5, y = cy + 0.5 }, { x = left - 1.5, y = cy + 4 }, { x = left + 5.5, y = cy - 3.5 } },
        })
        islandLabel(elements, "Pasted", right, cy, a * island.done * 0.92)
      end
      if island.err > 0.01 then
        for _, d in ipairs({ 1, -1 }) do
          table.insert(elements, {
            type = "segments", action = "stroke", closed = false, strokeWidth = 2, strokeCapStyle = "round",
            strokeColor = rgba(RED, a * island.err),
            coordinates = { { x = left - 4, y = cy - 4 * d }, { x = left + 4, y = cy + 4 * d } },
          })
        end
        islandLabel(elements, island.message, right, cy, a * island.err * 0.92)
      end
    end
  end
  -- replaceElements reads an empty list as one bad element, so draw nothing explicitly.
  if #elements == 0 then table.insert(elements, { type = "rectangle", action = "skip" }) end
  canvas:replaceElements(elements)
end

local function islandStep()
  local t = nowSeconds()
  local dt = math.min(0.05, t - (island.lastTick or t))
  island.lastTick = t
  local g = island.geometry
  local wing = ISLAND_WINGS[island.mode]
  spring(island.w, wing and (g.core + 2 * wing) or g.restW, dt, 260, 0.62)
  spring(island.h, wing and g.height or g.restH, dt, 260, 0.72)
  -- The old state fades out faster than the new one fades in, so labels never overlap.
  local fadeIn, fadeOut = 1 - math.exp(-dt * 12), 1 - math.exp(-dt * 40)
  for key, mode in pairs({ rec = "recording", proc = "transcribing", done = "done", err = "error" }) do
    local on = island.mode == mode
    island[key] = island[key] + ((on and 1 or 0) - island[key]) * (on and fadeIn or fadeOut)
  end
  if island.mode == "recording" then island.elapsed = t - island.recStart end
  local target = (island.mode == "recording" and t - island.levelAt < 0.25) and island.targetLevel or 0
  island.level = island.level + (target - island.level) * (1 - math.exp(-dt * 18))
  for i = 1, ISLAND_BARS do
    local wobble = math.abs(math.sin(t * (5.3 + i * 1.37) + i * 1.9) * math.cos(t * (2.1 + i * 0.71)))
    local bandTarget = island.level * (0.4 + 0.6 * wobble)
    island.bands[i] = island.bands[i] + (bandTarget - island.bands[i]) * (1 - math.exp(-dt * 20))
  end
  islandDraw(t)
  local settled = math.abs(island.w.x - g.restW) < 0.5 and math.abs(island.w.v) < 2
    and math.abs(island.h.x - g.restH) < 0.5
  if not wing and settled then islandHide() end
end

local function islandOpen()
  local screen = (hs.mouse and hs.mouse.getCurrentScreen()) or hs.screen.mainScreen()
  if not screen then return end
  local g = islandGeometry(screen)
  local same = island.canvas and island.timer and island.geometry
    and screenKey(island.geometry.full.x, island.geometry.full.w, island.geometry.full.h)
      == screenKey(g.full.x, g.full.w, g.full.h)
  if not same then
    local width = g.core + 2 * ISLAND_WINGS.transcribing + 40
    if island.canvas then island.canvas:delete() end
    island.canvas = hs.canvas.new({ x = g.full.x + g.cx - width / 2, y = g.full.y, w = width, h = g.height + 20 })
    island.canvas:level(hs.canvas.windowLevels.overlay)
    island.canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
    island.w = { x = g.restW, v = 0 }
    island.h = { x = g.restH, v = 0 }
    island.geometry = g
  end
  island.canvas:show()
  if not island.timer then
    island.lastTick = nil
    island.timer = hs.timer.doEvery(1 / 60, islandStep)
  end
end

local function islandSetMode(mode, message)
  if island.holdTimer then island.holdTimer:stop(); island.holdTimer = nil end
  if mode == "recording" then
    island.recStart, island.elapsed, island.targetLevel = nowSeconds(), 0, 0
  end
  island.mode = mode
  island.message = message or island.message
  if not hs.canvas or not getSetting("notchIsland", true) then return end
  -- Later states reuse the pill this dictation opened, on the same screen.
  if mode == "recording" then islandOpen() end
  if ISLAND_HOLD[mode] then
    island.holdTimer = hs.timer.doAfter(ISLAND_HOLD[mode], function()
      if island.mode == mode then island.mode = "idle" end
    end)
  end
end

-- Recorder levels arrive as RMS (0–1). Room noise sits near -50 dB and close
-- speech near -15 dB, so map that range onto the bars.
local function islandLevel(rms)
  local db = 20 * math.log(math.max(rms or 0, 1e-6), 10)
  island.targetLevel = clamp((db + 50) / 35)
  island.levelAt = nowSeconds()
end

-- One place for every phase change the user should see and hear.
local function signal(transition, message)
  if transition == "start" then islandSetMode("recording")
  elseif transition == "stop" then islandSetMode("transcribing")
  elseif transition == "done" then islandSetMode("done")
  else islandSetMode("error", message or "Failed") end
  playSound(transition)
end

-- A fake dictation with simulated speech levels, so the island and the current
-- sound pack can be tried together without recording or pasting anything.
local demoTimers = {}
local function previewDictation()
  for _, timer in ipairs(demoTimers) do timer:stop() end
  demoTimers = {}
  signal("start")
  local nextChange, rms = 0, 0
  local levels = hs.timer.doEvery(1 / 30, function()
    local t = nowSeconds()
    if t > nextChange then
      local pause = math.random() < 0.2
      rms = pause and 0.003 or (0.01 + math.random() * 0.14)
      nextChange = t + (pause and 0.3 or (0.08 + math.random() * 0.17))
    end
    islandLevel(rms)
  end)
  table.insert(demoTimers, levels)
  table.insert(demoTimers, hs.timer.doAfter(3, function()
    levels:stop()
    signal("stop")
  end))
  table.insert(demoTimers, hs.timer.doAfter(4.4, function() signal("done") end))
end

readNotches()
if hs.screen and hs.screen.watcher then
  screenWatcher = hs.screen.watcher.new(readNotches)
  screenWatcher:start()
end

-- Paste transcribed text into the focused field. The transcript stays on the
-- clipboard, so the text survives when the paste lands in a window with no
-- focused text field.
local function typeText(text)
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then hs.alert.show("… no speech"); return false end
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({"cmd"}, "v")
  return true
end

local function transcribe(path)
  if not serverReady then
    phase = "warming"
    setIcon("⏳")
    hs.alert.show("Whisper is restarting — try again in a moment")
    signal("error", "Restarting")
    return
  end

  transcriptionStartedNs = hs.timer.absoluteTime()
  transcriptionTask = hs.task.new(CURL, function(code, stdout, stderr)
    local completedNs = hs.timer.absoluteTime()
    lastMetrics.transcription_ms = (completedNs - transcriptionStartedNs) / 1000000
    if stopRequestedNs then
      lastMetrics.stop_to_text_ms = (completedNs - stopRequestedNs) / 1000000
    end
    transcriptionTask = nil
    if code ~= 0 then
      hs.alert.show("Whisper transcription failed")
      print(stderr)
      -- The most common cause is a dead server; re-enter the health-poll loop
      -- so a launchd-restarted server is adopted without a config reload.
      resetServer()
      signal("error", "Failed")
      return
    end
    if recorderReady and serverReady then
      phase = "ready"
      setIcon("🎙")
    else
      phase = "warming"
      setIcon("⏳")
    end
    if typeText(stdout) then signal("done") else signal("error", "No speech") end
  end, {
    "-sS", "--fail-with-body",
    "-F", "file=@" .. path,
    "-F", "response_format=text",
    "-F", "language=" .. LANG,
    SERVER_URL .. "/inference",
  })
  transcriptionTask:start()
end

local function handleRecorderEvent(event)
  if event.event == "ready" then
    recorderReady = true
    recorderRetries = 0
    microphoneActive = event.microphone_active == true
    lastMetrics.recorder_backend = event.backend
    lastMetrics.sample_rate = event.sample_rate
    refreshReadyState(true)
  elseif event.event == "started" then
    microphoneActive = event.microphone_active == true
    lastMetrics.capture_first_buffer_ms = event.command_to_first_buffer_ms
  elseif event.event == "stopped" then
    microphoneActive = event.microphone_active == true
    lastMetrics.wav_finalize_ms = event.command_to_wav_ms
    lastMetrics.wav_write_ms = event.wav_write_ms
    lastMetrics.microphone_release_ms = event.microphone_release_ms
    lastMetrics.samples = event.samples
    transcribe(event.path or WAV)
  elseif event.event == "level" then
    islandLevel(event.rms)
  elseif event.event == "error" then
    local wasDictating = phase == "recording" or phase == "transcribing"
    recorderReady = false
    microphoneActive = false
    phase = "warming"
    setIcon("⏳")
    if wasDictating then signal("error", "Mic error") end
    print("Recorder error: " .. tostring(event.message or "unknown error"))
  end
end

local function consumeRecorderOutput(chunk)
  recorderOutput = recorderOutput .. (chunk or "")
  while true do
    local newline = recorderOutput:find("\n", 1, true)
    if not newline then return end
    local line = recorderOutput:sub(1, newline - 1)
    recorderOutput = recorderOutput:sub(newline + 1)
    if line ~= "" then
      local ok, event = pcall(hs.json.decode, line)
      if ok and event then handleRecorderEvent(event) end
    end
  end
end

local function startRecorder()
  recorderOutput = ""
  local arguments = {}
  if MIC then
    table.insert(arguments, "--device")
    table.insert(arguments, MIC:gsub("^:", ""))
  end

  recorderTask = hs.task.new(RECORDER, function(code, stdout, stderr)
    recorderTask = nil
    recorderReady = false
    if not shuttingDown then
      if phase == "recording" or phase == "transcribing" then signal("error", "Mic error") end
      phase = "warming"
      setIcon("⏳")
      recorderRetries = recorderRetries + 1
      local retryDelay = math.min(5, 0.5 * (2 ^ (recorderRetries - 1)))
      if recorderRetries == 3 then
        hs.alert.show("Recorder is retrying — check Hammerspoon Microphone permission")
      end
      if stderr and stderr ~= "" then print(stderr) end
      hs.timer.doAfter(retryDelay, startRecorder)
    end
  end, function(_, stdout, stderr)
    consumeRecorderOutput(stdout)
    if stderr and stderr ~= "" then print(stderr) end
    return true
  end, arguments)
  recorderTask:start()
end

local pollServer
pollServer = function(generation)
  if shuttingDown or serverReady or generation ~= serverPollGeneration then return end
  hs.http.asyncGet(SERVER_URL .. "/health", nil, function(status)
    if generation ~= serverPollGeneration then return end
    if status == 200 then
      serverReady = true
      refreshReadyState(true)
    else
      hs.timer.doAfter(0.25, function() pollServer(generation) end)
    end
  end)
end

local function watchServer()
  serverPollGeneration = serverPollGeneration + 1
  pollServer(serverPollGeneration)
end

-- The server stopped answering. Drop back to warming and poll until launchd
-- restarts it (issue #4: an adopted server was never watched before).
resetServer = function()
  serverReady = false
  phase = "warming"
  setIcon("⏳")
  watchServer()
end

-- Catch a server that dies while dictation is idle, so the next dictation
-- does not have to fail once before recovery starts.
serverWatchdog = hs.timer.doEvery(10, function()
  if shuttingDown or not serverReady or phase ~= "ready" then return end
  local generation = serverPollGeneration
  hs.http.asyncGet(SERVER_URL .. "/health", nil, function(status)
    if shuttingDown or not serverReady or generation ~= serverPollGeneration then return end
    if status ~= 200 then resetServer() end
  end)
end)

local function startRecording()
  if phase ~= "ready" then
    hs.alert.show(statusText())
    playSound("error")
    return
  end
  phase = "recording"
  setIcon("🔴")
  signal("start")
  recorderTask:setInput("START " .. WAV .. "\n")
end

local function stopRecording()
  if phase ~= "recording" then return end
  phase = "transcribing"
  setIcon("⏳")
  signal("stop")
  stopRequestedNs = hs.timer.absoluteTime()
  recorderTask:setInput("STOP\n")
end

-- ---- welcome popup ------------------------------------------------------------
-- Shown once, on the first press of the dictation key after this version is
-- installed. F5 or "Start dictating" closes it and starts recording; Esc or
-- "Close" only closes it. The window never takes focus, so the text field the
-- user was in keeps it.
local ONBOARDING_VERSION = 1
local ONBOARDING_HTML = [==[
<!doctype html><html><head><meta charset="utf-8"><style>
html, body { margin: 0; background: transparent; -webkit-user-select: none; cursor: default;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }
body { display: flex; justify-content: center; padding-top: 24px; }
.card { width: 380px; border-radius: 28px; background: #fffdf8; color: #2b1d10; padding: 12px 12px 18px; box-sizing: border-box;
  box-shadow: 0 0 0 0.5px rgba(80,50,20,.12), 0 30px 60px -20px rgba(90,55,20,.55);
  animation: cardIn 420ms cubic-bezier(.34,1.3,.64,1) backwards; transition: opacity 180ms ease, transform 180ms ease; }
.card.out { opacity: 0; transform: scale(.97); }
@keyframes cardIn { from { opacity: 0; transform: translateY(16px) scale(.95) rotate(-1.2deg); } }
.scene { position: relative; height: 120px; border-radius: 18px; overflow: hidden;
  background: radial-gradient(80% 90% at 20% 100%, #ffb36b, transparent 60%), radial-gradient(70% 80% at 90% 0%, #7a5cff, transparent 60%), linear-gradient(160deg, #3b2a6b, #e0735a); }
.mb { position: absolute; inset: 0 0 auto; height: 20px; background: rgba(0,0,0,.15); }
.isl { position: absolute; top: 0; left: 50%; width: 220px; height: 26px; transform: translateX(-50%);
  background: #000; border-radius: 0 0 14px 14px; overflow: hidden; animation: islW 7s cubic-bezier(.32,.72,0,1) infinite; }
.isl > div { position: absolute; inset: 0; display: flex; align-items: center; justify-content: space-between; padding: 0 12px;
  font-size: 11px; font-weight: 600; color: #fff; white-space: nowrap; }
.rec { animation: islRec 7s ease infinite; }
.rec .l { display: flex; gap: 6px; align-items: center; font-variant-numeric: tabular-nums; }
.rec .l i { width: 7px; height: 7px; border-radius: 50%; background: #ff453a; }
.bars { display: flex; gap: 2px; align-items: center; height: 14px; }
.bars span { width: 2.5px; border-radius: 2px; background: #ff453a; height: 6px; animation: bar 520ms ease-in-out infinite alternate; }
.bars span:nth-child(1) { height: 5px; } .bars span:nth-child(2) { height: 11px; animation-delay: -120ms; }
.bars span:nth-child(3) { height: 8px; animation-delay: -300ms; } .bars span:nth-child(4) { height: 13px; animation-delay: -60ms; }
.bars span:nth-child(5) { height: 6px; animation-delay: -420ms; }
.busy, .done { justify-content: center !important; gap: 6px; opacity: 0; }
.busy { animation: islBusy 7s ease infinite; } .done { animation: islDone 7s ease infinite; }
.spin { width: 11px; height: 11px; border-radius: 50%; border: 2px solid rgba(255,255,255,.25); border-top-color: #fff; box-sizing: border-box; animation: spin 800ms linear infinite; }
.field { position: absolute; left: 50%; bottom: 16px; transform: translateX(-50%); width: 250px; height: 34px; border-radius: 9px; box-sizing: border-box;
  background: rgba(255,255,255,.88); color: #1d1d1f; font-size: 13px; display: flex; align-items: center; padding: 0 12px; gap: 1px; }
.field .txt { animation: islText 7s ease infinite; }
.field .caret { width: 1.5px; height: 15px; background: #0a84ff; }
h3 { margin: 16px 8px 10px; font-size: 18px; font-weight: 700; letter-spacing: -0.015em; }
ul { list-style: none; margin: 0 8px; padding: 0; display: grid; gap: 8px; }
li { display: flex; gap: 10px; align-items: center; font-size: 14px; color: #4a3a2a; }
li .b { width: 22px; height: 22px; border-radius: 7px; flex: none; display: grid; place-items: center; font-size: 12px; font-weight: 600; }
kbd { font: 600 12px -apple-system, BlinkMacSystemFont, sans-serif; padding: 1px 6px; border-radius: 5px; white-space: nowrap; background: #f1e8da; color: #2b1d10; }
.foot { display: flex; align-items: center; gap: 12px; margin: 16px 8px 0; }
.go { white-space: nowrap; font: 600 14px -apple-system, BlinkMacSystemFont, sans-serif; color: #fff; background: #ff3b30; border: 0; border-radius: 999px; padding: 9px 18px; cursor: pointer; }
.go:active { transform: scale(.97); }
.close { font: 500 13px -apple-system, BlinkMacSystemFont, sans-serif; color: #9a8670; background: none; border: 0; padding: 6px; cursor: pointer; }
.hint { margin: 12px 8px 0; font-size: 11.5px; color: #9a8670; }
@keyframes islW { 0%, 12% { width: 120px; } 18%, 55% { width: 220px; } 60%, 78% { width: 150px; } 82%, 95% { width: 170px; } 100% { width: 120px; } }
@keyframes islRec { 0%, 15% { opacity: 0; } 20%, 54% { opacity: 1; } 57%, 100% { opacity: 0; } }
@keyframes islBusy { 0%, 57% { opacity: 0; } 61%, 77% { opacity: 1; } 80%, 100% { opacity: 0; } }
@keyframes islDone { 0%, 80% { opacity: 0; } 84%, 94% { opacity: 1; } 98%, 100% { opacity: 0; } }
@keyframes islText { 0%, 82% { opacity: 0; } 86%, 97% { opacity: 1; } 100% { opacity: 0; } }
@keyframes bar { from { transform: scaleY(.45); } to { transform: scaleY(1.1); } }
@keyframes spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  .card { animation: fade 160ms ease-out backwards; } .card * { animation: none !important; }
  .rec { opacity: 1; } @keyframes fade { from { opacity: 0; } }
}
</style></head><body>
<div class="card">
  <div class="scene">
    <div class="mb"></div>
    <div class="isl">
      <div class="rec"><span class="l"><i></i>0:04</span><span class="bars"><span></span><span></span><span></span><span></span><span></span></span></div>
      <div class="busy"><span class="spin"></span>Transcribing</div>
      <div class="done"><svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke="#30d158" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 6.5l2.5 2.5L10 3.5"/></svg>Pasted</div>
    </div>
    <div class="field"><span class="txt">Pick up oat milk on the way</span><span class="caret"></span></div>
  </div>
  <h3>Your notch now listens back.</h3>
  <ul>
    <li><span class="b" style="background:#ffe3df;color:#d70015">●</span><span><kbd>F5</kbd> to talk, <kbd>F5</kbd> again to stop.</span></li>
    <li><span class="b" style="background:#e6f0ff;color:#0060df">I</span>Text lands wherever your cursor is.</li>
    <li><span class="b" style="background:#efe6ff;color:#6b3fd4">⌘</span><span>Your last transcript stays on the clipboard.</span></li>
    <li><span class="b" style="background:#fff0d9;color:#b25e00">♪</span>A short sound on start, stop and paste.</li>
    <li><span class="b" style="background:#e3f6e8;color:#1a7f37">✓</span>Everything stays on your Mac.</li>
  </ul>
  <div class="foot">
    <button class="go" type="button" id="go">Start dictating</button>
    <button class="close" type="button" id="close">Close</button>
  </div>
  <p class="hint">Pick sounds or turn them off in the 🎙 menu.</p>
</div>
<script>
function post(message) { try { webkit.messageHandlers.hark.postMessage(message); } catch (e) {} }
function closeCard() { document.querySelector(".card").classList.add("out"); }
document.getElementById("go").addEventListener("click", function () { post("start"); });
document.getElementById("close").addEventListener("click", function () { post("close"); });
</script>
</body></html>
]==]

local onboarding = nil

local function onboardingPending()
  return hs.webview ~= nil and getSetting("onboardingVersion", 0) < ONBOARDING_VERSION
end

local function closeOnboarding(startAfter)
  local current = onboarding
  if not current then return end
  onboarding = nil
  setSetting("onboardingVersion", ONBOARDING_VERSION)
  current.escape:delete()
  current.view:evaluateJavaScript("closeCard()")
  current.cleanup = hs.timer.doAfter(0.2, function() current.view:delete() end)
  if startAfter then startRecording() end
end

local function showOnboarding()
  if onboarding or not hs.webview then return end
  local screen = (hs.mouse and hs.mouse.getCurrentScreen()) or hs.screen.mainScreen()
  local f = screen:frame()
  local w, h = 440, 520
  local content = hs.webview.usercontent.new("hark")
  content:setCallback(function(message)
    if message.body == "start" then closeOnboarding(true)
    elseif message.body == "close" then closeOnboarding(false) end
  end)
  local view = hs.webview.new({ x = f.x + (f.w - w) / 2, y = f.y + (f.h - h) / 2 - 40, w = w, h = h },
    { developerExtrasEnabled = false }, content)
  view:windowStyle({ "borderless", "nonactivating" })
  view:transparent(true)
  view:allowTextEntry(false)
  view:level(hs.canvas.windowLevels.modalPanel)
  view:behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary" })
  view:html(ONBOARDING_HTML)
  view:show()
  onboarding = {
    view = view, content = content,
    escape = hs.hotkey.bind({}, "escape", function() closeOnboarding(false) end),
  }
end

local function toggle()
  if onboarding then closeOnboarding(true); return end
  if phase ~= "recording" and onboardingPending() then showOnboarding(); return end
  if phase == "recording" then stopRecording() else startRecording() end
end

for _, hotkey in ipairs(HOTKEYS) do
  hs.hotkey.bind(hotkey[1], hotkey[2], toggle)
end

-- ---- updates ------------------------------------------------------------------
-- "Check for Updates…" is the only thing that goes past 127.0.0.1: it asks
-- GitHub for the latest release. The update runs `hark update` detached,
-- because the installer restarts Hammerspoon. The next load says how it went.
local RELEASES_URL = "https://api.github.com/repos/bath/hark-stt/releases/latest"
local UPDATE_LOG = "/tmp/hark-update.log"
local updateState = nil -- nil, "checking" or "updating"

local function isNewer(latest, current)
  local a, b = {}, {}
  for n in latest:gmatch("%d+") do table.insert(a, tonumber(n)) end
  for n in current:gmatch("%d+") do table.insert(b, tonumber(n)) end
  for i = 1, math.max(#a, #b) do
    if (a[i] or 0) ~= (b[i] or 0) then return (a[i] or 0) > (b[i] or 0) end
  end
  return false
end

local function updateFailed()
  updateState = nil
  setSetting("updateFrom", "")
  if hs.dialog.blockAlert("The Hark update failed", "The log is in " .. UPDATE_LOG .. ".", "Show Log", "OK") == "Show Log" then
    hs.execute("open -t '" .. UPDATE_LOG .. "'")
  end
end

local function startUpdate(latest)
  if phase == "recording" or phase == "transcribing" then
    hs.alert.show("Finish the dictation, then update")
    return
  end
  updateState = "updating"
  setSetting("updateFrom", VERSION)
  hs.alert.show("Updating Hark to " .. latest .. ". Hammerspoon restarts when it is done.", 4)
  hs.task.new("/bin/bash", nil, { "-c",
    "export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin; "
    .. "(nohup '" .. HARK_DIR .. "/bin/hark' update >'" .. UPDATE_LOG .. "' 2>&1 </dev/null"
    .. " || open -g hammerspoon://harkUpdateFailed) &" }):start()
end

local function checkForUpdates()
  if updateState then return end
  updateState = "checking"
  local headers = { ["Accept"] = "application/vnd.github+json", ["User-Agent"] = "Hark/" .. VERSION }
  hs.http.asyncGet(RELEASES_URL, headers, function(status, body)
    updateState = nil
    local ok, release = pcall(hs.json.decode, body or "")
    local latest = status == 200 and ok and type(release) == "table" and type(release.tag_name) == "string"
      and (release.tag_name:gsub("^v", "")) or nil
    if not latest then
      hs.dialog.blockAlert("Could not check for updates",
        "GitHub did not answer (HTTP " .. tostring(status) .. "). Try again later.")
    elseif isNewer(latest, VERSION) then
      local answer = hs.dialog.blockAlert("Hark " .. latest .. " is available",
        "You have " .. VERSION .. ". The update takes about a minute, and Hammerspoon restarts at the end.",
        "Update", "Later")
      if answer == "Update" then startUpdate(latest) end
    else
      hs.dialog.blockAlert("Hark is up to date", "Version " .. VERSION .. " is the latest.")
    end
  end)
end

if hs.urlevent then hs.urlevent.bind("harkUpdateFailed", updateFailed) end

local updatedFrom = getSetting("updateFrom", "")
if updatedFrom ~= "" then
  setSetting("updateFrom", "")
  if updatedFrom ~= VERSION then hs.alert.show("Hark updated to " .. VERSION, 4) end
end

local function soundMenu()
  local current = getSetting("soundPack", defaultSoundPack)
  local items = {
    { title = "Off", checked = soundPackById[current] == nil, fn = function() setSetting("soundPack", "off") end },
    { title = "-" },
  }
  if #soundPacks == 0 then
    table.insert(items, { title = "No sounds installed (run install.sh)", disabled = true })
  end
  for _, pack in ipairs(soundPacks) do
    table.insert(items, {
      title = pack.name, checked = pack.id == current, tooltip = pack.description,
      fn = function() setSetting("soundPack", pack.id); previewSounds() end,
    })
  end
  table.insert(items, { title = "-" })
  local volume = getSetting("soundVolume", 0.6)
  for _, level in ipairs({ 0.25, 0.4, 0.6, 0.8, 1.0 }) do
    table.insert(items, {
      title = string.format("Volume %d%%", math.floor(level * 100 + 0.5)),
      checked = math.abs(volume - level) < 0.01,
      fn = function() setSetting("soundVolume", level); playSound("done") end,
    })
  end
  table.insert(items, { title = "-" })
  table.insert(items, { title = "Preview current sounds", fn = previewSounds })
  return items
end

if menu then
  menu:setMenu(function()
    local islandOn = getSetting("notchIsland", true)
    return {
      { title = "Status: " .. statusText(), disabled = true },
      { title = "Toggle dictation", fn = toggle },
      { title = "-" },
      { title = "Notch Island", checked = islandOn, fn = function()
        setSetting("notchIsland", not islandOn)
        if islandOn then islandHide() end
      end },
      { title = "Sound", menu = soundMenu() },
      { title = "Preview animation and sounds", disabled = phase ~= "ready", fn = previewDictation },
      { title = "Show welcome screen", fn = showOnboarding },
      { title = "-" },
      { title = "Hark " .. VERSION, disabled = true },
      { title = updateState == "checking" and "Checking for Updates…"
          or updateState == "updating" and "Updating…" or "Check for Updates…",
        disabled = updateState ~= nil, fn = checkForUpdates },
      { title = "-" },
      { title = "Reload Hammerspoon config", fn = function() hs.reload() end },
    }
  end)
end

local previousShutdownCallback = hs.shutdownCallback
hs.shutdownCallback = function()
  shuttingDown = true
  if recorderTask then
    recorderTask:setStreamingCallback(nil)
    recorderTask:setCallback(nil)
    recorderTask:setInput("QUIT\n")
  end
  if serverWatchdog then serverWatchdog:stop() end
  if statusTimer then statusTimer:stop() end
  islandHide()
  if island.canvas then island.canvas:delete() end
  if screenWatcher then screenWatcher:stop() end
  if onboarding then onboarding.view:delete() end
  if previousShutdownCallback then previousShutdownCallback() end
end

-- `hark doctor` reads this file instead of talking to Hammerspoon over IPC.
-- Test fakes have no accessibilityState, so they never write it.
local function writeStatus()
  if not hs.accessibilityState or not hs.json.write then return end
  hs.json.write({
    version = VERSION,
    phase = phase,
    recorder_ready = recorderReady,
    server_ready = serverReady,
    microphone_active = microphoneActive,
    accessibility = hs.accessibilityState(false),
    microphone = hs.microphoneState and hs.microphoneState(false) or false,
    updated = os.time(),
  }, STATUS_FILE, true, true)
end
writeStatus()
statusTimer = hs.timer.doEvery(5, writeStatus)

startRecorder()
watchServer()

return {
  version = VERSION,
  toggle = toggle,
  preview = previewDictation,
  welcome = showOnboarding,
  checkForUpdates = checkForUpdates,
  status = function() return phase end,
  diagnostics = function()
    return {
      phase = phase,
      recorder_ready = recorderReady,
      server_ready = serverReady,
      microphone_active = microphoneActive,
      last_metrics = lastMetrics,
    }
  end,
}
