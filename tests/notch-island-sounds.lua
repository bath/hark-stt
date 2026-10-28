-- Hammerspoon regression test for the Notch Island animation and the sounds
-- that play at each dictation transition.
-- Run from the Hammerspoon Console:
--   dofile("/absolute/path/to/tests/notch-island-sounds.lua")

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local repoRoot = scriptPath:match("^(.*)/tests/[^/]+$")
local soundDir = os.getenv("HOME") .. "/.hammerspoon/hark/sounds"

local clock = 1000000000
local played = {}
local settings = {}
local canvases = {}
local islandTick = nil
local islandTimer = nil
local recorderStream = nil
local transcript = "test transcript"
local pendingCurl = nil
local pendingTimers = {}
local mouseScreen = nil

local function fakeCanvas(frame)
  local canvas = { shown = false, deleted = false, elements = {} }
  function canvas:frame() return frame end
  function canvas:level() return canvas end
  function canvas:behaviorAsLabels() return canvas end
  function canvas:show() canvas.shown = true; return canvas end
  function canvas:hide() canvas.shown = false; return canvas end
  function canvas:delete() canvas.deleted = true end
  function canvas:replaceElements(elements) canvas.elements = elements; return canvas end
  table.insert(canvases, canvas)
  return canvas
end

local builtIn = {
  fullFrame = function() return { x = 0, y = 0, w = 2056, h = 1329 } end,
  frame = function() return { x = 0, y = 39, w = 2056, h = 1197 } end,
}
local external = {
  fullFrame = function() return { x = 941, y = -1080, w = 1920, h = 1080 } end,
  frame = function() return { x = 941, y = -1055, w = 1920, h = 1055 } end,
}
mouseScreen = builtIn

local fakeHs = {
  alert = { show = function() end },
  eventtap = { keyStroke = function() end },
  hotkey = { bind = function() end },
  http = { asyncGet = function(_, _, callback) callback(200, "ok", {}) end },
  json = {
    decode = hs.json.decode,
    read = function()
      return {
        default = "pop",
        packs = {
          { id = "pop", name = "Pop", files = {
            start = "pop/start.wav", stop = "pop/stop.wav", done = "pop/done.wav", error = "pop/error.wav" } },
          { id = "mac-classic", name = "macOS Classic", files = { start = "/System/Library/Sounds/Tink.aiff" } },
        },
      }
    end,
  },
  menubar = { new = function() return { setMenu = function() end, setTitle = function() end } end },
  pasteboard = { getContents = function() end, setContents = function() end },
  settings = {
    get = function(key) return settings[key] end,
    set = function(key, value) settings[key] = value end,
  },
  sound = {
    getByFile = function(path)
      return {
        stop = function() end,
        volume = function() end,
        play = function() table.insert(played, path) end,
      }
    end,
  },
  canvas = { new = fakeCanvas, windowLevels = { overlay = 102 } },
  mouse = { getCurrentScreen = function() return mouseScreen end },
  screen = {
    mainScreen = function() return builtIn end,
    watcher = { new = function() return { start = function() end, stop = function() end } end },
  },
  osascript = { javascript = function() return true, "0,2056,1329,918,918,38" end },
  timer = {
    absoluteTime = function() return clock end,
    doAfter = function(_, callback)
      local timer = { callback = callback }
      function timer:stop() timer.callback = nil end
      table.insert(pendingTimers, timer)
      return timer
    end,
    doEvery = function(interval, callback)
      local timer = { stopped = false }
      function timer:stop() timer.stopped = true end
      if interval < 1 then islandTick, islandTimer = callback, timer end
      return timer
    end,
  },
  task = {
    new = function(path, completion, streamOrArguments)
      local stream = type(streamOrArguments) == "function" and streamOrArguments or nil
      local task = {}
      function task:start()
        if path:match("/hark%-recorder$") then
          recorderStream = function(line) stream(task, line .. "\n", "") end
          recorderStream('{"event":"ready","backend":"AUHAL","microphone_active":false,"sample_rate":48000}')
        elseif path == "/usr/bin/curl" then
          pendingCurl = function() completion(0, transcript, "") end
        end
        return task
      end
      function task:setInput(command)
        if command:match("^START ") then
          recorderStream('{"event":"started","command_to_first_buffer_ms":40,"microphone_active":true}')
        elseif command == "STOP\n" then
          recorderStream('{"event":"stopped","command_to_wav_ms":10,"microphone_active":false,"path":"/tmp/hark-take.wav"}')
        end
        return task
      end
      function task:terminate() return task end
      return task
    end,
  },
}

