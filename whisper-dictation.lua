-- whisper-dictation.lua — private, low-latency local dictation for macOS.
--
-- A persistent native helper prepares a stopped Core Audio HAL input unit, and
-- a local whisper-server keeps the Whisper model loaded. The microphone remains
-- inactive until the start hotkey, then releases again before transcription.
--
-- whisper-server is owned by launchd (LaunchAgent com.whisper-dictation.server,
-- installed by install.sh) with KeepAlive, so it restarts on its own if it dies.
-- This module never launches the server; it polls /health and reconnects.

-- ---- config -----------------------------------------------------------------
local HOME           = os.getenv("HOME")
local RECORDER       = HOME .. "/.hammerspoon/bin/whisper-recorder"
local CURL           = "/usr/bin/curl"
local MIC            = nil -- nil = built-in Mac mic; or an exact name such as ":Studio Display Microphone"
local LANG           = "en"
local WAV            = "/tmp/whisper-dictate.wav"
local SERVER_HOST    = "127.0.0.1"
local SERVER_PORT    = 8178
local SOUND_DIR      = HOME .. "/.hammerspoon/whisper-sounds" -- built by sounds/generate.py
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
    if showAlert then hs.alert.show("Local Whisper dictation ready") end
  end
end

-- ---- settings ---------------------------------------------------------------
local SETTINGS_PREFIX = "whisperDictation."

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
-- dot and a timer on the left, voice bars on the right, a spinner while
-- transcribing. A screen with no notch gets the same pill dropping from the
-- top center. It appears on the screen of the focused window.
local ISLAND_WING = 64   -- how far the pill grows past each side of the notch, in points
local ISLAND_CORE = 64   -- empty center of the pill on screens with no notch
local ISLAND_BARS = 5
local RED = { red = 1, green = 0.27, blue = 0.23 }

