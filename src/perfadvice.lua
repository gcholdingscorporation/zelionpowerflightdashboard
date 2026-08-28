-- ZelionPerf layer 4: findings.
--
-- Turns the measurement and the inventory into a ranked list of things worth
-- doing, in the order worth doing them.
--
-- Three rules, learned from the alert engine one layer over in ZelionDash,
-- where the same failure mode applies: the only way a diagnostic tool fails
-- in practice is by becoming noise.
--
--   * EVERY FINDING NAMES AN ACTION. "Lua heap low" is a reading, not a
--     finding. "Lua heap down to 8k; the collector is running every third
--     frame - remove a widget from this screen" is a finding. Anything that
--     cannot be turned into a sentence with a verb in it belongs on the
--     readings panel instead, and several things that started here ended up
--     there.
--   * NOTHING IS REPORTED THAT WAS NOT MEASURED OR READ. There is no table of
--     scripts known to be slow, and no guess at what a script costs from its
--     size - size ranks the list, it never becomes a claim. Where the API
--     cannot answer, the finding says so rather than estimating.
--   * A CLEAN RADIO GETS A CLEAN ANSWER. If the frame rate is fine, it says
--     so and stops. A tool that always finds five things to fix teaches the
--     pilot that its findings are decoration.

return function(ZD)

local Stats = ZD.PerfStats
local Scan  = ZD.PerfScan

local Advice = {}
ZD.PerfAdvice = Advice

-- Severity doubles as sort key and as colour on screen.
Advice.HIGH, Advice.MED, Advice.LOW, Advice.INFO = 3, 2, 1, 0

--------------------------------------------------------------------------
-- Thresholds
--------------------------------------------------------------------------
--
-- These are judgements about what a pilot notices, not firmware limits, so
-- they are gathered here to be argued with in one place rather than buried in
-- the rules below.

-- Under 15fps the UI reads as laggy on a colour radio: a menu cursor lags the
-- wheel visibly. Between 15 and 25 it is usable but not smooth. Above 25
-- nobody has ever complained.
Advice.FPS_BAD, Advice.FPS_FAIR = 15, 25

-- Stutters per minute. One is a coincidence; six is something running on a
-- timer, and a timer is findable.
Advice.STALLS_PER_MIN = 6

-- EdgeTX gives Lua a fixed heap. Under 12k free, allocation starts failing
-- scripts outright, and well before that the collector runs so often that its
-- pauses are the frame rate. 25k is where to start worrying.
Advice.HEAP_LOW, Advice.HEAP_CRITICAL = 25000, 12000

-- Bytes per frame across all scripts. A retained-mode widget should sit near
-- zero; a few hundred is a script rebuilding tables every frame.
Advice.ALLOC_HIGH = 400

-- getUsage() is a percentage of the instruction budget. At 90 the script is
-- being preempted mid-refresh, which is exactly when a frame goes missing.
Advice.USAGE_HIGH = 90

--------------------------------------------------------------------------

-- `tone` is presentation, not severity: "7 fps faster than the baseline" is
-- the lowest-priority thing on the list and the best news on it, and a screen
-- that greys it out alongside the other INFO rows buries the one result the
-- pilot is standing there waiting for.
local function finding(severity, title, detail, tone)
  return { severity = severity, title = title, detail = detail, tone = tone }
end

