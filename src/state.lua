-- Layer 3: State model.
--
-- Turns a stream of individual sensor reads into the thing the UI actually
-- needs: a current value, a session extreme, and an honest answer to "can I
-- trust this number right now".
--
-- The central rule, inherited from both reference dashboards: a missing sensor
-- and a sensor legitimately reading zero must never look the same. Every value
-- here carries a validity flag, and the renderer is expected to consult it.
--
-- This layer performs no drawing and touches no EdgeTX API except through the
-- host adapter, which is what makes the arm/session logic testable offline.

return function(ZD)

local Host    = ZD.Host
local Roles   = ZD.Roles
local Sensors = ZD.Sensors
local Config  = ZD.Config
local RF2     = ZD.RF2

local State = {}
ZD.State = State

-- Link state, in descending order of trustworthiness:
--   true/false  Rotorflight RF Tool told us authoritatively
--   nil         RF Tool unavailable - callers must fall back to inference
-- Kept separate from "do we have telemetry" so the alert engine can tell a
-- genuinely dead link from a sensor that simply is not configured.
State.linkConnected = nil

-- Telemetry is serviced at 10 Hz. Nothing on a heli dashboard changes usefully
-- faster than that, and it keeps the widget off the radio's CPU budget.
State.SERVICE_INTERVAL = Host.seconds(0.1)

-- values[role] = { value, valid, status, min, max, hasExtremes }
State.values     = {}
State.modelName  = nil
State.armed      = false
State.holdActive = false

-- Session bookkeeping. A "session" runs from arm to disarm; extremes reset on
-- arm so each flight reports its own peaks rather than the day's.
State.flightSeconds   = 0
State.sessionStarted  = false

-- Captured for the flight log, so that a database worth modelling accumulates
-- before anything is built on it. None of this is displayed.
--
-- Resting voltage is sampled while DISARMED and frozen at arm, not read at the
-- moment of arming. With rotor-based arming the head is already turning by
-- then, so "the voltage at arm" would be a voltage under load - which is the
-- one number this is useless without, since sag is the whole point.
State.startPackVoltage = nil
State.startCellVoltage = nil
State.lastServiceTick = -1e9

local lastSecondTick = nil
local restPack, restCell = nil, nil
local currentSum, currentCount = 0, 0

-- The rotor-arming latch. Declared up here rather than beside the arm code
-- below because resetSession clears it: a `local` further down the file is not
-- in scope at that point, so the assignment silently created a global instead
-- and the latch survived a model change.
local spunUp, belowSince = false, nil

