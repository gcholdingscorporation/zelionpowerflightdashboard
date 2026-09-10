-- Layer 5f: Pack internal resistance, measured in flight.
--
-- A pack announces that it is finished long before its capacity does. What
-- goes first is internal resistance: the same throttle punch sags further
-- every month, and by the time the mAh figure has visibly dropped the pack has
-- been unpleasant to fly for a while. Resistance is the early signal, and it
-- is the one number here that cannot be read off any sensor.
--
-- The physics is a straight line:
--
--   V_cell = V_open(charge) - I * R
--
-- so cell voltage plotted against current has slope -R. That is the whole
-- measurement. The difficulty is V_open, which falls as the pack empties: a
-- regression across a whole flight blends the resistance slope with the
-- depletion slope and reports neither.
--
-- WHY NOT THE SIMPLER THING. The obvious approach - and the one the flight log
-- was already collecting for - is to divide the flight's voltage sag by its
-- peak current. Against 47 real flights that produced a believable 3.5 mOhm on
-- a 12S pack and a 4x spread of nonsense on a 3S micro. The two figures are
-- the extremes of the WHOLE FLIGHT and need not have happened at the same
-- moment; on a heli flown in long pulls they nearly coincide, and on one flown
-- in short punches they do not. It looked right on the aircraft that happened
-- to suit it, which is the most dangerous way for a measurement to be wrong.
--
-- So: regress over a SHORT WINDOW, inside which V_open is effectively fixed,
-- and take the median across the windows of a flight.

return function(ZD)

local Host  = ZD.Host
local State = ZD.State

local PackHealth = {}
ZD.PackHealth = PackHealth

-- Long enough for the current to move usefully, short enough that the pack
-- does not measurably deplete inside it.
PackHealth.WINDOW = Host.seconds(3)

-- The guard that matters most. Fitting a line to points that all share one x
-- divides by nearly zero and returns a huge, confident, meaningless number.
-- Expressed per cell so it means the same on a 3S micro and a 12S 700: the
-- current a pack sees scales with the aircraft, not with the cell count.
PackHealth.MIN_SPREAD_A = 8

-- A flight is worth reporting only once several windows agree. Two windows is
-- not a measurement.
PackHealth.MIN_WINDOWS = 5

-- Outside this it is not a battery. A healthy 12S cell sits near 3.5 mOhm and
-- a small high-C pack rather higher, so the band is deliberately wide: its job
-- is to reject arithmetic that has gone wrong, not to have an opinion on packs.
PackHealth.MIN_MOHM, PackHealth.MAX_MOHM = 0.5, 200

PackHealth.milliohms = nil   -- the flight's figure, or nil when there is none
PackHealth.windows   = 0     -- how many windows agreed it

local samples = {}           -- the current window's per-cell readings
local results = {}           -- one resistance per completed window
local windowStart = nil

local function reset()
  samples, results = {}, {}
  windowStart = nil
  PackHealth.milliohms = nil
  PackHealth.windows   = 0
end

PackHealth.reset = reset

-- Least squares through the window. Returns milliohms per cell, or nil when
-- the window cannot support a slope.
local function solve()
  -- Two points define a line; fewer define nothing, and this also guards the
  -- indexing below. There was a larger threshold here, on the theory that a
  -- thin window cannot average its noise away - but the noise is handled by
  -- the spread guard and the median, and nothing could be made to fail when
  -- the threshold was removed. A number that no test can justify is a number
  -- somebody will later tune in the dark.
  local n = #samples
  if n < 2 then return nil end

  local lo, hi = samples[1].i, samples[1].i
  for k = 2, n do
    local i = samples[k].i
    if i < lo then lo = i end
    if i > hi then hi = i end
  end
  if (hi - lo) < PackHealth.MIN_SPREAD_A then return nil end

  local si, sv, sii, siv = 0, 0, 0, 0
  for k = 1, n do
    local i, v = samples[k].i, samples[k].v
    si, sv = si + i, sv + v
    sii, siv = sii + i * i, siv + i * v
  end

  local denom = n * sii - si * si
  if denom <= 0 then return nil end
  -- Slope is negative for a real pack - more current, less voltage - so the
  -- resistance is its negation. A positive slope is not a pack behaving oddly,
  -- it is a window whose voltage happened to rise while the current did, and
  -- the plausibility band below throws it out.
  local slope = (n * siv - si * sv) / denom
  return -slope * 1000
end

local function closeWindow()
  local mohm = solve()
  if mohm and mohm >= PackHealth.MIN_MOHM and mohm <= PackHealth.MAX_MOHM then
    results[#results + 1] = mohm
  end
  samples = {}
end

-- The median, not the mean. One glitched frame, or a moment where the ESC hits
-- its own current limit, drags a mean and leaves a median alone.
local function median(t)
  local n = #t
  if n == 0 then return nil end
  table.sort(t)
  if n % 2 == 1 then return t[(n + 1) / 2] end
  return (t[n / 2] + t[n / 2 + 1]) / 2
end

function PackHealth.service(now)
  now = now or Host.now()

  if not State.armed then
    reset()
    return
  end
  -- Deliberately parked with the model powered. Same reasoning as the extremes.
  if State.holdActive then return end

  -- VALID, deliberately not "trusted".
  --
  -- The latch marks a reading untrusted while it is still falling, which is the
  -- right rule for a recorded minimum and precisely the wrong one here: the
  -- samples taken during a hard punch are the ones furthest along the current
  -- axis, and they are what makes the line worth fitting. Requiring them to
  -- have settled first throws away the best half of the measurement.
  --
  -- The case that guard exists for is still covered, and better: a collapse
  -- does not make a reading untrusted, it makes it INVALID - the latch returns
  -- nothing at all once the fall passes 0.8 V/cell, or drops below the
  -- plausible-cell floor. So a decaying rail never reaches this line.
  if not State.valid("cellVoltage") then return end
  local amps, ampsOk = State.get("current")
  if not ampsOk then return end

  samples[#samples + 1] = { i = amps, v = State.num("cellVoltage") }

  if windowStart == nil then windowStart = now end
  if (now - windowStart) < PackHealth.WINDOW then return end
  windowStart = now
  closeWindow()

  if #results >= PackHealth.MIN_WINDOWS then
    -- median() sorts in place, so hand it a copy: results is still being
    -- appended to for the rest of the flight.
    local copy = {}
    for k = 1, #results do copy[k] = results[k] end
    PackHealth.milliohms = median(copy)
    PackHealth.windows   = #results
  end
end

return PackHealth

end
