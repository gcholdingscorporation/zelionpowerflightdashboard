-- ZelionPerf layer 6: the widget.
--
-- Owns the EdgeTX lifecycle and the key handling, and nothing else.
--
-- The ordering inside refresh() is the whole contract with the sampler:
-- frameStart() first, before any other work, so the period it measures is
-- frame-to-frame and not work-to-work; frameEnd() last, after the screen has
-- been written, so the heap difference across the two covers everything this
-- widget did and nothing it did not.

return function(ZD)

local Host   = ZD.Host
local Theme  = ZD.Theme
local Stats  = ZD.PerfStats
local Probe  = ZD.PerfProbe
local Scan   = ZD.PerfScan
local Advice = ZD.PerfAdvice
local Screen = ZD.PerfScreen

local Widget = {}
ZD.PerfWidget = Widget

local function flag(name, fallback)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
end
local BOOL = flag("BOOL", 2)
local EVT_NEXT  = flag("EVT_VIRTUAL_NEXT",  -1)
local EVT_PREV  = flag("EVT_VIRTUAL_PREV",  -2)
local EVT_ENTER = flag("EVT_VIRTUAL_ENTER", -3)

local built = nil
local zoneW, zoneH = nil, nil
local scroll = 0

-- The findings list is rebuilt on a timer, not every frame.
--
-- Building it means running every rule and formatting a dozen strings, and
-- the answers move on the scale of seconds, not frames - the frame rate it
-- reasons about is itself a mean over two-second sub-windows. Rebuilding it
-- 30 times a second would allocate 30 times as much to say the same thing,
-- inside the one widget whose findings include "something on this screen is
-- allocating per frame".
--
-- Half a second, so a change the pilot just made still appears immediately
-- enough to feel like a response to it.
local REBUILD_TICKS = 50

local listCache, listAt = nil, nil

-- Counted so the throttle is an assertion rather than an intention. On the
-- radio nobody reads this; in the test suite it is what proves a hundred
-- frames do not produce a hundred rebuilds.
Widget.listBuilds = 0

-- Anything that makes the current list wrong right now, rather than merely
-- stale: a new baseline, a rescan, switching between the two lists.
local function invalidateList()
  listCache, listAt = nil, nil
end

Widget.showScripts = false
Widget.lastMarkOption, Widget.lastRescanOption = false, false

local function readZone(widget)
  local z = widget and widget.zone
  local w = tonumber(z and z.w) or Host.lcdW
  local h = tonumber(z and z.h) or Host.lcdH
  if w <= 0 then w = Host.lcdW end
  if h <= 0 then h = Host.lcdH end
  return w, h
end

local function ensureScreen(widget)
  local w, h = readZone(widget)
  if w ~= zoneW or h ~= zoneH then
    zoneW, zoneH = w, h
    built = nil
  end
  if built ~= "perf" then
    pcall(Screen.build, zoneW, zoneH)
    built = "perf"
    -- A rebuild can change the wrap width, and the cached lines were wrapped
    -- to the old one. Throw them away rather than render a list wrapped for a
    -- screen that is no longer there.
    invalidateList()
  end
end

--------------------------------------------------------------------------
-- The script inventory, as list entries
--------------------------------------------------------------------------
--
-- Rendered through the same list as the findings so there is one scrolling
-- widget on screen rather than two, and so a pilot who has read a finding
-- about mix scripts can switch straight to seeing which ones they have.
--
-- Severity here is not a judgement about the script. It is how much of the
-- time that KIND of script runs, which is the only thing this tool knows and
-- the only thing that should drive where the eye goes.
local KIND_SEVERITY = {
  mix = Advice.HIGH, func = Advice.MED, widget = Advice.LOW,
  telem = Advice.INFO, tool = Advice.INFO,
}