-- Telling a supply collapse from load sag.
--
-- When the main pack is unplugged, or a connector lets go in the air, the FC
-- does not stop talking: it runs on the ESC's capacitors or a backup buffer
-- and keeps sending while the rail decays - 4.1 V/cell, then 2.9, then 1.4,
-- then 0. Every one of those is a plausible-looking number, so the widget
-- recorded them as the flight's minimum, and announced "battery critical,
-- zero volts" on the way down. Both are wrong, and the second is the kind of
-- wrong that makes a pilot distrust the alert that matters.
--
-- The physical distinction, and it is a clean one:
--
-- A collapse KEEPS FALLING. Sag stops and holds, then recovers. That, rather
-- than the size of any single step, is the discriminator - and it has to be,
-- because a single step here is not a fixed slice of time. Telemetry arrives
-- at the flight controller's rate, not the widget's, so one service pass may
-- carry 100 ms of change or 500 ms of it, and any "too big for one frame"
-- rule is really a rule about how fast the sensor happens to update.
--
-- So a fall large enough to be worth questioning is never accepted on the
-- strength of one reading. It is held pending, and the NEXT reading decides:
--
--   still falling  -> a decay. Refused, and the collapse is declared.
--   holding steady -> a real value. Accepted once it has held.
--
-- How long "held" means is the one thing that differs by state. Armed, a real
-- sag has to show almost immediately or the dashboard is lying during the
-- part of the flight that matters, so the window is a fraction of a second.
-- Disarmed there is no load at all, a genuinely lower pack can only be one
-- somebody just plugged in, and it will sit there all day - so the window is
-- seconds, and a decay never survives it.
--
-- A refused reading is not shown, not recorded and not alerted on. It does not
-- freeze the old value in its place either: a stale number that looks live is
-- the thing this whole widget is built to avoid.
-- Measured over an unbroken RUN of falling readings, never over one step.
--
-- A step threshold was tried first and it does not work, for a reason worth
-- writing down: a decay does not arrive in one jump. It walks down - 3.55,
-- 2.95, 2.35, 1.75 - and every one of those steps is small enough to pass for
-- sag. Four "ordinary" readings later the flight's minimum is 1.75 V. What
-- gives it away is not any single step but that it never stops. Sag stops,
-- and then it recovers, because the pilot eases off.
--
-- So: while a reading is falling it is DISPLAYED but not TRUSTED. The tile
-- shows what the sensor says, live, because that is what a dashboard is for.
-- The flight's minimum and the low-cell alarm wait for the fall to stop -
-- which is a fraction of a second of real sag, and never, for a decay.
-- If the run's total fall passes the bar below, it is a collapse.
State.COLLAPSE_FALL_CELL = 0.8   -- total fall in one unbroken run, per cell
-- Any change smaller than this is noise, not a fall, and ends a run.
State.FALL_EPSILON       = 0.05
-- How long a fall has to have stopped before its value is trusted. Armed, a
-- real sag has to reach the alarm quickly or the alarm is late; disarmed there
-- is no load, so the only thing that legitimately reads lower is a pack
-- somebody just plugged in, and that will sit there all day.
State.ARMED_SETTLE       = Host.seconds(0.3)
State.VOLT_SETTLE        = Host.seconds(3)
-- A connected cell reads its real 3.3-4.2 V or collapses towards zero. Nothing
-- in between is a cell, so this floor can never mask a genuine low-cell alert:
-- it sits far below the ~3.3 V where one would fire.
State.MIN_PLAUSIBLE_CELL = 1.0

-- True for the pass in which a reading was refused as a collapse.
State.supplyCollapsed = false
-- Latched while the main supply is gone in flight. Cleared by a healthy
-- reading, and by disarming - a normal unplug on the bench is not an emergency.
State.powerLost = false

local function blank()
  return { value = nil, valid = false, status = "unbound",
           min = nil, max = nil, hasExtremes = false }
end

local function slot(role)
  local s = State.values[role]
  if not s then
    s = blank()
    State.values[role] = s
  end
  return s
end

--------------------------------------------------------------------------
-- Accessors used by the renderer
--------------------------------------------------------------------------

-- Returns value, valid. Callers that just want a number for arithmetic can use
-- State.num(role, default); anything user-visible should check validity.
function State.get(role)
  local s = State.values[role]
  if not s then return nil, false end
  return s.value, s.valid
end

function State.num(role, default)
  local s = State.values[role]
  if not s or not s.valid then return default or 0 end
  return s.value
end

function State.valid(role)
  local s = State.values[role]
  return s ~= nil and s.valid
end

function State.status(role)
  local s = State.values[role]
  return s and s.status or "unbound"
end

function State.max(role)
  local s = State.values[role]
  if not s or not s.hasExtremes then return nil end
  return s.max
end

function State.min(role)
  local s = State.values[role]
  if not s or not s.hasExtremes then return nil end
  return s.min
end

--------------------------------------------------------------------------
-- Session control
--------------------------------------------------------------------------

function State.resetExtremes()
  for role, s in pairs(State.values) do
    s.min = nil
    s.max = nil
    s.hasExtremes = false
  end
end

-- Mean current over the flight, as opposed to the peak the log already keeps.
-- A peak says how hard you hit it once; a mean says how you flew.
function State.avgCurrent()
  if currentCount == 0 then return nil end
  return currentSum / currentCount
end

-- Whether a reading is settled enough to act on, as opposed to merely being
-- the latest thing the sensor said. Only voltages are ever untrusted.
function State.trusted(role)
  local s = State.values[role]
  return s ~= nil and s.valid == true and s.trusted ~= false
end

function State.resetSession()
  State.resetExtremes()
  currentSum, currentCount = 0, 0
  State.startPackVoltage, State.startCellVoltage = nil, nil
  spunUp, belowSince = false, nil
  latch = {}
  cellsCache = nil
  State.supplyCollapsed, State.powerLost = false, false
  State.flightSeconds  = 0
  State.sessionStarted = false
  lastSecondTick = nil
