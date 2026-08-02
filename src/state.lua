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

local State = {}
ZD.State = State

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
