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

-- The largest consumed-capacity figure seen, ACROSS flights.
--
-- The floor below outlives a landing, so something has to say when it must
-- not. This is that something: a flight controller resets its consumed-mAh
-- counter when it loses power, so a flight that opens lower than the last one
-- closed is a flight on a different pack.
local lastUsed = nil

-- Clears the per-flight measurement. The floor is deliberately NOT cleared
-- here - see newPack().
local function reset()
  samples = {}
  FlightTime.seconds = nil
  FlightTime.rate    = nil
end

-- Clears everything, including the floor and the pack memory.
local function newPack()
  reset()
  floorSeconds = nil
  lastUsed = nil
end

FlightTime.reset = newPack

local function reserve()
  return Config.setting("reservePct")
end

-- Returns seconds, or nil plus the reason.
local function estimate(now)
  local used, usedOk = State.get("capacity")
  local pct,  pctOk  = State.get("batteryPercent")
  if not usedOk then return nil, "no capacity sensor" end
  if not pctOk  then return nil, "no battery percent" end

  -- A new pack, detected across the gap between two flights.
  --
  -- The check below this one compares against the first sample of the CURRENT
  -- flight, and the samples are cleared on every landing - so on its own it
  -- can only catch a counter reset mid-flight, never a pack swapped between
  -- two. That was fine while the floor died at the landing too. It is not fine
  -- now: without this, a fresh pack inherits the last pack's floor, and a full
  -- battery reads forty seconds remaining with no way to climb back.
  if lastUsed and used < lastUsed - 1 then
    newPack()
    lastUsed = used
    return nil, "new pack"
  end
  lastUsed = used

  samples[#samples + 1] = { t = now, used = used }
  while #samples > 1 and (now - samples[1].t) > FlightTime.WINDOW do
    table.remove(samples, 1)
  end

  local first = samples[1]
  local span  = now - first.t
  if span < FlightTime.MIN_SPAN then return nil, "measuring" end

  -- Capacity used only ever increases. The cross-flight check above catches a
  -- counter reset; this one catches a drift smaller than its threshold that
  -- has still accumulated backwards across the window, which would otherwise
  -- give a negative rate and an estimate that grows as the pack empties.
  local drawn = used - first.used
  if drawn < 0 then
    newPack()
    return nil, "new pack"
  end

  local seconds_span = span / Host.TICKS_PER_SECOND
  local rate = drawn / seconds_span          -- mAh per second
  FlightTime.rate = rate
  if rate <= 0 then return nil, "not drawing" end

  -- Belt and braces on the same question. A pack reading this full cannot be
  -- the one just landed on, whatever the capacity counter says - a flight
  -- controller that kept power through the swap, or a percentage published
  -- from voltage rather than coulombs, would slip past the check above.
  if pct > FlightTime.MAX_PCT then
    -- The floor only. Not newPack(), which also throws away the samples and so
    -- restarts the eight-second measuring window - and since this branch is
    -- reached on every pass while the pack reads full, it never got past it:
    -- measure for eight seconds, wipe, measure for eight seconds, forever.
    -- The rate is a fine measurement here; it is the remainder arithmetic that
    -- cannot be done on a pack this full.
    floorSeconds = nil
    return nil, "pack too full to tell"
  end
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
    -- reset(), not newPack(): the rate has to be re-measured on the next
    -- flight, but the floor belongs to the PACK and the pack is still on the
    -- aircraft. Clearing it here is what silenced the countdown on a second
    -- flight - the estimate was rebuilt from scratch, the timer jumped back
    -- up, and EdgeTX does not re-announce a threshold it has already spoken.
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

-- What the timer should read when there is no estimate.
--
-- The pilot's own configured start, which is what the timer reads after a
-- reset: a countdown sitting at its start says "ready", which is exactly true
-- and is neither the last pack's number nor an announcement. EdgeTX already
-- puts it there itself at model load on a non-persistent timer; this stops the
-- widget overwriting it with something worse.
--
-- A timer with no start configured - counting up, or simply never set - has
-- nothing better available, so it keeps the zero.
local function idleValue(idx)
  local t = Host.timer(idx)
  local start = t and tonumber(t.start)
  if start and start > 0 then return math.floor(start) end
  return 0
end

function FlightTime.driveTimer()
  local idx = FlightTime.timerIndex
  if idx == nil then return false end

  -- No estimate means write the pilot's own start value, not zero and not
  -- nothing.
  --
  -- Writing nothing leaves the timer showing whatever the last flight left
  -- there: arm on a fresh pack and it reads four minutes, from the pack before
  -- it, until the new one falls below 95% and the estimate appears. A stale
  -- number that looks live is the one thing this widget exists not to do.
  --
  -- Zero was the first answer to that and it is wrong for a reason that only
  -- shows up on a radio: zero is not a neutral value on a countdown timer, it
  -- is a state, and EdgeTX announces it. Power the radio on with nothing
  -- flying, this writes zero before any flight exists, and the radio says
  -- "timer elapsed" on every boot. We meant it as "nothing to say" and the
  -- radio read it as "you are out of time" - an alert with no flight behind
  -- it, which is the same way alerts stop being believed.
  local secs = FlightTime.seconds
  if secs == nil then secs = idleValue(idx) else secs = math.floor(secs + 0.5) end

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