end

function State.reloadModel()
  local name = Host.modelName()
  State.modelName = name
  State.values = {}
  Sensors.reload(name)
  -- The next model is quite possibly the other helicopter.
  ZD.Profiles.reset()
  State.resetSession()
end

--------------------------------------------------------------------------
-- Governor
--------------------------------------------------------------------------

-- Rotorflight's governor state codes. Both the dashboard and the alert engine
-- ask for this, so it lives here rather than in either of them.
local GOV_STATES = {
  [0]="OFF", [1]="IDLE", [2]="SPOOLUP", [3]="RECOVERY", [4]="ACTIVE",
  [5]="THR-OFF", [6]="LOST-HS", [7]="AUTOROT", [8]="BAILOUT", [9]="BYPASS",
}

State.GOV_STATES = GOV_STATES

-- Returns "--" when unbound, so a caller that just wants something to print
-- can use it directly; callers that care must check State.valid("governor").
function State.governorText()
  local g, ok = State.get("governor")
  if not ok then return "--" end
  return GOV_STATES[math.floor(g)] or "UNKNOWN"
end

--------------------------------------------------------------------------
-- Arm detection
--------------------------------------------------------------------------

-- Rotorflight publishes ARM as a bit field; bit 0 set means armed, which covers
-- 1, 3, 5, 7 and so on. Lua 5.2 in EdgeTX has no reliable bitwise operators
-- across builds, so test the low bit arithmetically.
local function armedFromFlags(flags)
  if flags == nil then return nil end
  return (math.floor(flags) % 2) == 1
end

-- armSwitch is an optional EdgeTX source id used only when the model publishes
-- no ARM telemetry at all. Telemetry always wins when present: a switch says
-- what the pilot asked for, telemetry says what the aircraft did.
State.armSwitch = nil

-- Which way round the switch is. EdgeTX reports a two-position switch as
-- -1024 and +1024, and which end means "armed" depends entirely on how the
-- switch is mounted and set up - there is nothing in the value to say. Arming
-- with the switch back therefore reads as permanently armed, and the widget
-- has no way to know it is wrong: it would run the flight timer on the bench
-- and log a flight the moment you switched off.
State.armInvert = false

-- Last resort: the rotor itself. A flight controller that publishes no ARM
-- flags and a pilot who has not nominated a switch would otherwise never
-- record a flight, never reset their peaks and never run the flight timer -
-- which is the case on every non-Rotorflight stack tried so far.
--
-- Spinning is not quite flying, but it is the honest signal available, and it
-- is the one a flight log wants anyway: the interesting numbers all happen
-- while the head is turning. Hysteresis keeps a spool-down from ending the
-- flight, and the landing delay keeps a momentary dropout from doing so.
-- Defaults, used until an aircraft profile says otherwise. They suit a large
-- heli, which idles far below 250; a 200-size flies at around 5000 rpm and
-- would have its spool-up counted as a flight at these numbers.
State.SPIN_UP        = 250     -- rpm: the head is turning, call it a flight
State.SPIN_DOWN      = 100     -- rpm: below this, start counting down
State.LANDED_SECONDS = 5

local function spinThresholds()
  local up, down = ZD.Profiles.spin()
  return up or State.SPIN_UP, down or State.SPIN_DOWN
end

local function armedFromRotor(now)
  local hs, ok = State.get("headspeed")
  if not ok then
    -- No headspeed at all is not a landing; it is a dropout. Hold the state.
    return spunUp
  end
  local spinUp, spinDown = spinThresholds()
  if hs >= spinUp then
    spunUp, belowSince = true, nil
  elseif spunUp and hs < spinDown then
    if belowSince == nil then belowSince = now end
    if (now - belowSince) >= Host.seconds(State.LANDED_SECONDS) then
      spunUp, belowSince = false, nil
    end
  else
    belowSince = nil
  end
  return spunUp
end

