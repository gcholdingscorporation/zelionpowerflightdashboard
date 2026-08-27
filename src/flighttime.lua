-- Layer 5e: Flight time remaining.
--
-- The number a heli pilot actually wants and no telemetry stream carries:
-- how long until you have to be on the ground.
--
-- Voltage is a late signal on an electric heli. Sag under load dominates, so
-- a cell alert fires when you are already most of the way through the pack -
-- the logged flights that prompted this were landing at 24-42% having tripped
-- the 3.40 V alert. Consumed capacity is the early, linear one.
--
-- Deliberately does NOT need to know the pack size. Capacity used is a real
-- number of mAh and battery percent is a fraction of the whole, so the two
-- together give the remainder directly:
--
--   remaining = used * (pct - reserve) / (100 - pct)
--
-- 580 mAh gone with 42% showing implies 420 mAh left of a 1000 mAh pack, and
-- nobody had to tell the widget it was a 1000. That matters because the same
-- radio flies a 400 mAh 2S and a 12S 700, and a pack size configured once is
-- a pack size that is wrong the next time you change battery.

return function(ZD)

local Host   = ZD.Host
local State  = ZD.State
local Config = ZD.Config

local FlightTime = {}
ZD.FlightTime = FlightTime

-- Draw rate is averaged over a window rather than read instantaneously.
-- Hovering and hard 3D differ by an order of magnitude, and an estimate that
-- swings between four minutes and forty seconds on every collective pump is
-- worse than no estimate - a pilot stops believing it, which is the same way
-- alerts fail.
FlightTime.WINDOW   = Host.seconds(30)
-- Below this span the rate is noise, not a measurement.
FlightTime.MIN_SPAN = Host.seconds(8)
-- Percent must have moved this far before the remainder arithmetic means
-- anything. Near 100% the divisor collapses and the answer runs to infinity.
FlightTime.MAX_PCT  = 95
FlightTime.CAP      = 3600      -- an hour; anything beyond is not a real answer

FlightTime.seconds = nil        -- the estimate, or nil when none can be made
FlightTime.rate    = nil        -- mAh per second, averaged
FlightTime.why     = "idle"     -- why there is no estimate, in a pilot's terms

local samples = {}
local floorSeconds = nil        -- monotonic clamp, see below

local function reset()
  samples = {}
  floorSeconds = nil
  FlightTime.seconds = nil
  FlightTime.rate    = nil
end

FlightTime.reset = reset

local function reserve()
  return Config.setting("reservePct")
end

-- Returns seconds, or nil plus the reason.
local function estimate(now)
  local used, usedOk = State.get("capacity")
  local pct,  pctOk  = State.get("batteryPercent")
  if not usedOk then return nil, "no capacity sensor" end
  if not pctOk  then return nil, "no battery percent" end

  samples[#samples + 1] = { t = now, used = used }
  while #samples > 1 and (now - samples[1].t) > FlightTime.WINDOW do
    table.remove(samples, 1)
  end

  local first = samples[1]
  local span  = now - first.t
  if span < FlightTime.MIN_SPAN then return nil, "measuring" end

  -- Capacity used only ever increases. A decrease means the flight controller
  -- reset its counter - a new pack - so start over rather than reporting a
  -- negative draw.
  local drawn = used - first.used
  if drawn < 0 then
    reset()
    return nil, "new pack"
  end

  local seconds_span = span / Host.TICKS_PER_SECOND
  local rate = drawn / seconds_span          -- mAh per second
  FlightTime.rate = rate
  if rate <= 0 then return nil, "not drawing" end

  if pct > FlightTime.MAX_PCT then return nil, "pack too full to tell" end
  local left = pct - reserve()
  if left <= 0 then return 0, nil end

  -- No pack size required: used mAh is an absolute quantity and pct is the
  -- fraction still in there, so the remainder follows from the two.
  local remaining = used * left / (100 - pct)
  local secs = remaining / rate
  if secs ~= secs or secs == math.huge then return nil, "cannot tell" end
  if secs > FlightTime.CAP then secs = FlightTime.CAP end
  return secs, nil
end

function FlightTime.service(now)
  now = now or Host.now()

  if not State.armed then
    reset()
    FlightTime.why = "idle"
    return
  end

  local secs, why = estimate(now)
  if secs == nil then
    FlightTime.seconds = nil
    FlightTime.why = why or "cannot tell"
    return
  end

  -- Monotonic: the estimate may only fall. Two reasons. A number that climbs
  -- while you fly reads as broken even when it is arithmetically right after
  -- a spell of hovering. And EdgeTX announces a countdown by watching for
  -- threshold crossings, so a value that drifts back up over 60 would
  -- announce "one minute" twice.
  if floorSeconds == nil or secs < floorSeconds then
    floorSeconds = secs
  end
  FlightTime.seconds = floorSeconds
  FlightTime.why = "ok"
end

--------------------------------------------------------------------------
-- Driving an EdgeTX timer
--------------------------------------------------------------------------
--
-- Rather than inventing an announcement system, write the estimate into a
-- real EdgeTX timer and let the radio do the talking. The pilot already
-- configures countdown voice, minute calls and haptic on the timer page, in
-- their own language - and the timer shows up on the header bar and every
-- telemetry screen, not only on this widget.
--
-- Only `value` is written. Mode, name, countdown beeps and haptic belong to
-- the pilot; a widget that overwrote those would fight the settings page.

FlightTime.timerIndex = nil     -- nil = off, else 0-based EdgeTX timer index

local lastWritten = nil

function FlightTime.driveTimer()
  local idx = FlightTime.timerIndex
  if idx == nil then return false end

  local secs = FlightTime.seconds
  if secs == nil then return false end
  secs = math.floor(secs + 0.5)

  -- Once a second at most. The estimate is a 30 second average; writing it at
  -- 10 Hz would be ten times the work for the same number.
  if lastWritten == secs then return false end
  lastWritten = secs

  return Host.setTimer(idx, { value = secs })
end

-- For the sensor map. "why" is the whole point: an estimate that is simply
-- absent looks identical whether the sensor is missing, the pack is too full
-- to tell yet, or the maths gave up.
function FlightTime.clock()
  local s = FlightTime.seconds
  if s == nil then return "--" end
  s = math.floor(s + 0.5)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- Which EdgeTX timer is being overwritten, for the sensor map. Nothing else
-- on the radio says. Point this at a timer already in use and it quietly
-- stops being that timer - the pilot's own flight timer replaced by this
-- countdown, wearing its name and its settings, and no way to tell until you
-- are in the air wondering why it reads wrong.
--
-- Shown rather than forbidden. A hard refusal would also block someone doing
-- it deliberately, and the problem here was never the choice - it was that
-- the choice was invisible.
function FlightTime.timerLabel()
  local idx = FlightTime.timerIndex
  if idx == nil then return nil end
  return string.format("T%d", idx + 1)
end

function FlightTime.resetTimerWrite()
  lastWritten = nil
end

return FlightTime

end
