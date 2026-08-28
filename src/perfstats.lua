-- ZelionPerf layer 1: frame-timing statistics.
--
-- Pure arithmetic over frame periods. No host calls, no EdgeTX types, no
-- state outside the tables it is handed - which is what makes the awkward
-- parts (quantisation, garbage-collection sawtooth, is-this-difference-real)
-- testable on a desktop instead of guessed at on a radio.
--
-- THE CLOCK IS THE WHOLE PROBLEM. EdgeTX gives Lua one time source,
-- getTime(), counting 10ms ticks. A colour radio draws its UI at roughly
-- 20-40 frames per second, so a single frame period is 3 or 4 ticks and any
-- one measurement of it is wrong by up to a third. Everything below exists to
-- get trustworthy numbers out of a clock that coarse:
--
--   * The frame rate is taken from the SPAN of a window, not from the mean of
--     its samples. Consecutive periods telescope - (t1-t0) + (t2-t1) + ... is
--     just (tn-t0) - so a window of 60 frames carries one rounding error in
--     total rather than 60 of them. Over two seconds that is well under 1%.
--   * Percentiles are reported as they are measured, in whole ticks, and the
--     screen labels them in 10ms steps. A p95 quoted as "37.4ms" from this
--     clock would be a fiction.
--   * Stalls are counted with an absolute floor far above the noise. A frame
--     period of 3 ticks against 4 is quantisation; 25 against 4 is the radio
--     stopping, and that is the thing a pilot actually sees.

return function(ZD)

local Stats = {}
ZD.PerfStats = Stats

-- Frame periods are clamped into the histogram at 5 seconds. Anything longer
-- is the widget having been off-screen, not a slow frame, and is discarded by
-- the sampler before it reaches here - the clamp is only a backstop against
-- one absurd sample stretching the histogram walk.
local MAX_TICK = 500

-- A frame this long is a visible hitch rather than a slow average, whatever
-- the radio's baseline rate. 20 ticks is 200ms: about the point at which a
-- moving needle is seen to jump rather than to travel.
Stats.STALL_FLOOR_TICKS = 20

-- ...and anything this many times the typical frame counts too, so a stutter
-- on a radio that is already running at 12fps is still called one.
Stats.STALL_RATIO = 3

--------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------
--
-- A window accumulates the frame periods seen between two points in time. It
-- holds a histogram rather than the samples themselves: frame periods are
-- small integers, so counting them costs a fixed handful of table slots
-- however long the window runs, and a profiler that grows its own working set
-- every frame is a profiler measuring its own garbage collection.

function Stats.newWindow()
  return {
    frames = 0,       -- periods recorded (one fewer than frames observed)
    span   = 0,       -- ticks from the first period to the last
    hist   = {},      -- [tickCount] = howManyFrames
    worst  = 0,       -- longest single period, in ticks
    over   = 0,       -- periods longer than MAX_TICK
  }
end

function Stats.add(w, dtTicks)
  local dt = math.floor(tonumber(dtTicks) or 0)
  if dt < 0 then return end
  w.frames = w.frames + 1
  w.span   = w.span + dt
  if dt > w.worst then w.worst = dt end
  if dt > MAX_TICK then
    w.over = w.over + 1
    dt = MAX_TICK
  end
  w.hist[dt] = (w.hist[dt] or 0) + 1
end

function Stats.isEmpty(w)
  return not w or w.frames == 0
end

-- Frames per second across the window.
--
-- Returns nil rather than a number when there is not enough to say. A window
-- of one frame has a span of one period and would report a confident figure
-- from a single 10ms-quantised sample; a window whose span is zero would
-- report infinity. Both are worse than "not yet".
Stats.MIN_FRAMES_FOR_FPS = 8

function Stats.fps(w)
  if not w or w.frames < Stats.MIN_FRAMES_FOR_FPS or w.span <= 0 then
    return nil
  end
  return w.frames * 100 / w.span
