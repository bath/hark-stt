-- Hammerspoon regression test for the one-time welcome popup.
-- Run from the Hammerspoon Console:
--   dofile("/absolute/path/to/tests/onboarding.lua")

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local repoRoot = scriptPath:match("^(.*)/tests/[^/]+$")

-- The island has its own test; keep it out of this one.
local function freshSettings() return { ["whisperDictation.notchIsland"] = false } end
local settings = freshSettings()
local views = {}
local recorderCommands = {}
local escapeBound = 0

local screen = {
  fullFrame = function() return { x = 0, y = 0, w = 1440, h = 900 } end,
  frame = function() return { x = 0, y = 25, w = 1440, h = 875 } end,
}

local function fakeView(rect, _, content)
  local view = { rect = rect, content = content, shown = false, deleted = false, scripts = {} }
  for _, method in ipairs({ "windowStyle", "transparent", "allowTextEntry", "level", "behaviorAsLabels", "html" }) do
    view[method] = function() return view end
  end
  function view:show() view.shown = true; return view end
  function view:delete() view.deleted = true end
  function view:evaluateJavaScript(script) table.insert(view.scripts, script); return view end
  table.insert(views, view)
  return view
end

local fakeHs = {
  alert = { show = function() end },
  eventtap = { keyStroke = function() end },
  hotkey = {
    bind = function(_, key)
      if key == "escape" then escapeBound = escapeBound + 1 end
      return { delete = function() if key == "escape" then escapeBound = escapeBound - 1 end end }
    end,
  },
  http = { asyncGet = function(_, _, callback) callback(200, "ok", {}) end },
  json = hs.json,
  menubar = { new = function() return { setMenu = function() end, setTitle = function() end } end },
  pasteboard = { getContents = function() end, setContents = function() end },
  settings = {
    get = function(key) return settings[key] end,
    set = function(key, value) settings[key] = value end,
  },
  canvas = { windowLevels = { modalPanel = 8 } },
  mouse = { getCurrentScreen = function() return screen end },
  screen = { mainScreen = function() return screen end },
  webview = {
    new = fakeView,
    usercontent = {
      new = function()
        local content = {}
        function content:setCallback(callback) content.callback = callback; return content end
        return content
      end,
    },
  },
  timer = {
    absoluteTime = (function()
      local now = 1000000000
      return function() now = now + 1000000; return now end
    end)(),
    doAfter = function(_, callback) callback(); return { stop = function() end } end,
    doEvery = function() return { stop = function() end } end,
  },
  task = {
    new = function(path, completion, streamOrArguments)
      local stream = type(streamOrArguments) == "function" and streamOrArguments or nil
      local task = {}
      function task:start()
        if path:match("/whisper%-recorder$") then
          stream(task, '{"event":"ready","backend":"AUHAL","microphone_active":false,"sample_rate":48000}\n', "")
        elseif path == "/usr/bin/curl" then
          completion(0, "test transcript", "")
        end
        return task
      end
      function task:setInput(command)
        table.insert(recorderCommands, command)
        if command:match("^START ") then
          stream(task, '{"event":"started","microphone_active":true}\n', "")
        elseif command == "STOP\n" then
          stream(task, '{"event":"stopped","microphone_active":false,"path":"/tmp/whisper-dictate.wav"}\n', "")
        end
        return task
      end
      function task:terminate() return task end
      return task
    end,
  },
}

local fakeIo = { open = function() return nil end }
local function load()
  local env = setmetatable({ hs = fakeHs, io = fakeIo, os = { getenv = os.getenv } }, { __index = _G })
  local module = assert(loadfile(repoRoot .. "/whisper-dictation.lua", "t", env))()
  assert(module.status() == "ready", "module should become ready")
  return module
end

-- First press after the update: the welcome card shows and nothing records.
local module = load()
module.toggle()
assert(#views == 1 and views[1].shown, "the first press should show the welcome card")
assert(#recorderCommands == 0, "the first press must not start recording")
assert(escapeBound == 1, "Esc should close the card while it shows")
assert(views[1].rect.x == (1440 - 440) / 2, "the card should be centered on the pointer's screen")

-- Second press: the card closes and dictation starts, and it never shows again.
module.toggle()
assert(views[1].deleted and views[1].scripts[1] == "closeCard()", "the second press should close the card")
assert(escapeBound == 0, "the Esc hotkey should be released")
assert(recorderCommands[1] and recorderCommands[1]:match("^START "), "closing with F5 should start recording")
assert(settings["whisperDictation.onboardingVersion"] == 1, "the card should be marked as seen")
module.toggle()
assert(module.status() == "ready", "dictation should finish normally")

-- A later session goes straight to recording.
module = load()
module.toggle()
assert(#views == 1, "the card must not show again after it was seen")
assert(module.status() == "recording", "a later press should record")
module.toggle()

-- The card's Close button only closes it; Start dictating also records.
settings = freshSettings()
module = load()
module.toggle()
views[#views].content.callback({ body = "close" })
assert(views[#views].deleted and module.status() == "ready", "Close should not start recording")
assert(settings["whisperDictation.onboardingVersion"] == 1, "Close should also mark the card as seen")
settings = freshSettings()
module = load()
module.toggle()
views[#views].content.callback({ body = "start" })
assert(module.status() == "recording", "Start dictating should start recording")
module.toggle()

print("PASS: welcome card shows once, then hands off to dictation")