local function readArmed(now)
  local flags, status = Sensors.read("armFlags")
  if status == "ok" then
    local a = armedFromFlags(flags)
    if a ~= nil then return a, "telemetry" end
  end
  if State.armSwitch and State.armSwitch ~= 0 then
    local v = Host.read(State.armSwitch)
    if v ~= nil then
      local on = v > 0
      if State.armInvert then on = not on end
      return on, State.armInvert and "switch (inv)" or "switch"
    end
  end
  if State.valid("headspeed") or spunUp then
    return armedFromRotor(now or Host.now()), "rotor"
  end
  return false, "none"
end

State.armSource = "none"

--------------------------------------------------------------------------
-- Service pass
--------------------------------------------------------------------------

-- How many cells the pack has, so a per-cell threshold can be applied to a
-- pack-voltage reading. From the sensor when the FC publishes one, otherwise
-- from the ratio of the two voltages, and remembered: the moment the numbers
-- are needed is the moment they have stopped being trustworthy.
local cellsCache = nil

function State.cells()
  local n, ok = State.get("cellCount")
  if ok and n and n >= 1 then
    cellsCache = math.floor(n + 0.5)
    return cellsCache
  end
  local pack, pOk = State.get("packVoltage")
  local cell, cOk = State.get("cellVoltage")
  if pOk and cOk and pack and cell and cell > State.MIN_PLAUSIBLE_CELL then
    local guess = math.floor(pack / cell + 0.5)
    if guess >= 1 and guess <= 16 then cellsCache = guess end
  end
  return cellsCache
end

-- role -> { held = last accepted reading, pend = { v, t } }
local latch = {}

-- Returns the reading to use, or nil when it was refused. `scale` converts a
-- per-cell threshold into this role's own units: 1 for a cell reading, the
-- cell count for a pack reading.
-- Returns: value to display (nil when there is nothing honest to show), and
-- whether that value may be trusted to set a minimum or raise an alarm.
local function latchVoltage(role, raw, scale, now)
  local eps    = State.FALL_EPSILON       * scale
  local total  = State.COLLAPSE_FALL_CELL * scale
  local floor  = State.MIN_PLAUSIBLE_CELL * scale
  local settle = State.armed and State.ARMED_SETTLE or State.VOLT_SETTLE

  local L = latch[role]
  if not L then L = {}; latch[role] = L end
  L.staleSince = nil

  -- Below the floor there is no supply at all. The decay's own tail, and the
  -- one case that needs no corroboration.
  if raw < floor then
    L.run = nil
    State.supplyCollapsed = true
    return nil, false
  end

  local held = L.held
  if held == nil then
    L.held, L.run = raw, nil
    return raw, true
  end

  -- Not falling. Ends any run, and is every reading in a normal flight.
  if raw >= held - eps then
    L.held, L.run = raw, nil
    return raw, true
  end

  local run = L.run
  if run == nil then
    L.run = { from = held, last = raw, t = now }
    return raw, false
  end
  if raw < run.last - eps then
    run.last, run.t = raw, now      -- still going down; the clock restarts
  end

  -- Nothing with a battery behind it falls this far without stopping.
  if (run.from - raw) > total then
    State.supplyCollapsed = true
    return nil, false
  end

  if (now - run.t) >= settle then
    L.held, L.run = raw, nil
    return raw, true
  end
  return raw, false
end

-- After a real gap there is nothing left to compare against: the next reading
-- may be a different pack. Without this, a fresh pack that reads lower than the
-- one before it is refused forever as a decay that never stops.
local function forgetIfStale(role, now)
  local L = latch[role]
  if not L or L.held == nil then return end
  if L.staleSince == nil then L.staleSince = now; return end
  if (now - L.staleSince) >= State.VOLT_SETTLE then latch[role] = nil end
end

-- The per-cell scale for a role, or nil for one the latch does not police.
-- BEC is deliberately absent: it is a regulated rail that legitimately drops,
-- and on a buffer takeover it is the one reading still worth having.
local function voltScale(role)
  if role == "cellVoltage" then return 1 end
  if role == "packVoltage" then return State.cells() end
  return nil
end

