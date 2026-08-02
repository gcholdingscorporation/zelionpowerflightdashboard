-- ZelionDash - RC helicopter telemetry dashboard for EdgeTX
-- Version 0.1.0-dev
--
-- GENERATED FILE - do not edit.
-- Built from src/*.lua by tools/build.lua. Edit the sources and rebuild.

local ZD = { VERSION = "0.1.0-dev" }

-- ======== src/host.lua ========
do
  local factory = (function()
-- Layer 1: Host adapter.
--
-- Every call into the EdgeTX runtime goes through this module. Two reasons:
--   1. Firmware differences (getSourceValue only exists on newer builds, mkdir
--      is absent on older ones) are absorbed in one place.
--   2. Layers 2-4 can then be exercised on a desktop Lua against a mock host,
--      which is where the alert-gate and resolver logic actually gets tested.
--
-- Nothing here interprets telemetry. It reads, writes and reports capability.

return function(ZD)

local Host = {}
ZD.Host = Host

-- Bind the host globals once. rawget avoids EdgeTX's read-only global lookup
-- raising on names the running firmware does not define.
local function g(name)
  return rawget(_G, name)
end

local getTimeFn        = g("getTime")
local getValueFn       = g("getValue")
local getFieldInfoFn   = g("getFieldInfo")
local getSourceValueFn = g("getSourceValue")
local getSourceNameFn  = g("getSourceName")
local getVersionFn     = g("getVersion")
local getRSSIFn        = g("getRSSI")
local modelTbl         = g("model")
local ioTbl            = g("io")
local dirTbl           = g("dir")
local osTbl            = g("os")
local mkdirFn          = g("mkdir")
local fstatFn          = g("fstat")

Host.hasSourceValue = type(getSourceValueFn) == "function"
Host.hasLvgl        = type(g("lvgl")) == "table"

--------------------------------------------------------------------------
-- Time
--------------------------------------------------------------------------

-- EdgeTX getTime() counts 10ms ticks since boot. All durations in this widget
-- are expressed in those ticks; TICKS_PER_SECOND makes that explicit at the
-- call sites instead of leaving bare 100s scattered through the alert code.
Host.TICKS_PER_SECOND = 100

function Host.now()
  if not getTimeFn then return 0 end
  local ok, t = pcall(getTimeFn)
  if not ok then return 0 end
  return tonumber(t) or 0
end

function Host.seconds(n)
  return math.floor((tonumber(n) or 0) * Host.TICKS_PER_SECOND)
end

--------------------------------------------------------------------------
-- Radio identity and screen geometry
--------------------------------------------------------------------------

-- Resolution is read from the host rather than inferred from the radio name.
-- A radio we have never heard of still lands in the right size class.
Host.lcdW = tonumber(g("LCD_W")) or 480
Host.lcdH = tonumber(g("LCD_H")) or 272

local radioName, versionString = nil, nil
if getVersionFn then
  local ok, a, b = pcall(getVersionFn)
  if ok then
    radioName     = a
    versionString = b
  end
end
Host.radioName     = tostring(radioName or "unknown")
Host.versionString = tostring(versionString or "")

-- Lowercased once so callers can do plain substring tests.
Host.radioTag = string.lower(Host.radioName .. " " .. Host.versionString)

function Host.radioMatches(pattern)
  return string.find(Host.radioTag, pattern, 1, true) ~= nil
end

--------------------------------------------------------------------------
-- Source reads
--------------------------------------------------------------------------

-- Resolve a telemetry name to its numeric source id.
-- Returns id, or nil when the firmware reports the name does not exist.
function Host.fieldId(name)
  if not getFieldInfoFn then return nil, false end
  local ok, info = pcall(getFieldInfoFn, name)
  if not ok then return nil, false end
  if type(info) ~= "table" or info.id == nil then
    -- The lookup itself succeeded, so "no such source" is a trustworthy
    -- answer rather than an unsupported-API guess.
    return nil, true
  end
  return info.id, true
end

-- Read a source by id or name.
--
-- Returns: value, current, fresh
--   value   number, or nil when unreadable
--   current true when the host affirms this is live data
--   fresh   false only when the host explicitly says the sample is stale
--
-- The distinction matters: getValue() returns 0 for a source that does not
-- exist, which is indistinguishable from a sensor legitimately reading zero.
-- getSourceValue() reports that difference, so it is preferred when present.
function Host.read(source)
  if source == nil then return nil, false, false end

  if getSourceValueFn then
    local ok, v, current, fresh = pcall(getSourceValueFn, source)
    if not ok then return nil, false, false end
    if type(v) == "table" then v = v.value end
    if v == nil or current == false then
      return nil, false, fresh ~= false
    end
    return tonumber(v), true, fresh ~= false
  end

  if not getValueFn then return nil, false, false end
  local ok, v = pcall(getValueFn, source)
  if not ok or v == nil then return nil, false, false end
  if type(v) == "table" then v = v.value end
  return tonumber(v), true, true
end

function Host.sourceName(id)
  if not getSourceNameFn then return nil end
  local ok, name = pcall(getSourceNameFn, id)
  if not ok then return nil end
  return name and tostring(name) or nil
end

function Host.rssi()
  if not getRSSIFn then return nil end
  local ok, v = pcall(getRSSIFn)
  if not ok then return nil end
  return tonumber(v)
end

--------------------------------------------------------------------------
-- Telemetry sensor enumeration (used by unit-based auto-discovery)
--------------------------------------------------------------------------

-- EdgeTX exposes at most 60 telemetry slots. Enumeration is best-effort: on a
-- firmware without model.getSensor this returns an empty list and the resolver
-- simply falls back to name matching, which is the primary path anyway.
local MAX_SENSOR_SLOTS = 60

function Host.listSensors()
  local out = {}
  if type(modelTbl) ~= "table" or type(modelTbl.getSensor) ~= "function" then
    return out
  end
  for i = 0, MAX_SENSOR_SLOTS - 1 do
    local ok, s = pcall(modelTbl.getSensor, i)
    if ok and type(s) == "table" then
      local name = s.name and tostring(s.name) or ""
      if name ~= "" then
        out[#out + 1] = {
          index = i,
          name  = name,
          unit  = tonumber(s.unit),
          prec  = tonumber(s.prec),
        }
      end
    end
  end
  return out
end

--------------------------------------------------------------------------
-- Model info
--------------------------------------------------------------------------

function Host.modelName()
  if type(modelTbl) ~= "table" or type(modelTbl.getInfo) ~= "function" then
    return "MODEL"
  end
  local ok, info = pcall(modelTbl.getInfo)
  local n = ok and info and info.name or nil
  if not n or n == "" then return "MODEL" end
  return tostring(n)
end

function Host.timer(index)
  if type(modelTbl) ~= "table" or type(modelTbl.getTimer) ~= "function" then
    return nil
  end
  local ok, t = pcall(modelTbl.getTimer, index or 0)
  if not ok or type(t) ~= "table" then return nil end
  return t
end

--------------------------------------------------------------------------
-- Filesystem
--------------------------------------------------------------------------

local READ_CHUNK     = 1024
local READ_MAX_BYTES = 64 * 1024

function Host.exists(path)
  if fstatFn then
    local ok, info = pcall(fstatFn, path)
    if ok and info ~= nil then return true end
    if ok then return false end
  end
  if type(ioTbl) ~= "table" then return false end
  local f = ioTbl.open(path, "r")
  if not f then return false end
  pcall(ioTbl.close, f)
  return true
end

function Host.readFile(path)
  if type(ioTbl) ~= "table" then return nil end
  local f = ioTbl.open(path, "r")
  if not f then return nil end
  local parts, total = {}, 0
  local ok = pcall(function()
    while true do
      local chunk = ioTbl.read(f, READ_CHUNK)
      if chunk == nil or chunk == "" then break end
      total = total + #chunk
      if total > READ_MAX_BYTES then break end
      parts[#parts + 1] = chunk
      if #chunk < READ_CHUNK then break end
    end
  end)
  pcall(ioTbl.close, f)
  if not ok then return nil end
  return table.concat(parts)
end

-- EdgeTX signals a write failure by returning nil from io.write rather than
-- necessarily raising, so pcall success alone does not prove the bytes landed.
local function writeDirect(path, content)
  if type(ioTbl) ~= "table" then return false end
  local f = ioTbl.open(path, "w")
  if not f then return false end
  local called, result = pcall(ioTbl.write, f, content)
  local closed = pcall(ioTbl.close, f)
  return called and result ~= nil and result ~= false and closed
end

local renameFn = (type(dirTbl) == "table" and dirTbl.rename)
                 or (type(osTbl) == "table" and osTbl.rename)
local deleteFn = (type(dirTbl) == "table" and dirTbl.del)
                 or (type(osTbl) == "table" and osTbl.remove)

-- Return values are useless as a success signal here: EdgeTX's dir.rename may
-- return nothing at all, while standard os.rename returns nil specifically to
-- report failure. The same value therefore means opposite things depending on
-- which host we are running against. Check the filesystem instead - it is the
-- only answer that is true on both.
local function tryRename(from, to)
  if not renameFn then return false end
  pcall(renameFn, from, to)
  return Host.exists(to) and not Host.exists(from)
end

local function tryDelete(path)
  if not deleteFn then return false end
  pcall(deleteFn, path)
  return not Host.exists(path)
end

-- Write via temp + rename when the firmware supports it, so a power-off
-- mid-write leaves either the old file or the new one, never a truncated one.
function Host.writeFile(path, content)
  content = content or ""
  if not renameFn then
    return writeDirect(path, content)
  end

  local tmp, backup = path .. ".tmp", path .. ".bak"
  tryDelete(tmp)
  if not writeDirect(tmp, content) then
    tryDelete(tmp)
    return false
  end

  local hadExisting = Host.exists(path)
  local movedExisting = false
  if hadExisting then
    tryDelete(backup)
    movedExisting = tryRename(path, backup)
    if not movedExisting then
      tryDelete(tmp)
      return false
    end
  end

  if tryRename(tmp, path) then
    if movedExisting then tryDelete(backup) end
    return true
  end

  if movedExisting then tryRename(backup, path) end
  tryDelete(tmp)
  return false
end

function Host.mkdir(path)
  if type(mkdirFn) ~= "function" then return false end
  local ok = pcall(mkdirFn, path)
  return ok
end

return Host

end

  end)()
  factory(ZD)
end

-- ======== src/roles.lua ========
do
  local factory = (function()
-- Layer 2a: Role definitions.
--
-- The dashboard never asks for a sensor by name. It asks for a ROLE
-- ("headspeed") and the resolver decides which of the model's actual telemetry
-- sensors fills it. This is the whole multi-vendor story: adding support for a
-- new ecosystem means adding candidate names here, not touching the UI.
--
-- Each role declares:
--   names   candidate sensor names, most-preferred first. Matched
--           case-insensitively; the first one the radio actually has wins.
--   unit    optional EdgeTX unit hint, used only by fallback discovery
--   min/max sanity window. A reading outside it is treated as invalid rather
--           than displayed, which keeps a garbage frame off the screen.
--   int     true when only whole numbers are meaningful (enums, counts)
--   track   "max", "min" or nil - which session extreme is worth recording
--
-- Names are drawn from the Rotorflight CRSF sensor set, with common aliases
-- from other stacks included so a non-Rotorflight setup still lights up.

return function(ZD)

local Roles = {}
ZD.Roles = Roles

-- EdgeTX unit constants, read from the host when available. These are only
-- ever used as a discovery tiebreak, and discovery refuses ambiguous matches,
-- so an incorrect fallback number degrades to "no auto-match" rather than a
-- wrong binding.
local function unit(name, fallback)
  return rawget(_G, name) or fallback
end

local U_VOLTS   = unit("UNIT_VOLTS", 1)
local U_AMPS    = unit("UNIT_AMPS", 2)
local U_CELSIUS = unit("UNIT_CELSIUS", 11)
local U_PERCENT = unit("UNIT_PERCENT", 13)
local U_MAH     = unit("UNIT_MAH", 14)
local U_RPMS    = unit("UNIT_RPMS", 18)

Roles.unitIds = {
  volts = U_VOLTS, amps = U_AMPS, celsius = U_CELSIUS,
  percent = U_PERCENT, mah = U_MAH, rpm = U_RPMS,
}

-- Declaration order is also the order shown on the diagnostics screen.
Roles.order = {
  "headspeed", "tailSpeed",
  "packVoltage", "cellVoltage", "cellCount", "batteryPercent",
  "current", "capacity", "power",
  "becVoltage", "escTemperature", "mcuTemperature",
  "governor", "armFlags", "throttle", "batteryProfile",
  "linkQuality", "rssi1", "rssi2",
  "txVoltage", "flightMode",
}

Roles.defs = {
  headspeed = {
    label = "Headspeed",
    names = { "Hspd", "HSpd", "RPM", "Rpm", "NR", "Hspeed" },
    unit = U_RPMS, min = 0, max = 100000, track = "max",
  },
  tailSpeed = {
    label = "Tail speed",
    names = { "Tspd", "TSpd", "TailRPM" },
    unit = U_RPMS, min = 0, max = 100000, track = "max",
  },

  packVoltage = {
    label = "Pack voltage",
    names = { "Vbat", "VBat", "RxBt", "A2", "Batt" },
    -- Upper bound is maxCells * an implausible-but-not-impossible per-cell
    -- voltage, so a 14S pack is accepted and a decoding glitch is not.
    unit = U_VOLTS, min = 0, max = 72, track = "min",
  },
  cellVoltage = {
    label = "Cell voltage",
    names = { "Vcel", "VCel", "Cels", "CelV" },
    unit = U_VOLTS, min = 0, max = 4.5, track = "min",
  },
  cellCount = {
    label = "Cell count",
    names = { "Cel#", "Cels#", "CellCount" },
    min = 1, max = 16, int = true,
  },
  batteryPercent = {
    label = "Battery %",
    names = { "Bat%", "Fuel", "Bat" },
    unit = U_PERCENT, min = 0, max = 100, track = "min",
  },

  current = {
    label = "Current",
    names = { "Curr", "Cur", "A1" },
    -- Negative values are legitimate: regenerative braking on spool-down.
    unit = U_AMPS, min = -500, max = 1000, track = "max",
  },
  capacity = {
    label = "Capacity used",
    names = { "Capa", "mAh", "Used" },
    unit = U_MAH, min = 0, max = 100000, track = "max",
  },
  power = {
    label = "Power",
    names = { "Pwr", "Watt", "Power" },
    min = 0, max = 100000, track = "max",
  },

  becVoltage = {
    label = "BEC voltage",
    names = { "Vbec", "VBec", "Bec" },
    unit = U_VOLTS, min = 0, max = 30, track = "min",
  },
  escTemperature = {
    label = "ESC temp",
    names = { "Tesc", "TEsc", "Temp", "Tmp1", "Tmp" },
    unit = U_CELSIUS, min = -40, max = 250, track = "max",
  },
  mcuTemperature = {
    label = "MCU temp",
    names = { "Tmcu", "TMcu", "Tmp2" },
    unit = U_CELSIUS, min = -40, max = 250, track = "max",
  },

  governor = {
    label = "Governor",
    names = { "Gov", "GOV" },
    min = 0, max = 15, int = true,
  },
  armFlags = {
    label = "Arm flags",
    names = { "ARM", "Arm" },
    min = 0, max = 255, int = true,
  },
  throttle = {
    label = "Throttle",
    names = { "Thr", "Thro", "THR" },
    unit = U_PERCENT, min = -100, max = 100, track = "max",
  },
  batteryProfile = {
    label = "Battery profile",
    names = { "BAT#", "Bat#", "Prof" },
    min = 0, max = 99, int = true,
  },

  linkQuality = {
    label = "Link quality",
    names = { "RQly", "RQLY", "LQ", "TQly" },
    unit = U_PERCENT, min = 0, max = 100, track = "min",
  },
  rssi1 = {
    label = "RSSI 1",
    names = { "1RSS", "RSSI", "RSS1" },
    min = -130, max = 20, track = "min",
  },
  rssi2 = {
    label = "RSSI 2",
    names = { "2RSS", "RSS2" },
    min = -130, max = 20, track = "min",
  },

  txVoltage = {
    label = "TX battery",
    names = { "tx-voltage", "TxBt", "txbatt" },
    unit = U_VOLTS, min = 0, max = 20,
  },
  flightMode = {
    label = "Flight mode",
    names = { "FM", "FlightMode" },
    min = 0, max = 8, int = true,
  },
}

-- Roles whose absence makes the dashboard substantially less useful. Surfaced
-- on the diagnostics screen so a mis-set-up model is visible on the radio
-- rather than showing as a screen full of dashes.
Roles.important = {
  headspeed = true, packVoltage = true, current = true,
  batteryPercent = true, escTemperature = true, governor = true,
}

function Roles.get(name)
  return Roles.defs[name]
end

-- Clamp-free validity test. Values outside the window are rejected outright
-- rather than clamped, because a clamped garbage reading still looks plausible
-- on screen and that is worse than showing nothing.
function Roles.isSane(role, value)
  local def = Roles.defs[role]
  if not def or value == nil then return false end
  local v = tonumber(value)
  if v == nil then return false end
  if def.min and v < def.min then return false end
  if def.max and v > def.max then return false end
  if def.int and v ~= math.floor(v) then return false end
  return true
end

return Roles

end

  end)()
  factory(ZD)
end

-- ======== src/config.lua ========
do
  local factory = (function()
-- Layer 2b: SD-card configuration.
--
-- EdgeTX widget settings screens hold about a dozen controls, mostly dropdowns.
-- That is nowhere near enough room for per-role sensor overrides, so overrides
-- live in a plain text file the pilot can edit in Notepad:
--
--   /WIDGETS/ZelionDash/sensors.cfg
--
--   # applies to every model unless overridden below
--   [*]
--   headspeed = Hspd
--   escTemperature = Tesc
--
--   [Goblin 700]
--   escTemperature = Tmp1
--
-- Section headers are model names, matched case-insensitively against the
-- radio's current model. [*] is the fallback for every model. Unknown keys are
-- collected and reported rather than silently dropped, because a typo that
-- fails quietly is exactly what makes a config file frustrating.

return function(ZD)

local Host  = ZD.Host
local Roles = ZD.Roles

local Config = {}
ZD.Config = Config

Config.PATH = "/WIDGETS/ZelionDash/sensors.cfg"

local function trim(s)
  return (string.gsub(tostring(s or ""), "^%s*(.-)%s*$", "%1"))
end

-- Parse into { [sectionLower] = { [roleName] = sensorName } }.
-- Returns sections, problems.
function Config.parse(text)
  local sections, problems = {}, {}
  if not text or text == "" then return sections, problems end

  local current = "*"
  sections[current] = sections[current] or {}
  local lineNo = 0

  for rawLine in string.gmatch(text, "[^\r\n]*") do
    lineNo = lineNo + 1
    local line = trim(rawLine)
    -- Both # and ; are accepted as comment markers; pilots coming from either
    -- INI or shell conventions should not have to guess.
    if line ~= "" and string.sub(line, 1, 1) ~= "#"
       and string.sub(line, 1, 1) ~= ";" then
      local section = string.match(line, "^%[(.+)%]$")
      if section then
        current = string.lower(trim(section))
        sections[current] = sections[current] or {}
      else
        local key, value = string.match(line, "^([^=]+)=(.*)$")
        key   = trim(key)
        value = trim(value)
        if key == "" or value == "" then
          problems[#problems + 1] =
            string.format("line %d: expected 'role = sensor'", lineNo)
        elseif not Roles.get(key) then
          problems[#problems + 1] =
            string.format("line %d: unknown role '%s'", lineNo, key)
        else
          sections[current][key] = value
        end
      end
    end
  end

  return sections, problems
end

Config.sections = {}
Config.problems = {}
Config.loaded   = false

function Config.load()
  Config.sections = {}
  Config.problems = {}
  Config.loaded   = true
  local text = Host.readFile(Config.PATH)
  if not text then
    -- A missing file is the normal case, not an error: everything
    -- auto-detects. Only a malformed file produces problems.
    return false
  end
  Config.sections, Config.problems = Config.parse(text)
  return true
end

-- Overrides for one model: the [*] defaults with the model's own section
-- layered on top.
function Config.overridesFor(modelName)
  if not Config.loaded then Config.load() end
  local out = {}
  local shared = Config.sections["*"]
  if shared then
    for role, sensor in pairs(shared) do out[role] = sensor end
  end
  local specific = Config.sections[string.lower(trim(modelName or ""))]
  if specific then
    for role, sensor in pairs(specific) do out[role] = sensor end
  end
  return out
end

return Config

end

  end)()
  factory(ZD)
end

-- ======== src/sensors.lua ========
do
  local factory = (function()
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

  end)()
  factory(ZD)
end

-- ======== src/state.lua ========
do
  local factory = (function()
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

  end)()
  factory(ZD)
end

-- ======== src/widget.lua ========
do
  local factory = (function()
-- Widget entry point.
--
-- Phase 2/3 deliverable: a sensor diagnostics screen. It renders one row per
-- role showing what that role bound to, how it bound, and what it currently
-- reads. This is the screen to look at when a panel on the finished dashboard
-- shows dashes, and it is deliberately the first thing that exists - it proves
-- the resolver against real hardware before any layout work is committed to.
--
-- Drawing here uses plain lcd.draw* rather than LVGL. That is intentional for
-- scaffolding: it is trivially portable across both target resolutions and
-- will be replaced wholesale by the real renderer once the layout lands.

return function(ZD)

local Host    = ZD.Host
local Roles   = ZD.Roles
local Config  = ZD.Config
local Sensors = ZD.Sensors
local State   = ZD.State

local Widget = {}
ZD.Widget = Widget

local function flag(name, fallback)
  return rawget(_G, name) or fallback
end

local SMLSIZE = flag("SMLSIZE", 0)
local BOLD    = flag("BOLD", 0)
local RIGHT   = flag("RIGHT", 0)
local SOURCE  = flag("SOURCE", 1)
local BOOL    = flag("BOOL", 2)

local EVT_NEXT = flag("EVT_VIRTUAL_NEXT", -1)
local EVT_PREV = flag("EVT_VIRTUAL_PREV", -2)

local C = {}
local function initColors()
  local rgb = lcd.RGB
  C.bg     = rgb(0, 0, 0)
  C.text   = rgb(235, 238, 242)
  C.dim    = rgb(124, 134, 148)
  C.line   = rgb(42, 45, 51)
  C.ok     = rgb(34, 197, 94)
  C.warn   = rgb(240, 180, 41)
  C.bad    = rgb(239, 68, 68)
  C.accent = rgb(95, 211, 188)
end

--------------------------------------------------------------------------
-- Row formatting
--------------------------------------------------------------------------

-- How a role bound is worth showing: "unit" means the widget guessed, and a
-- guess is exactly the thing a pilot should sanity-check before flying.
local HOW_LABEL = {
  override = "cfg",
  name     = "auto",
  unit     = "guess",
}

local function statusColor(row)
  if row.status == "ok" or row.status == "derived" then return C.ok end
  if row.status == "insane" then return C.bad end
  if row.important then return C.warn end
  return C.dim
end

local function formatValue(row)
  if row.status == "unbound" then return "--" end
  if row.status == "stale"   then return "no data" end
  if row.status == "insane"  then return "out of range" end
  local v = row.value
  if v == nil then return "--" end
  if math.abs(v - math.floor(v + 0.5)) < 0.05 then
    return string.format("%d", math.floor(v + 0.5))
  end
  return string.format("%.2f", v)
end

--------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------

local scroll = 0

local function drawScreen(widget)
  local w, h = Host.lcdW, Host.lcdH
  local compact = w < 700

  lcd.drawFilledRectangle(0, 0, w, h, C.bg)

  local pad     = compact and 6 or 12
  local headerH = compact and 20 or 28
  local rowH    = compact and 14 or 20

  -- Header
  lcd.drawText(pad, compact and 2 or 5,
               "ZelionDash - sensor map", BOLD + C.accent)
  local bound = 0
  local rows = Sensors.report()
  for _, r in ipairs(rows) do
    if r.sensor then bound = bound + 1 end
  end
  lcd.drawText(w - pad, compact and 2 or 5,
               string.format("%d/%d bound", bound, #rows),
               RIGHT + SMLSIZE + C.dim)
  lcd.drawLine(0, headerH, w, headerH, SOLID, C.line)

  -- Column layout, proportional so both screen sizes stay readable.
  local colRole   = pad
  local colSensor = math.floor(w * 0.34)
  local colHow    = math.floor(w * 0.56)
  local colValue  = w - pad

  local footerH  = compact and 16 or 22
  local listTop  = headerH + (compact and 3 or 6)
  local listH    = h - listTop - footerH
  local visible  = math.max(1, math.floor(listH / rowH))

  if scroll > #rows - visible then scroll = math.max(0, #rows - visible) end
  if scroll < 0 then scroll = 0 end

  for i = 1, visible do
    local row = rows[i + scroll]
    if row then
      local y = listTop + (i - 1) * rowH
      local color = statusColor(row)
      lcd.drawText(colRole, y, row.label, SMLSIZE + (row.important and BOLD or 0) + C.text)
      lcd.drawText(colSensor, y, row.sensor or "-", SMLSIZE + color)
      lcd.drawText(colHow, y, row.how and HOW_LABEL[row.how] or "", SMLSIZE + C.dim)
      lcd.drawText(colValue, y, formatValue(row), RIGHT + SMLSIZE + color)
    end
  end

  -- Footer: the two things that explain most "why is it blank" questions.
  local fy = h - footerH + (compact and 1 or 3)
  local note
  if #Config.problems > 0 then
    note = "cfg: " .. Config.problems[1]
    lcd.drawText(pad, fy, note, SMLSIZE + C.bad)
  else
    note = State.armed and "ARMED" or "disarmed"
    note = note .. "  " .. Host.modelName()
    if #Sensors.unresolved > 0 then
      note = note .. "  (" .. #Sensors.unresolved .. " unresolved)"
    end
    lcd.drawText(pad, fy, note, SMLSIZE + C.dim)
  end
  if #rows > visible then
    lcd.drawText(w - pad, fy,
                 string.format("%d-%d", scroll + 1, math.min(#rows, scroll + visible)),
                 RIGHT + SMLSIZE + C.dim)
  end
end

--------------------------------------------------------------------------
-- Widget lifecycle
--------------------------------------------------------------------------

local function readOptions(widget)
  local opts = widget.options or {}
  State.armSwitch = opts.ArmSwitch
  return opts.HoldSwitch and Host.read(opts.HoldSwitch) or nil
end

local function serviceOpts(widget)
  local hold = readOptions(widget)
  return { hold = hold ~= nil and hold > 0 }
end

function Widget.create(zone, options)
  initColors()
  Config.load()
  State.reloadModel()
  return { zone = zone, options = options }
end

function Widget.update(widget, options)
  widget.options = options
  Config.load()
  Sensors.reload(Host.modelName())
end

function Widget.refresh(widget, event, touchState)
  State.service(Host.now(), serviceOpts(widget))

  if event == EVT_NEXT then
    scroll = scroll + 1
  elseif event == EVT_PREV then
    scroll = scroll - 1
  end

  drawScreen(widget)
end

-- Telemetry is serviced here too, so session peaks and flight time are
-- recorded while another screen is in front. Both reference dashboards do
-- this, and it is the single most important structural decision in either.
function Widget.background(widget)
  State.service(Host.now(), serviceOpts(widget))
end

Widget.options = {
  { "ArmSwitch",  SOURCE, 0 },
  { "HoldSwitch", SOURCE, 0 },
}

Widget.OPTION_LABELS = {
  ArmSwitch  = "Arm Switch (fallback)",
  HoldSwitch = "Hold Switch",
}

function Widget.translate(name)
  return Widget.OPTION_LABELS[name] or name
end

return Widget

end

  end)()
  factory(ZD)
end

return {
  name       = "ZelionDash",
  options    = ZD.Widget.options,
  create     = ZD.Widget.create,
  update     = ZD.Widget.update,
  refresh    = ZD.Widget.refresh,
  background = ZD.Widget.background,
  translate  = ZD.Widget.translate,
}