local function scriptEntries(scan)
  local out = {}
  if not scan or not scan.ok then
    out[1] = { severity = Advice.INFO, title = "No script list",
               detail = scan and scan.reason
                        or "The storage has not been scanned yet." }
    return out
  end

  local m = scan.model or {}
  local parts = {}
  local function add(n, word)
    if n ~= nil then parts[#parts + 1] = string.format("%d %s", n, word) end
  end
  add(m.sensors, "sensors")
  add(m.logicalSwitches, "logical switches")
  add(m.specialFunctions, "special functions")
  add(m.mixes, "mixes")
  out[#out + 1] = {
    severity = Advice.INFO,
    title = string.format("%d scripts installed", #scan.scripts),
    -- The model's own load shares the main task with every script here, so it
    -- belongs on the same page even though none of it is Lua.
    detail = (#parts > 0) and ("This model: " .. table.concat(parts, ", "))
             or "This firmware does not report the model's own counts.",
  }

  for _, s in ipairs(scan.scripts) do
    out[#out + 1] = {
      severity = KIND_SEVERITY[s.kind] or Advice.INFO,
      title = s.name,
      detail = string.format("%s  runs %s  %s%s", s.dir, s.when,
                             s.size and Stats.fmtBytes(s.size) .. "b" or "size unknown",
                             s.compiled and "  compiled" or ""),
    }
  end

  for _, dir in ipairs(scan.unreadable or {}) do
    out[#out + 1] = { severity = Advice.INFO, title = dir,
                      detail = "not present, or not readable on this radio" }
  end
  return out
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Widget.create(zone, options)
  pcall(Theme.build)
  -- Scanned here rather than on the first frame. The scan makes hundreds of
  -- firmware calls and touches storage; run from a refresh it would produce a
  -- stall of its own, which the sampler would then faithfully report to the
  -- pilot as their problem.
  pcall(Scan.run)
  pcall(Probe.reset)
  invalidateList()
  built = nil
  zoneW, zoneH = nil, nil
  scroll = 0
  return { zone = zone, options = options }
end

function Widget.update(widget, options)
  widget.options = options
  Widget.showScripts = (options and options.Scripts == 1) or false

  -- Edge-triggered, the way ZelionDash's Test Alert is: switching the option
  -- on performs the action once. EdgeTX widget options have no button type,
  -- so a toggle that acts on the transition is the nearest thing - and unlike
  -- acting on the value, a firmware that calls update() repeatedly cannot
  -- turn it into a loop.
  local mark = (options and options.Mark == 1) or false
  if mark and not Widget.lastMarkOption then pcall(Probe.mark, "settings") end
  Widget.lastMarkOption = mark

  local rescan = (options and options.Rescan == 1) or false
  if rescan and not Widget.lastRescanOption then pcall(Scan.run) end
  Widget.lastRescanOption = rescan

  invalidateList()
  built = nil
  ensureScreen(widget)
end

-- ENTER marks a baseline, or clears the one that is there. That single key is
-- the whole optimisation loop: mark, change one thing, read the delta.
local function handleEvent(event)
  if event == nil then return end
  if event == EVT_NEXT then
    scroll = scroll + 1
  elseif event == EVT_PREV then
    scroll = scroll - 1
  elseif event == EVT_ENTER then
    if Probe.baseline then
      Probe.clearBaseline()
      Probe.restart()
    else
      Probe.mark("marked")
    end
    invalidateList()
  end
end

function Widget.refresh(widget, event, touchState)
  Probe.frameStart(Host.now())
  ensureScreen(widget)
  handleEvent(event)

  local snap = Probe.snapshot()
  local cmp  = Probe.comparison(snap)
  local scan = Scan.result

  local now = Host.now()
  if listCache == nil or listAt == nil
     or now - listAt >= REBUILD_TICKS or now < listAt then
    if Widget.showScripts then
      local ok, entries = pcall(scriptEntries, scan)
      listCache = ok and entries or {}
    else
      local ok, findings = pcall(Advice.build, snap, scan, cmp,
                                 Probe.baselineLabel)
      listCache = ok and findings or {}
    end
    -- Wrapped here, on the throttled path, rather than in the renderer where
    -- it ran for every visible entry on every frame. Wrapping allocates a
    -- table and a string per word; on hardware that was most of what this
    -- widget was reporting against its own name.
    local cols = Screen.cols()
    for _, f in ipairs(listCache) do
      f.lines = Screen.wrap(f.detail, cols, 2)
    end
    listAt = now
    Widget.listBuilds = Widget.listBuilds + 1
  end
  local list = listCache

  local ok, clamped = pcall(Screen.update, {
    snap = snap,
    findings = list,
    comparison = cmp,
    baselineFps = Probe.baseline and Probe.baseline.fps or nil,
    scroll = scroll,
    hint = Widget.showScripts and "heaviest-running first"
           or (Probe.baseline and "ENTER clears the baseline"
                              or "ENTER marks a baseline"),
  })
  if ok and clamped then scroll = clamped end

  Probe.frameEnd()
end

-- Deliberately empty of measurement. Off-screen there are no frames to time,
-- and the honest thing for an analyser to cost when it is not being looked at
-- is nothing at all.
function Widget.background(widget)
end

Widget.options = {
  -- Capture the current frame rate to compare against. Also available on the
  -- ENTER key, which is where it actually gets used - the settings page is
  -- for a radio whose ENTER does not reach the widget.
  { "Mark",    BOOL, 0 },
  -- Re-walk the storage and the model. Needed after installing or deleting a
  -- script, since the scan is deliberately not repeated per frame.
  { "Rescan",  BOOL, 0 },
  -- Swap the list from findings to the raw inventory.
  { "Scripts", BOOL, 0 },
}

Widget.OPTION_LABELS = {
  Mark    = "Mark Baseline (toggle)",
  Rescan  = "Rescan Scripts (toggle)",
  Scripts = "Show Script List",
}

function Widget.translate(name)
  return Widget.OPTION_LABELS[name] or name
end

-- Exposed for the tests and for tools/dump_screen.lua, so what is documented
-- is what the radio builds.
Widget.scriptEntries = scriptEntries

return Widget

end