end

-- The period at the given percentile, in ticks. Walks the histogram in
-- ascending tick order, which is a sort the keys already give for free.
--
-- Bounded by the worst frame seen rather than by MAX_TICK. On a healthy radio
-- the worst frame is about 5 ticks, so this is a five-step loop instead of a
-- five-hundred-step one - and it runs three times per frame, inside the tool
-- whose entire job is not to cost frames.
function Stats.percentile(w, p)
  if Stats.isEmpty(w) then return nil end
  local target = w.frames * (tonumber(p) or 50) / 100
  local seen = 0
  for tick = 0, math.min(w.worst, MAX_TICK) do
    local n = w.hist[tick]
    if n then
      seen = seen + n
      if seen >= target then return tick end
    end
  end
  return w.worst
end

-- How many frames took long enough to be seen as a stutter.
--
-- The threshold is the larger of the absolute floor and a multiple of the
-- typical frame, so it means the same thing on a radio running at 40fps as on
-- one running at 12. Returned alongside the threshold used, because "4 stalls"
-- means nothing without it.
function Stats.stalls(w)
  if Stats.isEmpty(w) then return 0, Stats.STALL_FLOOR_TICKS end
  local typical = Stats.percentile(w, 50) or 0
  local threshold = math.max(Stats.STALL_FLOOR_TICKS,
                             typical * Stats.STALL_RATIO)
  local n = 0
  for tick, count in pairs(w.hist) do
    if tick >= threshold then n = n + count end
  end
  n = n + w.over
  return n, threshold
end

function Stats.summary(w)
  local stalls, threshold = Stats.stalls(w)
  return {
    frames    = w and w.frames or 0,
    fps       = Stats.fps(w),
    p50       = Stats.percentile(w, 50),
    p95       = Stats.percentile(w, 95),
    worst     = w and w.worst or 0,
    stalls    = stalls,
    stallAt   = threshold,
  }
end

--------------------------------------------------------------------------
-- Series
--------------------------------------------------------------------------
--
-- A short ring of recent sub-window frame rates. Its purpose is not to draw a
-- graph: it is to answer "how much does this number move when nothing has
-- changed", which is the only thing that makes a before-and-after comparison
-- worth printing.

function Stats.newSeries(cap)
  return { cap = tonumber(cap) or 8, n = 0, next = 1 }
end

function Stats.push(s, v)
  v = tonumber(v)
  if v == nil then return end
  s[s.next] = v
  s.next = s.next % s.cap + 1
  if s.n < s.cap then s.n = s.n + 1 end
end

function Stats.mean(s)
  if not s or s.n == 0 then return nil end
  local sum = 0
  for i = 1, s.n do sum = sum + s[i] end
  return sum / s.n
end

-- Full range rather than a standard deviation. With at most eight samples a
-- deviation is barely better than the range and much harder to explain, and
-- the number is going on screen next to the words "run to run".
function Stats.spread(s)
  if not s or s.n < 2 then return nil end
  local lo, hi = s[1], s[1]
  for i = 2, s.n do
    if s[i] < lo then lo = s[i] end
    if s[i] > hi then hi = s[i] end
  end
  return hi - lo
end

--------------------------------------------------------------------------
-- Heap tracking
--------------------------------------------------------------------------
--
-- Free Lua heap does not fall smoothly, it saws: down as scripts allocate, up
-- in a step every time the collector runs. So the useful figure is not the
-- slope of the line - which averages the two and reports something close to
-- zero for a script allocating hard - but the sum of the DOWNWARD moves. That
-- is bytes actually allocated, and dividing it by frames gives the number
-- that predicts how often collection will interrupt a frame.

-- A rise this small is measurement noise or another script freeing an object,
-- not a collection. Counting those would report a collector running every
-- frame on a radio that is perfectly healthy.
local COLLECTION_RISE = 512