-- The two entries most worth testing first, named.
--
-- "Work through the script list below" was the original advice and it is not
-- advice, it is a gesture at a menu. The scan already knows which entries run
-- most of the time, so the finding can say which ones - and on a radio that
-- is actually slow, that sentence is the whole product.
--
-- Named, never blamed: this says where to point the experiment, not what the
-- cost is. Nothing here knows what either entry costs, and the only way to
-- find out is the baseline.
local function namedSuspects(scan, limit)
  if not scan or not scan.ok then return nil end
  local names = {}
  for _, s in ipairs(scan.scripts) do
    -- Anything that only runs on its own page or from the Tools menu is not
    -- costing frames while you are looking at this screen, so it is not a
    -- suspect however big it is.
    if s.weight > 0 and #names < (limit or 2) then
      names[#names + 1] = s.name
    end
  end
  if #names == 0 then return nil end
  return table.concat(names, " and ")
end

-- Frame rate, stutters, and the difference between them.
--
-- They are separate findings because they have different causes and different
-- fixes: a low average is too much work every frame, while stutters on a good
-- average are something periodic - an SD write, a collection, a script that
-- wakes on a timer.
local function frameRate(out, snap, scan)
  local fps = snap.fps
  if fps == nil then return end

  local suspects = namedSuspects(scan, 2)
  local howToTest = suspects
    and string.format("Test %s first - they run the most. Press ENTER to "
                      .. "mark a baseline, take one off this model, and read "
                      .. "the difference.", suspects)
    or "Mark a baseline with ENTER, change one thing, and read the difference."

  if fps < Advice.FPS_BAD then
    out[#out + 1] = finding(Advice.HIGH,
      string.format("UI is running at %s fps", Stats.fmtFps(fps)),
      "Slow enough to feel in the menus. " .. howToTest)
  elseif fps < Advice.FPS_FAIR then
    out[#out + 1] = finding(Advice.MED,
      string.format("UI is running at %s fps", Stats.fmtFps(fps)),
      "Usable but not smooth. " .. howToTest)
  end

  if snap.stalls and snap.stalls > 0 and snap.frames > 0 and fps > 0 then
    local minutes = (snap.frames / fps) / 60
    local perMin = minutes > 0 and (snap.stalls / minutes) or 0
    if perMin >= Advice.STALLS_PER_MIN then
      out[#out + 1] = finding(Advice.MED,
        string.format("%d stutters, worst %s", snap.stalls,
                      Stats.fmtMs(snap.worst)),
        "Frames this long are periodic, not steady load. Logged telemetry "
        .. "sensors writing to storage and garbage collection are the two "
        .. "usual causes; both are below.")
    end
  end
end

local function memory(out, snap)
  local free = snap.freeMemory
  if free ~= nil then
    if free < Advice.HEAP_CRITICAL then
      out[#out + 1] = finding(Advice.HIGH,
        string.format("Lua heap down to %s free", Stats.fmtBytes(free)),
        "This close to full, scripts start failing to load at all and the "
        .. "collector runs constantly. Take a widget off this screen.")
    elseif free < Advice.HEAP_LOW then
      out[#out + 1] = finding(Advice.MED,
        string.format("Lua heap at %s free", Stats.fmtBytes(free)),
        "Enough to run, not enough to run without frequent collection. "
        .. "Fewer widgets on one screen is the cheapest fix.")
    end
  end

  local alloc = snap.allocPerFrame
  if alloc ~= nil and alloc >= Advice.ALLOC_HIGH then
    out[#out + 1] = finding(Advice.MED,
      string.format("%s allocated per frame", Stats.fmtBytes(alloc)),
      "Something on this screen rebuilds its objects every frame instead of "
      .. "updating them. That is what the collector is being fed."
      .. (snap.selfAlloc and string.format(" This widget accounts for %s of it.",
                                           Stats.fmtBytes(snap.selfAlloc)) or ""))
  end
end

local function luaLoad(out, snap)
  local u = snap.usageMax
  if u ~= nil and u >= Advice.USAGE_HIGH then
    out[#out + 1] = finding(Advice.MED,
      string.format("Lua instruction budget peaked at %d%%", math.floor(u)),
      "At this point EdgeTX preempts a script part-way through and finishes "
      .. "it on the next cycle, which is a frame you do not get.")
  end
end

-- The inventory findings. These are the ones a measurement alone cannot
-- reach, because they are about code that is running whether or not the
-- analyser is on screen to see it.
local function inventory(out, scan, snap)
  -- A slow radio changes what the inventory means. On a healthy one, "you
  -- have a lot of widgets" is trivia and belongs at the bottom of the list;
  -- on one measured below the smooth threshold it is the leading candidate,
  -- because a widget goes on running background() when it is not showing and
  -- that is the cost nobody looks for.
  local slow = (snap and snap.fps ~= nil and snap.fps < Advice.FPS_FAIR) or false

  if not scan or not scan.ok then
    if scan and scan.reason then
      out[#out + 1] = finding(Advice.INFO, "Script list unavailable", scan.reason)
    end
    return
  end

  local mixes = scan.counts.mix or 0
  if mixes > 0 then
    out[#out + 1] = finding(Advice.HIGH,
      string.format("%d mix script%s running continuously",
                    mixes, mixes == 1 and "" or "s"),
      "Scripts in /SCRIPTS/MIXES/ run every mixer cycle on every screen, and "
      .. "keep running when you navigate away. They are the only kind you "
      .. "cannot get away from, so they are the first thing to test by "
      .. "removing.")
  end

  local widgets = scan.counts.widget or 0
  if widgets >= 6 then
    out[#out + 1] = finding(slow and Advice.MED or Advice.LOW,
      string.format("%d widgets installed", widgets),
      slow
        and ("Most widgets run background() when they are NOT showing, so on "
             .. "a radio this slow they cost frames from every screen, not "
             .. "just their own. Deleting one you no longer use is the "
             .. "cheapest thing on this list to test.")
        or ("Only the ones placed on the screen in front of you cost frames - "
            .. "but most also run background() when they are not showing. An "
            .. "installed widget you no longer use is free to delete."))
  end

  local raw = Scan.uncompiled(scan)
  if raw >= 3 then
    out[#out + 1] = finding(Advice.LOW,
      string.format("%d scripts are .lua rather than .luac", raw),
      "EdgeTX compiles each one on first run after a change, which is a pause "
      .. "and a peak in heap use. Shipping .luac avoids both. This costs "
      .. "startup, not steady frame rate.")
  end

  local m = scan.model or {}
  if (m.sensors or 0) >= 30 then
    out[#out + 1] = finding(Advice.MED,
      string.format("%d telemetry sensors on this model", m.sensors),
      "Every sensor is decoded on the main task as frames arrive. Deleting "
      .. "the ones you do not display or log is the one telemetry change that "
      .. "reliably buys frames back.")
  end
  if (m.loggedSensors or 0) > 0 and (m.sensors or 0) > 0 then
    out[#out + 1] = finding(Advice.LOW,
      string.format("%d of %d sensors are logged to storage",
                    m.loggedSensors, m.sensors),
      "Logging writes on the main task. If the stutter count above is high "
      .. "and steady, turn logging off for a flight and compare.")
  end
end

-- The before-and-after result, when there is one. Reported at the top,
-- because a pilot who has just changed something is looking for exactly this
-- and nothing else.
local function comparison(out, cmp, label)
  if not cmp or cmp.verdict == "unknown" then return end
  local was = label and (" (" .. label .. ")") or ""
  if cmp.verdict == "same" then
    out[#out + 1] = finding(Advice.INFO,
      "No measurable change since the baseline" .. was,
      string.format("Difference is %s fps against %s fps of run-to-run "
                    .. "spread, so it is not distinguishable from noise.",
                    Stats.fmtFps(math.abs(cmp.delta)), Stats.fmtFps(cmp.noise)))
  elseif cmp.verdict == "better" then
    out[#out + 1] = finding(Advice.INFO,
      string.format("%s fps faster than the baseline%s",
                    Stats.fmtFps(cmp.delta), was),
      string.format("Bigger than the %s fps run-to-run spread. Keep the "
                    .. "change.", Stats.fmtFps(cmp.noise)), "good")
  else
    out[#out + 1] = finding(Advice.MED,
      string.format("%s fps slower than the baseline%s",
                    Stats.fmtFps(math.abs(cmp.delta)), was),
      string.format("Bigger than the %s fps run-to-run spread. Whatever "
                    .. "changed since the mark cost that.", Stats.fmtFps(cmp.noise)))
  end
end

--------------------------------------------------------------------------

-- Build the ranked list.
--
-- `snap` comes from PerfProbe.snapshot(), `scan` from PerfScan.get(), `cmp`
-- from PerfProbe.comparison() or nil.
function Advice.build(snap, scan, cmp, baselineLabel)
  local out = {}
  snap = snap or {}

  comparison(out, cmp, baselineLabel)
  frameRate(out, snap, scan)
  memory(out, snap)
  luaLoad(out, snap)
  inventory(out, scan, snap)

  -- Stable sort by severity. table.sort is not stable in Lua, and the order
  -- within a severity is meaningful - the comparison result was put first
  -- deliberately - so the original position is carried as the tiebreak.
  for i, f in ipairs(out) do f.order = i end
  table.sort(out, function(a, b)
    if a.severity ~= b.severity then return a.severity > b.severity end
    return a.order < b.order
  end)

  if #out == 0 then
    local fps = snap.fps
    out[1] = finding(Advice.INFO, "Nothing worth changing",
      fps and string.format(
        "%s fps with no stutters and heap to spare. Measured over %d frames.",
        Stats.fmtFps(fps), snap.frames or 0)
      or "Still measuring. Leave this screen in front for a few seconds.",
      fps and "good" or nil)
  end
  return out
end

return Advice

end
