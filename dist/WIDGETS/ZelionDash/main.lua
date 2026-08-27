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

-- The radio's RTC. A flight log with no date is a list of numbers in an
-- unknown order, so fall back to something obviously wrong rather than
-- something plausibly wrong: 1970 in a spreadsheet reads as "the clock was
-- not set", which is exactly what happened.
function Host.dateTime()
  local fn = g("getDateTime")
  if type(fn) == "function" then
    local ok, t = pcall(fn)
    if ok and type(t) == "table" and tonumber(t.year) then
      return { year = tonumber(t.year) or 1970, mon = tonumber(t.mon) or 1,
               day = tonumber(t.day) or 1, hour = tonumber(t.hour) or 0,
               min = tonumber(t.min) or 0, sec = tonumber(t.sec) or 0 }
    end
  end
  return { year = 1970, mon = 1, day = 1, hour = 0, min = 0, sec = 0 }
end

--------------------------------------------------------------------------
-- Audio and haptic
--------------------------------------------------------------------------

-- Every one of these is optional: a radio may be built without haptic, and a
-- firmware may not expose the call at all. An alert that cannot be heard must
-- never be an alert that raises.
--
-- playNumber speaks a value through the radio's own number vocabulary, which
-- is why nothing here ships a .wav. The pilot hears the reading in whatever
-- language the radio is set to, and there is no asset to install or lose.
local PREC1 = g("PREC1") or 0x10
local PREC2 = g("PREC2") or 0x20

Host.PREC1, Host.PREC2 = PREC1, PREC2
Host.UNIT_VOLTS   = tonumber(g("UNIT_VOLTS"))   or 1
Host.UNIT_CELSIUS = tonumber(g("UNIT_CELSIUS")) or 11
Host.UNIT_RPMS    = tonumber(g("UNIT_RPMS"))    or 18
Host.UNIT_PERCENT = tonumber(g("UNIT_PERCENT")) or 13
Host.PLAY_NOW     = tonumber(g("PLAY_NOW"))     or 1

local function optional(name)
  return function(...)
    local fn = g(name)
    if type(fn) ~= "function" then return false end
    local ok = pcall(fn, ...)
    return ok
  end
end

Host.playNumber = optional("playNumber")
Host.playTone   = optional("playTone")
Host.playHaptic = optional("playHaptic")
Host.playFile   = optional("playFile")

--------------------------------------------------------------------------
-- Text measurement
--------------------------------------------------------------------------

-- lcd.sizeText(text, flags) -> width, height. Pure: it calls getTextWidth and
-- getFontHeight and touches no draw buffer, so unlike the rest of the lcd
-- table it is safe to call while building a retained LVGL screen.
--
-- Colour lives in bits 16+ of a text flag and sizeText masks it off for the
-- height but not the width, so only the font is passed in.
--
-- Falls back to an estimate when the call is missing. Digits are the only
-- thing measured here and they are tabular in EdgeTX's faces, so a per-digit
-- advance of 0.55 of the line height is close; it is used to place a unit
-- glyph, where being a few pixels out is cosmetic.
local FALLBACK_ADVANCE = 0.55

