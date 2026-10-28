-- Hammerspoon regression test for the 🎙 menu's Check for Updates flow.
-- Run from the Hammerspoon Console:
--   dofile("/absolute/path/to/tests/update-check.lua")

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local repoRoot = scriptPath:match("^(.*)/tests/[^/]+$")

local settings, alerts, dialogs, shells, urlEvents, menuBuilder
local release, answer

local function reset(version)
  settings = { ["hark.notchIsland"] = false, ["hark.onboardingVersion"] = 99 }
  alerts, dialogs, shells, urlEvents = {}, {}, {}, {}
  release, answer = nil, nil
end

local fakeHs = {
  alert = { show = function(text) table.insert(alerts, text) end },
  dialog = {
    blockAlert = function(title, _, ...)
      table.insert(dialogs, title)
      return answer
    end,
  },
  execute = function() end,
  eventtap = { keyStroke = function() end },
  hotkey = { bind = function() return { delete = function() end } end },
  http = {
    asyncGet = function(url, _, callback)
      if url:match("^https://api%.github%.com/") then callback(release.status, release.body, {})
      else callback(200, "ok", {}) end
    end,
  },
  json = hs.json,
  menubar = { new = function() return { setMenu = function(_, fn) menuBuilder = fn end, setTitle = function() end } end },
  pasteboard = { getContents = function() end, setContents = function() end },
  settings = {
    get = function(key) return settings[key] end,
    set = function(key, value) settings[key] = value end,
  },
  timer = {
    absoluteTime = function() return 0 end,
    doAfter = function(_, callback) callback(); return { stop = function() end } end,
    doEvery = function() return { stop = function() end } end,
  },
  task = {
    new = function(path, _, streamOrArguments)
      local task = {}
      function task:start()
        if path:match("/hark%-recorder$") then
          streamOrArguments(task, '{"event":"ready","backend":"AUHAL","microphone_active":false,"sample_rate":48000}\n', "")
        elseif path == "/bin/bash" then
          table.insert(shells, streamOrArguments[2])
        end
        return task
      end
      function task:setInput() return task end
      function task:terminate() return task end
      return task
    end,
  },
  urlevent = { bind = function(name, fn) urlEvents[name] = fn end },
}

local function load()
  local env = setmetatable({ hs = fakeHs, io = { open = function() return nil end }, os = { getenv = os.getenv } },
    { __index = _G })
  local module = assert(loadfile(repoRoot .. "/hark.lua", "t", env))()
  assert(module.status() == "ready", "module should become ready")
  return module
end

local function menuItem(prefix)
  for _, item in ipairs(menuBuilder()) do
    if item.title and item.title:sub(1, #prefix) == prefix then return item end
  end
end

local function releaseOf(tag) return { status = 200, body = hs.json.encode({ tag_name = tag }) } end

-- A newer release, and the user clicks Update: `hark update` runs detached.
reset()
local module = load()
local version = module.version
assert(menuItem("Hark " .. version), "the menu should show the version")
assert(menuItem("Check for Updates").fn == module.checkForUpdates, "the menu should offer Check for Updates")
release, answer = releaseOf("v99.0.0"), "Update"
module.checkForUpdates()
assert(dialogs[1] == "Hark 99.0.0 is available", "a newer release should be offered: " .. tostring(dialogs[1]))
assert(#shells == 1 and shells[1]:match("/bin/hark' update >'/tmp/hark%-update%.log' 2>&1 </dev/null"),
  "Update should run hark update with its output in the log")
assert(shells[1]:match("&$"), "the update must be detached, because it restarts Hammerspoon")
assert(shells[1]:match("hammerspoon://harkUpdateFailed"), "a failed update should report back")
assert(settings["hark.updateFrom"] == version, "the old version should be kept for the next load")
assert(menuItem("Updating").disabled, "the menu should show the update as running")
module.checkForUpdates()
assert(#dialogs == 1, "a second check during an update should do nothing")

-- The next load, after the installer restarts Hammerspoon, reports the new version.
settings["hark.updateFrom"] = "0.9.0"
alerts = {}
load()
local announced = false
for _, text in ipairs(alerts) do announced = announced or text == "Hark updated to " .. version end
assert(announced, "the new version should be announced")
assert(settings["hark.updateFrom"] == "", "the announcement should show once")
alerts = {}
load()
for _, text in ipairs(alerts) do assert(not text:match("updated"), "the announcement must not repeat") end

-- A failed update says so and points to the log.
reset()
load()
urlEvents.harkUpdateFailed()
assert(dialogs[1] == "The Hark update failed", "a failed update should show a dialog")
assert(menuItem("Check for Updates").disabled ~= true, "the menu should allow a new check after a failure")

-- Later does nothing.
reset()
module = load()
release, answer = releaseOf("v99.0.0"), "Later"
module.checkForUpdates()
assert(#shells == 0 and settings["hark.updateFrom"] == nil, "Later must not update")

-- The same, an older or a numerically larger release.
for tag, expected in pairs({
  ["v" .. version] = "Hark is up to date",
  ["v0.0.1"] = "Hark is up to date",
  [version:gsub("%d+$", function(n) return tostring(tonumber(n) + 10) end)] = "is available",
}) do
  reset()
  module = load()
  release, answer = releaseOf(tag), "Later"
  module.checkForUpdates()
  assert(dialogs[1] and dialogs[1]:match(expected), tag .. " should give '" .. expected .. "', got " .. tostring(dialogs[1]))
end

-- GitHub does not answer, or answers with something that is not a release.
for _, response in ipairs({ { status = -1, body = nil }, { status = 403, body = "{}" }, { status = 200, body = "<html>" } }) do
  reset()
  module = load()
  release = response
  module.checkForUpdates()
  assert(dialogs[1] == "Could not check for updates", "HTTP " .. response.status .. " should say the check failed")
  assert(menuItem("Check for Updates").disabled ~= true, "the menu should allow a new check")
end

print("PASS: Check for Updates offers newer releases, runs hark update detached, and reports the result")
