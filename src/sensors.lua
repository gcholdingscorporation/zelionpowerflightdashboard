-- Layer 2c: The sensor resolver.
--
-- Binds each role to a real telemetry source, in strict priority order:
--
--   1. override   the pilot named it in sensors.cfg - always wins
--   2. name       one of the role's candidate names exists on this model
--   3. unit       exactly one unclaimed sensor carries the role's unit
--
-- Step 3 is deliberately timid. It binds only when the match is unambiguous,
-- because a confidently wrong binding (showing MCU temperature in the ESC tile)
-- is far worse than an empty tile.
--
-- Binding is not one-shot. Helis are routinely powered on after the radio, so
-- unbound roles are re-probed on a timer, and a binding that goes stale is
-- released so it can re-resolve instead of pinning the model to a dead id.

return function(ZD)

local Host   = ZD.Host
local Roles  = ZD.Roles
local Config = ZD.Config

local Sensors = {}
ZD.Sensors = Sensors

-- Re-probe unbound roles once a second. Frequent enough that a heli powered on
-- mid-session lights up promptly, rare enough that a model with genuinely
-- absent sensors is not re-scanned every frame.
local REPROBE_INTERVAL = Host.seconds(1)

-- bindings[role] = { id=<source id>, name=<sensor name>, how=<"override"|"name"|"unit"> }
Sensors.bindings   = {}
Sensors.unresolved = {}
Sensors.overrides  = {}
Sensors.modelName  = nil

local lastProbe = -1e9

local function lower(s) return string.lower(tostring(s or "")) end

--------------------------------------------------------------------------
-- Binding
--------------------------------------------------------------------------

-- Try one concrete sensor name. Returns id when the firmware confirms it
-- exists. A firmware without getFieldInfo returns "unknown", in which case we
-- optimistically accept the name and let the read path sort it out.
local function tryName(name)
  local id, known = Host.fieldId(name)
  if id ~= nil then return id end
  if not known then return name end
  return nil
end

local function bindByOverride(role)
  local wanted = Sensors.overrides[role]
  if not wanted then return nil end
  local id = tryName(wanted)
  if id == nil then return nil, wanted end
  return { id = id, name = wanted, how = "override" }
end

local function bindByName(role)
  local def = Roles.get(role)
  if not def or not def.names then return nil end
  for i = 1, #def.names do
    local candidate = def.names[i]
    local id = tryName(candidate)
    if id ~= nil then
      return { id = id, name = candidate, how = "name" }
    end
  end
  return nil
end

-- Sensors already spoken for by a name/override binding are off the table for
-- unit discovery, so two temperature roles cannot both grab the same sensor.
local function claimedNames()
  local claimed = {}
  for _, b in pairs(Sensors.bindings) do
    if b and b.name then claimed[lower(b.name)] = true end
  end
  return claimed
end

local function bindByUnit(role, sensorList, claimed)
  local def = Roles.get(role)
  if not def or not def.unit then return nil end
  local match = nil
  for i = 1, #sensorList do
    local s = sensorList[i]
    if s.unit == def.unit and not claimed[lower(s.name)] then
      -- A second candidate makes this ambiguous. Bind nothing.
      if match then return nil end
      match = s
    end
  end
  if not match then return nil end
  local id = tryName(match.name)
  if id == nil then return nil end
  return { id = id, name = match.name, how = "unit" }
end

--------------------------------------------------------------------------
-- Resolution pass
--------------------------------------------------------------------------

-- Resolve every currently-unbound role. Cheap when everything is already
-- bound, which is the steady state.
function Sensors.resolve(force)
  if force then
    Sensors.bindings = {}
  end

  local pending = {}
  for i = 1, #Roles.order do
    local role = Roles.order[i]
    if not Sensors.bindings[role] then pending[#pending + 1] = role end
  end
  if #pending == 0 then
    Sensors.unresolved = {}
    return
  end

  -- Pass 1 and 2: explicit override, then candidate names.
  local stillPending = {}
  for i = 1, #pending do
    local role = pending[i]
    local binding = bindByOverride(role) or bindByName(role)
    if binding then
      Sensors.bindings[role] = binding
    else
      stillPending[#stillPending + 1] = role
    end
  end

  -- Pass 3: unit-based discovery, only for what is left.
  if #stillPending > 0 then
    local sensorList = Host.listSensors()
    if #sensorList > 0 then
      local claimed = claimedNames()
      local remaining = {}
      for i = 1, #stillPending do
        local role = stillPending[i]
        local binding = bindByUnit(role, sensorList, claimed)
        if binding then
          Sensors.bindings[role] = binding
          claimed[lower(binding.name)] = true
        else
          remaining[#remaining + 1] = role
        end
      end
      stillPending = remaining
    end
  end

  Sensors.unresolved = stillPending
end

-- Called when the active model changes: overrides differ per model, so every
-- binding has to be reconsidered from scratch.
function Sensors.reload(modelName)
  Sensors.modelName = modelName or Host.modelName()
  Sensors.overrides = Config.overridesFor(Sensors.modelName)
  lastProbe = -1e9
  Sensors.resolve(true)
end

function Sensors.service(now)
  now = now or Host.now()
  if #Sensors.unresolved == 0 then return end
  if (now - lastProbe) < REPROBE_INTERVAL then return end
  lastProbe = now
  Sensors.resolve(false)
end

--------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------

-- Read a role.
--
-- Returns: value, status
--   status "ok"      live reading inside the sanity window
--          "unbound" no sensor fills this role
--          "stale"   bound, but the host is not reporting live data
--          "insane"  bound and live, but the number is outside plausible range
--
-- Callers use the status rather than a nil check so the UI can say "--" for an
-- absent sensor and something louder for one that is present but reporting
-- nonsense.
function Sensors.read(role)
  local binding = Sensors.bindings[role]
  if not binding then return nil, "unbound" end

  local value, current = Host.read(binding.id)
  if value == nil or not current then
    -- Source ids shift as telemetry is discovered. Drop the binding so the
    -- next probe re-resolves it rather than reading a dead id forever.
    Sensors.bindings[role] = nil
    Sensors.unresolved[#Sensors.unresolved + 1] = role
    return nil, "stale"
  end

  if not Roles.isSane(role, value) then
    return nil, "insane"
  end

  return value, "ok"
end

function Sensors.boundTo(role)
  local b = Sensors.bindings[role]
  return b and b.name or nil
end

function Sensors.howBound(role)
  local b = Sensors.bindings[role]
  return b and b.how or nil
end

-- Diagnostics feed: every role, what it bound to and how. This is what the
-- on-radio setup screen renders, and it is the first thing to look at when a
-- panel shows dashes.
function Sensors.report()
  local rows = {}
  for i = 1, #Roles.order do
    local role = Roles.order[i]
    local def = Roles.get(role)
    local b = Sensors.bindings[role]
    local value, status = Sensors.read(role)
    rows[#rows + 1] = {
      role      = role,
      label     = def and def.label or role,
      sensor    = b and b.name or nil,
      how       = b and b.how or nil,
      value     = value,
      status    = status,
      important = Roles.important[role] == true,
    }
  end
  return rows
end

return Sensors

end