function Host.textWidth(text, font, lineHeight)
  text = tostring(text or "")
  if text == "" then return 0 end
  local sizeText = type(lcd) == "table" and lcd.sizeText
  if type(sizeText) == "function" then
    local ok, w = pcall(sizeText, text, font or 0)
    if ok and tonumber(w) and tonumber(w) > 0 then return math.floor(tonumber(w)) end
  end
  return math.floor(#text * (tonumber(lineHeight) or 0) * FALLBACK_ADVANCE)
end

Host.hasTextMeasurement = type(lcd) == "table" and type(lcd.sizeText) == "function"

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

-- io.open does not merely return nil for a path it cannot use. Ask it for a
-- file inside a folder that is not there and the firmware raises, and that
-- throw travels: it took out a whole flight record, from inside a pcall that
-- discarded the message. Nothing in this file may call io.open directly.
local function openFile(path, mode)
  if type(ioTbl) ~= "table" or type(ioTbl.open) ~= "function" then return nil end
  local ok, f = pcall(ioTbl.open, path, mode)
  if not ok then return nil end
  return f
end

function Host.exists(path)
  if fstatFn then
    local ok, info = pcall(fstatFn, path)
    if ok and info ~= nil then return true end
  end
  if type(ioTbl) == "table" then
    local f = openFile(path, "r")
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
-- Results are cached per path, and the probe bitmap is dropped and collected
-- immediately. Bitmap.open ALLOCATES: probing a file costs as much memory as
-- displaying it, and on a radio the Lua heap is small enough that repeating
-- that every rebuild - on top of the copy lvgl.image loads - exhausts it and
-- faults the script.
local imageProbeCache = {}

local function collect()
  local gc = g("collectgarbage")
  if type(gc) == "function" then pcall(gc) end
end

function Host.imageLoads(path)
  local cached = imageProbeCache[path]
  if cached ~= nil then return cached end
  if type(bitmapTbl) ~= "table" or type(bitmapTbl.open) ~= "function" then
    imageProbeCache[path] = false
    return false
  end
  local result = false
  local ok, bmp = pcall(bitmapTbl.open, path)
  if ok and bmp ~= nil then
    if type(bitmapTbl.getSize) ~= "function" then
      result = true
    else
      local sized, w = pcall(bitmapTbl.getSize, bmp)
      result = sized and tonumber(w) ~= nil and tonumber(w) > 0
    end
  end
  bmp = nil
  collect()
  imageProbeCache[path] = result
  return result
end

Host.collect = collect

function Host.imageExists(path)
  if Host.imageLoads(path) then return true end
  return Host.exists(path)
end

function Host.readFile(path)
  if type(ioTbl) ~= "table" then return nil end
  local f = openFile(path, "r")
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
  local f = openFile(path, "w")
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

-- EdgeTX's mkdir returns a FatFs result code rather than raising: 0 is
-- created, 8 is "already there" - both of which mean the directory now exists.
-- Trusting pcall's success instead reports victory on every failure, which is
-- the same mistake that made an atomic file write silently do nothing.
--
-- A trailing slash is FR_INVALID_NAME to f_mkdir, so strip it. Callers keep
-- their paths in "/LOGS/" form because that is what concatenates with a
-- filename, and would otherwise all have to remember this.
--
-- mkdir arrived in EdgeTX 2.11. Older firmware returns false here, which is
-- why anything that needs a directory also needs a fallback.
Host.MKDIR_OK, Host.MKDIR_EXISTS = 0, 8

function Host.mkdir(path)
  if type(mkdirFn) ~= "function" then return false end
  -- string.gsub(s, ...) rather than s:gsub(...). EdgeTX registers `string` as
  -- a plain table without the metatable that makes method syntax work, so
  -- indexing a string raises on the radio and nowhere else. This one line is
  -- what "attempt to index a string value" was, and it took a flight with it.
  path = string.gsub(tostring(path or ""), "/+$", "")
  if path == "" then return false end
  local ok, res = pcall(mkdirFn, path)
  if not ok then return false end
  res = tonumber(res)
  -- A firmware that returns nothing at all gets the benefit of the doubt: the
  -- write that follows is the real test either way.
  if res == nil then return true end
  return res == Host.MKDIR_OK or res == Host.MKDIR_EXISTS
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
-- The role's window is the outer limit; an aircraft profile may tighten it.
-- Looked up at call time rather than captured, because Profiles loads after
-- this module and the active profile changes with the model.
function Roles.isSane(role, value)
  local def = Roles.defs[role]
  if not def or value == nil then return false end
  local v = tonumber(value)
  if v == nil then return false end
  if def.min and v < def.min then return false end
  if def.max and v > def.max then return false end
  if def.int and v ~= math.floor(v) then return false end

  local P = ZD.Profiles
  local w = P and P.window(role)
  if w then
    if w.min and v < w.min then return false end
    if w.max and v > w.max then return false end
  end
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

-- One reserved section name that holds settings rather than sensor overrides.
-- A model called "battery" would be an odd thing to name a helicopter, and the
-- alternative - a second file - is worse.
Config.SETTINGS_SECTION = "battery"

-- Numbers, with the range each is allowed to take. Anything outside it is a
-- typo rather than an intention, and a wrong cell voltage here would quietly
-- misreport the state of charge in the air.
local SETTINGS = {
  cellFull = { default = 4.00, min = 3.00, max = 4.50 },
  cellMin  = { default = 3.30, min = 2.50, max = 4.00 },
  -- Alert thresholds. alertCell is the one a pilot actually tunes: it is the
  -- voltage you want to hear about, not the voltage the pack dies at.
  alertCell = { default = 3.40, min = 2.80, max = 4.10 },
  alertEsc  = { default = 110,  min = 40,   max = 200 },
}

-- Parse into { [sectionLower] = { [roleName] = sensorName } }, plus
-- Config.settings for the reserved section.
-- Returns sections, problems, settings.
-- Which settings the file actually named, as opposed to the ones sitting at
-- their defaults. Both look identical in Config.settings, and the aircraft
-- profile needs to tell them apart: it may fill in a threshold nobody set, but
-- must never overrule one a pilot wrote down.
Config.explicit = {}

function Config.parse(text)
  local sections, problems = {}, {}
  local settings = {}
  local explicit = {}
  for k, spec in pairs(SETTINGS) do settings[k] = spec.default end
  if not text or text == "" then
    Config.explicit = explicit
    return sections, problems, settings
  end

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
        -- The reserved section holds settings, so it gets no bindings table.
        if current ~= Config.SETTINGS_SECTION then
          sections[current] = sections[current] or {}
        end
      else
        local key, value = string.match(line, "^([^=]+)=(.*)$")
        key   = trim(key)
        value = trim(value)
        if key == "" or value == "" then
          problems[#problems + 1] =
            string.format("line %d: expected 'role = sensor'", lineNo)
        elseif current == Config.SETTINGS_SECTION then
          local spec = SETTINGS[key]
          local n = tonumber(value)
          if not spec then
            problems[#problems + 1] =
              string.format("line %d: unknown [battery] setting '%s'", lineNo, key)
          elseif not n or n < spec.min or n > spec.max then
            problems[#problems + 1] =
              string.format("line %d: %s must be %.2f..%.2f", lineNo, key,
                            spec.min, spec.max)
          else
            settings[key] = n
            explicit[key] = true
          end
        elseif not Roles.get(key) then
          problems[#problems + 1] =
            string.format("line %d: unknown role '%s'", lineNo, key)
        else
          sections[current][key] = value
        end
      end
    end
  end

  if settings.cellMin >= settings.cellFull then
    problems[#problems + 1] = "cellMin must be below cellFull"
    settings.cellMin  = SETTINGS.cellMin.default
    settings.cellFull = SETTINGS.cellFull.default
    explicit.cellMin, explicit.cellFull = nil, nil
  end

  Config.explicit = explicit
  return sections, problems, settings
end

Config.sections = {}
Config.problems = {}
Config.settings = {}
Config.loaded   = false

-- The reserved section is not model-scoped: one pack chemistry per radio is
-- the common case, and per-model curves would need a second lookup for a
-- setting almost nobody changes.
function Config.setting(name)
  if not Config.loaded then Config.load() end
  local v = Config.settings[name]
  if v ~= nil then return v end
  return SETTINGS[name] and SETTINGS[name].default
end

function Config.load()
  Config.sections = {}
  Config.problems = {}
  Config.loaded   = true
  local text = Host.readFile(Config.path())
  if not text then
    -- A missing file is the normal case, not an error: everything
    -- auto-detects. Only a malformed file produces problems.
    local _, _, defaults = Config.parse(nil)
    Config.settings = defaults
    return false
  end
  Config.sections, Config.problems, Config.settings = Config.parse(text)
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

-- ======== src/profiles.lua ========
do
  local factory = (function()
-- Layer 2c: Aircraft profile.
--
-- What class of helicopter this is. The widget can read every sensor on the
-- model and still not know whether 300 A is a glitch or a Tuesday, because
-- that depends entirely on the aircraft: a 700-size electric pulls it, and a
-- 200-size would be on fire. Telemetry carries no such context, so it is
-- either configured or inferred.
--
-- A profile therefore carries only things the widget genuinely cannot detect
-- and that change what it does:
--
--   windows   what readings are plausible, so a bad frame can be rejected
--   spin      what headspeed means "the head is turning", for arm detection
--   settings  thresholds that differ by aircraft class rather than by chemistry
--
-- Anything the same on both aircraft is deliberately absent. Cell voltage
-- alerts are not here: a LiPo cell is 3.4 V in trouble whether it is one of
-- two or one of fourteen.
--
-- Naming follows what the pilot asked for, but the split is really by size and
-- pack rather than by firmware - Rotorflight runs 200-size helis too. A
-- Rotorflight 200 wants the small profile, and the auto rule below picks it,
-- because it goes on pack voltage rather than on which firmware is talking.

return function(ZD)

local Config = ZD.Config

local Profiles = {}
ZD.Profiles = Profiles

Profiles.AUTO, Profiles.LARGE, Profiles.SMALL = 0, 1, 2

-- Windows are upper bounds only. The lower bound stays 0 everywhere it already
-- was: a low reading is the thing you most want recorded, and clamping it is
-- how a real brownout gets thrown away.
Profiles.defs = {
  [Profiles.LARGE] = {
    id    = "rotorflight",
    label = "Rotorflight",
    note  = "6S 1800mAh and up",
    windows = {
      headspeed   = { max =   4000 },   -- 700-size turns 1500-2200
      packVoltage = { max =     72 },   -- 14S at an implausible 5.1V/cell
      current     = { max =    400 },
      capacity    = { max =  20000 },
      power       = { max =  20000 },
    },
    -- Proven on hardware at these values; a 700 idles far below 250.
    spinUp = 250, spinDown = 100,
    settings = { alertEsc = 110 },
  },
  [Profiles.SMALL] = {
    id    = "osf03",
    label = "OMPHOBBY OSF03",
    note  = "200-size, 2S-3S",
    windows = {
      headspeed   = { max =  12000 },   -- 200-size flies around 5000
      packVoltage = { max =   13.5 },   -- 3S at 4.5V/cell
      current     = { max =     80 },
      capacity    = { max =   3000 },
      power       = { max =   1000 },
    },
    -- A 200-size flies at ~5000 rpm, so 250 would call a slow spool a flight.
    spinUp = 1000, spinDown = 400,
    -- A small ESC in a tight canopy is in trouble well before a 700's is.
    settings = { alertEsc = 90 },
  },
}

-- Above this the pack is 6S or more; below it, 3S or less. 6S is 18V flat and
-- 3S is 12.6V full, so nothing lands in the gap. Read once, from the pack
-- itself, which is why this works on a Rotorflight 200 as well.
Profiles.AUTO_VOLTS = 15

Profiles.selected = Profiles.AUTO   -- what the widget option says
Profiles.detected = nil             -- what auto-detection settled on

-- Auto-detection latches. A pack reading that dips through the boundary during
-- a brownout must not reclassify the aircraft mid-flight and silently move
-- every threshold underneath the pilot.
function Profiles.observe(volts, ok)
  if not ok then return end
  if Profiles.detected ~= nil then return end
  volts = tonumber(volts)
  if volts == nil or volts <= 0 then return end
  Profiles.detected =
    (volts >= Profiles.AUTO_VOLTS) and Profiles.LARGE or Profiles.SMALL
end

-- Cleared on model change: the next model is quite possibly the other heli.
function Profiles.reset()
  Profiles.detected = nil
end

function Profiles.set(n)
  n = tonumber(n)
  if n ~= Profiles.LARGE and n ~= Profiles.SMALL then n = Profiles.AUTO end
  if n ~= Profiles.selected then
    Profiles.selected = n
    Profiles.detected = nil
  end
end

-- Returns the active profile, or nil when nothing has been chosen or detected
-- yet. nil is a real answer and callers must handle it: before telemetry
-- arrives there is no honest way to say how big the helicopter is, and
-- guessing would narrow the windows against an aircraft nobody has seen.
function Profiles.current()
  if Profiles.selected ~= Profiles.AUTO then
    return Profiles.defs[Profiles.selected]
  end
  if Profiles.detected ~= nil then return Profiles.defs[Profiles.detected] end
  return nil
end

-- "set" | "auto" | "waiting" - shown on the sensor map beside the name, the
-- same way a sensor binding says how it was made. A profile silently moves
-- alert thresholds, so how it was chosen has to be as visible as what it is.
function Profiles.how()
  if Profiles.selected ~= Profiles.AUTO then return "set" end
  if Profiles.detected ~= nil then return "auto" end
  return "waiting"
end

function Profiles.label()
  local p = Profiles.current()
  if not p then return "--" end
  return p.label
end

-- Tightens a role's sanity window. Never widens one: the role definition is
-- the outer limit and a profile only ever says "and on this aircraft, less
-- than that".
function Profiles.window(role)
  local p = Profiles.current()
  if not p then return nil end
  return p.windows[role]
end

function Profiles.spin()
  local p = Profiles.current()
  if not p then return nil, nil end
  return p.spinUp, p.spinDown
end

-- sensors.cfg wins. Someone who wrote a threshold down meant it, and a profile
-- guessing from pack voltage does not get to overrule that.
function Profiles.setting(name)
  if Config.explicit and Config.explicit[name] then
    return Config.setting(name)
  end
  local p = Profiles.current()
  if p and p.settings[name] ~= nil then return p.settings[name] end
  return Config.setting(name)
end

return Profiles

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
Sensors.disabled   = {}
Sensors.modelName  = nil

-- "off" in sensors.cfg means the role stays unbound, and pass 3 must not fill
-- it in either. Until this existed there was no way to reject a wrong guess:
-- an ExpressLRS setup publishes no Thr sensor, so throttle fell through to the
-- unit pass, which matched the first spare percent sensor on the radio - TQly,
-- the transmitter link quality - and showed a confident, permanent THR 100%.
-- Naming a different sensor could not help, because a name the firmware does
-- not know falls through to the same guess.
local OFF_VALUES = { off = true, none = true, no = true, ["-"] = true }

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
  Sensors.disabled = {}
  for i = 1, #Roles.order do
    local role = Roles.order[i]
    if OFF_VALUES[lower(Sensors.overrides[role])] then
      -- Cleared rather than skipped: the role may already hold a binding from
      -- before the pilot switched it off.
      Sensors.bindings[role] = nil
      Sensors.disabled[role] = true
    elseif not Sensors.bindings[role] then
      pending[#pending + 1] = role
    end
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
      -- Switched off in sensors.cfg reads differently from never found: one
      -- is a decision, the other is a gap worth chasing.
      off       = Sensors.disabled[role] == true,
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
--      radio's storage, which silently diverges the moment you fly the same
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

-- What rf2.apiVersion read the last time we looked. The poll below acts on a
-- *change* in that field rather than on its value, so that an explicit
-- disconnect event - which RF Tool does deliver, and which is authoritative -
-- cannot be immediately undone by a poll seeing a field RF Tool has not
-- bothered to clear.
local polledApi = nil

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
    -- Adopt whatever the field says now, so the poll treats this as the
    -- current state rather than as a fresh connection to react to.
    local tbl = rf2Table()
    polledApi = tbl and tonumber(tbl.apiVersion) or nil
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
  now = now or Host.now()

  if not RF2.registered then
    if (now - lastAttempt) < REGISTER_RETRY then return end
    lastAttempt = now
    local tbl = rf2Table()
    if not tbl or type(tbl.registerWidget) ~= "function" then return end
    if not pcall(tbl.registerWidget, RF2.proxy) then return end
    RF2.registered = true
  end

  -- Then keep watching RF Tool's own fields, every pass, for as long as we
  -- run. Events alone are not enough and this is the bug that proved it:
  -- RF Tool publishes state only on *change*, and on a radio that boots before
  -- the heli is powered we register while nothing is connected, hear no event
  -- when the flight controller later appears, and sit on "waiting" forever
  -- while RF Tool's own screen says Connected.
  --
  -- Seeding once at registration - which is what this used to do - only covers
  -- the case where the FC was already up at that instant. Reading two table
  -- fields per pass is a local lookup, not MSP, so there is no reason to be
  -- clever about when to do it.
  local rf2 = rf2Table()
  if not rf2 then return end

  local api = tonumber(rf2.apiVersion)
  if api == polledApi then return end
  polledApi = api

  if api ~= nil then
    RF2.apiVersion = api
    RF2.connected  = true
    RF2.craftName  = rf2.modelName
    requestFlightStats()
  else
    -- RF Tool lost its handshake with the flight controller.
    RF2.connected = false
    clearFcData()
  end
end

--------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------
--
-- This whole module is invisible when it works and invisible when it does not.
-- The only outward sign was the sensor map footer quietly showing the flight
-- controller's craft name instead of the EdgeTX model name, which is not
-- enough to tell "RF Tool is not installed" from "installed but never
-- registered" from "registered but the FC never handshaked" - four different
-- problems with four different fixes.
--
-- Returns detail, verdict, status. Same shape as FlightLog.status().
function RF2.status()
  if not RF2.available() then
    -- Not a fault. The dashboard is fully usable without RF Tool, and most
    -- radios will never have it.
    return "not installed", "optional", "unbound"
  end
  if not RF2.registered then
    return "found, not registered", "waiting", "insane"
  end

  local detail = RF2.craftName or "registered"
  if RF2.apiVersion then
    detail = detail .. string.format("  api %.2f", RF2.apiVersion)
  end

  if RF2.connected == false then return detail, "no link", "unbound" end
  if RF2.connected == nil then return detail, "waiting", "unbound" end
  return detail, RF2.linkState or "connected", "ok"
end

-- The flight controller's own totals, which is the point of the integration:
-- a counter kept on the radio diverges the moment you fly the same heli with
-- a second radio.
function RF2.statsText()
  if not RF2.available() then return "--", "off", "unbound" end
  if RF2.statsStatus == "unsupported" then
    return "needs MSP API 12.09", "too old", "unbound"
  end
  if RF2.statsStatus == "ok" then
    local s = string.format("%d flights", RF2.totalFlights or 0)
    local secs = tonumber(RF2.totalFlightSeconds)
    if secs then
      s = s .. string.format(", %dh %02dm",
                             math.floor(secs / 3600),
                             math.floor((secs % 3600) / 60))
    end
    return s, "ok", "ok"
  end
  if RF2.statsStatus == "error" then return "no usable reply", "FAILED", "insane" end
  return "--", RF2.statsStatus, "unbound"
end

function RF2.reset()
  RF2.registered = false
  RF2.linkState  = nil
  RF2.connected  = nil
  lastAttempt    = -1e9
  polledApi      = nil
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

-- The rotor-arming latch. Declared up here rather than beside the arm code
-- below because resetSession clears it: a `local` further down the file is not
-- in scope at that point, so the assignment silently created a global instead
-- and the latch survived a model change.
local spunUp, belowSince = false, nil

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
  spunUp, belowSince = false, nil
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

  -- Pack voltage first, so auto-detection has settled on an aircraft before
  -- anything downstream asks the profile what is plausible. sampleRole runs
  -- the role again below; reading a sensor twice is cheaper than sampling
  -- every other role against a profile that arrives one pass late.
  do
    local v, ok = Sensors.read("packVoltage")
    ZD.Profiles.observe(v, ok == "ok")
  end

  for i = 1, #Roles.order do
    sampleRole(Roles.order[i])
  end
  deriveFuel()
  derivePower()

  -- After sampling, because the rotor fallback reads headspeed.
  local wasArmed = State.armed
  local armed, source = readArmed(now)
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

-- ======== src/alerts.lua ========
do
  local factory = (function()
-- Layer 5c: Alert engine.
--
-- The dashboard shows you a problem. This tells you about one - which is the
-- part that matters, because for most of a flight you are looking at the
-- helicopter and not at the screen.
--
-- Reads State, drives Host's audio and haptic. Owns no telemetry logic and
-- draws nothing, so the whole thing is testable off-radio.
--
-- Three rules keep it from becoming noise, which is the only way an alert
-- system fails in practice:
--
--   Hysteresis. Every alert clears at a different value from the one that
--   triggers it. A cell sagging across 3.40V under load would otherwise
--   announce itself on every rotor beat.
--
--   Repeat, don't chatter. While a condition holds, it repeats on a timer
--   rather than every service pass, and the timer is long enough to be
--   ignorable and short enough to not be forgotten.
--
--   Settle first. Nothing fires until telemetry has been live for a few
--   seconds. A pack reads 0.00V for the instant before the ESC reports, and
--   an alarm on power-up teaches the pilot to ignore alarms.

return function(ZD)

local Host   = ZD.Host
local State  = ZD.State
local Config = ZD.Config

local Alerts = {}
ZD.Alerts = Alerts

Alerts.enabled = true

-- Telemetry has to be live this long before anything can fire.
Alerts.SETTLE = Host.seconds(4)

Alerts.fired = {}          -- id -> true while the condition is held
Alerts.lastSpoken = nil    -- id of the most recent alert, for the UI
Alerts.count = 0           -- total fires this session, for tests and diagnostics

local liveSince = nil
local state = {}           -- id -> { active, nextAt }

--------------------------------------------------------------------------
-- Definitions
--------------------------------------------------------------------------

-- trigger/clear are deliberately asymmetric. speak() is called on every fire,
-- after the haptic, and may say nothing at all - a governor fault has no
-- number worth reading out.
-- Cell voltage is chemistry, not aircraft: a LiPo cell is in trouble at 3.4 V
-- whether it is one of two or one of fourteen. ESC temperature is aircraft -
-- a small ESC in a tight canopy is struggling well before a 700's is - so it
-- goes through the profile, which still lets sensors.cfg overrule it.
local function cellLow()  return Config.setting("alertCell") end
local function escHigh()  return ZD.Profiles.setting("alertEsc") end

local GOV_FAULT = { ["THR-OFF"] = true, ["LOST-HS"] = true, AUTOROT = true }

local DEFS = {
  {
    id = "cell",
    -- The one the pilot actually flies to. A margin of 0.10V on the way back
    -- up: a pack that has hit its floor does not recover quietly.
    test  = function() return State.valid("cellVoltage")
                          and State.num("cellVoltage") <= cellLow() end,
    clear = function() return not State.valid("cellVoltage")
                          or State.num("cellVoltage") >= cellLow() + 0.10 end,
    repeatAfter = 15,
    haptic = { 60, 80, 2 },
    speak = function()
      Host.playNumber(math.floor(State.num("cellVoltage") * 100 + 0.5),
                      Host.UNIT_VOLTS, Host.PREC2)
    end,
  },
  {
    id = "esc",
    test  = function() return State.valid("escTemperature")
                          and State.num("escTemperature") >= escHigh() end,
    clear = function() return not State.valid("escTemperature")
                          or State.num("escTemperature") <= escHigh() - 8 end,
    repeatAfter = 20,
    haptic = { 90, 90, 2 },
    speak = function()
      Host.playNumber(math.floor(State.num("escTemperature") + 0.5),
                      Host.UNIT_CELSIUS, 0)
    end,
  },
  {
    id = "governor",
    -- No number to read out: the state is the message, and the pilot has
    -- rather more urgent things to do than listen to a word.
    test  = function()
      return State.valid("governor") and GOV_FAULT[State.governorText()] == true
    end,
    clear = function()
      return not State.valid("governor")
             or GOV_FAULT[State.governorText()] ~= true
    end,
    repeatAfter = 10,
    haptic = { 40, 60, 3 },
    tone = { 260, 200, 40 },
  },
  {
    id = "link",
    -- Only meaningful once a link has existed. Rotorflight tells us
    -- authoritatively when it can; otherwise link quality carries it.
    test = function()
      if State.linkConnected == false then return true end
      return State.valid("linkQuality") and State.num("linkQuality") <= 30
    end,
    clear = function()
      if State.linkConnected == true then return true end
      return not State.valid("linkQuality") or State.num("linkQuality") >= 45
    end,
    repeatAfter = 12,
    haptic = { 50, 50, 2 },
    tone = { 180, 300, 60 },
  },
}

Alerts.DEFS = DEFS

--------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------

local function fire(def)
  local h = def.haptic
  if h then
    for _ = 1, (h[3] or 1) do Host.playHaptic(h[1], h[2], Host.PLAY_NOW) end
  end
  if def.tone then
    Host.playTone(def.tone[1], def.tone[2], def.tone[3], Host.PLAY_NOW)
  end
  if def.speak then pcall(def.speak) end
  Alerts.lastSpoken = def.id
  Alerts.count = Alerts.count + 1
end

-- Fires one alert on demand, so "are the alerts working" can be answered
-- without waiting for a flat pack or editing a threshold in sensors.cfg and
-- editing it back afterwards. Also the honest pre-flight check: it proves the
-- volume is up and the haptic is on, which are radio settings this widget has
-- no way to see.
--
-- Speaks the live cell voltage when there is one, so the answer includes
-- "and it is reading the right sensor".
function Alerts.selfTest()
  local def = DEFS[1]
  local h = def.haptic
  for _ = 1, (h[3] or 1) do Host.playHaptic(h[1], h[2], Host.PLAY_NOW) end
  local v = State.valid("cellVoltage")
            and State.num("cellVoltage") or cellLow()
  Host.playNumber(math.floor(v * 100 + 0.5), Host.UNIT_VOLTS, Host.PREC2)
  Alerts.lastSpoken = "test"
  Alerts.count = Alerts.count + 1
  return true
end

function Alerts.reset()
  state = {}
  liveSince = nil
  Alerts.fired = {}
  Alerts.lastSpoken = nil
  Alerts.count = 0
end

-- Any live flight value counts as telemetry being up. Deliberately the same
-- test the dashboard once used to decide it had something worth drawing.
local function telemetryLive()
  return State.valid("cellVoltage") or State.valid("packVoltage")
      or State.valid("headspeed") or State.valid("batteryPercent")
      or State.valid("current")
end

function Alerts.service(now)
  now = now or Host.now()
  if not Alerts.enabled then
    liveSince = nil
    return
  end

  if not telemetryLive() then
    -- Losing telemetry is not itself an alert - a dropout is common and the
    -- dashboard already says so. Clear the settle timer so a reconnect gets
    -- its grace period back rather than firing on the first noisy sample.
    liveSince = nil
    return
  end
  if liveSince == nil then liveSince = now end
  if (now - liveSince) < Alerts.SETTLE then return end

  -- A held hold switch means the pilot is deliberately parked with the model
  -- powered. Freezing the extremes without silencing the alarms would make
  -- the feature useless on the bench.
  if State.holdActive then return end

  for _, def in ipairs(DEFS) do
    local s = state[def.id]
    if not s then s = { active = false, nextAt = 0 }; state[def.id] = s end

    if s.active then
      if def.clear() then
        s.active = false
        Alerts.fired[def.id] = nil
      elseif now >= s.nextAt then
        fire(def)
        s.nextAt = now + Host.seconds(def.repeatAfter)
      end
    elseif def.test() then
      s.active = true
      Alerts.fired[def.id] = true
      fire(def)
      s.nextAt = now + Host.seconds(def.repeatAfter)
    end
  end
end

-- What is currently sounding, worst first, for anything that wants to show it.
function Alerts.active()
  local out = {}
  for _, def in ipairs(DEFS) do
    if Alerts.fired[def.id] then out[#out + 1] = def.id end
  end
  return out
end

return Alerts

end

  end)()
  factory(ZD)
end

-- ======== src/flightlog.lua ========
do
  local factory = (function()
-- Layer 5d: Flight log.
--
-- One CSV line per flight, written once, at the moment the flight ends. The
-- numbers a pilot wants afterwards are all session extremes the State layer is
-- already tracking, so this owns no telemetry logic - it decides when a flight
-- counts, formats it, and gets it onto the card without losing what was there
-- before.
--
-- CSV rather than anything cleverer because it opens in a spreadsheet, appends
-- readably, and survives being edited by hand. Rotorflight's own scripts keep
-- a flights-count.csv for the same reasons.
--
-- Read-modify-write rather than append: EdgeTX's Lua io is a reduced
-- implementation and this codebase has only ever exercised "r" and "w", so
-- betting a flight record on "a" being present is a bet with no upside. Going
-- through Host.writeFile buys the atomic temp-and-rename it already does, and
-- it is what makes the record cap below possible at all.

return function(ZD)

local Host  = ZD.Host
local State = ZD.State

local FlightLog = {}
ZD.FlightLog = FlightLog

-- /LOGS/ is where EdgeTX keeps its own telemetry CSVs, so it is where a pilot
-- already looks and where a file manager already points. It also survives
-- reinstalling the widget, which the widget's own folder does not - copying a
-- new build over the top would take the flight history with it.
--
-- "SD card" is the wrong word for this and has been all along: EdgeTX presents
-- one path namespace whether the storage is a card or internal flash, and Lua
-- cannot tell the difference. It is just the radio's storage.
FlightLog.DIR      = "/LOGS/"
FlightLog.FILE     = "zeliondash.csv"
FlightLog.FALLBACK = nil       -- set if /LOGS/ turns out not to be writable

-- Below this a "flight" is a spool-up test, a bench run, or a bounced start.
-- Logging those buries the real ones.
FlightLog.MIN_SECONDS = 20

-- Storage is not infinite and nobody reads the five-hundredth flight back.
-- Oldest records fall off the top; the header always survives.
FlightLog.MAX_RECORDS = 200

FlightLog.HEADER =
  "date,time,model,seconds,max_rpm,min_cell,min_pack,max_amps," ..
  "max_esc_c,used_mah,end_pct"

FlightLog.lastError  = nil
FlightLog.lastWrite  = nil    -- the CSV line most recently written
FlightLog.written    = 0      -- records written this session
FlightLog.skipped    = 0      -- flights too short to bother with
FlightLog.madeDir    = nil    -- whether mkdir reported the folder usable

-- Why nothing has been written, in the pilot's terms. "No file appeared" has
-- three completely different causes and they were indistinguishable: the log
-- is off, no flight has ended yet, or the write failed. Only the last is a
-- fault, and only the last is worth chasing.
function FlightLog.status()
  if not FlightLog.enabled then return "off", "off" end
  if FlightLog.lastError then return FlightLog.lastError, "FAILED" end
  if FlightLog.written > 0 then
    return FlightLog.path(), string.format("%d written", FlightLog.written)
  end
  if FlightLog.skipped > 0 then
    return FlightLog.path(),
           string.format("%d too short", FlightLog.skipped)
  end
  return FlightLog.path(), "no flight yet"
end

function FlightLog.path()
  if FlightLog.FALLBACK then return FlightLog.FALLBACK end
  return FlightLog.DIR .. FlightLog.FILE
end

-- If /LOGS/ cannot be written - a radio whose firmware lays things out
-- differently, or a folder that simply is not there - fall back to the widget's
-- own folder rather than losing the flight. Tried once, then remembered, so a
-- failing write is not retried on every landing.
local function fallBack()
  if FlightLog.FALLBACK then return end
  FlightLog.FALLBACK = Host.widgetDir() .. FlightLog.FILE
end

--------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------

-- A missing reading is empty, never zero. A spreadsheet column of zeroes that
-- were really "no sensor" is worse than a gap, because it averages.
--
-- Rounds before formatting an integer. Telemetry values are floats, and Lua
-- 5.3 onwards refuses "%d" for one with a fractional part - the derived
-- battery percentage comes off a sigmoid, so it is 96.37 rather than 96, and
-- the whole record was failing to format because of it.
local function num(v, fmt)
  v = tonumber(v)
  if v == nil then return "" end
  if fmt == "%d" then
    -- math.floor can still hand back a float for a value with no integer
    -- representation - an infinity, or something enormous off a glitched
    -- sensor - and Lua 5.3's "%d" refuses those. Better a blank column than a
    -- lost flight.
    local n = math.floor(v + 0.5)
    if n ~= n or n == math.huge or n == -math.huge then return "" end
    local ok, s = pcall(string.format, "%d", n)
    return ok and s or ""
  end
  local ok, s = pcall(string.format, fmt, v)
  return ok and s or ""
end

-- Each field is built independently. A record is written once, at landing, and
-- there is no second chance at it: one column that will not format must cost
-- that column and nothing else. The whole record failing to format is exactly
-- what happened on hardware, and it took the flight with it.
local function safe(fn)
  local ok, v = pcall(fn)
  if not ok or v == nil then return "" end
  return tostring(v)
end

-- Commas and quotes in a model name would otherwise shift every column after
-- it. Quoting is the CSV answer; doubling the quote is how CSV escapes one.
local function field(s)
  -- Function form throughout: EdgeTX has no string metatable, so s:gsub()
  -- raises on the radio. See Host.mkdir.
  s = string.gsub(tostring(s or ""), '"', '""')
  if string.find(s, '[,"\n]') then return '"' .. s .. '"' end
  return s
end

-- Date parts are coerced individually. getDateTime is the radio's RTC and its
-- fields have to survive being absent, floating point, or something a
-- particular firmware decided to return instead.
local function clockPart(t, key, fallback)
  local v = math.floor(tonumber(t and t[key]) or fallback)
  if v ~= v or v == math.huge or v == -math.huge then return fallback end
  return v
end

function FlightLog.record()
  local ok, dt = pcall(Host.dateTime)
  local t = (ok and type(dt) == "table") and dt or {}

  return table.concat({
    safe(function()
      return string.format("%04d-%02d-%02d", clockPart(t, "year", 1970),
                           clockPart(t, "mon", 1), clockPart(t, "day", 1))
    end),
    safe(function()
      return string.format("%02d:%02d:%02d", clockPart(t, "hour", 0),
                           clockPart(t, "min", 0), clockPart(t, "sec", 0))
    end),
    safe(function() return field(State.modelName or Host.modelName()) end),
    safe(function() return num(State.flightSeconds, "%d") end),
    safe(function() return num(State.max("headspeed"), "%d") end),
    safe(function() return num(State.min("cellVoltage"), "%.2f") end),
    safe(function() return num(State.min("packVoltage"), "%.2f") end),
    safe(function() return num(State.max("current"), "%.1f") end),
    safe(function() return num(State.max("escTemperature"), "%d") end),
    safe(function() return num(State.max("capacity"), "%d") end),
    safe(function()
      if not State.valid("batteryPercent") then return "" end
      return num(State.num("batteryPercent"), "%d")
    end),
  }, ",")
end

--------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------

local function splitLines(text)
  local out = {}
  for line in string.gmatch(tostring(text or ""), "[^\r\n]+") do
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

-- Returns the records already on the card, header excluded. A file that is
-- unreadable or has the wrong header is treated as absent rather than
-- appended to: half a flight log is more confusing than a fresh one, and the
-- previous file survives as the .bak that Host.writeFile leaves behind.
function FlightLog.read()
  local text = Host.readFile(FlightLog.path())
  if not text then return {} end
  local lines = splitLines(text)
  if #lines == 0 then return {} end
  if lines[1] ~= FlightLog.HEADER then return {} end
  table.remove(lines, 1)
  return lines
end

function FlightLog.append(line)
  -- The folder first, before anything opens a file inside it. /LOGS/ is only
  -- there if the radio has logged telemetry before, and reading a path inside
  -- a folder that does not exist is not a quiet nil on this firmware - it
  -- raises. Doing the mkdir between the read and the write, which is where it
  -- used to sit, meant the read went first and took the flight with it.
  FlightLog.madeDir = Host.mkdir(FlightLog.DIR)

  local records = FlightLog.read()
  records[#records + 1] = line
  while #records > FlightLog.MAX_RECORDS do table.remove(records, 1) end
  local body = FlightLog.HEADER .. "\n" .. table.concat(records, "\n") .. "\n"

  local ok = Host.writeFile(FlightLog.path(), body)
  if not ok and not FlightLog.FALLBACK then
    fallBack()
    -- Re-read: the fallback location may already hold a history of its own.
    records = FlightLog.read()
    records[#records + 1] = line
    while #records > FlightLog.MAX_RECORDS do table.remove(records, 1) end
    body = FlightLog.HEADER .. "\n" .. table.concat(records, "\n") .. "\n"
    ok = Host.writeFile(FlightLog.path(), body)
  end

  if ok then
    FlightLog.lastWrite = line
    FlightLog.written = FlightLog.written + 1
    FlightLog.lastError = nil
  else
    FlightLog.lastError = "write failed: " .. FlightLog.path()
  end
  return ok
end

--------------------------------------------------------------------------
-- Service
--------------------------------------------------------------------------

FlightLog.enabled = true

-- Called every service pass. Does nothing at all until State latches a disarm,
-- so the card is touched exactly once per flight rather than on any kind of
-- timer - file I/O runs in the same loop that draws the screen.
function FlightLog.service()
  if not State.disarmPending then return false end
  local seconds = State.flightSeconds

  -- Consume it either way. A flight too short to log is still a flight that
  -- has ended, and leaving the latch set would write it at the next disarm.
  State.consumeDisarm()

  if not FlightLog.enabled then return false end
  if seconds < FlightLog.MIN_SECONDS then
    FlightLog.skipped = FlightLog.skipped + 1
    return false
  end

  -- Marked before the attempt, cleared on success. Every silent failure so far
  -- has been a throw from somewhere nobody had enumerated, and the status line
  -- read "no flight yet" - the same thing it says when the heli never left the
  -- ground. Claiming the failure up front means an unknown one still shows up:
  -- whatever goes wrong from here, it cannot go wrong quietly.
  FlightLog.lastError = "interrupted before the write"

  local ok, line = pcall(FlightLog.record)
  if not ok then
    -- Carry the real message. "could not format the record" cost a round trip
    -- to hardware and said nothing: the whole point of showing an error on the
    -- radio is that it names what went wrong.
    FlightLog.lastError = "fmt: " .. tostring(line)
    return false
  end

  local wrote
  ok, wrote = pcall(FlightLog.append, line)
  if not ok then
    -- append raising was the one path that reported nothing at all. It is how
    -- a real 27-second flight vanished with the log still saying "no flight
    -- yet", and it is the reason for the marker above.
    FlightLog.lastError = "write: " .. tostring(wrote)
    return false
  end
  return wrote == true
end

function FlightLog.reset()
  FlightLog.written, FlightLog.skipped = 0, 0
  FlightLog.lastWrite, FlightLog.lastError = nil, nil
  FlightLog.FALLBACK = nil
end

return FlightLog

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

-- EdgeTX packs the font into bits 8..11 of a text flag as an ENUMERATED INDEX,
-- not as independent bits (radio/src/gui/colorlcd/fonts.h):
--
--   0 STD   1 BOLD   2 TINSIZE   3 SMLSIZE   4 MIDSIZE   5 DBLSIZE   6 XXLSIZE
--
-- BOLD is a font in its own right - standard size, bold weight - and NOT a
-- modifier. Adding it to a size does plain arithmetic inside that field and
-- quietly selects a different font: SMLSIZE + BOLD is MIDSIZE, MIDSIZE + BOLD
-- is DBLSIZE, DBLSIZE + BOLD is XXLSIZE. Every one of those is legal, merely
-- wrong, which is why the mistake survived so long.
--
-- XXLSIZE + BOLD is index 7, and on EdgeTX 2.11 FONTS_COUNT is 7 - so index 7
-- is one past the end. LvglWidgetLabel::setFont calls etx_font(), which does
-- `etx_obj_add_style(obj, styles->font[fontIdx])` against `lv_style_t
-- font[FONTS_COUNT]` with no bounds check, handing LVGL a style read from off
-- the end of the array. That is a native fault, not a Lua error: no pcall can
-- catch it, and the transmitter reboots into EMERGENCY MODE.
--
-- Exactly two labels used XXLSIZE + BOLD - battery percent and headspeed - and
-- both live only on the dashboard. That is why safe mode (DBLSIZE + BOLD, which
-- lands on XXLSIZE) and standby (MIDSIZE + BOLD, which lands on DBLSIZE) both
-- ran fine while every render level that drew the dashboard took the radio down.
--
-- So each entry below is a COMPLETE font selection. Never add two together.
-- DBLSIZE and XXLSIZE are drawn from bold glyph sets already; there is no bold
-- variant of TINSIZE/SMLSIZE/MIDSIZE, which makes BOLD itself the only
-- emphasis available at text sizes.
Theme.font = {
  tiny      = flag("TINSIZE", 0),
  small     = flag("SMLSIZE", 0),
  smallBold = flag("BOLD", 0),      -- STD weight bold: the only small emphasis
  normal    = flag("STDSIZE", 0),
  mid       = flag("MIDSIZE", 0),
  midBold   = flag("MIDSIZE", 0),   -- no bold MIDSIZE exists
  large     = flag("DBLSIZE", 0),   -- already bold
  huge      = flag("XXLSIZE", flag("DBLSIZE", 0)),  -- already bold
}

-- 2.12 appends an eighth font; 2.11 stops at XXLSIZE. Clamping to 6 is correct
-- on both, and the extra one is a nicety nothing here asks for.
Theme.FONT_MAX_INDEX = 6
local FONT_SHIFT, FONT_STEPS = 256, 16

-- Last line of defence, applied to every font that reaches LVGL. A call site
-- that computes a size wrongly gets a cosmetic bug; one that computes an
-- out-of-range index reboots the radio, so the index is clamped rather than
-- trusted. Colour lives in bits 16+ and alignment in bits 0..7, so both pass
-- through untouched.
-- Counts how often it had to intervene. On the radio nobody reads this; in the
-- test suite it is the assertion. Clamping makes a bad font harmless, which
-- would also make a reintroduced `size + BOLD` invisible again - so the tests
-- assert this stays at zero across every screen rather than merely asserting
-- that nothing crashed.
Theme.fontClamps = 0

function Theme.safeFont(flags)
  flags = tonumber(flags) or 0
  local idx = math.floor(flags / FONT_SHIFT) % FONT_STEPS
  if idx <= Theme.FONT_MAX_INDEX then return flags end
  Theme.fontClamps = Theme.fontClamps + 1
  return flags - (idx - Theme.FONT_MAX_INDEX) * FONT_SHIFT
end

--------------------------------------------------------------------------
-- Font metrics
--------------------------------------------------------------------------
--
-- EdgeTX compiles ONE of three font sets into the firmware, chosen by the
-- radio's screen size at build time (radio/src/fonts/CMakeLists.txt): "lrg"
-- for 800x480, "sml" for 320x240, "std" for everything else - which is where
-- the TX15's 480x320 lands. The line heights below are read out of the
-- generated lv_font_en_*.c files in v2.11.0.
--
-- These are far larger than a design mock-up suggests. SMLSIZE is 23px tall on
-- a TX16S, not the ~11px "small" usually means, and XXLSIZE is 102px. Without
-- the real numbers the layout is guesswork, and guessed text positions are how
-- two labels 24px apart ended up on top of each other on hardware.
local FONT_HEIGHTS = {
  --      STD BOLD XXS  XS   L   XL  XXL
  lrg = { [0]=29, 29, 17, 23, 46, 58, 102 },
  std = { [0]=21, 20, 12, 17, 29, 40,  69 },
  sml = { [0]=14, 14, 10, 12, 18, 26,  44 },
}

Theme.metrics = "std"

function Theme.useMetricsFor(w)
  Theme.metrics = ((tonumber(w) or 0) >= 800) and "lrg" or "std"
  return Theme.metrics
end

-- Height of one line in the given font flags, in pixels on the current radio.
function Theme.fontHeight(flags)
  local idx = math.floor((tonumber(flags) or 0) / FONT_SHIFT) % FONT_STEPS
  local set = FONT_HEIGHTS[Theme.metrics] or FONT_HEIGHTS.std
  return set[idx] or set[0]
end

Theme.built = false

function Theme.build()
  if Theme.built then return end
  if type(lcd) ~= "table" or type(lcd.RGB) ~= "function" then return end
  local rgb = lcd.RGB

  -- One navy for everything: the screen, every tile, and the empty part of the
  -- battery gauge. No fill contrast anywhere - a panel is its green outline,
  -- and the gauge's level is read purely by where the lime stops.
  --
  -- tools/make_logos.py flattens the artwork onto Theme.bg. Change this and
  -- the PNGs have to be regenerated, or every logo carries a box of the old
  -- background around it.
  Theme.bg     = rgb(  9,  15,  35)
  Theme.panel  = Theme.bg
  Theme.track  = Theme.bg
  Theme.rule   = rgb( 35,  48,  83)
  Theme.ink    = rgb(242, 245, 248)
  Theme.dim    = rgb(148, 163, 190)

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

  -- Every panel is outlined in the brand green, matching the battery gauge.
  -- That makes green decorative rather than a signal, which is fine as long as
  -- amber and red keep their meaning - so the governor still overrides its
  -- border when the state is one that needs attention.
  Theme.panelBr = Theme.lime

  -- The governor tile matches every other tile while nothing is wrong - idle
  -- and running are both just navy behind green, and the state is carried by
  -- the word itself. Warning and critical keep a filled background: those are
  -- the two an unmissable tile is for, and flattening them to match the rest
  -- would be uniformity bought with the one signal worth having.
  Theme.govRunBg  = Theme.bg
  Theme.govRunBr  = Theme.lime
  Theme.govWarnBg = rgb( 52,  40,  10)
  Theme.govWarnBr = rgb(160, 118,  20)
  Theme.govCritBg = rgb( 58,  16,  16)
  Theme.govCritBr = rgb(170,  50,  50)
  Theme.govIdleBg = Theme.bg
  Theme.govIdleBr = Theme.lime

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
-- Other resolutions in the same class keep the class's fonts and paddings and
-- distribute the leftover height proportionally. tools/dump_screen.lua plus
-- tools/render_screen.py draw whatever this produces, at true resolution and
-- with EdgeTX's own font metrics.

return function(ZD)

local Layout = {}
ZD.Layout = Layout

Layout.ROOMY_MIN_WIDTH = 700

-- Per-class constants. Vertical figures marked "anchor" are the design values
-- at that class's reference height and are scaled when the screen differs.
-- The right column was widened at the hero column's expense. The three tiles
-- were 88px wide on a TX16S, which is barely three digits of MIDSIZE, and the
-- logo sat in a 252px box with the governor cramped above it. Taking that
-- width off the hero costs nothing: the hero only has to fit "1850" and "100",
-- and both still do.
--
-- valShare is the fraction of a hero tile's inner width the big number gets,
-- per tile, because a four-digit headspeed needs more of it than a
-- three-digit percentage. See buildHeroTile.
local CLASS = {
  roomy = {
    name = "roomy", refH = 480,
    pad = 10, gap = 10, barW = 96, rightW = 340,
    topH = 40, stripH = 44, contentGap = 6, stripGap = 8,
    chipH = 75, colGapV = 8,
    heroGapV = 8, batShare = 0.508,
    batValShare = 0.62, hsValShare = 0.78,
    govH = 90, rowGapV = 8, tileH = 110, tileGapH = 3,
  },
  tight = {
    name = "tight", refH = 320,
    pad = 6, gap = 6, barW = 64, rightW = 190,
    topH = 28, stripH = 36, contentGap = 6, stripGap = 8,
    chipH = 61, colGapV = 7,
    heroGapV = 6, batShare = 0.5,
    batValShare = 0.62, hsValShare = 0.82,
    govH = 56, rowGapV = 7, tileH = 74, tileGapH = 3,
  },
}

-- Height over width of the Zelion lockup, from assets/zelion_lockup.png.
-- Everything that places the mark works from this rather than from a pair of
-- pixel dimensions, so the artwork can be regenerated at any size.
local LOGO_ASPECT = 1522 / 2708

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

  -- The mark fills whatever space is left at its own aspect ratio, never
  -- stretched: an unevenly scaled logo is worse than a slightly smaller one.
  -- Derived from the box rather than from fixed dimensions, so widening the
  -- right column actually grows the logo instead of leaving it adrift in the
  -- middle of a bigger box.
  local lw, lh = logoBox.w, round(logoBox.w * LOGO_ASPECT)
  if lh > logoBox.h then
    lh = logoBox.h
    lw = round(lh / LOGO_ASPECT)
  end
  L.logo = rect(logoBox.x + round((logoBox.w - lw) / 2),
                logoBox.y + round((logoBox.h - lh) / 2), lw, lh)

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

-- A corner radius larger than half the shorter side is geometrically
-- impossible, and asking a graphics library to draw one is a classic way to
-- crash it natively. This code was doing exactly that: the battery gauge fill
-- is created one pixel tall with a radius of 5, and the TX battery fill one
-- pixel tall with a radius of 2. Both are clamped here rather than at every
-- call site, because the offending sizes are runtime values - a gauge at 0%
-- is one pixel tall no matter what radius the design asked for.
--
-- Declared before setp(), which calls it. It used to sit below, so the call in
-- setp() resolved to a nil global instead - harmless only because every radius
-- that reached it happened to have clamped to zero at build time.
Dashboard.noRound = false

local function safeRadius(w, h, rounded)
  if Dashboard.noRound then return 0 end
  local r = rounded or 0
  if r <= 0 then return 0 end
  local limit = math.floor(math.min(w or 0, h or 0) / 2)
  if limit < 0 then limit = 0 end
  if r > limit then return limit end
  return r
end

local function setp(obj, props)
  if not obj then return end
  local st = SHADOW[obj]
  if not st then st = {}; SHADOW[obj] = st end
  if props.font ~= nil then props.font = Theme.safeFont(props.font) end
  -- Resizing can make an existing radius illegal - a gauge shrinking to one
  -- pixel keeps the radius it was built with unless it is re-clamped.
  if props.w ~= nil or props.h ~= nil then
    local w = props.w or st.w
    local h = props.h or st.h
    if st.rounded and st.rounded > 0 and w and h then
      local r = safeRadius(w, h, st.rounded)
      if r ~= st.rounded then props.rounded = r end
    end
  end
  local changed = false
  for k, v in pairs(props) do
    if st[k] ~= v then st[k] = v; changed = true end
  end
  if changed then obj:set(props) end
end

-- Deliberately no hide()/show(). Those were the other construct safe mode
-- never exercises; an object that should not be seen is collapsed to a single
-- pixel in the colour behind it instead.
local function setHidden(obj, hidden, bgColor)
  if not obj then return end
  if hidden then
    setp(obj, { h = 1, color = bgColor })
  end
end

-- Every font passes through Theme.safeFont on its way to LVGL. EdgeTX indexes
-- its font style array with no bounds check, so an index it has no font for is
-- a native fault and an EMERGENCY MODE reboot - not something pcall can catch.
local function label(x, y, w, text, font, color, align)
  local p = { x=x, y=y, w=w or 0, h=0, text=text or "",
              font=Theme.safeFont(font or 0),
              color=color or Theme.ink, align=align or 0 }
  return remember(lvgl.label(p), p)
end

local function rectangle(x, y, w, h, color, filled, rounded, thickness)
  local p = { x=x, y=y, w=w, h=h, color=color,
              filled=filled and 1 or 0, rounded=safeRadius(w, h, rounded),
              thickness=thickness or 1 }
  return remember(lvgl.rectangle(p), p)
end

-- A panel is two FILLED rectangles, the outer one showing through a 1px inset
-- to read as a border.
--
-- Hardware verdict: safe mode - filled rectangles and labels only - does not
-- crash the radio, while the full dashboard does even with every image
-- disabled. Unfilled rectangles were one of only two constructs the dashboard
-- used that safe mode did not, so nothing draws with filled=0 any more.
-- Keeping two objects preserves independent recolouring for the governor.
local function panel(r, fill, border, rounded)
  local rd = rounded or 5
  return {
    border = rectangle(r.x, r.y, r.w, r.h, border, true, rd, 0),
    fill   = rectangle(r.x + 1, r.y + 1, r.w - 2, r.h - 2, fill, true,
                       rd > 1 and rd - 1 or rd, 0),
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

-- Lives in State: the alert engine needs the same answer and has no business
-- reaching into the renderer for it.
local function govText() return State.governorText() end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

local L
local mode  -- "dash" | "minimal" | "toosmall"

-- There is one screen. A separate standby screen used to stand in until
-- telemetry arrived, on the reasoning that a grid of dashes looks broken - but
-- the dashboard already distinguishes "no sensor" from "reading zero" honestly,
-- and showing the real layout immediately says more than a splash does: you can
-- see the widget is alive, laid out, and waiting on named values. It also
-- removes the screen-to-screen transition, which is where the emergency-mode
-- reboot used to happen. The Zelion lockup is on the dashboard anyway, so the
-- branding never leaves the screen.


-- Artwork lives on the radio's storage, so it can simply be absent - a widget copied
-- without its PNGs is the likeliest first-run mistake. Check before asking
-- LVGL to load it: a missing image otherwise fails silently and leaves a hole
-- with nothing to explain it.
Dashboard.logoMissing = false
Dashboard.missingPath = nil

function Dashboard.placeLogo(r, filename)
  if Dashboard.noLogo then
    local F = Theme.font
    label(r.x, r.y + math.floor((r.h - Theme.fontHeight(F.mid)) / 2), r.w,
          "ZELION POWER", F.mid, Theme.steel, ALIGN_CENTER)
    return
  end
  local path = assetDir() .. filename
  -- Cached in Host, so a rebuild does not re-open (and re-allocate) the file.
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
    label(r.x, r.y + math.floor((r.h - Theme.fontHeight(F.mid)) / 2), r.w,
          "ZELION POWER", F.mid, Theme.steel, ALIGN_CENTER)
  end

  -- Attempted unconditionally: if LVGL can load it, it renders regardless of
  -- what the probes concluded.
  lvgl.image({ x=r.x, y=r.y, w=r.w, h=r.h, fill=false, file=path })
end

-- Text is placed from measured font heights, not from offsets tuned against a
-- design mock-up. EdgeTX's fonts are much larger than a mock-up implies -
-- SMLSIZE is 23px on a TX16S and XXLSIZE is 102px - so every panel on this
-- screen had its header sitting inside its own value. Asking Theme for the
-- height and stacking from that is the only version that holds on both radios.
local function fh(font) return Theme.fontHeight(font) end

local function buildTopBar()
  local F = Theme.font
  local roomy = L.class == "roomy"
  -- Three items share the top bar, so each gets a bounded box rather than the
  -- full width. A centred label spanning the whole screen looks fine until the
  -- craft name is long enough to reach the clock.
  local nameW = roomy and 260 or 150
  V.modelName = label(L.c.pad, L.top.y + (roomy and 5 or 4), nameW, "",
                      F.tiny, Theme.ink)
  local timerX = L.c.pad + nameW + 10
  V.timer = label(timerX, L.top.y + math.floor((L.c.topH - fh(F.small)) / 2),
                  L.w - timerX * 2, "", F.small, Theme.ink, ALIGN_CENTER)

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
  -- Clear of the glyph itself: the reading used to be drawn on top of it.
  local txW = roomy and 44 or 34
  V.txText = label(bx - 6 - txW, by, txW, "", F.tiny, Theme.ink, ALIGN_RIGHT)

  lvgl.hline({ x=0, y=L.topRule, w=L.w, h=1, color=Theme.rule })
end

local function buildLeftColumn()
  local F = Theme.font
  local c, b = L.cell, L.bar

  local roomy = L.class == "roomy"
  V.cellPanel = panel(c, Theme.panel, Theme.panelBr, 6)
  local y = c.y + (roomy and 4 or 3)
  label(c.x, y, c.w, "CELL", F.tiny, Theme.lime, ALIGN_CENTER)
  -- smallBold, not large: DBLSIZE is 58px on a TX16S and this chip is 75 tall.
  V.cellValue = label(c.x, y + fh(F.tiny) + (roomy and 3 or 2), c.w, "",
                      F.smallBold, Theme.ink, ALIGN_CENTER)
  V.cellMin = label(c.x, c.y + c.h - fh(F.tiny) - (roomy and 3 or 2), c.w, "",
                    F.tiny, Theme.peak, ALIGN_CENTER)

  -- Brand-green border: the gauge is the Zelion instrument on this screen.
  -- Two filled rects rather than an outlined one, for the same reason as panel().
  rectangle(b.x, b.y, b.w, b.h, Theme.lime, true, 7, 0)
  rectangle(b.x + 2, b.y + 2, b.w - 4, b.h - 4, Theme.track, true, 5, 0)
  V.barFill = rectangle(b.x + 3, b.y + b.h - 4, b.w - 6, 1, Theme.lime, true, 5, 0)
  V.barGeom = { x=b.x + 3, y=b.y + 3, w=b.w - 6, h=b.h - 6 }
end

-- Both hero tiles share one shape: a header line, a very large number under it,
-- a rule, and a row of small footnotes on the floor of the tile. Only the
-- header's right-hand item and the number's unit differ, so build it once.
--
-- The number is left-aligned and its unit tracks it: the unit's x is recomputed
-- from the measured width of the reading whenever that reading changes width,
-- so "%" hugs "68" and "100" alike instead of sitting at a fixed offset with a
-- gap that grows as the value shortens.
--
-- valShare is now only a clamp - the widest the number is allowed to grow
-- before its unit would be pushed off the tile.
local function buildHeroTile(r, title, unitText, unitFont, slotCount, valShare)
  local F = Theme.font
  local roomy = L.class == "roomy"
  local padX  = roomy and 14 or 8
  local inner = r.w - padX * 2

  panel(r, Theme.panel, Theme.panelBr)

  local headY = r.y + (roomy and 6 or 4)
  local headH = math.max(fh(F.tiny), fh(F.small))
  label(r.x + padX, headY, math.floor(inner / 2), title, F.tiny, Theme.dim)

  local footH = fh(F.tiny)
  local footY = r.y + r.h - footH - (roomy and 6 or 4)
  local ruleY = footY - (roomy and 6 or 4)

  -- The number sits centred in the band between the header and the rule rather
  -- than tucked straight under the header, which left it riding high with all
  -- the slack pooled beneath it.
  local bandTop = headY + headH
  local valY = bandTop + math.max(0,
                 math.floor(((ruleY - bandTop) - fh(F.huge)) / 2))
  local valW = math.floor(inner * valShare)
  -- Left-aligned, flush with the panel title above it.
  local value = label(r.x + padX, valY, valW, "", F.huge, Theme.ink)

  -- The unit sits on the number's right shoulder, on its baseline. Both "%"
  -- and "RPM" belong to the number they qualify; at the tile's far edge they
  -- read as separate fields.
  local unit, unitGeom
  if unitText then
    local gap = roomy and 8 or 4
    unitGeom = { x0 = r.x + padX, gap = gap, font = F.huge,
                 lineH = fh(F.huge), maxX = r.x + padX + valW + gap,
                 width = inner - valW - gap }
    unit = label(unitGeom.maxX, valY + fh(F.huge) - fh(unitFont),
                 unitGeom.width, unitText, unitFont, Theme.dim)
  end

  lvgl.hline({ x=r.x + padX, y=ruleY, w=inner, h=1, color=Theme.rule })

  local foots, slotW = {}, math.floor(inner / slotCount)
  for i = 1, slotCount do
    foots[i] = label(r.x + padX + slotW * (i - 1), footY, slotW, "",
                     F.tiny, Theme.dim)
  end

  -- Returned so the caller can put its own reading on the header's right.
  return value, foots, { x = r.x + padX + math.floor(inner / 2),
                         y = headY, w = math.floor(inner / 2) },
         unit, unitGeom
end

-- Writes a hero reading and slides its unit up against it.
--
-- The measurement is the point: without it the unit has to sit at a fixed
-- offset chosen for the widest possible reading, which strands it half a panel
-- away from a two-digit value. lcd.sizeText is pure - it reads font metrics and
-- touches no draw buffer - so it is safe to call here.
local function setHeroValue(value, geom, unit, text)
  setp(value, { text = text })
  if not (unit and geom) then return end
  local w = Host.textWidth(text, geom.font, geom.lineH)
  local x = geom.x0 + w + geom.gap
  if x > geom.maxX then x = geom.maxX end
  setp(unit, { x = x, w = geom.width + (geom.maxX - x) })
end

local function buildHero()
  local F = Theme.font
  local roomy = L.class == "roomy"

  -- Three footnotes, not four. The hero column gave width to the right column,
  -- and a fourth slot no longer holds "MIN 47.3V" without touching its
  -- neighbour. Cell count was the one worth losing: it moves up beside the
  -- pack voltage, where it reads as the "12S" qualifying it.
  local packSlot
  V.batValue, V.batFoot, packSlot, V.batUnit, V.batUnitGeom =
    buildHeroTile(L.battery, "BATTERY", "%", F.mid, 3, L.c.batValShare)
  -- Total pack voltage shares the header line. It is the one reading with
  -- nowhere else to go once the percentage takes the whole value band, and it
  -- reads cleanly against the panel title.
  V.batPack = label(packSlot.x, packSlot.y, packSlot.w, "",
                    F.small, Theme.ink, ALIGN_RIGHT)

  -- "RPM" is a word, not a glyph, so it takes the smaller unit font. At F.mid
  -- it would be wider than the space a four-digit headspeed leaves.
  local _hsSlot
  V.hsValue, V.hsFoot, _hsSlot, V.hsUnit, V.hsUnitGeom =
    buildHeroTile(L.headspeed, "HEADSPEED", "RPM", F.small, roomy and 3 or 2,
                  L.c.hsValShare)
end

local function buildRightColumn()
  local F = Theme.font
  local roomy = L.class == "roomy"

  local g = L.gov
  V.govPanel = panel(g, Theme.govIdleBg, Theme.govIdleBr)
  -- The wider right column pays for a bigger governor and bigger tile values.
  -- Both were sized for a 274px column that had to hold three 88px tiles.
  local govFont = roomy and F.large or F.mid
  local gy = g.y + (roomy and 5 or 4)
  label(g.x, gy, g.w, "GOVERNOR", F.tiny, Theme.dim, ALIGN_CENTER)
  V.govState = label(g.x, gy + fh(F.tiny) + (roomy and 4 or 2), g.w, "",
                     govFont, Theme.dim, ALIGN_CENTER)

  -- Labels carry their units on both screens; at 54px wide there is no room
  -- for a separate unit glyph, and consistency beats a spare pixel. Abbreviated
  -- on the wide screen too: "CURRENT A" is 88px of tile and TINSIZE is 17px
  -- tall, so it ran off its own panel.
  local defs = { "CURR A", "ESC °C", "BEC V" }
  -- Centred, like the governor above them: three narrow tiles of one reading
  -- each read as a row, and a left-aligned value drifts away from its own
  -- label as the reading changes width.
  local tileFont = roomy and F.large or F.mid
  V.tiles = {}
  for i = 1, 3 do
    local t = L.tiles[i]
    local ty = t.y + (roomy and 6 or 4)
    panel(t, Theme.panel, Theme.panelBr)
    label(t.x + 6, ty, t.w - 12, defs[i], F.tiny, Theme.dim, ALIGN_CENTER)
    V.tiles[i] = {
      value = label(t.x + 6, ty + fh(F.tiny) + (roomy and 4 or 2), t.w - 12, "",
                    tileFont, Theme.ink, ALIGN_CENTER),
      foot  = label(t.x + 6, t.y + t.h - fh(F.tiny) - (roomy and 6 or 4),
                    t.w - 12, "", F.tiny, Theme.peak, ALIGN_CENTER),
    }
  end

  -- No frame: a panel border fought the mark's own outline.
  Dashboard.placeLogo(L.logo, roomy and "logo_panel.png" or "logo_small.png")
end

local function buildStrip()
  local F = Theme.font
  local roomy = L.class == "roomy"
  lvgl.hline({ x=0, y=L.stripRule, w=L.w, h=1, color=Theme.rule })
  local y = L.stripRule + (roomy and 10 or 7)
  V.flights = label(L.c.pad, y, 300, "", F.tiny, Theme.dim)
  if roomy then
    V.tagline = label(0, y, L.w, "NO HYPE / JUST VOLTAGE / REAL POWER",
                      F.tiny, Theme.dim, ALIGN_CENTER)
  end
  -- Wide enough for a full "NO IMAGE: <path>", which is the longest thing that
  -- can land here and the whole reason the notice names a path at all.
  V.link = label(L.c.pad, y, L.w - L.c.pad * 2, "", F.tiny, Theme.steel,
                 ALIGN_RIGHT)
end

-- Smallest zone the tight layout can be drawn into honestly. Below this the
-- panels would overlap, so say so rather than render a mess.
Dashboard.MIN_W, Dashboard.MIN_H = 440, 250

-- Last resort. A dozen objects, no bitmap, no panels: if even this cannot be
-- built the widget is not the problem. Reached only after a real build has
-- already failed.
function Dashboard.buildMinimal(w, h)
  if type(lvgl) ~= "table" then return end
  lvgl.clear()
  V, SHADOW = {}, {}
  Host.collect()
  mode = "minimal"
  local F = Theme.font
  Theme.useMetricsFor(Host.lcdW or w)
  rectangle(0, 0, w, h, Theme.bg, true, 0, 0)
  V.modelName = label(8, 6, w - 16, "", F.tiny, Theme.ink)
  local y = 6 + fh(F.tiny) + 4
  label(0, y, w, "ZELIONDASH - SAFE MODE", F.tiny, Theme.warn, ALIGN_CENTER)
  -- Three readings on a clear screen. Spaced by their own height, so the last
  -- one still lands above the bottom edge on a 320px-tall radio.
  local rest = h - (y + fh(F.tiny) + 4)
  local step = math.floor(rest / 3)
  local top  = y + fh(F.tiny) + 4
  V.minBat  = label(8, top + math.floor((step - fh(F.large)) / 2), w - 16, "",
                    F.large, Theme.ink, ALIGN_CENTER)
  V.minHs   = label(8, top + step + math.floor((step - fh(F.large)) / 2), w - 16, "",
                    F.large, Theme.ink, ALIGN_CENTER)
  V.minCell = label(8, top + step * 2 + math.floor((step - fh(F.mid)) / 2), w - 16, "",
                    F.mid, Theme.dim, ALIGN_CENTER)
  Dashboard.update()
end

local function buildTooSmall(w, h)
  local F = Theme.font
  rectangle(0, 0, w, h, Theme.bg, true, 0, 0)
  local y = math.floor(h / 2) - fh(F.mid)
  label(0, y, w, "ZELIONDASH", F.mid, Theme.steel, ALIGN_CENTER)
  y = y + fh(F.mid) + 2
  label(0, y, w, "NEEDS A FULL SCREEN WIDGET SLOT",
        F.tiny, Theme.warn, ALIGN_CENTER)
  label(0, y + fh(F.tiny) + 2, w,
        string.format("this zone is %dx%d, minimum is %dx%d",
                      w, h, Dashboard.MIN_W, Dashboard.MIN_H),
        F.tiny, Theme.dim, ALIGN_CENTER)
end

-- w,h are the WIDGET ZONE, not the screen. LVGL objects are children of the
-- widget, so anything drawn past the zone edge is silently clipped - laying
-- out against LCD_W/LCD_H produces a dashboard with its right half missing.
function Dashboard.build(w, h)
  if type(lvgl) ~= "table" then return end
  Theme.build()
  lvgl.clear()
  V, SHADOW = {}, {}
  -- lvgl.clear() drops the previous screen's objects and bitmaps; reclaim them
  -- before allocating the next screen rather than letting both coexist.
  Host.collect()
  Dashboard.logoMissing = false
  w = w or Host.lcdW
  h = h or Host.lcdH
  -- Which font set this firmware was compiled with follows the radio's screen,
  -- not the widget's zone, so ask the host rather than the zone we were given.
  Theme.useMetricsFor(Host.lcdW or w)

  if w < Dashboard.MIN_W or h < Dashboard.MIN_H then
    mode = "toosmall"
    buildTooSmall(w, h)
    return
  end

  mode = "dash"
  L = Layout.build(w, h)
  rectangle(0, 0, L.w, L.h, Theme.bg, true, 0, 0)
  buildTopBar()
  buildLeftColumn()
  buildHero()
  buildRightColumn()
  buildStrip()
  Dashboard.update()
end

Dashboard.mode = function() return mode end

--------------------------------------------------------------------------
-- Sensor map
--------------------------------------------------------------------------
--
-- Retained LVGL, like everything else on screen, because a widget that
-- declares useLvgl gets NO immediate-mode drawing at all. LuaWidget's
-- checkEvents calls refresh(nullptr) on the LVGL path, which leaves
-- luaLcdBuffer null, and every lcd.draw* guards on
-- `if (!luaLcdAllowed || !luaLcdBuffer) return 0`. This screen was written
-- with lcd.drawText and so drew precisely nothing - the widget looked like it
-- had vanished until the option was switched back off.
--
-- Rows are built once for however many fit on screen and then only have their
-- text rewritten, so scrolling costs nothing and the object count is bounded
-- by the screen rather than by the number of roles.

local SM = { rows = {}, visible = 0 }

Dashboard.sensorRows = 0

function Dashboard.buildSensorMap(w, h)
  if type(lvgl) ~= "table" then return end
  Theme.build()
  lvgl.clear()
  V, SHADOW = {}, {}
  Host.collect()
  w = w or Host.lcdW
  h = h or Host.lcdH
  Theme.useMetricsFor(Host.lcdW or w)
  mode = "sensors"

  local F = Theme.font
  local compact = w < 700
  local pad = compact and 6 or 12
  rectangle(0, 0, w, h, Theme.bg, true, 0, 0)

  local headerH = fh(F.small) + (compact and 4 or 8)
  label(pad, compact and 2 or 4, math.floor(w * 0.6),
        compact and "SENSOR MAP" or "ZELIONDASH - SENSOR MAP",
        F.small, Theme.steel)
  V.smCount = label(w - pad - 160, compact and 4 or 7, 160, "",
                    F.tiny, Theme.dim, ALIGN_RIGHT)
  lvgl.hline({ x = 0, y = headerH, w = w, h = 1, color = Theme.rule })

  local rowH    = fh(F.tiny) + (compact and 3 or 4)
  local footerH = fh(F.tiny) + (compact and 4 or 8)
  local listTop = headerH + (compact and 3 or 6)
  SM.visible = math.max(1, math.floor((h - listTop - footerH) / rowH))

  -- Three columns, not four. "how" is folded into the sensor cell as a
  -- suffix: it is worth knowing whether a binding came from the config file,
  -- a name match or a unit guess, but not worth a column of its own once
  -- every row costs a retained object.
  local colRole   = pad
  local colSensor = math.floor(w * 0.36)
  local sensorW   = math.floor(w * 0.34)
  local colValue  = w - pad

  SM.rows = {}
  for i = 1, SM.visible do
    local y = listTop + (i - 1) * rowH
    SM.rows[i] = {
      role   = label(colRole, y, colSensor - colRole - 4, "", F.tiny, Theme.ink),
      sensor = label(colSensor, y, sensorW, "", F.tiny, Theme.dim),
      value  = label(colValue - 120, y, 120, "", F.tiny, Theme.dim, ALIGN_RIGHT),
    }
  end

  local fy = h - footerH + (compact and 1 or 3)
  V.smNote = label(pad, fy, w - pad * 2 - 90, "", F.tiny, Theme.dim)
  V.smPage = label(w - pad - 90, fy, 90, "", F.tiny, Theme.dim, ALIGN_RIGHT)
end

-- rows: { { label, sensor, how, value, status, important }, ... }
function Dashboard.updateSensorMap(rows, scroll, bound, note, noteBad)
  if mode ~= "sensors" then return end
  rows = rows or {}
  Dashboard.sensorRows = #rows
  local n = SM.visible
  if scroll > #rows - n then scroll = math.max(0, #rows - n) end
  if scroll < 0 then scroll = 0 end

  setp(V.smCount, { text = string.format("%d bound", bound or 0) })
  setp(V.smNote, { text = note or "", color = noteBad and Theme.crit or Theme.dim })
  setp(V.smPage, { text = (#rows > n)
                          and string.format("%d-%d/%d", scroll + 1,
                                            math.min(#rows, scroll + n), #rows)
                          or "" })

  for i = 1, n do
    local r = SM.rows[i]
    local row = rows[i + scroll]
    if not row then
      setp(r.role, { text = "" }); setp(r.sensor, { text = "" })
      setp(r.value, { text = "" })
    else
      local color = Theme.dim
      if row.status == "ok" or row.status == "derived" then color = Theme.lime
      elseif row.status == "insane" then color = Theme.crit
      elseif row.important then color = Theme.warn end

      local sensor = row.sensor or "-"
      if row.how then sensor = sensor .. " (" .. row.how .. ")" end
      setp(r.role,   { text = row.label or "",
                       color = row.important and Theme.steel or Theme.ink })
      setp(r.sensor, { text = sensor, color = color })
      setp(r.value,  { text = row.value or "", color = color })
    end
  end
  return scroll
end

function Dashboard.sensorMapVisible() return SM.visible end

--------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------

local function flightsText()
  if RF2.statsStatus == "ok" and RF2.totalFlights then
    local t = string.format("%d FLIGHTS", RF2.totalFlights)
    if RF2.totalFlightSeconds then
      local s = RF2.totalFlightSeconds
      t = t .. string.format(" - %d:%02d:%02d", math.floor(s / 3600),
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
                     color = fh <= 0 and Theme.track
                             or (pct > 0.5 and Theme.lime
                                 or (pct > 0.25 and Theme.warn or Theme.crit)) })
    setp(V.txText, { text = string.format("%.1f", tx) })
  else
    setHidden(V.txFill, true, Theme.track)
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
                      color = fh <= 0 and Theme.track or Theme.batteryColor(pct) })
  else
    setHidden(V.barFill, true, Theme.track)
  end
end

local function updateHero()
  local roomy = L.class == "roomy"

  local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
  setHeroValue(V.batValue, V.batUnitGeom, V.batUnit,
               pct and string.format("%d", math.floor(pct + 0.5)) or "--")
  setp(V.batValue, { color = pct and Theme.ink or Theme.dim })
  -- Cell count qualifies the pack voltage, so it rides with it: "12S 47.3 V".
  local pack, packOk = State.get("packVoltage")
  local packText = packOk and string.format("%.1f V", pack) or "--"
  if packOk and State.valid("cellCount") then
    packText = string.format("%dS %s", math.floor(State.num("cellCount")), packText)
  end
  setp(V.batPack, { text = packText,
                    color = packOk and Theme.ink or Theme.dim })

  local foots = {
    fmtExtreme("MIN", State.min("packVoltage"), "%.1fV"),
    fmtExtreme("SAG", cellSag(), "%.2f"),
    State.valid("capacity") and string.format("%d mAh", math.floor(State.num("capacity")))
      or "-- mAh",
  }
  for i = 1, #V.batFoot do
    setp(V.batFoot[i], { text = foots[i] or "" })
  end

  local hs, hsOk = State.get("headspeed")
  setHeroValue(V.hsValue, V.hsUnitGeom, V.hsUnit,
               hsOk and string.format("%d", math.floor(hs + 0.5)) or "--")
  setp(V.hsValue, { color = hsOk and Theme.ink or Theme.dim })
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
    -- It needs the whole strip, so the slogan stands down - an error outranks
    -- a tagline, and the two were printing through each other.
    setp(V.tagline, { text = "" })
    setp(V.link, { text = "NO IMAGE: " .. tostring(Dashboard.missingPath),
                   color = Theme.warn })
    return
  end
  -- A sounding alert takes the strip. The radio may be muted, the pilot may
  -- have missed it, and "which one was that" is a question worth answering
  -- without having to remember what the buzz pattern meant.
  local ZD_Alerts = ZD.Alerts
  local active = ZD_Alerts and ZD_Alerts.active() or {}
  if #active > 0 then
    setp(V.tagline, { text = "" })
    setp(V.link, { text = "ALERT: " .. string.upper(table.concat(active, " + ")),
                   color = Theme.crit })
    return
  end
  setp(V.tagline, { text = "NO HYPE / JUST VOLTAGE / REAL POWER" })
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
  if type(lvgl) ~= "table" or mode == "toosmall" then return end
  if mode == "minimal" then
    setp(V.modelName, { text = RF2.craftName or Host.modelName() })
    local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
    setp(V.minBat, { text = pct and (string.format("%d", math.floor(pct + 0.5)) .. "%") or "--",
                     color = pct and Theme.batteryColor(pct) or Theme.dim })
    local hs, hsOk = State.get("headspeed")
    setp(V.minHs, { text = hsOk and (string.format("%d", math.floor(hs + 0.5)) .. " RPM") or "-- RPM",
                    color = hsOk and Theme.ink or Theme.dim })
    local cv, cvOk = State.get("cellVoltage")
    setp(V.minCell, { text = cvOk and (string.format("%.2f", cv) .. " V/cell") or "-- V/cell",
                      color = cvOk and Theme.cellColor(cv) or Theme.dim })
    return
  end
  if not V.flights then return end
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
local Alerts  = ZD.Alerts
local FlightLog = ZD.FlightLog
local Profiles = ZD.Profiles
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
local VALUE  = flag("VALUE", 0)
local SMLSIZE, BOLD, RIGHT = flag("SMLSIZE", 0), flag("BOLD", 0), flag("RIGHT", 0)

Widget.showSensors = false
local built = nil          -- "dash" | "sensors" | nil
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
-- Diagnostics screen
--------------------------------------------------------------------------
--
-- Builds the row data only. The drawing lives in Dashboard, because a widget
-- that declares useLvgl gets no immediate-mode drawing at all: EdgeTX calls
-- refresh(nullptr) on that path and every lcd.draw* bails on the null buffer.
-- This screen used lcd.drawText and therefore rendered nothing whatsoever.

local HOW = { override = "cfg", name = "auto", unit = "guess" }

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
-- inferring any of it from this side of the link.
local ASSET_FILES = { "logo_panel.png", "logo_small.png" }

-- Returns a one-line summary and the full detail block separately. The detail
-- used to lead the list, from when a missing PNG was the open problem - but it
-- is seven rows, and it pushed the roles a pilot actually consults down past
-- the fold. The summary carries the only bit worth seeing every time: whether
-- the artwork loaded. Detail goes to the bottom, where it is still one scroll
-- away when something breaks.
local function assetRows()
  local dir = Host.widgetDir()
  local detail, bad = {}, 0

  local listing = Host.listDir(dir)
  if listing == nil then
    detail[#detail + 1] = { label = "  dir()", sensor = "unavailable",
                            status = "unbound" }
  elseif #listing == 0 then
    detail[#detail + 1] = { label = "  dir()", sensor = "EMPTY", status = "insane" }
    bad = bad + 1
  else
    for _, name in ipairs(listing) do
      detail[#detail + 1] = { label = "  " .. name, sensor = "", status = "ok" }
    end
  end

  for _, f in ipairs(ASSET_FILES) do
    local p = Host.probeImage(dir .. f)
    local ok = p.bmp and p.w and p.w > 0
    if not ok then bad = bad + 1 end
    local s = string.format("%s%s%s", p.fstat and "F" or "-",
                            p.io and "I" or "-", p.bmp and "B" or "-")
    if p.size then s = s .. " " .. tostring(p.size) .. "b" end
    if p.w then s = s .. " w" .. tostring(p.w) end
    detail[#detail + 1] = { label = "  " .. f, sensor = s,
                            status = ok and "ok" or "insane" }
  end

  local summary = {
    label = "-- ARTWORK --",
    sensor = dir,
    value = (bad == 0) and string.format("%d ok", #ASSET_FILES)
            or string.format("%d MISSING", bad),
    status = (bad == 0) and "ok" or "insane",
    important = true,
  }
  detail[#detail + 1] = { label = "-- ARTWORK DETAIL --",
                          sensor = Host.widgetDirSource, status = "ok",
                          important = true }
  -- The header belongs above the block it heads.
  table.insert(detail, 1, table.remove(detail))
  return summary, detail
end

local function sensorMapRows()
  local sensorRows, bound = Sensors.report(), 0
  for _, r in ipairs(sensorRows) do if r.sensor then bound = bound + 1 end end

  -- Roles first: they are what the screen is consulted for. Two status lines
  -- above them, the artwork detail below.
  --
  -- The flight log is silent by design - it writes once, at landing, and says
  -- nothing. That leaves no way to tell it is working without pulling the card,
  -- so it reports itself here: how it decided the heli was flying, how long,
  -- and whether the last write landed.
  local summary, detail = assetRows()
  local where, verdict = FlightLog.status()
  local profile = Profiles.current()
  local rfWhere, rfVerdict, rfStatus = RF2.status()
  local statsText, statsVerdict, statsStatus = RF2.statsText()
  local rows = { summary, {
    -- Optional, and silent either way. Without this the only outward sign of
    -- RF Tool was the footer quietly showing the FC's craft name, which cannot
    -- distinguish "not installed" from "installed but never registered" from
    -- "registered but the FC never handshaked".
    label = "-- RF TOOL --",
    sensor = rfWhere,
    value = rfVerdict,
    status = rfStatus,
    important = true,
  }, {
    label = "  fc stats",
    sensor = statsText,
    value = statsVerdict,
    status = statsStatus,
  }, {
    -- What the widget thinks it is bolted to. It decides which readings are
    -- plausible, what headspeed counts as flying, and when the ESC is too hot,
    -- so a wrong profile is quiet and consequential.
    label = "-- PROFILE --",
    sensor = Profiles.label() .. (profile and ("  " .. profile.note) or ""),
    value = Profiles.how(),
    status = profile and "ok" or "unbound",
    important = true,
  }, {
    label = "-- FLIGHT LOG --",
    sensor = where,
    value = verdict,
    status = FlightLog.lastError and "insane"
             or (FlightLog.written > 0 and "ok" or "unbound"),
    important = true,
  }, {
    -- The line that says whether a flight is even being detected. Without a
    -- flight there is nothing to write, and "no file appeared" reads exactly
    -- the same either way.
    label = "  flight",
    sensor = State.armed and ("FLYING, from " .. State.armSource)
             or ("idle, arm source " .. State.armSource),
    value = string.format("%d:%02d  min %ds",
                          math.floor(State.flightSeconds / 60),
                          math.floor(State.flightSeconds % 60),
                          FlightLog.MIN_SECONDS),
    status = State.armed and "ok" or "unbound",
  } }
  for _, r in ipairs(sensorRows) do
    rows[#rows + 1] = {
      label = r.label, sensor = r.off and "off" or r.sensor, status = r.status,
      important = r.important, how = r.how and HOW[r.how] or nil,
      value = formatValue(r),
    }
  end
  for _, r in ipairs(detail) do rows[#rows + 1] = r end

  local note, bad = nil, false
  if #Config.problems > 0 then
    note, bad = "cfg: " .. Config.problems[1], true
  else
    note = (State.armed and "ARMED" or "disarmed") .. "  " ..
           (RF2.craftName or Host.modelName())
    if #Sensors.unresolved > 0 then
      note = note .. "  (" .. #Sensors.unresolved .. " unresolved)"
    end
  end
  return rows, bound, note, bad
end

-- Exposed for tools/dump_screen.lua, so the documented sensor map is the one
-- the radio builds rather than a hand-written sample that drifts.
Widget.sensorMapRows = sensorMapRows

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local function serviceOpts(widget)
  local opts = widget.options or {}
  State.armSwitch = opts.ArmSwitch
  State.armInvert = opts.ArmInvert == 1
  local hold = false
  if opts.HoldSwitch and opts.HoldSwitch ~= 0 then
    local v = Host.read(opts.HoldSwitch)
    if v ~= nil then
      hold = v > 0
      if opts.HoldInvert == 1 then hold = not hold end
    end
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
      -- It used to clear the screen and draw nothing, which is exactly what a
      -- widget looks like when it has disappeared.
      pcall(Dashboard.buildSensorMap, zoneW, zoneH)
      built = "sensors"
      scroll = 0
    end
    return
  end

  -- One screen. It is built once and then only ever updated, so there is no
  -- longer a standby-to-dashboard transition to get wrong.
  if built ~= "dash" then
    -- A widget must never be able to fault the transmitter. Lua raises on
    -- memory exhaustion, and an unhandled raise from a widget is what puts
    -- EdgeTX into emergency mode - so every build is caught, and each failure
    -- steps down to something cheaper rather than propagating.
    local ok = pcall(Dashboard.build, zoneW, zoneH)
    if not ok and not Dashboard.noLogo then
      Dashboard.noLogo = true          -- retry without any bitmap
      Widget.degraded = "no-logo"
      ok = pcall(Dashboard.build, zoneW, zoneH)
    end
    if not ok and not Dashboard.noRound then
      Dashboard.noRound = true         -- then without rounded corners
      Widget.degraded = "no-round"
      ok = pcall(Dashboard.build, zoneW, zoneH)
    end
    if not ok then
      Widget.degraded = "safe-mode"
      pcall(Dashboard.buildMinimal, zoneW, zoneH)
    end
    built = "dash"
  end
end

function Widget.create(zone, options)
  -- create() and update() were the two entry points still unguarded. Anything
  -- that raises here happens before a screen exists at all.
  pcall(Theme.build)
  pcall(Config.load)
  pcall(State.reloadModel)
  built = nil
  zoneW, zoneH = nil, nil
  return { zone = zone, options = options }
end

function Widget.update(widget, options)
  widget.options = options
  Widget.showSensors = (options and options.SensorMap == 1) or false
  Alerts.enabled = not (options and options.Alerts == 0)
  FlightLog.enabled = not (options and options.FlightLog == 0)
  Profiles.set(options and options.Profile)

  -- Edge-triggered: switching Test Alert on sounds one alert, switching it off
  -- and on again sounds another. update() is only called when the options
  -- change, but guarding on the transition costs nothing and means a firmware
  -- that calls it more often cannot turn this into a siren.
  local test = (options and options.TestAlert == 1) or false
  if test and not Widget.lastTestOption then pcall(Alerts.selfTest) end
  Widget.lastTestOption = test
  -- There used to be a Level option here, stepping the renderer down one
  -- construct at a time. It existed only to bisect the emergency-mode reboot
  -- on hardware; the cause turned out to be XXLSIZE + BOLD selecting a font
  -- index EdgeTX has no font for (see Theme.font), so the option has done its
  -- job. The automatic ladder in ensureScreen() stays - it is the part that
  -- protects a radio nobody is standing next to.
  Dashboard.noRound = false
  Dashboard.noLogo  = false
  Widget.degraded = nil
  pcall(Config.load)
  pcall(Sensors.reload, Host.modelName())
  pcall(Alerts.reset)
  built = nil
  ensureScreen(widget)
end

Widget.degraded = nil

function Widget.refresh(widget, event, touchState)
  local now = Host.now()
  pcall(State.service, now, serviceOpts(widget))
  pcall(Alerts.service, now)
  pcall(FlightLog.service)
  ensureScreen(widget)

  if Widget.showSensors then
    if event == flag("EVT_VIRTUAL_NEXT", -1) then scroll = scroll + 1
    elseif event == flag("EVT_VIRTUAL_PREV", -2) then scroll = scroll - 1 end
    local ok, rows, bound, note, bad = pcall(sensorMapRows)
    if ok then
      local clamped = Dashboard.updateSensorMap(rows, scroll, bound, note, bad)
      if clamped then scroll = clamped end
    end
  else
    pcall(Dashboard.update)
  end
end

-- Telemetry is serviced here too, so session peaks and flight time are
-- recorded while another screen is in front - and, more to the point, so the
-- alerts still sound. A low cell does not stop mattering because the pilot
-- happened to be looking at the model setup page.
function Widget.background(widget)
  local now = Host.now()
  pcall(State.service, now, serviceOpts(widget))
  pcall(Alerts.service, now)
  -- Logged from here too: a flight can end while the pilot is on another
  -- screen, and an unwritten flight is lost the moment the model changes.
  pcall(FlightLog.service)
end

Widget.options = {
  -- 0 auto, 1 Rotorflight (6S and up), 2 OMPHOBBY OSF03 (200-size).
  --
  -- A number rather than a name because EdgeTX widget options have no list
  -- type - BOOL, VALUE, SOURCE, SWITCH, COLOR, STRING and TIMER, and nothing
  -- that presents a set of named choices. So the resolved name is printed on
  -- the sensor map instead, where it can also say whether it was set or
  -- detected. A profile moves alert thresholds silently, and an unlabelled
  -- "2" in a settings page is not good enough on its own.
  { "Profile",    VALUE,  0, 0, 2 },
  -- EdgeTX reports a two-position switch as -1024 and +1024, and nothing in
  -- the value says which end the pilot calls "armed" - that depends on how the
  -- switch is mounted. Getting it backwards is silent and consequential in
  -- both cases: a reversed arm switch runs the flight timer on the bench and
  -- logs a flight when you switch off, and a reversed hold switch silences the
  -- alerts for the whole flight while looking exactly like a working one.
  { "ArmSwitch",  SOURCE, 0 },
  { "ArmInvert",  BOOL,   0 },
  { "HoldSwitch", SOURCE, 0 },
  { "HoldInvert", BOOL,   0 },
  { "SensorMap",  BOOL,   0 },
  { "Alerts",     BOOL,   1 },
  { "TestAlert",  BOOL,   0 },
  { "FlightLog",  BOOL,   1 },
}

Widget.OPTION_LABELS = {
  ArmSwitch  = "Arm Switch (fallback)",
  HoldSwitch = "Hold Switch",
  SensorMap  = "Show Sensor Map",
  Alerts     = "Audio + Vibe Alerts",
  TestAlert  = "Test Alert (toggle)",
  FlightLog  = "Log Flights",
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
