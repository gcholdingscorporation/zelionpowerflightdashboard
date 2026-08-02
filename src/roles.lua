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