function Stats.newHeap()
  return { samples = 0, allocated = 0, collections = 0,
           minFree = nil, maxFree = nil, last = nil }
end

function Stats.heapSample(h, free)
  free = tonumber(free)
  if free == nil then return end
  h.samples = h.samples + 1
  if h.minFree == nil or free < h.minFree then h.minFree = free end
  if h.maxFree == nil or free > h.maxFree then h.maxFree = free end
  if h.last ~= nil then
    local d = free - h.last
    if d < 0 then
      h.allocated = h.allocated - d
    elseif d >= COLLECTION_RISE then
      h.collections = h.collections + 1
    end
  end
  h.last = free
end

-- Bytes allocated per frame, or nil before there is a second sample to
-- difference against.
--
-- A slight UNDERESTIMATE, unavoidably: in the frame where the collector runs,
-- what it handed back and what was allocated arrive as one net rise, and the
-- allocation inside it cannot be separated out. So the figure misses roughly
-- one frame's worth per collection. It is reported as a floor on what is
-- being allocated rather than corrected by a guess.
function Stats.allocPerFrame(h)
  if not h or h.samples < 2 then return nil end
  return h.allocated / (h.samples - 1)
end

--------------------------------------------------------------------------
-- Before and after
--------------------------------------------------------------------------

-- Below this, two frame rates are the same number as far as anyone can tell.
-- It exists because spread can legitimately come back as zero - eight
-- sub-windows that all landed on the same quantised figure - and a zero noise
-- floor would declare a 0.05fps difference an improvement.
Stats.FPS_NOISE_FLOOR = 0.5

-- Compare two snapshots taken by the sampler.
--
-- Returns a table, never nil, so the screen always has something to print:
--   delta    change in frame rate, positive being faster, or nil if unknowable
--   noise    the band inside which the two are indistinguishable
--   verdict  "better" | "worse" | "same" | "unknown"
--
-- The verdict is deliberately conservative. A pilot who removes a script,
-- sees "3 fps faster" and it was noise will not trust the next reading, so a
-- difference smaller than the run-to-run spread is reported as no change
-- rather than as a small one.
function Stats.compare(before, after)
  local out = { delta = nil, noise = nil, verdict = "unknown" }
  if type(before) ~= "table" or type(after) ~= "table" then return out end
  local a, b = tonumber(before.fps), tonumber(after.fps)
  if a == nil or b == nil then return out end

  local noise = math.max(tonumber(before.spread) or 0,
                         tonumber(after.spread) or 0,
                         Stats.FPS_NOISE_FLOOR)
  local delta = b - a
  out.delta, out.noise = delta, noise
  if math.abs(delta) <= noise then
    out.verdict = "same"
  elseif delta > 0 then
    out.verdict = "better"
  else
    out.verdict = "worse"
  end
  return out
end

--------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------
--
-- Here rather than in the renderer, because how precisely a number may be
-- printed is a property of how it was measured. A frame period read from a
-- 10ms clock is shown in 10ms steps; printing it to a tenth of a millisecond
-- would claim an accuracy the clock cannot give and would make the analyser
-- look more certain than it is.

function Stats.ticksToMs(ticks)
  if ticks == nil then return nil end
  return math.floor(ticks) * 10
end

function Stats.fmtMs(ticks)
  if ticks == nil then return "--" end
  return string.format("%dms", Stats.ticksToMs(ticks))
end

function Stats.fmtFps(fps)
  if fps == nil then return "--" end
  if fps >= 100 then return string.format("%d", math.floor(fps + 0.5)) end
  return string.format("%.1f", fps)
end

function Stats.fmtBytes(n)
  if n == nil then return "--" end
  if math.abs(n) >= 10240 then
    return string.format("%.0fk", n / 1024)
  end
  if math.abs(n) >= 1024 then
    return string.format("%.1fk", n / 1024)
  end
  return string.format("%d", math.floor(n + 0.5))
end

return Stats

end
