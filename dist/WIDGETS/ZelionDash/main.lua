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

-- Bind the host globals once. EdgeTX publishes much of its API through a read-only global lookup table,
-- not as raw entries in _G. rawget() alone therefore reports half the host as
-- missing, so fall through to a normal index.
local function g(name)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  return v
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
local bitmapTbl        = g("Bitmap")

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
-- Where this widget is installed
--------------------------------------------------------------------------

-- EdgeTX names a widget from the Lua table it returns, not from the folder it
-- lives in, so the folder can be called anything at all - on the first radio
-- this ran on it was "zelion". Assuming a name meant the artwork silently
-- failed to load on a completely correct install.
--
-- Ask Lua where this chunk came from first, which is exact and needs no
-- guessing. Only if that is unavailable fall back to probing known names.
local WIDGET_DIR_CANDIDATES = {
  "/WIDGETS/zelion/",     "/WIDGETS/Zelion/",     "/WIDGETS/ZELION/",
  "/WIDGETS/ZelionDash/", "/WIDGETS/zeliondash/", "/WIDGETS/ZELIONDASH/",
  "/WIDGETS/Zeliondash/", "/WIDGETS/ZelionPower/", "/WIDGETS/zelionpower/",
}

Host.WIDGET_PROBE_FILE = "logo_panel.png"
Host.widgetDirSource = "unknown"

local resolvedWidgetDir = nil

-- "@/WIDGETS/zelion/main.lua" -> "/WIDGETS/zelion/"
local function dirFromChunkSource()
  local dbg = g("debug")
  if type(dbg) ~= "table" or type(dbg.getinfo) ~= "function" then return nil end
  local ok, info = pcall(dbg.getinfo, 1, "S")
  if not ok or type(info) ~= "table" then return nil end
  local src = tostring(info.source or "")
  src = string.gsub(src, "^@", "")
  local dir = string.match(src, "^(.*[/\\])[^/\\]*$")
  if dir and dir ~= "" and string.find(dir, "WIDGETS") then return dir end
  return nil
end

function Host.widgetDir()
  if resolvedWidgetDir then return resolvedWidgetDir end

  local fromChunk = dirFromChunkSource()
  if fromChunk then
    resolvedWidgetDir = fromChunk
    Host.widgetDirSource = "chunk"
    return resolvedWidgetDir
  end

  for _, d in ipairs(WIDGET_DIR_CANDIDATES) do
    if Host.imageLoads(d .. Host.WIDGET_PROBE_FILE) then
      resolvedWidgetDir = d
      Host.widgetDirSource = "probe"
      return d
    end
  end

  -- Nothing loaded, so fall back to the canonical name. sensors.cfg is looked
  -- up in this folder too, and a config file should not go missing just
  -- because the artwork did.
  resolvedWidgetDir = "/WIDGETS/ZelionDash/"
  Host.widgetDirSource = "fallback"
  return resolvedWidgetDir
end

function Host.widgetDirCandidates() return WIDGET_DIR_CANDIDATES end

--------------------------------------------------------------------------
-- Directory listing and image probing (diagnostics)
--------------------------------------------------------------------------

