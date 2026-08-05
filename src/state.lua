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
State.lastServiceTick = -1e9

local lastSecondTick = nil

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

function State.resetSession()
  State.resetExtremes()
  State.flightSeconds  = 0
  State.sessionStarted = false
  lastSecondTick = nil
end

function State.reloadModel()
  local name = Host.modelName()
  State.modelName = name
  State.values = {}
  Sensors.reload(name)
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

local function readArmed()
  local flags, status = Sensors.read("armFlags")
  if status == "ok" then
    local a = armedFromFlags(flags)
    if a ~= nil then return a, "telemetry" end
  end
  if State.armSwitch and State.armSwitch ~= 0 then
    local v = Host.read(State.armSwitch)
    if v ~= nil then return v > 0, "switch" end
  end
  return false, "none"
end

State.armSource = "none"

--------------------------------------------------------------------------
-- Service pass
--------------------------------------------------------------------------

local function sampleRole(role)
  local s = slot(role)
  local value, status = Sensors.read(role)
  s.status = status

  if status ~= "ok" then
    -- Deliberately retain the last good extremes. A momentary telemetry
    -- dropout should not erase the session's peak headspeed.
    s.value = nil
    s.valid = false
    return
  end

  s.value = value
  s.valid = true

  local def = Roles.get(role)
  if not def or not def.track then return end
  if State.holdActive then return end

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

  local wasArmed = State.armed
  local armed, source = readArmed()
  State.armed = armed
  State.armSource = source

  if armed and not wasArmed then
    -- Fresh flight: peaks belong to this flight, not the previous one.
    State.resetExtremes()
    State.flightSeconds  = 0
    State.sessionStarted = true
    lastSecondTick = nil
  elseif wasArmed and not armed then
    -- Latch the disarm. The logging layer clears it once the flight has been
    -- written, so a flight is recorded exactly once even if that write is
    -- deferred or retried.
    State.disarmPending = true
  end

  for i = 1, #Roles.order do
    sampleRole(Roles.order[i])
  end
  deriveFuel()
  derivePower()

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