local function advance(seconds)
  local frames = math.floor(seconds * 60 + 0.5)
  for _ = 1, frames do
    clock = clock + math.floor(1e9 / 60)
    if islandTick and not islandTimer.stopped then islandTick() end
  end
end

local function runTimers()
  local timers = pendingTimers
  pendingTimers = {}
  for _, timer in ipairs(timers) do
    if timer.callback then timer.callback() end
  end
end

local function finishTranscription()
  local finish = pendingCurl
  pendingCurl = nil
  finish()
end

local function textShown(canvas, text)
  for _, element in ipairs(canvas.elements) do
    if element.type == "text" and element.text == text then return true end
  end
  return false
end

local function pill(canvas)
  local first = canvas.elements[1]
  return first and first.type == "rectangle" and first.frame or nil
end

local function hasElement(canvas, kind)
  for _, element in ipairs(canvas.elements) do
    if element.type == kind then return true end
  end
  return false
end

local fakeIo = { open = function() return { close = function() end } end }
local env = setmetatable({ hs = fakeHs, io = fakeIo, os = { getenv = os.getenv } }, { __index = _G })
local module = assert(loadfile(repoRoot .. "/hark.lua", "t", env))()
assert(module.status() == "ready", "module should become ready")

-- Start: the start sound plays and the notch grows into the pill.
module.toggle()
assert(played[1] == soundDir .. "/pop/start.wav", "start should play the default pack's start sound")
local canvas = canvases[#canvases]
assert(canvas and canvas.shown, "the island canvas should show when recording starts")
recorderStream('{"event":"level","rms":0.1}')
advance(0.8)
local frame = pill(canvas)
assert(frame and math.abs(frame.w - (220 + 128)) < 2, "the pill should grow 64 pt past each side of the 220 pt notch")
assert(hasElement(canvas, "text"), "recording should show the timer")
assert(hasElement(canvas, "circle"), "recording should show the red dot")

-- Stop: the stop sound plays and the pill says "Transcribing".
module.toggle()
assert(played[2] == soundDir .. "/pop/stop.wav", "stop should play the stop sound")
advance(0.5)
assert(textShown(canvas, "Transcribing"), "the pill should say Transcribing while Whisper works")
assert(hasElement(canvas, "arc"), "transcribing should show the spinner")

-- Pasted: the done sound plays, the pill shows a check and "Pasted", then it
-- shrinks back into the notch and hides.
finishTranscription()
assert(played[3] == soundDir .. "/pop/done.wav", "a pasted transcript should play the done sound")
advance(0.5)
assert(textShown(canvas, "Pasted"), "the pill should say Pasted after the text lands")
assert(hasElement(canvas, "segments"), "pasted should show the check mark")
runTimers()
advance(1.5)
assert(not canvas.shown, "the island should hide once it is back inside the notch")
assert(islandTimer.stopped, "the animation timer should stop when the island is idle")

-- No speech: the error sound plays and the pill says so.
transcript = "   "
module.toggle()
module.toggle()
finishTranscription()
assert(played[#played] == soundDir .. "/pop/error.wav", "an empty transcript should play the error sound")
advance(0.5)
assert(textShown(canvases[#canvases], "No speech"), "the pill should say No speech")
runTimers()
advance(1.5)

-- Multi-monitor: the pill opens on the screen with the mouse pointer. This one
-- has no notch, so the pill drops from its top center under the menu bar.
mouseScreen = external
transcript = "test transcript"
module.toggle()
local outside = canvases[#canvases]
assert(outside ~= canvas and outside.shown, "a new island should open on the screen with the pointer")
local f = outside:frame()
assert(math.abs(f.x + f.w / 2 - (941 + 960)) < 1 and f.y == -1080, "the island should center on the external screen's top edge")
advance(0.8)
assert(math.abs(pill(outside).h - 14 - (25 + 6)) < 1, "with no notch the pill should be the menu bar height plus 6 pt")
module.toggle()
finishTranscription()
runTimers()
advance(1.5)
mouseScreen = builtIn

-- The menu choices are respected: sounds off, island off.
settings["hark.soundPack"] = "off"
settings["hark.notchIsland"] = false
local playedBefore, canvasesBefore = #played, #canvases
transcript = "test transcript"
module.toggle()
assert(#played == playedBefore, "no sound should play when sounds are off")
assert(#canvases == canvasesBefore and not canvases[#canvases].shown, "no island should show when it is turned off")
module.toggle()
finishTranscription()

print("PASS: notch island shows each dictation state on the pointer's screen and plays its sound")