-- EdgeTX exposes `dir` as an iterator function on some builds and as a table
-- of file operations on others, so check which one this firmware has.
function Host.listDir(path)
  if type(dirTbl) ~= "function" then return nil end
  local out = {}
  local ok = pcall(function()
    for name in dirTbl(path) do
      out[#out + 1] = tostring(name)
      if #out >= 32 then break end
    end
  end)
  if not ok then return nil end
  return out
end

-- Report what each method thinks of a file, separately. Collapsing them into
-- one boolean is what left "the file is right there" and "the widget cannot
-- see it" impossible to tell apart.
function Host.probeImage(path)
  local r = { fstat = false, io = false, bmp = false, size = nil, w = nil }
  if fstatFn then
    local ok, info = pcall(fstatFn, path)
    if ok and info ~= nil then
      r.fstat = true
      r.size = tonumber(info.size)
    end
  end
  if type(ioTbl) == "table" then
    local f = ioTbl.open(path, "r")
    if f then
      r.io = true
      pcall(ioTbl.close, f)
    end
  end
  if type(bitmapTbl) == "table" and type(bitmapTbl.open) == "function" then
    local ok, bmp = pcall(bitmapTbl.open, path)
    if ok and bmp ~= nil then
      r.bmp = true
      if type(bitmapTbl.getSize) == "function" then
        local sized, w = pcall(bitmapTbl.getSize, bmp)
        if sized then r.w = tonumber(w) end
      end
    end
  end
  return r
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
  end
  if type(ioTbl) == "table" then
    local f = ioTbl.open(path, "r")
    if f then
      pcall(ioTbl.close, f)
      return true
    end
  end
  return false
end

-- The only trustworthy test for artwork on this firmware.
--
-- Hardware verdict: fstat and io.open both fail for files that exist, and
-- Bitmap.open never returns nil - it hands back a "not found" placeholder that
-- measures zero. So a non-nil bitmap proves nothing and a positive width
-- proves everything.
function Host.imageLoads(path)
  if type(bitmapTbl) ~= "table" or type(bitmapTbl.open) ~= "function" then
    return false
  end
  local ok, bmp = pcall(bitmapTbl.open, path)
  if not ok or bmp == nil then return false end
  if type(bitmapTbl.getSize) ~= "function" then return true end
  local sized, w = pcall(bitmapTbl.getSize, bmp)
  return sized and tonumber(w) ~= nil and tonumber(w) > 0
end

function Host.imageExists(path)
  if Host.imageLoads(path) then return true end
  return Host.exists(path)
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
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
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

-- Resolved lazily: the widget's folder is not known at module load, and is
-- not necessarily named after the widget.
function Config.path()
  return Host.widgetDir() .. "sensors.cfg"
end

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
  local text = Host.readFile(Config.path())
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

-- ======== src/rf2.lua ========
do
  local factory = (function()
-- Layer 2.5: Rotorflight RF Tool integration (optional).
--
-- Rotorflight's RF Tool widget publishes a single global table, `rf2`, which
-- other widgets may use. It gives us two things telemetry alone cannot:
--
--   1. Authoritative connection state. Without this we can only infer "is the
--      link up" from link quality plus a guess about whether any sensor looks
--      alive. RF Tool actually knows.
--   2. The flight controller's own flight statistics - total flights and total
--      airtime, maintained by the FC itself. That beats a counter kept on the
--      radio's SD card, which silently diverges the moment you fly the same
--      heli with a second radio.
--
-- This module is strictly additive. `rf2` only exists when RF Tool is
-- installed and loaded, so every access is guarded and every value it provides
-- is optional. The dashboard must be fully usable with RF Tool absent.
--
-- MSP is request/response over the telemetry link, not a free local read. It
-- is issued only on state transitions, never per frame - the same discipline
-- Rotorflight's own RfStats example widget follows.

return function(ZD)

local Host = ZD.Host

local RF2 = {}
ZD.RF2 = RF2

-- MSP_FLIGHT_STATS was introduced in MSP API 12.9. Asking an older flight
-- controller produces no reply, so gate on the version rather than waiting on
-- a request that will never come back.
local FLIGHT_STATS_MIN_API = 12.09

-- How often to retry registering while RF Tool has not loaded yet. Its widget
-- may initialise after ours, so absence at startup is not permanent.
local REGISTER_RETRY = Host.seconds(5)

RF2.registered   = false
RF2.linkState    = nil    -- "connected" | "disconnected" | "armed" | "disarmed"
RF2.connected    = nil    -- true/false, or nil when RF Tool is unavailable
RF2.apiVersion   = nil
RF2.craftName    = nil

RF2.totalFlights       = nil
RF2.totalFlightSeconds = nil
RF2.totalDistanceM     = nil

-- none | pending | ok | unsupported | error
RF2.statsStatus = "none"

local lastAttempt = -1e9

local function rf2Table()
  local t = rawget(_G, "rf2")
  if type(t) ~= "table" then return nil end
  return t
end

function RF2.available()
  return rf2Table() ~= nil
end

--------------------------------------------------------------------------
-- Flight statistics
--------------------------------------------------------------------------

local function statValue(stats, field)
  local entry = stats and stats[field]
  if type(entry) ~= "table" then return nil end
  return tonumber(entry.value)
end

local function onReceivedStats(_, stats)
  local flights = statValue(stats, "stats_total_flights")
  if flights == nil then
    -- A reply we cannot parse is a real failure, not a zero.
    RF2.statsStatus = "error"
    return
  end
  RF2.totalFlights       = flights
  RF2.totalFlightSeconds = statValue(stats, "stats_total_time_s")
  RF2.totalDistanceM     = statValue(stats, "stats_total_dist_m")
  RF2.statsStatus        = "ok"
end

local function requestFlightStats()
  local rf2 = rf2Table()
  if not rf2 then return end

  local api = tonumber(rf2.apiVersion)
  RF2.apiVersion = api
  if api == nil then
    -- Not yet handshaked with the flight controller; a later state event will
    -- bring us back here.
    return
  end
  if api < FLIGHT_STATS_MIN_API then
    RF2.statsStatus = "unsupported"
    return
  end

  local ok, api_module = pcall(rf2.useApi, "mspFlightStats")
  if not ok or type(api_module) ~= "table"
     or type(api_module.read) ~= "function" then
    RF2.statsStatus = "error"
    return
  end

  RF2.statsStatus = "pending"
  if not pcall(api_module.read, onReceivedStats, nil) then
    RF2.statsStatus = "error"
  end
end

RF2.requestFlightStats = requestFlightStats

--------------------------------------------------------------------------
-- State events
--------------------------------------------------------------------------

local function clearFcData()
  RF2.totalFlights       = nil
  RF2.totalFlightSeconds = nil
  RF2.totalDistanceM     = nil
  RF2.craftName          = nil
  RF2.apiVersion         = nil
  RF2.statsStatus        = "none"
end

local function handleStateChange(newState)
  RF2.linkState = newState

  if newState == "disconnected" then
    RF2.connected = false
    clearFcData()
    return
  end

  RF2.connected = true
  local rf2 = rf2Table()
  if rf2 then
    RF2.craftName  = rf2.modelName
    RF2.apiVersion = tonumber(rf2.apiVersion)
  end

  -- Re-read on connect and after every landing. Stats only change when a
  -- flight ends, so disarm is exactly when the numbers become stale.
  if newState == "connected" or newState == "disarmed" then
    requestFlightStats()
  end
end

-- A stable proxy is registered rather than the widget instance itself. EdgeTX
-- may call create() again (resize, settings change), and RF Tool's registry is
-- append-only - registering a fresh table each time would leave stale
-- duplicates receiving events forever.
RF2.proxy = {
  onStateChanged = function(_, newState)
    handleStateChange(newState)
  end,
}

--------------------------------------------------------------------------
-- Service
--------------------------------------------------------------------------

-- Called from the normal service pass. Cheap once registered, and retries on a
-- slow timer while RF Tool has not appeared.
function RF2.service(now)
  if RF2.registered then return end
  now = now or Host.now()
  if (now - lastAttempt) < REGISTER_RETRY then return end
  lastAttempt = now

  local rf2 = rf2Table()
  if not rf2 or type(rf2.registerWidget) ~= "function" then return end

  if not pcall(rf2.registerWidget, RF2.proxy) then return end
  RF2.registered = true

  -- RF Tool only publishes state on *change*. If the flight controller was
  -- already connected before we registered, no event is coming - so seed from
  -- the current state instead of waiting for one that never arrives.
  if tonumber(rf2.apiVersion) ~= nil then
    RF2.connected = true
    RF2.craftName = rf2.modelName
    requestFlightStats()
  end
end

function RF2.reset()
  RF2.registered = false
  RF2.linkState  = nil
  RF2.connected  = nil
  lastAttempt    = -1e9
  clearFcData()
end

return RF2

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

-- ======== src/theme.lua ========
do
  local factory = (function()
-- Layer 5a: Colours and font ladder.
--
-- Zelion lime doubles as the "healthy" state. Brand green and battery-OK green
-- would otherwise be two competing greens on one display; merged, there is
-- exactly one green on screen and it is the brand's. Amber and red stay
-- strictly reserved for a value that needs attention now, so an alarm keeps
-- its meaning.
--
-- Colours are built lazily: lcd.RGB does not exist until the widget is
-- created, so this cannot run at module load.

return function(ZD)

local Theme = {}
ZD.Theme = Theme

-- EdgeTX publishes its constants through a read-only global lookup table
-- rather than as raw entries in _G, so rawget() alone returns nil for every
-- one of them. Missing this silently collapses every font size and alignment
-- to 0: on hardware the dashboard rendered entirely in the default font,
-- left-aligned, with no error anywhere to say why.
local function flag(name, fallback)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
end

-- EdgeTX offers a fixed ladder of font sizes, not arbitrary point values.
-- Everything the renderer draws picks from these, which is why the layout
-- positions text by anchor rather than by measured height.
Theme.font = {
  small  = flag("SMLSIZE", 0),
  normal = 0,
  mid    = flag("MIDSIZE", 0),
  large  = flag("DBLSIZE", 0),
  huge   = flag("XXLSIZE", flag("DBLSIZE", 0)),
  bold   = flag("BOLD", 0),
}

Theme.built = false

function Theme.build()
  if Theme.built then return end
  if type(lcd) ~= "table" or type(lcd.RGB) ~= "function" then return end
  local rgb = lcd.RGB

  Theme.bg     = rgb(  6,   8,  11)
  Theme.panel  = rgb( 16,  20,  26)
  Theme.rule   = rgb( 35,  42,  51)
  Theme.track  = rgb(  9,  12,  16)
  Theme.ink    = rgb(242, 245, 248)
  Theme.dim    = rgb(118, 129, 143)

  -- Brand
  Theme.lime     = rgb(139, 224,  74)
  Theme.limeDark = rgb( 78, 143,  34)
  Theme.steel    = rgb(127, 196, 238)

  -- Status. Reserved: never used for decoration.
  Theme.warn = rgb(245, 179,   1)
  Theme.crit = rgb(239,  68,  68)

  -- Recorded extremes. Deliberately desaturated so a session peak never
  -- reads as a live warning.
  Theme.peak = rgb(185, 154,  74)

  -- Governor panel backgrounds, keyed by the severity of the state.
  Theme.govRunBg  = rgb( 21,  42,  12)
  Theme.govRunBr  = rgb( 61, 107,  31)
  Theme.govWarnBg = rgb( 42,  33,  10)
  Theme.govWarnBr = rgb( 90,  67,  19)
  Theme.govCritBg = rgb( 42,  13,  13)
  Theme.govCritBr = rgb( 88,  27,  27)
  Theme.govIdleBg = Theme.panel
  Theme.govIdleBr = Theme.rule

  Theme.built = true
end

--------------------------------------------------------------------------
-- Value -> colour
--------------------------------------------------------------------------

function Theme.batteryColor(pct)
  if pct == nil then return Theme.dim end
  if pct >= 50 then return Theme.lime end
  if pct >= 20 then return Theme.warn end
  return Theme.crit
end

-- 3.50V/cell is the conventional "land now" threshold on a LiPo.
function Theme.cellColor(v)
  if v == nil then return Theme.dim end
  if v <= 3.50 then return Theme.crit end
  if v <= 3.65 then return Theme.warn end
  return Theme.ink
end

function Theme.tempColor(c)
  if c == nil then return Theme.dim end
  if c >= 110 then return Theme.crit end
  if c >= 95  then return Theme.warn end
  return Theme.ink
end

function Theme.becColor(v)
  if v == nil then return Theme.dim end
  if v < 4.8 then return Theme.crit end
  if v < 5.1 then return Theme.warn end
  return Theme.ink
end

function Theme.linkColor(pct)
  if pct == nil or pct <= 0 then return Theme.crit end
  if pct >= 60 then return Theme.lime end
  if pct >= 40 then return Theme.warn end
  return Theme.crit
end

-- Governor states that mean the rotor is driven, in trouble, or stopped.
local GOV_RUNNING = { ACTIVE=true, SPOOLUP=true, RECOVERY=true, BAILOUT=true, BYPASS=true }
local GOV_CRIT    = { ["THR-OFF"]=true, ["LOST-HS"]=true }

function Theme.govColors(state)
  if GOV_RUNNING[state] then
    return Theme.lime, Theme.govRunBg, Theme.govRunBr
  elseif GOV_CRIT[state] then
    return Theme.crit, Theme.govCritBg, Theme.govCritBr
  elseif state == "IDLE" or state == "AUTOROT" then
    return Theme.warn, Theme.govWarnBg, Theme.govWarnBr
  end
  return Theme.dim, Theme.govIdleBg, Theme.govIdleBr
end

return Theme

end

  end)()
  factory(ZD)
end

-- ======== src/layout.lua ========
do
  local factory = (function()
-- Layer 4: Layout engine.
--
-- Produces a table of {x,y,w,h} regions for the screen the widget is running
-- on. Pure arithmetic and no drawing, so the whole thing is testable off-radio.
--
-- Two density classes rather than one scaled layout. The targets are different
-- shapes, not one shape at two sizes: 800x480 on the TX16S Mk3 against 480x320
-- on the TX15 is 0.60 the width but 0.67 the height, and 40% of the area. More
-- to the point, EdgeTX has a fixed ladder of font sizes, so text cannot shrink
-- continuously - panels have to rearrange instead of scaling.
--
-- The geometry below reproduces tools/render_layout.py at both anchor sizes.
-- Other resolutions in the same class keep the class's fonts and paddings and
-- distribute the leftover height proportionally.

return function(ZD)

local Layout = {}
ZD.Layout = Layout

Layout.ROOMY_MIN_WIDTH = 700

-- Per-class constants. Vertical figures marked "anchor" are the design values
-- at that class's reference height and are scaled when the screen differs.
local CLASS = {
  roomy = {
    name = "roomy", refH = 480,
    pad = 10, gap = 10, barW = 96, rightW = 274,
    topH = 40, stripH = 44, contentGap = 6, stripGap = 8,
    chipH = 75, colGapV = 8,
    heroGapV = 8, batShare = 0.508,
    govH = 86, rowGapV = 8, tileH = 132, tileGapH = 5,
    logoW = 252, logoH = 142,
  },
  tight = {
    name = "tight", refH = 320,
    pad = 6, gap = 6, barW = 64, rightW = 168,
    topH = 28, stripH = 36, contentGap = 6, stripGap = 8,
    chipH = 61, colGapV = 7,
    heroGapV = 6, batShare = 0.5,
    govH = 53, rowGapV = 7, tileH = 88, tileGapH = 3,
    logoW = 153, logoH = 86,
  },
}

local function rect(x, y, w, h)
  return { x = x, y = y, w = w, h = h }
end

local function round(v) return math.floor(v + 0.5) end

function Layout.classFor(w)
  return (w >= Layout.ROOMY_MIN_WIDTH) and "roomy" or "tight"
end

-- Build the layout for a screen. Returns a table of regions plus the class
-- name, so the renderer can pick fonts and decide what to abbreviate.
function Layout.build(w, h)
  local className = Layout.classFor(w)
  local C = CLASS[className]
  local L = { class = className, w = w, h = h, c = C }

  -- Bands
  L.top       = rect(0, 0, w, C.topH)
  L.topRule   = C.topH
  L.stripRule = h - C.stripH
  L.strip     = rect(0, L.stripRule + 1, w, C.stripH - 1)

  local contentTop = C.topH + C.contentGap
  local contentH   = (L.stripRule - C.stripGap) - contentTop
  L.content = rect(0, contentTop, w, contentH)

  -- Columns. Hero width is whatever is left, so the layout adapts to a screen
  -- wider than its anchor without stretching the fixed-width side columns.
  local barX   = C.pad
  local heroX  = barX + C.barW + C.gap
  local rightX = w - C.pad - C.rightW
  local heroW  = rightX - C.gap - heroX
  L.heroTooNarrow = heroW < 160

  -- --- left column: cell chip pinned top, gauge beneath -------------------
  local chipH = C.chipH
  L.cell = rect(barX, contentTop, C.barW, chipH)
  local barY = contentTop + chipH + C.colGapV
  L.bar = rect(barX, barY, C.barW, contentH - chipH - C.colGapV)

  -- --- hero column: battery above, headspeed below ------------------------
  local heroAvail = contentH - C.heroGapV
  local batH = round(heroAvail * C.batShare)
  L.battery   = rect(heroX, contentTop, heroW, batH)
  L.headspeed = rect(heroX, contentTop + batH + C.heroGapV, heroW,
                     heroAvail - batH)

  -- --- right column: governor, tile row, logo -----------------------------
  -- Governor and the tile row are fixed; the logo takes the remainder, so a
  -- taller screen grows the brand block rather than stretching the data.
  local govH  = C.govH
  local tileH = C.tileH
  L.gov = rect(rightX, contentTop, C.rightW, govH)

  local tileY = contentTop + govH + C.rowGapV
  local tileW = math.floor((C.rightW - C.tileGapH * 2) / 3)
  L.tiles = {}
  for i = 1, 3 do
    L.tiles[i] = rect(rightX + (tileW + C.tileGapH) * (i - 1), tileY, tileW, tileH)
  end
  -- Give any rounding slack to the last tile so the row ends flush.
  L.tiles[3].w = (rightX + C.rightW) - L.tiles[3].x

  local logoY = tileY + tileH + C.rowGapV
  local logoBox = rect(rightX, logoY, C.rightW, (contentTop + contentH) - logoY)
  L.logoBox = logoBox

  -- The mark is centred in whatever space is left, never stretched: an
  -- unevenly scaled logo is worse than a slightly smaller one.
  local lw, lh = C.logoW, C.logoH
  if lh > logoBox.h then
    lw = round(lw * logoBox.h / lh)
    lh = logoBox.h
  end
  L.logo = rect(logoBox.x + round((logoBox.w - lw) / 2),
                logoBox.y + round((logoBox.h - lh) / 2), lw, lh)

  return L
end

-- Standby layout: the mark and tagline, centred. Used when there is no
-- telemetry worth drawing.
function Layout.buildStandby(w, h)
  local className = Layout.classFor(w)
  local C = CLASS[className]
  local L = { class = className, w = w, h = h, c = C }

  L.top       = rect(0, 0, w, C.topH)
  L.topRule   = C.topH
  L.stripRule = h - C.stripH
  L.strip     = rect(0, L.stripRule + 1, w, C.stripH - 1)

  local top = C.topH + C.contentGap
  local avail = (L.stripRule - C.stripGap) - top

  -- Reserve room beneath the mark for the tagline and the status line.
  local reserve = (className == "roomy") and 96 or 62
  local boxH = avail - reserve
  -- Matches the shipped asset. Deliberately modest: a radio has to decode the
  -- image into RAM, and a 500x281 RGBA logo needed 549KB, which EdgeTX's Lua
  -- sandbox could not allocate - the artwork silently failed to load.
  local lw, lh = 320, 180
  if className ~= "roomy" then lw, lh = 240, 135 end
  if lh > boxH then
    lw = round(lw * boxH / lh)
    lh = boxH
  end
  if lw > w - C.pad * 2 then
    lh = round(lh * (w - C.pad * 2) / lw)
    lw = w - C.pad * 2
  end

  L.logo    = rect(round((w - lw) / 2), top, lw, lh)
  L.divider = rect(round(w * 0.25), L.logo.y + lh + 14, round(w * 0.5), 1)
  L.tagline = rect(0, L.divider.y + 10, w, 16)
  L.status  = rect(0, L.tagline.y + (className == "roomy" and 30 or 22), w, 20)
  return L
end

return Layout

end

  end)()
  factory(ZD)
end

-- ======== src/dashboard.lua ========
do
  local factory = (function()
-- Layer 6: The dashboard renderer.
--
-- Retained-mode LVGL: every object is created once in build(), and refresh()
-- pushes only the properties whose values actually changed. A shadow table
-- holds the last value written to each object so an unchanged frame costs no
-- host calls at all.
--
-- Reads State and Layout; owns no telemetry logic of its own. If a number
-- looks wrong on screen, this file is almost never where the bug is.

return function(ZD)

local Host   = ZD.Host
local State  = ZD.State
local Theme  = ZD.Theme
local Layout = ZD.Layout
local RF2    = ZD.RF2

local Dashboard = {}
ZD.Dashboard = Dashboard

local function assetDir() return Host.widgetDir() end

function Dashboard.assetDir() return assetDir() end
function Dashboard.assetDirResolved() return Host.widgetDirSource ~= "fallback"
                                             and Host.widgetDir() or false end

-- EdgeTX publishes its constants through a read-only global lookup table
-- rather than as raw entries in _G, so rawget() alone returns nil for every
-- one of them. Missing this silently collapses every font size and alignment
-- to 0: on hardware the dashboard rendered entirely in the default font,
-- left-aligned, with no error anywhere to say why.
local function flag(name, fallback)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
end
local ALIGN_CENTER = flag("CENTER", flag("CENTERED", 0))
local ALIGN_RIGHT  = flag("RIGHT", 0)

local GOV_STATES = {
  [0]="OFF", [1]="IDLE", [2]="SPOOLUP", [3]="RECOVERY", [4]="ACTIVE",
  [5]="THR-OFF", [6]="LOST-HS", [7]="AUTOROT", [8]="BAILOUT", [9]="BYPASS",
}

local V, SHADOW = {}, {}

--------------------------------------------------------------------------
-- Retained-object helpers
--------------------------------------------------------------------------

local function remember(obj, props)
  local st = {}
  for k, v in pairs(props) do st[k] = v end
  st.visible = true
  SHADOW[obj] = st
  return obj
end

local function setp(obj, props)
  if not obj then return end
  local st = SHADOW[obj]
  if not st then st = {}; SHADOW[obj] = st end
  local changed = false
  for k, v in pairs(props) do
    if st[k] ~= v then st[k] = v; changed = true end
  end
  if changed then obj:set(props) end
end

local function setVisible(obj, vis)
  if not obj then return end
  local st = SHADOW[obj]
  if not st then st = {}; SHADOW[obj] = st end
  vis = vis and true or false
  if st.visible == vis then return end
  st.visible = vis
  if vis then obj:show() else obj:hide() end
end

local function label(x, y, w, text, font, color, align)
  local p = { x=x, y=y, w=w or 0, h=0, text=text or "",
              font=font or 0, color=color or Theme.ink, align=align or 0 }
  return remember(lvgl.label(p), p)
end

local function rectangle(x, y, w, h, color, filled, rounded, thickness)
  local p = { x=x, y=y, w=w, h=h, color=color,
              filled=filled and 1 or 0, rounded=rounded or 0,
              thickness=thickness or 1 }
  return remember(lvgl.rectangle(p), p)
end

-- A panel is a fill plus a separate border so the two can be recoloured
-- independently - the governor block changes both as its state changes.
local function panel(r, fill, border, rounded)
  return {
    fill   = rectangle(r.x, r.y, r.w, r.h, fill,   true,  rounded or 5, 1),
    border = rectangle(r.x, r.y, r.w, r.h, border, false, rounded or 5, 1),
  }
end

local function setPanel(p, fill, border)
  setp(p.fill,   { color = fill })
  setp(p.border, { color = border })
end

--------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------

local function fmt(v, pattern, scale)
  if v == nil then return "--" end
  return string.format(pattern, v * (scale or 1))
end

local function fmtInt(role)
  local v, ok = State.get(role)
  if not ok then return "--" end
  return string.format("%d", math.floor(v + 0.5))
end

local function fmtExtreme(prefix, value, pattern)
  if value == nil then return prefix .. " --" end
  return prefix .. " " .. string.format(pattern, value)
end

local function clockText(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Sag is the gap between the pack's best cell voltage this flight and what it
-- is delivering now: the number that actually says how the pack is holding up.
local function cellSag()
  local now, ok = State.get("cellVoltage")
  local best = State.max("cellVoltage")
  if not ok or best == nil then return nil end
  local sag = best - now
  if sag < 0 then sag = 0 end
  return sag
end

local function govText()
  local g, ok = State.get("governor")
  if not ok then return "--" end
  return GOV_STATES[math.floor(g)] or "UNKNOWN"
end

--------------------------------------------------------------------------
-- Standby
--------------------------------------------------------------------------

-- Nothing truthful to draw: no link, and none of the values a dashboard
-- exists to show. Anything less strict would blank the screen mid-flight
-- during a telemetry dropout, which is precisely when it must not.
function Dashboard.shouldStandby()
  if State.linkConnected == true then return false end
  if State.valid("headspeed") or State.valid("packVoltage")
     or State.valid("batteryPercent") or State.valid("cellVoltage")
     or State.valid("current") then
    return false
  end
  return true
end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

local L
local mode  -- "dash" | "standby"


-- Artwork lives on the SD card, so it can simply be absent - a widget copied
-- without its PNGs is the likeliest first-run mistake. Check before asking
-- LVGL to load it: a missing image otherwise fails silently and leaves a hole
-- with nothing to explain it.
Dashboard.logoMissing = false
Dashboard.missingPath = nil

function Dashboard.placeLogo(r, filename)
  local path = assetDir() .. filename
  local ok = Host.imageExists(path)

  -- Draw the wordmark FIRST, then the image over it. A probe that says
  -- "missing" is evidence, not proof: it was wrong on hardware once already.
  -- Ordering it this way means a working image always wins, and the wordmark
  -- is only ever seen when nothing loaded at all.
  if not ok then
    Dashboard.logoMissing = true
    Dashboard.missingPath = path
    -- One label, not two stacked: without a way to measure text there is no
    -- safe gap between them, and a two-line version overlapped itself the
    -- moment the fonts started resolving.
    local F = Theme.font
    label(r.x, r.y + math.floor(r.h / 2) - 12, r.w, "ZELION POWER",
          F.mid + F.bold, Theme.steel, ALIGN_CENTER)
  end

  -- Attempted unconditionally: if LVGL can load it, it renders regardless of
  -- what the probes concluded.
  lvgl.image({ x=r.x, y=r.y, w=r.w, h=r.h, fill=false, file=path })
end

local function buildTopBar()
  local F = Theme.font
  V.modelName = label(L.c.pad, L.class == "roomy" and 10 or 7, 260, "",
                      F.small + F.bold, Theme.ink)
  V.timer = label(0, L.class == "roomy" and 4 or 2, L.w, "",
                  F.mid + F.bold, Theme.ink, ALIGN_CENTER)

  -- Signal bars, then the TX battery glyph at the far right.
  local barsX = L.w - L.c.pad - (L.class == "roomy" and 200 or 128)
  local step  = L.class == "roomy" and 10 or 8
  local unit  = L.class == "roomy" and 6 or 5
  local baseY = L.class == "roomy" and 30 or 22
  V.signal = {}
  for i = 1, 4 do
    local bh = 6 + (i - 1) * 4
    V.signal[i] = rectangle(barsX + (i - 1) * step, baseY - bh, unit, bh,
                            Theme.rule, true, 0, 0)
  end

  local bw, bh = (L.class == "roomy" and 16 or 13), (L.class == "roomy" and 22 or 16)
  local bx = L.w - L.c.pad - 36
  local by = L.class == "roomy" and 14 or 10
  rectangle(bx + math.floor((bw - 8) / 2), by - 4, 8, 3, Theme.dim, true, 1, 0)
  V.txBody = panel({x=bx, y=by, w=bw, h=bh}, Theme.track, Theme.dim, 3)
  V.txFill = rectangle(bx + 2, by + bh - 3, bw - 4, 1, Theme.lime, true, 2, 0)
  V.txGeom = { x=bx, y=by, w=bw, h=bh }
  V.txText = label(L.w - L.c.pad - 30, L.class == "roomy" and 13 or 9, 30, "",
                   Theme.font.small + Theme.font.bold, Theme.ink)

  lvgl.hline({ x=0, y=L.topRule, w=L.w, h=1, color=Theme.rule })
end

local function buildLeftColumn()
  local F = Theme.font
  local c, b = L.cell, L.bar

  V.cellPanel = panel(c, Theme.bg, Theme.limeDark, 6)
  label(c.x, c.y + 6, c.w, "CELL", F.small + F.bold, Theme.lime, ALIGN_CENTER)
  V.cellValue = label(c.x, c.y + (L.class == "roomy" and 20 or 16), c.w, "",
                      F.large + F.bold, Theme.ink, ALIGN_CENTER)
  V.cellMin = label(c.x, c.y + c.h - (L.class == "roomy" and 16 or 14), c.w, "",
                    F.small, Theme.peak, ALIGN_CENTER)

  -- Brand-green border: the gauge is the Zelion instrument on this screen.
  rectangle(b.x, b.y, b.w, b.h, Theme.track, true,  7, 1)
  rectangle(b.x, b.y, b.w, b.h, Theme.lime,  false, 7, 2)
  V.barFill = rectangle(b.x + 3, b.y + b.h - 4, b.w - 6, 1, Theme.lime, true, 5, 0)
  V.barGeom = { x=b.x + 3, y=b.y + 3, w=b.w - 6, h=b.h - 6 }
end

local function buildHero()
  local F = Theme.font
  local roomy = L.class == "roomy"
  local padX, footY = 16, roomy and 150 or 95

  local r = L.battery
  panel(r, Theme.panel, Theme.rule)
  label(r.x + padX, r.y + 12, r.w - padX * 2, "BATTERY", F.small + F.bold, Theme.dim)
  V.batValue = label(r.x + padX, r.y + (roomy and 30 or 22), r.w - padX * 2, "",
                     F.huge + F.bold, Theme.ink)
  V.batUnit  = label(r.x + r.w - padX - 40, r.y + (roomy and 60 or 44), 40, "%",
                     F.mid, Theme.dim, ALIGN_RIGHT)
  V.batPack  = label(r.x + padX, r.y + r.h - (roomy and 62 or 46), r.w - padX * 2, "",
                     F.mid + F.bold, Theme.ink, ALIGN_RIGHT)
  lvgl.hline({ x=r.x + padX, y=r.y + r.h - (roomy and 30 or 24),
               w=r.w - padX * 2, h=1, color=Theme.rule })
  V.batFoot = {}
  local slots = roomy and 4 or 3
  local slotW = math.floor((r.w - padX * 2) / slots)
  for i = 1, slots do
    V.batFoot[i] = label(r.x + padX + slotW * (i - 1), r.y + r.h - (roomy and 22 or 18),
                         slotW, "", F.small, Theme.dim)
  end

  r = L.headspeed
  panel(r, Theme.panel, Theme.rule)
  label(r.x + padX, r.y + 12, r.w - padX * 2, "HEADSPEED", F.small + F.bold, Theme.dim)
  V.hsValue = label(r.x + padX, r.y + (roomy and 30 or 22), r.w - padX * 2, "",
                    F.huge + F.bold, Theme.ink)
  label(r.x + r.w - padX - 60, r.y + (roomy and 76 or 54), 60, "RPM",
        F.small + F.bold, Theme.dim, ALIGN_RIGHT)
  lvgl.hline({ x=r.x + padX, y=r.y + r.h - (roomy and 30 or 24),
               w=r.w - padX * 2, h=1, color=Theme.rule })
  V.hsFoot = {}
  local hslots = roomy and 3 or 2
  local hslotW = math.floor((r.w - padX * 2) / hslots)
  for i = 1, hslots do
    V.hsFoot[i] = label(r.x + padX + hslotW * (i - 1), r.y + r.h - (roomy and 22 or 18),
                        hslotW, "", F.small, Theme.dim)
  end
end

local function buildRightColumn()
  local F = Theme.font
  local roomy = L.class == "roomy"

  local g = L.gov
  V.govPanel = panel(g, Theme.govIdleBg, Theme.govIdleBr)
  label(g.x, g.y + 8, g.w, "GOVERNOR", F.small + F.bold, Theme.dim, ALIGN_CENTER)
  V.govState = label(g.x, g.y + (roomy and 28 or 20), g.w, "",
                     F.large + F.bold, Theme.dim, ALIGN_CENTER)

  -- Labels carry their units on both screens; at 54px wide there is no room
  -- for a separate unit glyph, and consistency beats a spare pixel.
  local defs = roomy
    and { {"CURRENT A"}, {"ESC °C"}, {"BEC V"} }
    or  { {"CURR A"},    {"ESC °C"}, {"BEC V"} }
  V.tiles = {}
  for i = 1, 3 do
    local t = L.tiles[i]
    panel(t, Theme.panel, Theme.rule)
    label(t.x + 6, t.y + 7, t.w - 12, defs[i][1], F.small, Theme.dim)
    V.tiles[i] = {
      value = label(t.x + 6, t.y + (roomy and 26 or 22), t.w - 12, "",
                    F.mid + F.bold, Theme.ink),
      foot  = label(t.x + 6, t.y + t.h - 16, t.w - 12, "", F.small, Theme.peak),
    }
  end

  -- No frame: a panel border fought the mark's own outline.
  Dashboard.placeLogo(L.logo, roomy and "logo_panel.png" or "logo_small.png")
end

local function buildStrip()
  local F = Theme.font
  lvgl.hline({ x=0, y=L.stripRule, w=L.w, h=1, color=Theme.rule })
  local y = L.stripRule + (L.class == "roomy" and 14 or 10)
  V.flights = label(L.c.pad, y, 300, "", F.small, Theme.dim)
  if L.class == "roomy" then
    label(0, y, L.w, "NO HYPE · JUST VOLTAGE · REAL POWER", F.small, Theme.dim, ALIGN_CENTER)
  end
  V.link = label(L.w - L.c.pad - 160, y, 160, "", F.small, Theme.steel, ALIGN_RIGHT)
end

-- Compact readout of what the radio itself finds in the widget folder.
-- Lives on standby because that is where a failed load is actually seen;
-- requiring the pilot to find a settings toggle to diagnose it was a mistake.
local ASSET_FILES = { "logo_panel.png", "logo_standby.png", "logo_small.png" }

function Dashboard.assetDiagLines(maxLines)
  local out = {}
  assetDir()

  -- main.lua is definitely present - the widget is running from it. If it also
  -- reads as missing then the probes are useless here and only a positive
  -- bitmap width means anything; if it reads fine, the folder is right and the
  -- PNGs specifically are the problem.
  local control = Host.probeImage(assetDir() .. "main.lua")
  out[#out + 1] = string.format("control main.lua %s%s%s  (must exist)",
    control.fstat and "F" or "-", control.io and "I" or "-",
    control.bmp and "B" or "-")

  out[#out + 1] = string.format("DIR (%s): %s",
                                Host.widgetDirSource, assetDir())

  for _, f in ipairs(ASSET_FILES) do
    local p = Host.probeImage(assetDir() .. f)
    out[#out + 1] = string.format("%s %s%s%s%s%s", f,
      p.fstat and "F" or "-", p.io and "I" or "-", p.bmp and "B" or "-",
      p.size and (" " .. p.size .. "b") or "",
      p.w and (" w" .. p.w) or "")
  end
  while maxLines and #out > maxLines do table.remove(out) end
  return out
end

local function buildStandby()
  local F = Theme.font
  V.modelName = label(L.c.pad, L.class == "roomy" and 10 or 7, 260, "",
                      F.small + F.bold, Theme.ink)
  lvgl.hline({ x=0, y=L.topRule, w=L.w, h=1, color=Theme.rule })

  Dashboard.placeLogo(L.logo, "logo_standby.png")
  lvgl.hline({ x=L.divider.x, y=L.divider.y, w=L.divider.w, h=1, color=Theme.rule })
  label(0, L.tagline.y, L.w, "NO HYPE · JUST VOLTAGE · REAL POWER",
        F.small, Theme.dim, ALIGN_CENTER)
  V.status = label(0, L.status.y, L.w, "WAITING FOR TELEMETRY",
                   F.mid + F.bold, Theme.warn, ALIGN_CENTER)

  local roomy = L.class == "roomy"
  local lineH = roomy and 15 or 12
  local dy = L.status.y + (roomy and 28 or 22)
  local room = math.floor((L.stripRule - dy) / lineH)
  V.diag = {}
  for i = 1, math.max(0, math.min(roomy and 6 or 3, room)) do
    V.diag[i] = label(L.c.pad, dy + (i - 1) * lineH, L.w - L.c.pad * 2, "",
                      F.small, Theme.dim, ALIGN_CENTER)
  end

  lvgl.hline({ x=0, y=L.stripRule, w=L.w, h=1, color=Theme.rule })
  local sy = L.stripRule + (L.class == "roomy" and 14 or 10)
  V.flights = label(L.c.pad, sy, 300, "", F.small, Theme.dim)
  -- Standby is where a first run lands, so the missing-artwork notice belongs
  -- here as well as on the dashboard. It lives in the strip rather than under
  -- the status line, which is where it previously collided with it.
  V.link = label(0, sy, L.w - L.c.pad, "", F.small + F.bold,
                 Theme.warn, ALIGN_RIGHT)
end

-- Smallest zone the tight layout can be drawn into honestly. Below this the
-- panels would overlap, so say so rather than render a mess.
Dashboard.MIN_W, Dashboard.MIN_H = 440, 250

local function buildTooSmall(w, h)
  local F = Theme.font
  rectangle(0, 0, w, h, Theme.bg, true, 0, 0)
  label(0, math.floor(h / 2) - 26, w, "ZELIONDASH", F.mid + F.bold,
        Theme.steel, ALIGN_CENTER)
  label(0, math.floor(h / 2), w, "NEEDS A FULL SCREEN WIDGET SLOT",
        F.small + F.bold, Theme.warn, ALIGN_CENTER)
  label(0, math.floor(h / 2) + 20, w,
        string.format("this zone is %dx%d, minimum is %dx%d",
                      w, h, Dashboard.MIN_W, Dashboard.MIN_H),
        F.small, Theme.dim, ALIGN_CENTER)
end

-- w,h are the WIDGET ZONE, not the screen. LVGL objects are children of the
-- widget, so anything drawn past the zone edge is silently clipped - laying
-- out against LCD_W/LCD_H produces a dashboard with its right half missing.
function Dashboard.build(standby, w, h)
  if type(lvgl) ~= "table" then return end
  Theme.build()
  lvgl.clear()
  V, SHADOW = {}, {}
  Dashboard.logoMissing = false
  w = w or Host.lcdW
  h = h or Host.lcdH

  if w < Dashboard.MIN_W or h < Dashboard.MIN_H then
    mode = "toosmall"
    buildTooSmall(w, h)
    return
  end

  mode = standby and "standby" or "dash"

  if standby then
    L = Layout.buildStandby(w, h)
    rectangle(0, 0, L.w, L.h, Theme.bg, true, 0, 0)
    buildStandby()
  else
    L = Layout.build(w, h)
    rectangle(0, 0, L.w, L.h, Theme.bg, true, 0, 0)
    buildTopBar()
    buildLeftColumn()
    buildHero()
    buildRightColumn()
    buildStrip()
  end
  Dashboard.update()
end

Dashboard.mode = function() return mode end

--------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------

local function flightsText()
  if RF2.statsStatus == "ok" and RF2.totalFlights then
    local t = string.format("%d FLIGHTS", RF2.totalFlights)
    if RF2.totalFlightSeconds then
      local s = RF2.totalFlightSeconds
      t = t .. string.format(" · %d:%02d:%02d", math.floor(s / 3600),
                             math.floor(s % 3600 / 60), s % 60)
    end
    return t
  end
  return ""
end

local function updateTopBar()
  setp(V.modelName, { text = RF2.craftName or Host.modelName() })
  setp(V.timer, { text = clockText(State.flightSeconds) })

  local lq = State.valid("linkQuality") and State.num("linkQuality") or nil
  local bars = 0
  if lq then
    bars = (lq >= 80 and 4) or (lq >= 60 and 3) or (lq >= 40 and 2)
           or (lq >= 20 and 1) or 0
  end
  local col = Theme.linkColor(lq)
  for i = 1, 4 do
    setp(V.signal[i], { color = (i <= bars) and col or Theme.rule })
  end

  local tx = State.valid("txVoltage") and State.num("txVoltage") or nil
  if tx then
    -- 2S: 7.0V empty, 8.4V full.
    local pct = math.max(0, math.min(1, (tx - 7.0) / 1.4))
    local fh = math.floor((V.txGeom.h - 4) * pct)
    setp(V.txFill, { y = V.txGeom.y + V.txGeom.h - 2 - fh,
                     h = math.max(1, fh),
                     color = pct > 0.5 and Theme.lime
                             or (pct > 0.25 and Theme.warn or Theme.crit) })
    setVisible(V.txFill, fh > 0)
    setp(V.txText, { text = string.format("%.1f", tx) })
  else
    setVisible(V.txFill, false)
    setp(V.txText, { text = "--" })
  end
end

local function updateLeftColumn()
  local cell, ok = State.get("cellVoltage")
  setp(V.cellValue, { text = ok and string.format("%.2f", cell) or "--",
                      color = ok and Theme.cellColor(cell) or Theme.dim })
  setp(V.cellMin, { text = fmtExtreme("MIN", State.min("cellVoltage"), "%.2f") })

  local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
  if pct then
    local g = V.barGeom
    local fh = math.floor(g.h * math.max(0, math.min(100, pct)) / 100)
    setp(V.barFill, { y = g.y + g.h - fh, h = math.max(1, fh),
                      color = Theme.batteryColor(pct) })
    setVisible(V.barFill, fh > 0)
  else
    setVisible(V.barFill, false)
  end
end

local function updateHero()
  local roomy = L.class == "roomy"

  local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
  setp(V.batValue, { text = pct and string.format("%d", math.floor(pct + 0.5)) or "--",
                     color = pct and Theme.ink or Theme.dim })
  local pack, packOk = State.get("packVoltage")
  setp(V.batPack, { text = packOk and string.format("%.1f V", pack) or "--",
                    color = packOk and Theme.ink or Theme.dim })

  local foots = {
    fmtExtreme("MIN", State.min("packVoltage"), "%.1fV"),
    fmtExtreme("SAG", cellSag(), "%.2f"),
    State.valid("capacity") and string.format("%d mAh", math.floor(State.num("capacity")))
      or "-- mAh",
    State.valid("cellCount") and string.format("%dS", math.floor(State.num("cellCount")))
      or "--S",
  }
  for i = 1, #V.batFoot do
    setp(V.batFoot[i], { text = foots[i] or "" })
  end

  local hs, hsOk = State.get("headspeed")
  setp(V.hsValue, { text = hsOk and string.format("%d", math.floor(hs + 0.5)) or "--",
                    color = hsOk and Theme.ink or Theme.dim })
  local hfoots = {
    fmtExtreme("MAX", State.max("headspeed"), "%d"),
    State.valid("tailSpeed") and string.format("TAIL %d", math.floor(State.num("tailSpeed")))
      or "TAIL --",
    State.valid("throttle") and string.format("THR %d%%", math.floor(State.num("throttle")))
      or "THR --",
  }
  for i = 1, #V.hsFoot do
    setp(V.hsFoot[i], { text = hfoots[i] or "" })
  end
end

local function updateRightColumn()
  local g = govText()
  local fg, bg, br = Theme.govColors(g)
  setPanel(V.govPanel, bg, br)
  setp(V.govState, { text = g, color = fg })

  local cur, curOk = State.get("current")
  setp(V.tiles[1].value, { text = curOk and string.format("%d", math.floor(cur + 0.5)) or "--",
                           color = curOk and Theme.ink or Theme.dim })
  setp(V.tiles[1].foot, { text = fmtExtreme("MAX", State.max("current"), "%d") })

  local esc, escOk = State.get("escTemperature")
  setp(V.tiles[2].value, { text = escOk and string.format("%d", math.floor(esc + 0.5)) or "--",
                           color = escOk and Theme.tempColor(esc) or Theme.dim })
  setp(V.tiles[2].foot, { text = fmtExtreme("MAX", State.max("escTemperature"), "%d") })

  local bec, becOk = State.get("becVoltage")
  setp(V.tiles[3].value, { text = becOk and string.format("%.1f", bec) or "--",
                           color = becOk and Theme.becColor(bec) or Theme.dim })
  setp(V.tiles[3].foot, { text = fmtExtreme("MIN", State.min("becVoltage"), "%.1f") })
end

local function updateStrip()
  setp(V.flights, { text = flightsText() })
  local text, color = "", Theme.steel
  if Dashboard.logoMissing then
    -- Name the exact path that failed: "missing" is not actionable, a path is.
    setp(V.link, { text = "NO IMAGE: " .. tostring(Dashboard.missingPath),
                   color = Theme.warn })
    return
  end
  if RF2.available() then
    if State.linkConnected == false then
      text, color = "RF2 DISCONNECTED", Theme.dim
    elseif RF2.registered then
      text = "RF2 LINKED"
    end
  end
  setp(V.link, { text = text, color = color })
end

function Dashboard.update()
  if type(lvgl) ~= "table" or mode == "toosmall" or not V.flights then return end
  if mode == "standby" then
    setp(V.modelName, { text = RF2.craftName or Host.modelName() })
    setp(V.flights, { text = flightsText() })
    setp(V.link, { text = Dashboard.logoMissing
                          and ("NO IMAGE: " .. tostring(Dashboard.missingPath))
                          or "" })
    if V.diag then
      local lines = Dashboard.logoMissing
                    and Dashboard.assetDiagLines(#V.diag) or {}
      for i = 1, #V.diag do
        setp(V.diag[i], { text = lines[i] or "" })
      end
    end
    return
  end
  updateTopBar()
  updateLeftColumn()
  updateHero()
  updateRightColumn()
  updateStrip()
end

return Dashboard

end

  end)()
  factory(ZD)
end

-- ======== src/widget.lua ========
do
  local factory = (function()
-- Widget entry point.
--
-- Owns the EdgeTX lifecycle and nothing else: which screen is showing, when to
-- rebuild it, and servicing telemetry from both refresh() and background().
--
-- Two screens. The dashboard is the product; the sensor map is a diagnostics
-- view, reachable from the settings, that shows which telemetry sensor got
-- bound to each role. It is the first place to look when a panel reads "--".

return function(ZD)

local Host    = ZD.Host
local Roles   = ZD.Roles
local Config  = ZD.Config
local Sensors = ZD.Sensors
local RF2     = ZD.RF2
local State   = ZD.State
local Theme   = ZD.Theme
local Dashboard = ZD.Dashboard

local Widget = {}
ZD.Widget = Widget

-- EdgeTX publishes its constants through a read-only global lookup table
-- rather than as raw entries in _G, so rawget() alone returns nil for every
-- one of them. Missing this silently collapses every font size and alignment
-- to 0: on hardware the dashboard rendered entirely in the default font,
-- left-aligned, with no error anywhere to say why.
local function flag(name, fallback)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
end
local SOURCE = flag("SOURCE", 1)
local BOOL   = flag("BOOL", 2)
local SMLSIZE, BOLD, RIGHT = flag("SMLSIZE", 0), flag("BOLD", 0), flag("RIGHT", 0)

Widget.showSensors = false
local built = nil          -- "dash" | "standby" | "sensors" | nil
local scroll = 0
local zoneW, zoneH = nil, nil

-- EdgeTX gives each widget a zone, which is only the whole screen when it sits
-- in a full-screen layout slot. LVGL objects are children of the widget, so
-- anything laid out against LCD_W/LCD_H gets clipped at the zone edge - the
-- dashboard renders with its right-hand side simply missing.
local function readZone(widget)
  local z = widget and widget.zone
  local w = tonumber(z and z.w) or Host.lcdW
  local h = tonumber(z and z.h) or Host.lcdH
  if w <= 0 then w = Host.lcdW end
  if h <= 0 then h = Host.lcdH end
  return w, h
end

--------------------------------------------------------------------------
-- Diagnostics screen (immediate mode - it is a tool, not the product)
--------------------------------------------------------------------------

local HOW = { override = "cfg", name = "auto", unit = "guess" }

local function statusColor(row)
  if row.status == "ok" or row.status == "derived" then return Theme.lime end
  if row.status == "insane" then return Theme.crit end
  if row.important then return Theme.warn end
  return Theme.dim
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

-- Appended to the diagnostics list. Answers, from the radio itself, what is
-- actually in the widget folder and what each probe makes of it - rather than
-- inferring any of it from this side of the SD card.
local ASSET_FILES = { "logo_panel.png", "logo_standby.png", "logo_small.png" }
local ASSET_DIR = "/WIDGETS/ZelionDash/"

local function assetRows()
  local rows = {}
  rows[#rows + 1] = { label = "-- ASSETS --", sensor = ASSET_DIR,
                      status = "ok", important = true }

  local listing = Host.listDir(ASSET_DIR)
  if listing == nil then
    rows[#rows + 1] = { label = "dir()", sensor = "unavailable", status = "unbound" }
  elseif #listing == 0 then
    rows[#rows + 1] = { label = "dir()", sensor = "EMPTY", status = "insane" }
  else
    for _, name in ipairs(listing) do
      rows[#rows + 1] = { label = "  " .. name, sensor = "", status = "ok" }
    end
  end

  for _, f in ipairs(ASSET_FILES) do
    local p = Host.probeImage(ASSET_DIR .. f)
    local flags = string.format("%s%s%s",
      p.fstat and "F" or "-", p.io and "I" or "-", p.bmp and "B" or "-")
    local detail = flags
    if p.size then detail = detail .. " " .. tostring(p.size) .. "b" end
    if p.w then detail = detail .. " w" .. tostring(p.w) end
    rows[#rows + 1] = {
      label = f, sensor = detail,
      status = (p.bmp and p.w and p.w > 0) and "ok" or "insane",
    }
  end
  return rows
end

local function drawSensorMap()
  local w, h = zoneW or Host.lcdW, zoneH or Host.lcdH
  local compact = w < 700
  lcd.drawFilledRectangle(0, 0, w, h, Theme.bg)

  local pad     = compact and 6 or 12
  local headerH = compact and 20 or 28
  local rowH    = compact and 14 or 20

  local sensorRows, bound = Sensors.report(), 0
  for _, r in ipairs(sensorRows) do if r.sensor then bound = bound + 1 end end
  -- Assets lead the list: they are what a first run needs to check, they are
  -- only a handful of lines, and burying them past the fold is what made the
  -- artwork problem take several rounds to pin down.
  local rows = assetRows()
  for _, r in ipairs(sensorRows) do rows[#rows + 1] = r end

  lcd.drawText(pad, compact and 2 or 5,
               compact and "Sensors" or "ZelionDash - sensor map", BOLD + Theme.steel)
  lcd.drawText(w - pad, compact and 2 or 5,
               string.format("%d bound", bound), RIGHT + SMLSIZE + Theme.dim)
  lcd.drawLine(0, headerH, w, headerH, SOLID, Theme.rule)

  local colRole, colSensor = pad, math.floor(w * 0.34)
  local colHow, colValue   = math.floor(w * 0.56), w - pad
  local footerH = compact and 16 or 22
  local listTop = headerH + (compact and 3 or 6)
  local visible = math.max(1, math.floor((h - listTop - footerH) / rowH))

  if scroll > #rows - visible then scroll = math.max(0, #rows - visible) end
  if scroll < 0 then scroll = 0 end

  for i = 1, visible do
    local row = rows[i + scroll]
    if row then
      local y, color = listTop + (i - 1) * rowH, statusColor(row)
      lcd.drawText(colRole, y, row.label,
                   SMLSIZE + (row.important and BOLD or 0) + Theme.ink)
      lcd.drawText(colSensor, y, row.sensor or "-", SMLSIZE + color)
      lcd.drawText(colHow, y, row.how and HOW[row.how] or "", SMLSIZE + Theme.dim)
      lcd.drawText(colValue, y, formatValue(row), RIGHT + SMLSIZE + color)
    end
  end

  local fy = h - footerH + (compact and 1 or 3)
  if #Config.problems > 0 then
    lcd.drawText(pad, fy, "cfg: " .. Config.problems[1], SMLSIZE + Theme.crit)
  else
    local note = (State.armed and "ARMED" or "disarmed") .. "  " ..
                 (RF2.craftName or Host.modelName())
    if #Sensors.unresolved > 0 then
      note = note .. "  (" .. #Sensors.unresolved .. " unresolved)"
    end
    lcd.drawText(pad, fy, note, SMLSIZE + Theme.dim)
  end
  if #rows > visible then
    lcd.drawText(w - pad, fy,
                 string.format("%d-%d", scroll + 1, math.min(#rows, scroll + visible)),
                 RIGHT + SMLSIZE + Theme.dim)
  end
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local function serviceOpts(widget)
  local opts = widget.options or {}
  State.armSwitch = opts.ArmSwitch
  local hold = false
  if opts.HoldSwitch and opts.HoldSwitch ~= 0 then
    local v = Host.read(opts.HoldSwitch)
    hold = v ~= nil and v > 0
  end
  return { hold = hold }
end

-- Rebuild only when the screen we should be showing actually changes.
-- Tearing down and recreating every LVGL object per frame would defeat the
-- entire point of retained mode.
local function ensureScreen(widget)
  local w, h = readZone(widget)
  if w ~= zoneW or h ~= zoneH then
    zoneW, zoneH = w, h
    built = nil          -- a resized zone needs a fresh layout
  end
  if Widget.showSensors then
    if built ~= "sensors" then
      if type(lvgl) == "table" then lvgl.clear() end
      built = "sensors"
    end
    return
  end
  local want = Dashboard.shouldStandby() and "standby" or "dash"
  if built ~= want then
    Dashboard.build(want == "standby", zoneW, zoneH)
    built = want
  end
end

function Widget.create(zone, options)
  Theme.build()
  Config.load()
  State.reloadModel()
  built = nil
  zoneW, zoneH = nil, nil
  return { zone = zone, options = options }
end

function Widget.update(widget, options)
  widget.options = options
  Widget.showSensors = (options and options.SensorMap == 1) or false
  Config.load()
  Sensors.reload(Host.modelName())
  built = nil
  ensureScreen(widget)
end

function Widget.refresh(widget, event, touchState)
  State.service(Host.now(), serviceOpts(widget))
  ensureScreen(widget)

  if Widget.showSensors then
    if event == flag("EVT_VIRTUAL_NEXT", -1) then scroll = scroll + 1
    elseif event == flag("EVT_VIRTUAL_PREV", -2) then scroll = scroll - 1 end
    drawSensorMap()
  else
    Dashboard.update()
  end
end

-- Telemetry is serviced here too, so session peaks and flight time are
-- recorded while another screen is in front.
function Widget.background(widget)
  State.service(Host.now(), serviceOpts(widget))
end

Widget.options = {
  { "ArmSwitch",  SOURCE, 0 },
  { "HoldSwitch", SOURCE, 0 },
  { "SensorMap",  BOOL,   0 },
}

Widget.OPTION_LABELS = {
  ArmSwitch  = "Arm Switch (fallback)",
  HoldSwitch = "Hold Switch",
  SensorMap  = "Show Sensor Map",
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
  useLvgl    = true,
}