local function sampleRole(role, now)
  local s = slot(role)
  local value, status = Sensors.read(role)
  s.status = status

  local trusted = true
  local scale = voltScale(role)
  if scale then
    now = now or Host.now()
    if status == "ok" then
      local kept, ok = latchVoltage(role, value, scale, now)
      if kept == nil then
        -- Refused outright. Given its own status so the sensor map can say
        -- which readings were thrown away, rather than showing a bare dash.
        s.value, s.valid, s.status, s.trusted = nil, false, "collapsed", false
        return
      end
      value, trusted = kept, ok
    else
      forgetIfStale(role, now)
    end
  end

  if status ~= "ok" then
    -- Deliberately retain the last good extremes. A momentary telemetry
    -- dropout should not erase the session's peak headspeed.
    s.value = nil
    s.valid = false
    s.trusted = false
    return
  end

  s.value = value
  s.valid = true
  s.trusted = trusted

  local def = Roles.get(role)
  if not def or not def.track then return end
  if State.holdActive then return end
  -- A reading still on its way down has not been shown to be a reading. It is
  -- on the screen because the screen should be live; it is not in the record
  -- because the record outlives the moment.
  if not trusted then return end

  if not s.hasExtremes then
    s.min = value
    s.max = value
    s.hasExtremes = true
  else
    if value > s.max then s.max = value end
    if value < s.min then s.min = value end
  end
end

-- Power is published by some stacks and absent from others. When absent,
-- derive it, but only from two readings that are themselves valid - a
-- fabricated 0 W would be indistinguishable from a real one.
local function derivePower()
  local s = slot("power")
  if s.valid then return end
  local v, vOk = State.get("packVoltage")
  local a, aOk = State.get("current")
  if not vOk or not aOk then return end
  local watts = v * a
  if not Roles.isSane("power", watts) then return end
  s.value  = watts
  s.valid  = true
  s.status = "derived"
  if State.holdActive then return end
  if not s.hasExtremes then
    s.min, s.max, s.hasExtremes = watts, watts, true
  else
    if watts > s.max then s.max = watts end
    if watts < s.min then s.min = watts end
  end
end

-- Rotorflight computes the state of charge on the flight controller - the
-- "Smart Fuel" feature - and publishes the result as the Bat% telemetry
-- sensor (sid 0x1014, "Main battery charge / fuel level"). So on a Rotorflight
-- heli the batteryPercent role binds straight to it and nothing here runs:
-- the FC has the pack's history, the sag model and the stick positions, and
-- this widget has none of those.
--
-- Its four modes, from src/main/sensors/smartfuel.c:
--   OFF       nothing is computed
--   VOLTAGE   sag-compensated cell voltage through a sigmoid
--   CURRENT   initial charge minus used capacity, falling back to VOLTAGE
--             when no capacity is configured
--   COMBINED  the lower of the two - the conservative reading, and the one
--             worth setting on a heli
--
-- The fallback below is for the other case: a flight controller that is not
-- Rotorflight, or one with Smart Fuel switched off. It is deliberately the
-- same curve Rotorflight uses in VOLTAGE mode, so a pilot who has seen the
-- number on one setup reads the same number on the other:
--
--   scaled = 3.0 + (cell - min) / (full - min) * 1.2      clamped to 3.0..4.2
--   charge = 1 / (1 + e^(-12 * (scaled - 3.7)))
--
-- What it cannot do is Rotorflight's sag compensation, which needs collective
-- and cyclic deflection. Under load this therefore reads low - which is the
-- safe direction to be wrong in, and why it is only ever a fallback.
local function expApprox(x)
  -- No math.exp in some EdgeTX Lua builds, and this is cheaper anyway.
  -- Two-term scaling and squaring: exact enough for a curve drawn at 1% steps.
  local n = 1 + x / 256
  for _ = 1, 8 do n = n * n end
  return n
end

local function chargeFromCellVoltage(cell, cellMin, cellFull)
  if cell >= cellFull then return 100 end
  if cell <= cellMin  then return 0 end
  local scaled = 3.0 + ((cell - cellMin) / (cellFull - cellMin)) * 1.2
  if scaled < 3.0 then scaled = 3.0 elseif scaled > 4.2 then scaled = 4.2 end
  local charge = 1 / (1 + expApprox(-12 * (scaled - 3.7)))
  if charge < 0 then charge = 0 elseif charge > 1 then charge = 1 end
  return charge * 100
end

State.chargeFromCellVoltage = chargeFromCellVoltage