local island = {
  mode = "idle", rec = 0, proc = 0, level = 0, targetLevel = 0, levelAt = 0,
  recStart = 0, elapsed = 0, bands = {}, w = { x = 0, v = 0 }, h = { x = 0, v = 0 },
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

local function islandDraw(t)
  local g, canvas = island.geometry, island.canvas
  local W, H = math.max(0, island.w.x), math.max(0, island.h.x)
  local cw = canvas:frame().w
  local x0, x1, cy = cw / 2 - W / 2, cw / 2 + W / 2, H / 2
  local elements = {}
  if W > 1 and H > 1 then
    local r = math.min(14, H / 2)
    -- The rectangle starts above the screen edge, so only its bottom corners show.
    table.insert(elements, {
      type = "rectangle", action = "fill", fillColor = { white = 0, alpha = 1 },
      frame = { x = x0, y = -r, w = W, h = H + r }, roundedRectRadii = { xRadius = r, yRadius = r },
    })
    local act = math.max(island.rec, island.proc)
    local alpha = clamp((W - g.restW) / (ISLAND_WING * 1.6)) * clamp(act * 1.3 - 0.15)
    if alpha > 0.02 then
      if island.rec > 0.01 then
        local blink = 0.5 + 0.5 * math.cos(t * 2 * math.pi)
        table.insert(elements, {
          type = "circle", action = "fill", center = { x = x0 + 18, y = cy }, radius = 4,
          fillColor = { red = RED.red, green = RED.green, blue = RED.blue, alpha = alpha * island.rec * (0.55 + 0.45 * blink) },
        })
        local seconds = math.floor(island.elapsed)
        table.insert(elements, {
          type = "text", frame = { x = x0 + 28, y = cy - 8, w = 44, h = 16 },
          text = string.format("%d:%02d", seconds // 60, seconds % 60),
          textFont = ".AppleSystemUIFontDemi", textSize = 12,
          textColor = { white = 1, alpha = alpha * island.rec },
        })
      end
      if island.proc > 0.01 then
        local start = (t * 340) % 360
        table.insert(elements, {
          type = "arc", action = "stroke", arcRadii = false, center = { x = x0 + 20, y = cy }, radius = 6,
          startAngle = start, endAngle = start + 250, strokeWidth = 1.8, strokeCapStyle = "round",
          strokeColor = { white = 1, alpha = alpha * island.proc },
        })
      end
      local mix = island.proc / (island.rec + island.proc + 1e-4)
      local color = {
        red = RED.red + (1 - RED.red) * mix, green = RED.green + (1 - RED.green) * mix,
        blue = RED.blue + (1 - RED.blue) * mix, alpha = alpha,
      }
      for i = 1, ISLAND_BARS do
        local live = 3 + island.bands[i] * (H - 16)
        local wave = 3 + 5 * (0.5 + 0.5 * math.sin(t * 6 - i))
        local bh = live * (1 - mix) + wave * mix
        table.insert(elements, {
          type = "rectangle", action = "fill", fillColor = color,
          frame = { x = x1 - 20 - (i - 1) * 5, y = cy - bh / 2, w = 2.6, h = bh },
          roundedRectRadii = { xRadius = 1.3, yRadius = 1.3 },
        })
      end
    end
  end
  canvas:replaceElements(elements)
end

local function islandStep()
  local t = nowSeconds()
  local dt = math.min(0.05, t - (island.lastTick or t))
  island.lastTick = t
  local g = island.geometry
  local active = island.mode ~= "idle"
  spring(island.w, active and (g.core + 2 * ISLAND_WING) or g.restW, dt, 260, 0.62)
  spring(island.h, active and g.height or g.restH, dt, 260, 0.72)
  local ease = 1 - math.exp(-dt * 9)
  island.rec = island.rec + ((island.mode == "recording" and 1 or 0) - island.rec) * ease
  island.proc = island.proc + ((island.mode == "transcribing" and 1 or 0) - island.proc) * ease
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
  if not active and settled then islandHide() end
end

local function islandOpen()
  local screen = hs.screen.mainScreen()
  if not screen then return false end
  local g = islandGeometry(screen)
  local width = g.core + 2 * ISLAND_WING + 40
  local frame = { x = g.full.x + g.cx - width / 2, y = g.full.y, w = width, h = g.height + 20 }
  local reuse = island.canvas and island.timer and island.geometry
    and screenKey(island.geometry.full.x, island.geometry.full.w, island.geometry.full.h)
      == screenKey(g.full.x, g.full.w, g.full.h)
  if not reuse then
    if island.canvas then island.canvas:delete() end
    island.canvas = hs.canvas.new(frame)
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
  return true
end

local function islandSetMode(mode)
  local t = hs.timer.absoluteTime() / 1e9
  if mode == "recording" then
    island.recStart, island.elapsed, island.targetLevel = t, 0, 0
  end
  island.mode = mode
  if not hs.canvas or not getSetting("notchIsland", true) then return end
  if mode ~= "idle" then islandOpen() end
end

-- Recorder levels arrive as RMS (0–1). Room noise sits near -50 dB and close
-- speech near -15 dB, so map that range onto the bars.
local function islandLevel(rms)
  local db = 20 * math.log(math.max(rms or 0, 1e-6), 10)
  island.targetLevel = clamp((db + 50) / 35)
  island.levelAt = nowSeconds()
end

-- One place for every phase change the user should see and hear.
local function signal(transition)
  if transition == "start" then islandSetMode("recording")
  elseif transition == "stop" then islandSetMode("transcribing")
  else islandSetMode("idle") end
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
    signal("error")
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
      signal("error")
      return
    end
    if recorderReady and serverReady then
      phase = "ready"
      setIcon("🎙")
    else
      phase = "warming"
      setIcon("⏳")
    end
    signal(typeText(stdout) and "done" or "error")
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
    if wasDictating then signal("error") end
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
      if phase == "recording" or phase == "transcribing" then signal("error") end
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

local function toggle()
  if phase == "recording" then stopRecording() else startRecording() end
end

for _, hotkey in ipairs(HOTKEYS) do
  hs.hotkey.bind(hotkey[1], hotkey[2], toggle)
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
  islandHide()
  if island.canvas then island.canvas:delete() end
  if screenWatcher then screenWatcher:stop() end
  if previousShutdownCallback then previousShutdownCallback() end
end

startRecorder()
watchServer()

return {
  toggle = toggle,
  preview = previewDictation,
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
