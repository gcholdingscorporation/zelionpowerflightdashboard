-- ZelionPerf layer 2: the sampler.
--
-- Called once per frame, from the widget's refresh. Turns the host's two cost
-- probes and one coarse clock into the running picture the screen draws and
-- the advice engine reasons about.
--
-- Two rules shape all of it:
--
--   1. IT MUST NOT PERTURB WHAT IT MEASURES. Everything here is a fixed
--      number of arithmetic operations on tables allocated once. No string
--      building, no closures, no table constructors on the frame path - a
--      profiler that allocates per frame drives the collector it is trying to
--      report on, and would show the pilot its own cost as their problem.
--   2. A GAP IS NOT A SLOW FRAME. EdgeTX stops calling refresh() the moment
--      another screen comes forward, so the period across that gap is
--      however long the pilot spent in the menus. Counting it would put a
--      40-second "frame" in the histogram and drag the average frame rate to
--      near zero. Gaps are detected and used to restart the clock instead.

return function(ZD)

local Host  = ZD.Host
local Stats = ZD.PerfStats

local Probe = {}
ZD.PerfProbe = Probe

-- A period longer than this is the widget having been away, not the radio
-- having been slow. One second is far above any frame a working radio
-- produces and far below any time a pilot spends on another screen.
Probe.GAP_TICKS = 100

-- How much wall clock goes into one sub-window. Each closes into a single
-- frame-rate figure, and the spread of those figures is what tells a real
-- before-and-after difference from noise. Two seconds is long enough that
-- quantisation has averaged out and short enough that eight of them fit in
-- the time a pilot will hold still for.
Probe.SUBWINDOW_TICKS = 200

-- Sub-windows kept. Eight covers about sixteen seconds of history, which is
-- the horizon over which "nothing changed" is a believable claim.
Probe.SERIES_CAP = 8

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

Probe.baseline = nil        -- snapshot captured by the pilot, or nil
Probe.baselineLabel = nil

local total, sub, series, heap
local lastFrame, subStart
local gaps, usageSum, usageSamples, usageMax
local selfAlloc, selfSamples, frameFree

function Probe.reset()
  total  = Stats.newWindow()
  sub    = Stats.newWindow()
  series = Stats.newSeries(Probe.SERIES_CAP)
  heap   = Stats.newHeap()
  lastFrame, subStart = nil, nil
  gaps = 0
  usageSum, usageSamples, usageMax = 0, 0, nil
  selfAlloc, selfSamples, frameFree = 0, 0, nil
end

Probe.reset()

-- Clears the measurement without touching the captured baseline. This is what
-- the mark key calls: the point of marking is to start measuring the new
-- configuration from scratch, not to average it with the old one.
function Probe.restart()
  local keep, keepLabel = Probe.baseline, Probe.baselineLabel
  Probe.reset()
  Probe.baseline, Probe.baselineLabel = keep, keepLabel
end

Probe.gaps = function() return gaps end

--------------------------------------------------------------------------
-- The frame path
--------------------------------------------------------------------------

-- Call at the top of refresh(), before doing any other work.
--
-- `now` is Host.now(). Passed in rather than read here so the caller's single
-- clock read serves both the sampler and the rest of the frame, and so tests
-- can drive time directly.
function Probe.frameStart(now)
  now = tonumber(now) or 0

  if lastFrame ~= nil then
    local dt = now - lastFrame
    -- A clock that went backwards is getTime() having wrapped. Treat it as a
    -- gap: one absurd sample discarded is better than a negative period, and
    -- better than the alternative of reasoning about the wrap point.
    if dt < 0 or dt > Probe.GAP_TICKS then
      gaps = gaps + 1
      subStart = now
      -- The sub-window in flight spans the gap, so it is void rather than
      -- short. Reuse the table; a fresh one here would allocate per gap.
      sub.frames, sub.span, sub.worst, sub.over = 0, 0, 0, 0
      for k in pairs(sub.hist) do sub.hist[k] = nil end
    else
      Stats.add(total, dt)
      Stats.add(sub, dt)
    end
  end
  lastFrame = now

  if subStart == nil then subStart = now end
  if now - subStart >= Probe.SUBWINDOW_TICKS then
    local f = Stats.fps(sub)
    if f then Stats.push(series, f) end
    sub.frames, sub.span, sub.worst, sub.over = 0, 0, 0, 0
    for k in pairs(sub.hist) do sub.hist[k] = nil end
    subStart = now
  end

  local u = Host.usage()
  if u then
    usageSum = usageSum + u
    usageSamples = usageSamples + 1
    if usageMax == nil or u > usageMax then usageMax = u end
  end

  local free = Host.freeMemory()
  Stats.heapSample(heap, free)
  frameFree = free
end

-- Call at the bottom of refresh(), after the screen has been updated.
--
-- The difference across the frame is what THIS widget allocated, which is the
-- one cost figure the analyser can attribute to a single script with
-- certainty - it is the only script it can put brackets around. It is
-- reported on screen so the pilot can see the measurement is not the thing
-- being measured; a reading above a few dozen bytes here is a bug in this
-- widget, not a finding about theirs.
function Probe.frameEnd()
  if frameFree == nil then return end
  local after = Host.freeMemory()
  if after == nil then return end
  local used = frameFree - after
  -- Negative means the collector ran mid-frame and handed back more than we
  -- took. Nothing to attribute, so it is skipped rather than counted as a
  -- gain that would drag the average below zero.
  if used >= 0 then
    selfAlloc = selfAlloc + used
    selfSamples = selfSamples + 1
  end
  frameFree = nil
end

--------------------------------------------------------------------------
-- Reading it back
--------------------------------------------------------------------------

-- The current picture, as a fresh table. Built on demand for the screen and
-- the advice engine - both of which run once per frame, so this is one
-- allocation per frame in the one place that cannot avoid it.
function Probe.snapshot(label)
  local s = Stats.summary(total)

  -- Prefer the mean of the closed sub-windows: it is the same measurement
  -- taken several times, which is what gives a spread to compare against.
  -- Before the first one closes, fall back to the running window so the
  -- screen shows a number within a second of being opened rather than "--".
  local fps = Stats.mean(series) or s.fps
  s.fps = fps
  s.spread = Stats.spread(series)
  s.subWindows = series.n
  s.gaps = gaps

  s.usage    = usageSamples > 0 and (usageSum / usageSamples) or nil
  s.usageMax = usageMax
  s.freeMemory = heap.last
  s.minFree    = heap.minFree
  s.allocPerFrame = Stats.allocPerFrame(heap)
  s.collections   = heap.collections
  s.selfAlloc = selfSamples > 0 and (selfAlloc / selfSamples) or nil
  s.label = label
  return s
end

-- Capture the current picture as the thing to compare against, and start
-- measuring again. Returns the snapshot stored.
function Probe.mark(label)
  local snap = Probe.snapshot(label)
  -- Refuse to mark a baseline there is not enough evidence for. A comparison
  -- against two seconds of noise is worse than no comparison: it produces a
  -- confident-looking delta that means nothing.
  if snap.fps == nil then return nil end
  Probe.baseline = snap
  Probe.baselineLabel = label
  Probe.restart()
  return snap
end

function Probe.clearBaseline()
  Probe.baseline = nil
  Probe.baselineLabel = nil
end

-- nil until a baseline exists; otherwise the verdict from Stats.compare.
function Probe.comparison(current)
  if not Probe.baseline then return nil end
  return Stats.compare(Probe.baseline, current or Probe.snapshot())
end

return Probe

end
