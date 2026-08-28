-- ZelionPerf layer 3: the inventory.
--
-- What is installed on this radio that can take frame time, and when each of
-- it runs.
--
-- START HERE, BECAUSE THE OBVIOUS THING IS NOT POSSIBLE. EdgeTX's Lua API has
-- no call that enumerates running scripts, and no call that reports another
-- script's cost. getUsage() describes the caller's own execution cycle and
-- there is nothing else. A widget therefore cannot do what a desktop profiler
-- does - attribute time to each process - and any widget claiming to is
-- making the numbers up.
--
-- What it can do is the next best thing, which turns out to be most of the
-- value: list the scripts that exist, say when each one runs, and let the
-- measured frame rate say what they cost in total. The classification is the
-- part that matters, because it is not intuitive and it decides where to look
-- first:
--
--   /SCRIPTS/MIXES/       runs every mixer cycle, on every screen, from the
--                         moment the model is selected. Cannot be escaped by
--                         navigating away. Costs frames everywhere.
--   /SCRIPTS/FUNCTIONS/   runs while its special function's switch is active.
--   /WIDGETS/             runs when it is on the screen in front of you, via
--                         refresh(); and off-screen via background(), which
--                         most widgets use and which still costs.
--   /SCRIPTS/TELEMETRY/   runs only while its own telemetry page is showing.
--   /SCRIPTS/TOOLS/       runs only while open from the Tools menu.
--
-- So a heavy telemetry script is nearly free until you look at it, and a
-- trivial mix script is never free at all. A pilot hunting a slow UI reaches
-- for the thing they can see, which is usually the wrong end of that list.

return function(ZD)

local Host = ZD.Host

local Scan = {}
ZD.PerfScan = Scan

-- Ordered by how much of the time the code runs, worst first. `weight` ranks
-- findings later; it is a statement about frequency, not about quality.
Scan.CLASSES = {
  { dir = "/SCRIPTS/MIXES/",     kind = "mix",    when = "every cycle",  weight = 4 },
  { dir = "/SCRIPTS/FUNCTIONS/", kind = "func",   when = "switch on",    weight = 3 },
  { dir = "/WIDGETS/",           kind = "widget", when = "on screen",    weight = 2,
    folders = true },
  { dir = "/SCRIPTS/TELEMETRY/", kind = "telem",  when = "its page",     weight = 1 },
  { dir = "/SCRIPTS/TOOLS/",     kind = "tool",   when = "Tools menu",   weight = 0 },
}

-- Folder listing is capped well below any sane install. A radio with more
-- than this in one folder has a finding of its own, and walking it with fstat
-- is slow enough on real storage to be felt as a pause.
local MAX_PER_DIR = 24

local function isScript(name)
  return string.match(name, "%.lua$") ~= nil
      or string.match(name, "%.luac$") ~= nil
end

local function isCompiled(name)
  return string.match(name, "%.luac$") ~= nil
end

-- Strips the extension so a script shipping as both main.lua and main.luac is
-- not counted twice - EdgeTX runs one of them, not both.
local function stem(name)
  return (string.gsub(name, "%.luac?$", ""))
end

--------------------------------------------------------------------------

Scan.result = nil

local function emptyResult()
  return {
    ok       = false,
    reason   = nil,
    scripts  = {},
    counts   = { mix = 0, func = 0, widget = 0, telem = 0, tool = 0 },
    model    = {},
    unreadable = {},
  }
end

-- Scans one folder of plain scripts.
local function scanScripts(class, out)
  local files = Host.listFiles(class.dir, MAX_PER_DIR)
  if files == nil then
    -- Not there, or there and unlistable - dir() reports both the same way.
    -- Recorded rather than treated as an error: most radios have never had a
    -- /SCRIPTS/MIXES/ folder, and that is a clean bill of health, not a
    -- failure. The screen prints these as "not present".
    out.unreadable[#out.unreadable + 1] = class.dir
    return
  end
  local seen = {}
  for _, f in ipairs(files) do
    if isScript(f.name) then
      local key = stem(f.name)
      if not seen[key] then
        seen[key] = true
        out.scripts[#out.scripts + 1] = {
          name = key, dir = class.dir, kind = class.kind,
          when = class.when, weight = class.weight,
          size = f.size, compiled = isCompiled(f.name),
        }
        out.counts[class.kind] = out.counts[class.kind] + 1
      end
    end
  end
end

-- /WIDGETS/ holds a folder per widget, each with a main.lua inside. dir()
-- lists the folders; the size has to be fetched from the file within, and a
-- folder with no main.lua is not a widget at all.
local function scanWidgets(class, out)
  local names = Host.listDir(class.dir, MAX_PER_DIR)
  if names == nil then
    out.unreadable[#out.unreadable + 1] = class.dir
    return
  end
  for _, name in ipairs(names) do
    -- dir() lists "." and ".." on some builds and not others.
    if name ~= "." and name ~= ".." and not isScript(name) then
      local base = class.dir .. name .. "/main."
      local size, compiled = nil, false
      local f = Host.probeSize(base .. "luac")
      if f then
        size, compiled = f, true
      else
        size = Host.probeSize(base .. "lua")
      end
      if size ~= nil then
        out.scripts[#out.scripts + 1] = {
          name = name, dir = class.dir, kind = class.kind,
          when = class.when, weight = class.weight,
          size = size, compiled = compiled,
        }
        out.counts[class.kind] = out.counts[class.kind] + 1
      end
    end
  end
end

-- Heaviest-running first, then largest first inside a class. That ordering is
-- the advice: the top of this list is where to look.
local function sortScripts(scripts)
  table.sort(scripts, function(a, b)
    if a.weight ~= b.weight then return a.weight > b.weight end
    local sa, sb = a.size or 0, b.size or 0
    if sa ~= sb then return sa > sb end
    return a.name < b.name
  end)
end

-- Walks the storage and the model. EXPENSIVE - hundreds of firmware calls,
-- several of them touching storage. Called on demand and on first build,
-- never from a frame.
function Scan.run()
  local out = emptyResult()

  if not Host.hasDir then
    out.reason = "this firmware has no dir(), so installed scripts cannot be listed"
    Scan.result = out
    return out
  end

  for _, class in ipairs(Scan.CLASSES) do
    if class.folders then scanWidgets(class, out) else scanScripts(class, out) end
  end
  sortScripts(out.scripts)

  out.model = Host.modelInventory() or {}
  out.ok = true
  Scan.result = out
  return out
end

function Scan.get()
  return Scan.result or Scan.run()
end

-- Scripts that run without the pilot choosing to look at them. This is the
-- number the advice engine cares about most.
function Scan.alwaysRunning(result)
  result = result or Scan.get()
  local n = 0
  for _, s in ipairs(result.scripts) do
    if s.kind == "mix" then n = n + 1 end
  end
  return n
end

function Scan.uncompiled(result)
  result = result or Scan.get()
  local n = 0
  for _, s in ipairs(result.scripts) do
    if not s.compiled then n = n + 1 end
  end
  return n
end

return Scan

end