local function deriveFuel()
  local s = slot("batteryPercent")
  if s.valid then return end          -- the FC already said; never second-guess it
  local cell, cellOk = State.get("cellVoltage")
  if not cellOk then return end
  local pct = chargeFromCellVoltage(cell,
                                    Config.setting("cellMin"),
                                    Config.setting("cellFull"))
  if not Roles.isSane("batteryPercent", pct) then return end
  s.value  = pct
  s.valid  = true
  s.status = "derived"
  if State.holdActive then return end
  if not s.hasExtremes then
    s.min, s.max, s.hasExtremes = pct, pct, true
  else
    if pct > s.max then s.max = pct end
    if pct < s.min then s.min = pct end
  end
end

local function updateFlightTimer(now)
  -- Count wall-clock seconds rather than service ticks so a skipped frame does
  -- not shorten the recorded flight time.
  local second = math.floor(now / Host.TICKS_PER_SECOND)
  if lastSecondTick == nil then
    lastSecondTick = second
    return
  end
  if second == lastSecondTick then return end
  local elapsed = second - lastSecondTick
  lastSecondTick = second
  if State.armed and not State.holdActive and elapsed > 0 then
    State.flightSeconds = State.flightSeconds + elapsed
  end
end

-- Returns true when a sample was actually taken, so the caller knows whether
-- there is anything new to redraw.
function State.service(now, opts)
  now = now or Host.now()
  if (now - State.lastServiceTick) < State.SERVICE_INTERVAL then
    return false
  end
  State.lastServiceTick = now

  opts = opts or {}
  State.holdActive = opts.hold == true

  if State.modelName ~= Host.modelName() then
    State.reloadModel()
  end

  Sensors.service(now)
  RF2.service(now)
  State.linkConnected = RF2.connected

  -- Pack voltage first, so auto-detection has settled on an aircraft before
  -- anything downstream asks the profile what is plausible. sampleRole runs
  -- the role again below; reading a sensor twice is cheaper than sampling
  -- every other role against a profile that arrives one pass late.
  do
    local v, ok = Sensors.read("packVoltage")
    ZD.Profiles.observe(v, ok == "ok")
  end

  State.supplyCollapsed = false
  for i = 1, #Roles.order do
    sampleRole(Roles.order[i], now)
  end
  deriveFuel()
  derivePower()

  -- After sampling, because the rotor fallback reads headspeed.
  local wasArmed = State.armed
  local armed, source = readArmed(now)
  State.armed = armed
  State.armSource = source

  -- Only ever a flight emergency. A pack pulled on the bench collapses exactly
  -- the same way, and an alarm for that would teach the pilot to ignore it.
  if not armed then
    State.powerLost = false
  elseif State.supplyCollapsed then
    State.powerLost = true
  elseif State.trusted("packVoltage") or State.trusted("cellVoltage") then
    State.powerLost = false
  end

  if armed and not wasArmed then
    -- Fresh flight: peaks belong to this flight, not the previous one.
    State.resetExtremes()
    currentSum, currentCount = 0, 0
    -- Freeze the last voltages seen before the rotor was turning.
    State.startPackVoltage = restPack
    State.startCellVoltage = restCell
    State.flightSeconds  = 0
    State.sessionStarted = true
    lastSecondTick = nil
  elseif wasArmed and not armed then
    -- Latch the disarm. The logging layer clears it once the flight has been
    -- written, so a flight is recorded exactly once even if that write is
    -- deferred or retried.
    State.disarmPending = true
  end

  if armed then
    if not State.holdActive then
      local amps, ampsOk = State.get("current")
      if ampsOk then
        currentSum = currentSum + amps
        currentCount = currentCount + 1
      end
    end
  else
    -- Disarmed, so whatever the pack reads now is a resting reading.
    local pv, pOk = State.get("packVoltage")
    local cv, cOk = State.get("cellVoltage")
    if pOk then restPack = pv end
    if cOk then restCell = cv end
  end

  updateFlightTimer(now)
  return true
end

-- Set when a flight has just ended and not yet been persisted.
State.disarmPending = false

function State.consumeDisarm()
  if not State.disarmPending then return false end
  State.disarmPending = false
  return true
end

return State

end
