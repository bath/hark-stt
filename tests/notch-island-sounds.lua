-- Hammerspoon regression test for the Notch Island animation and the sounds
-- that play at each dictation transition.
-- Run from the Hammerspoon Console:
--   dofile("/absolute/path/to/tests/notch-island-sounds.lua")

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local repoRoot = scriptPath:match("^(.*)/tests/[^/]+$")
local soundDir = os.getenv("HOME") .. "/.hammerspoon/whisper-sounds"

local clock = 1000000000
local played = {}
local settings = {}
local canvases = {}
local islandTick = nil
local islandTimer = nil
local recorderStream = nil
local transcript = "test transcript"

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

local screen = {
  fullFrame = function() return { x = 0, y = 0, w = 2056, h = 1329 } end,
  frame = function() return { x = 0, y = 39, w = 2056, h = 1197 } end,
}

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
  screen = {
    mainScreen = function() return screen end,
    watcher = { new = function() return { start = function() end, stop = function() end } end },
  },
  osascript = { javascript = function() return true, "0,2056,1329,918,918,38" end },
  timer = {
    absoluteTime = function() return clock end,
    doAfter = function(_, callback) callback(); return { stop = function() end } end,
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
        if path:match("/whisper%-recorder$") then
          recorderStream = function(line) stream(task, line .. "\n", "") end
          recorderStream('{"event":"ready","backend":"AUHAL","microphone_active":false,"sample_rate":48000}')
        elseif path == "/usr/bin/curl" then
          completion(0, transcript, "")
        end
        return task
      end
      function task:setInput(command)
        if command:match("^START ") then
          recorderStream('{"event":"started","command_to_first_buffer_ms":40,"microphone_active":true}')
        elseif command == "STOP\n" then
          recorderStream('{"event":"stopped","command_to_wav_ms":10,"microphone_active":false,"path":"/tmp/whisper-dictate.wav"}')
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
local module = assert(loadfile(repoRoot .. "/whisper-dictation.lua", "t", env))()
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

-- Stop: the stop sound plays, then the pasted sound once the text lands, and
-- the pill shrinks back into the notch and hides.
module.toggle()
assert(played[2] == soundDir .. "/pop/stop.wav", "stop should play the stop sound")
assert(played[3] == soundDir .. "/pop/done.wav", "a pasted transcript should play the done sound")
advance(1.5)
assert(not canvas.shown, "the island should hide once it is back inside the notch")
assert(islandTimer.stopped, "the animation timer should stop when the island is idle")

-- No speech: the error sound plays.
transcript = "   "
module.toggle()
module.toggle()
assert(played[#played] == soundDir .. "/pop/error.wav", "an empty transcript should play the error sound")
advance(1.5)

-- The menu choices are respected: sounds off, island off.
settings["whisperDictation.soundPack"] = "off"
settings["whisperDictation.notchIsland"] = false
local playedBefore, canvasesBefore = #played, #canvases
transcript = "test transcript"
module.toggle()
assert(#played == playedBefore, "no sound should play when sounds are off")
assert(#canvases == canvasesBefore and not canvases[#canvases].shown, "no island should show when it is turned off")
module.toggle()

print("PASS: notch island animates and each transition plays its sound")
