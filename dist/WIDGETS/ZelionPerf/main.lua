-- ZelionPerf - EdgeTX UI frame rate analyser
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
local getUsageFn       = g("getUsage")
local getFreeMemFn     = g("getAvailableMemory")

Host.hasSourceValue = type(getSourceValueFn) == "function"
Host.hasDir         = type(dirTbl) == "function"
Host.hasUsage       = type(getUsageFn) == "function"
Host.hasFreeMemory  = type(getFreeMemFn) == "function"
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
          -- A logged sensor is written to storage as well as computed, which
          -- is an SD write on the main task rather than arithmetic on it.
          -- Absent on firmware that does not report it, which reads as false.
          logs  = s.logs == true or s.logs == 1,
        }
      end
    end
  end
  return out
end


--------------------------------------------------------------------------
-- Runtime cost probes
--------------------------------------------------------------------------
--
-- The two numbers EdgeTX will tell a script about its own execution. Both are
-- read on the hot path, so both are plain pcall-guarded reads with no
-- allocation: a probe that costs a frame to take is measuring itself.

-- getUsage() is "percent of the Lua instruction budget already used in this
-- execution cycle" (radio/src/lua/api_general.cpp). Its SCOPE is not the same
-- on every build: a colour radio running an LVGL script gets that script's own
-- refresh figure, while the other paths get a whole-radio number derived from
-- the Lua task duration. Nothing in the API says which you were handed, so
-- this is reported as a load percentage and never as "your widget costs N%".
-- The wall clock below is what carries any claim about the frame rate.
function Host.usage()
  if not getUsageFn then return nil end
  local ok, v = pcall(getUsageFn)
  if not ok then return nil end
  return tonumber(v)
end

-- Free bytes remaining in the Lua heap. The absolute figure matters less than
-- its slope: a heap draining a few hundred bytes per frame is a script
-- allocating per frame, and the garbage collection that follows is felt as a
-- stutter rather than as a lower average frame rate.
function Host.freeMemory()
  if not getFreeMemFn then return nil end
  local ok, v = pcall(getFreeMemFn)
  if not ok then return nil end
  return tonumber(v)
end


-- Size of one file in bytes, or nil when it is not there. The cheapest
-- "does this exist" the firmware offers, and the inventory needs the number
-- anyway.
function Host.probeSize(path)
  if type(fstatFn) ~= "function" then return nil end
  local ok, info = pcall(fstatFn, path)
  if not ok or type(info) ~= "table" then return nil end
  return tonumber(info.size)
end

-- Names AND sizes for a folder, for the script inventory. listDir() answers
-- "what is in here", which is all the dashboard's asset probe needs; the
-- analyser also needs how big each one is, since a script's size is the only
-- proxy it has for what that script costs before it runs.
--
-- Capped at 64 entries. A folder larger than that is its own finding, and
-- walking it with fstat on a radio is slow enough to be felt.
function Host.listFiles(path, limit)
  limit = tonumber(limit) or 64
  local names = Host.listDir(path, limit)
  if names == nil then return nil end
  local out = {}
  for i = 1, math.min(#names, limit) do
    local name = names[i]
    local size = nil
    if fstatFn then
      local ok, info = pcall(fstatFn, path .. name)
      if ok and type(info) == "table" then size = tonumber(info.size) end
    end
    out[#out + 1] = { name = name, size = size }
  end
  return out
end

--------------------------------------------------------------------------
-- Model inventory
--------------------------------------------------------------------------
--
-- What this model asks the radio to compute on every mixer pass. None of it is
-- Lua, but all of it shares the main task with Lua, so it sets the budget the
-- scripts are competing for. Read once on a rescan, never per frame - the
-- getters below walk firmware structures and are far too expensive to call
-- from a refresh.

-- EdgeTX's own table limits. Enumeration stops at the first empty slot only
-- where the firmware packs them; logical switches and special functions are
-- sparse, so those are walked in full.
local MAX_LOGICAL_SWITCHES = 64
local MAX_SPECIAL_FUNCTIONS = 64

local function count(fn)
  if type(fn) ~= "function" then return nil end
  local ok, n = pcall(fn)
  if not ok then return nil end
  return tonumber(n)
end

-- Returns a table of counts, each entry nil where the firmware would not say.
-- nil and 0 are kept apart deliberately: "this radio has no getMixesCount"
-- must not be presented to the pilot as "you have no mixes".
function Host.modelInventory()
  local out = { mixes = nil, inputs = nil, logicalSwitches = nil,
                specialFunctions = nil, sensors = nil, loggedSensors = nil }
  if type(modelTbl) ~= "table" then return out end

  out.mixes  = count(modelTbl.getMixesCount)
  out.inputs = count(modelTbl.getInputsCount)

  if type(modelTbl.getLogicalSwitch) == "function" then
    local n = 0
    for i = 0, MAX_LOGICAL_SWITCHES - 1 do
      local ok, ls = pcall(modelTbl.getLogicalSwitch, i)
      -- func 0 is LS_FUNC_NONE: the slot exists but computes nothing.
      if ok and type(ls) == "table" and (tonumber(ls.func) or 0) ~= 0 then
        n = n + 1
      end
    end
    out.logicalSwitches = n
  end

  if type(modelTbl.getCustomFunction) == "function" then
    local n = 0
    for i = 0, MAX_SPECIAL_FUNCTIONS - 1 do
      local ok, cf = pcall(modelTbl.getCustomFunction, i)
      -- An unused slot comes back as nil on current firmware and as a table
      -- with no switch on older ones; both mean "not configured".
      if ok and type(cf) == "table" and cf.switch ~= nil then
        n = n + 1
      end
    end
    out.specialFunctions = n
  end

  local sensors = Host.listSensors()
  out.sensors = #sensors
  local logged = 0
  for _, s in ipairs(sensors) do
    if s.logs then logged = logged + 1 end
  end
  out.loggedSensors = logged
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
function Host.listDir(path, limit)
  if type(dirTbl) ~= "function" then return nil end
  limit = tonumber(limit) or 32
  local out = {}
  local ok = pcall(function()
    for name in dirTbl(path) do
      out[#out + 1] = tostring(name)
      if #out >= limit then break end
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

-- Writes a live timer value. EdgeTX's setTimer accepts mode, start, value,
-- countdownBeep, minuteBeep, persistent, name, showElapsed, switch,
-- countdownStart and extraHaptic; `value` sets the running value rather than
-- the start, which is what makes a timer drivable from a script.
--
-- Only the fields the caller passes are touched. Everything else on that timer
-- belongs to the pilot's settings page, and a widget that overwrote a name or
-- a countdown preference would be a widget nobody keeps installed.
function Host.setTimer(index, fields)
  if type(modelTbl) ~= "table" or type(modelTbl.setTimer) ~= "function" then
    return false
  end
  if type(fields) ~= "table" then return false end
  return (pcall(modelTbl.setTimer, index or 0, fields))
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

-- ======== src/perfstats.lua ========
do
  local factory = (function()
-- ZelionPerf layer 1: frame-timing statistics.
--
-- Pure arithmetic over frame periods. No host calls, no EdgeTX types, no
-- state outside the tables it is handed - which is what makes the awkward
-- parts (quantisation, garbage-collection sawtooth, is-this-difference-real)
-- testable on a desktop instead of guessed at on a radio.
--
-- THE CLOCK IS THE WHOLE PROBLEM. EdgeTX gives Lua one time source,
-- getTime(), counting 10ms ticks. A colour radio draws its UI at roughly
-- 20-40 frames per second, so a single frame period is 3 or 4 ticks and any
-- one measurement of it is wrong by up to a third. Everything below exists to
-- get trustworthy numbers out of a clock that coarse:
--
--   * The frame rate is taken from the SPAN of a window, not from the mean of
--     its samples. Consecutive periods telescope - (t1-t0) + (t2-t1) + ... is
--     just (tn-t0) - so a window of 60 frames carries one rounding error in
--     total rather than 60 of them. Over two seconds that is well under 1%.
--   * Percentiles are reported as they are measured, in whole ticks, and the
--     screen labels them in 10ms steps. A p95 quoted as "37.4ms" from this
--     clock would be a fiction.
--   * Stalls are counted with an absolute floor far above the noise. A frame
--     period of 3 ticks against 4 is quantisation; 25 against 4 is the radio
--     stopping, and that is the thing a pilot actually sees.

return function(ZD)

local Stats = {}
ZD.PerfStats = Stats

-- Frame periods are clamped into the histogram at 5 seconds. Anything longer
-- is the widget having been off-screen, not a slow frame, and is discarded by
-- the sampler before it reaches here - the clamp is only a backstop against
-- one absurd sample stretching the histogram walk.
local MAX_TICK = 500

-- A frame this long is a visible hitch rather than a slow average, whatever
-- the radio's baseline rate. 20 ticks is 200ms: about the point at which a
-- moving needle is seen to jump rather than to travel.
Stats.STALL_FLOOR_TICKS = 20

-- ...and anything this many times the typical frame counts too, so a stutter
-- on a radio that is already running at 12fps is still called one.
Stats.STALL_RATIO = 3

--------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------
--
-- A window accumulates the frame periods seen between two points in time. It
-- holds a histogram rather than the samples themselves: frame periods are
-- small integers, so counting them costs a fixed handful of table slots
-- however long the window runs, and a profiler that grows its own working set
-- every frame is a profiler measuring its own garbage collection.

function Stats.newWindow()
  return {
    frames = 0,       -- periods recorded (one fewer than frames observed)
    span   = 0,       -- ticks from the first period to the last
    hist   = {},      -- [tickCount] = howManyFrames
    worst  = 0,       -- longest single period, in ticks
    over   = 0,       -- periods longer than MAX_TICK
  }
end

function Stats.add(w, dtTicks)
  local dt = math.floor(tonumber(dtTicks) or 0)
  if dt < 0 then return end
  w.frames = w.frames + 1
  w.span   = w.span + dt
  if dt > w.worst then w.worst = dt end
  if dt > MAX_TICK then
    w.over = w.over + 1
    dt = MAX_TICK
  end
  w.hist[dt] = (w.hist[dt] or 0) + 1
end

function Stats.isEmpty(w)
  return not w or w.frames == 0
end

-- Frames per second across the window.
--
-- Returns nil rather than a number when there is not enough to say. A window
-- of one frame has a span of one period and would report a confident figure
-- from a single 10ms-quantised sample; a window whose span is zero would
-- report infinity. Both are worse than "not yet".
Stats.MIN_FRAMES_FOR_FPS = 8

function Stats.fps(w)
  if not w or w.frames < Stats.MIN_FRAMES_FOR_FPS or w.span <= 0 then
    return nil
  end
  return w.frames * 100 / w.span
end

-- The period at the given percentile, in ticks. Walks the histogram in
-- ascending tick order, which is a sort the keys already give for free.
--
-- Bounded by the worst frame seen rather than by MAX_TICK. On a healthy radio
-- the worst frame is about 5 ticks, so this is a five-step loop instead of a
-- five-hundred-step one - and it runs three times per frame, inside the tool
-- whose entire job is not to cost frames.
function Stats.percentile(w, p)
  if Stats.isEmpty(w) then return nil end
  local target = w.frames * (tonumber(p) or 50) / 100
  local seen = 0
  for tick = 0, math.min(w.worst, MAX_TICK) do
    local n = w.hist[tick]
    if n then
      seen = seen + n
      if seen >= target then return tick end
    end
  end
  return w.worst
end

-- How many frames took long enough to be seen as a stutter.
--
-- The threshold is the larger of the absolute floor and a multiple of the
-- typical frame, so it means the same thing on a radio running at 40fps as on
-- one running at 12. Returned alongside the threshold used, because "4 stalls"
-- means nothing without it.
function Stats.stalls(w)
  if Stats.isEmpty(w) then return 0, Stats.STALL_FLOOR_TICKS end
  local typical = Stats.percentile(w, 50) or 0
  local threshold = math.max(Stats.STALL_FLOOR_TICKS,
                             typical * Stats.STALL_RATIO)
  local n = 0
  for tick, count in pairs(w.hist) do
    if tick >= threshold then n = n + count end
  end
  n = n + w.over
  return n, threshold
end

function Stats.summary(w)
  local stalls, threshold = Stats.stalls(w)
  return {
    frames    = w and w.frames or 0,
    fps       = Stats.fps(w),
    p50       = Stats.percentile(w, 50),
    p95       = Stats.percentile(w, 95),
    worst     = w and w.worst or 0,
    stalls    = stalls,
    stallAt   = threshold,
  }
end

--------------------------------------------------------------------------
-- Series
--------------------------------------------------------------------------
--
-- A short ring of recent sub-window frame rates. Its purpose is not to draw a
-- graph: it is to answer "how much does this number move when nothing has
-- changed", which is the only thing that makes a before-and-after comparison
-- worth printing.

function Stats.newSeries(cap)
  return { cap = tonumber(cap) or 8, n = 0, next = 1 }
end

function Stats.push(s, v)
  v = tonumber(v)
  if v == nil then return end
  s[s.next] = v
  s.next = s.next % s.cap + 1
  if s.n < s.cap then s.n = s.n + 1 end
end

function Stats.mean(s)
  if not s or s.n == 0 then return nil end
  local sum = 0
  for i = 1, s.n do sum = sum + s[i] end
  return sum / s.n
end

-- Full range rather than a standard deviation. With at most eight samples a
-- deviation is barely better than the range and much harder to explain, and
-- the number is going on screen next to the words "run to run".
function Stats.spread(s)
  if not s or s.n < 2 then return nil end
  local lo, hi = s[1], s[1]
  for i = 2, s.n do
    if s[i] < lo then lo = s[i] end
    if s[i] > hi then hi = s[i] end
  end
  return hi - lo
end

--------------------------------------------------------------------------
-- Heap tracking
--------------------------------------------------------------------------
--
-- Free Lua heap does not fall smoothly, it saws: down as scripts allocate, up
-- in a step every time the collector runs. So the useful figure is not the
-- slope of the line - which averages the two and reports something close to
-- zero for a script allocating hard - but the sum of the DOWNWARD moves. That
-- is bytes actually allocated, and dividing it by frames gives the number
-- that predicts how often collection will interrupt a frame.

-- A rise this small is measurement noise or another script freeing an object,
-- not a collection. Counting those would report a collector running every
-- frame on a radio that is perfectly healthy.
local COLLECTION_RISE = 512

function Stats.newHeap()
  return { samples = 0, allocated = 0, collections = 0,
           minFree = nil, maxFree = nil, last = nil }
end

function Stats.heapSample(h, free)
  free = tonumber(free)
  if free == nil then return end
  h.samples = h.samples + 1
  if h.minFree == nil or free < h.minFree then h.minFree = free end
  if h.maxFree == nil or free > h.maxFree then h.maxFree = free end
  if h.last ~= nil then
    local d = free - h.last
    if d < 0 then
      h.allocated = h.allocated - d
    elseif d >= COLLECTION_RISE then
      h.collections = h.collections + 1
    end
  end
  h.last = free
end

-- Bytes allocated per frame, or nil before there is a second sample to
-- difference against.
--
-- A slight UNDERESTIMATE, unavoidably: in the frame where the collector runs,
-- what it handed back and what was allocated arrive as one net rise, and the
-- allocation inside it cannot be separated out. So the figure misses roughly
-- one frame's worth per collection. It is reported as a floor on what is
-- being allocated rather than corrected by a guess.
function Stats.allocPerFrame(h)
  if not h or h.samples < 2 then return nil end
  return h.allocated / (h.samples - 1)
end

--------------------------------------------------------------------------
-- Before and after
--------------------------------------------------------------------------

-- Below this, two frame rates are the same number as far as anyone can tell.
-- It exists because spread can legitimately come back as zero - eight
-- sub-windows that all landed on the same quantised figure - and a zero noise
-- floor would declare a 0.05fps difference an improvement.
Stats.FPS_NOISE_FLOOR = 0.5

-- Compare two snapshots taken by the sampler.
--
-- Returns a table, never nil, so the screen always has something to print:
--   delta    change in frame rate, positive being faster, or nil if unknowable
--   noise    the band inside which the two are indistinguishable
--   verdict  "better" | "worse" | "same" | "unknown"
--
-- The verdict is deliberately conservative. A pilot who removes a script,
-- sees "3 fps faster" and it was noise will not trust the next reading, so a
-- difference smaller than the run-to-run spread is reported as no change
-- rather than as a small one.
function Stats.compare(before, after)
  local out = { delta = nil, noise = nil, verdict = "unknown" }
  if type(before) ~= "table" or type(after) ~= "table" then return out end
  local a, b = tonumber(before.fps), tonumber(after.fps)
  if a == nil or b == nil then return out end

  local noise = math.max(tonumber(before.spread) or 0,
                         tonumber(after.spread) or 0,
                         Stats.FPS_NOISE_FLOOR)
  local delta = b - a
  out.delta, out.noise = delta, noise
  if math.abs(delta) <= noise then
    out.verdict = "same"
  elseif delta > 0 then
    out.verdict = "better"
  else
    out.verdict = "worse"
  end
  return out
end

--------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------
--
-- Here rather than in the renderer, because how precisely a number may be
-- printed is a property of how it was measured. A frame period read from a
-- 10ms clock is shown in 10ms steps; printing it to a tenth of a millisecond
-- would claim an accuracy the clock cannot give and would make the analyser
-- look more certain than it is.

function Stats.ticksToMs(ticks)
  if ticks == nil then return nil end
  return math.floor(ticks) * 10
end

function Stats.fmtMs(ticks)
  if ticks == nil then return "--" end
  return string.format("%dms", Stats.ticksToMs(ticks))
end

function Stats.fmtFps(fps)
  if fps == nil then return "--" end
  if fps >= 100 then return string.format("%d", math.floor(fps + 0.5)) end
  return string.format("%.1f", fps)
end

function Stats.fmtBytes(n)
  if n == nil then return "--" end
  if math.abs(n) >= 10240 then
    return string.format("%.0fk", n / 1024)
  end
  if math.abs(n) >= 1024 then
    return string.format("%.1fk", n / 1024)
  end
  return string.format("%d", math.floor(n + 0.5))
end

return Stats

end

  end)()
  factory(ZD)
end

-- ======== src/perfprobe.lua ========
do
  local factory = (function()
-- ZelionPerf layer 2: the sampler.
--
-- Called once per frame, from the widget's refresh. Turns the host's two cost
-- probes and one coarse clock into the running picture the screen draws and
-- the advice engine reasons about.
--
-- Two rules shape all of it:
--
--   1. IT MUST NOT PERTURB WHAT IT MEASURES. Everything here is a fixed
--      number of arithmetic operations on tables allocated once. No string
--      building, no closures, no table constructors on the frame path - a
--      profiler that allocates per frame drives the collector it is trying to
--      report on, and would show the pilot its own cost as their problem.
--   2. A GAP IS NOT A SLOW FRAME. EdgeTX stops calling refresh() the moment
--      another screen comes forward, so the period across that gap is
--      however long the pilot spent in the menus. Counting it would put a
--      40-second "frame" in the histogram and drag the average frame rate to
--      near zero. Gaps are detected and used to restart the clock instead.

return function(ZD)

local Host  = ZD.Host
local Stats = ZD.PerfStats

local Probe = {}
ZD.PerfProbe = Probe

-- A period longer than this is the widget having been away, not the radio
-- having been slow. One second is far above any frame a working radio
-- produces and far below any time a pilot spends on another screen.
Probe.GAP_TICKS = 100

-- How much wall clock goes into one sub-window. Each closes into a single
-- frame-rate figure, and the spread of those figures is what tells a real
-- before-and-after difference from noise. Two seconds is long enough that
-- quantisation has averaged out and short enough that eight of them fit in
-- the time a pilot will hold still for.
Probe.SUBWINDOW_TICKS = 200

-- Sub-windows kept. Eight covers about sixteen seconds of history, which is
-- the horizon over which "nothing changed" is a believable claim.
Probe.SERIES_CAP = 8

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

Probe.baseline = nil        -- snapshot captured by the pilot, or nil
Probe.baselineLabel = nil

local total, sub, series, heap
local lastFrame, subStart
local gaps, usageSum, usageSamples, usageMax
local selfAlloc, selfSamples, frameFree

function Probe.reset()
  total  = Stats.newWindow()
  sub    = Stats.newWindow()
  series = Stats.newSeries(Probe.SERIES_CAP)
  heap   = Stats.newHeap()
  lastFrame, subStart = nil, nil
  gaps = 0
  usageSum, usageSamples, usageMax = 0, 0, nil
  selfAlloc, selfSamples, frameFree = 0, 0, nil
end

Probe.reset()

-- Clears the measurement without touching the captured baseline. This is what
-- the mark key calls: the point of marking is to start measuring the new
-- configuration from scratch, not to average it with the old one.
function Probe.restart()
  local keep, keepLabel = Probe.baseline, Probe.baselineLabel
  Probe.reset()
  Probe.baseline, Probe.baselineLabel = keep, keepLabel
end

Probe.gaps = function() return gaps end

--------------------------------------------------------------------------
-- The frame path
--------------------------------------------------------------------------

-- Call at the top of refresh(), before doing any other work.
--
-- `now` is Host.now(). Passed in rather than read here so the caller's single
-- clock read serves both the sampler and the rest of the frame, and so tests
-- can drive time directly.
function Probe.frameStart(now)
  now = tonumber(now) or 0

  if lastFrame ~= nil then
    local dt = now - lastFrame
    -- A clock that went backwards is getTime() having wrapped. Treat it as a
    -- gap: one absurd sample discarded is better than a negative period, and
    -- better than the alternative of reasoning about the wrap point.
    if dt < 0 or dt > Probe.GAP_TICKS then
      gaps = gaps + 1
      subStart = now
      -- The sub-window in flight spans the gap, so it is void rather than
      -- short. Reuse the table; a fresh one here would allocate per gap.
      sub.frames, sub.span, sub.worst, sub.over = 0, 0, 0, 0
      for k in pairs(sub.hist) do sub.hist[k] = nil end
    else
      Stats.add(total, dt)
      Stats.add(sub, dt)
    end
  end
  lastFrame = now

  if subStart == nil then subStart = now end
  if now - subStart >= Probe.SUBWINDOW_TICKS then
    local f = Stats.fps(sub)
    if f then Stats.push(series, f) end
    sub.frames, sub.span, sub.worst, sub.over = 0, 0, 0, 0
    for k in pairs(sub.hist) do sub.hist[k] = nil end
    subStart = now
  end

  local u = Host.usage()
  if u then
    usageSum = usageSum + u
    usageSamples = usageSamples + 1
    if usageMax == nil or u > usageMax then usageMax = u end
  end

  local free = Host.freeMemory()
  Stats.heapSample(heap, free)
  frameFree = free
end

-- Call at the bottom of refresh(), after the screen has been updated.
--
-- The difference across the frame is what THIS widget allocated, which is the
-- one cost figure the analyser can attribute to a single script with
-- certainty - it is the only script it can put brackets around. It is
-- reported on screen so the pilot can see the measurement is not the thing
-- being measured; a reading above a few dozen bytes here is a bug in this
-- widget, not a finding about theirs.
function Probe.frameEnd()
  if frameFree == nil then return end
  local after = Host.freeMemory()
  if after == nil then return end
  local used = frameFree - after
  -- Negative means the collector ran mid-frame and handed back more than we
  -- took. Nothing to attribute, so it is skipped rather than counted as a
  -- gain that would drag the average below zero.
  if used >= 0 then
    selfAlloc = selfAlloc + used
    selfSamples = selfSamples + 1
  end
  frameFree = nil
end

--------------------------------------------------------------------------
-- Reading it back
--------------------------------------------------------------------------

-- The current picture, as a fresh table. Built on demand for the screen and
-- the advice engine - both of which run once per frame, so this is one
-- allocation per frame in the one place that cannot avoid it.
function Probe.snapshot(label)
  local s = Stats.summary(total)

  -- Prefer the mean of the closed sub-windows: it is the same measurement
  -- taken several times, which is what gives a spread to compare against.
  -- Before the first one closes, fall back to the running window so the
  -- screen shows a number within a second of being opened rather than "--".
  local fps = Stats.mean(series) or s.fps
  s.fps = fps
  s.spread = Stats.spread(series)
  s.subWindows = series.n
  s.gaps = gaps

  s.usage    = usageSamples > 0 and (usageSum / usageSamples) or nil
  s.usageMax = usageMax
  s.freeMemory = heap.last
  s.minFree    = heap.minFree
  s.allocPerFrame = Stats.allocPerFrame(heap)
  s.collections   = heap.collections
  s.selfAlloc = selfSamples > 0 and (selfAlloc / selfSamples) or nil
  s.label = label
  return s
end

-- Capture the current picture as the thing to compare against, and start
-- measuring again. Returns the snapshot stored.
function Probe.mark(label)
  local snap = Probe.snapshot(label)
  -- Refuse to mark a baseline there is not enough evidence for. A comparison
  -- against two seconds of noise is worse than no comparison: it produces a
  -- confident-looking delta that means nothing.
  if snap.fps == nil then return nil end
  Probe.baseline = snap
  Probe.baselineLabel = label
  Probe.restart()
  return snap
end

function Probe.clearBaseline()
  Probe.baseline = nil
  Probe.baselineLabel = nil
end

-- nil until a baseline exists; otherwise the verdict from Stats.compare.
function Probe.comparison(current)
  if not Probe.baseline then return nil end
  return Stats.compare(Probe.baseline, current or Probe.snapshot())
end

return Probe

end

  end)()
  factory(ZD)
end

-- ======== src/perfscan.lua ========
do
  local factory = (function()
-- ZelionPerf layer 3: the inventory.
--
-- What is installed on this radio that can take frame time, and when each of
-- it runs.
--
-- START HERE, BECAUSE THE OBVIOUS THING IS NOT POSSIBLE. EdgeTX's Lua API has
-- no call that enumerates running scripts, and no call that reports another
-- script's cost. getUsage() describes the caller's own execution cycle and
-- there is nothing else. A widget therefore cannot do what a desktop profiler
-- does - attribute time to each process - and any widget claiming to is
-- making the numbers up.
--
-- What it can do is the next best thing, which turns out to be most of the
-- value: list the scripts that exist, say when each one runs, and let the
-- measured frame rate say what they cost in total. The classification is the
-- part that matters, because it is not intuitive and it decides where to look
-- first:
--
--   /SCRIPTS/MIXES/       runs every mixer cycle, on every screen, from the
--                         moment the model is selected. Cannot be escaped by
--                         navigating away. Costs frames everywhere.
--   /SCRIPTS/FUNCTIONS/   runs while its special function's switch is active.
--   /WIDGETS/             runs when it is on the screen in front of you, via
--                         refresh(); and off-screen via background(), which
--                         most widgets use and which still costs.
--   /SCRIPTS/TELEMETRY/   runs only while its own telemetry page is showing.
--   /SCRIPTS/TOOLS/       runs only while open from the Tools menu.
--
-- So a heavy telemetry script is nearly free until you look at it, and a
-- trivial mix script is never free at all. A pilot hunting a slow UI reaches
-- for the thing they can see, which is usually the wrong end of that list.

return function(ZD)

local Host = ZD.Host

local Scan = {}
ZD.PerfScan = Scan

-- Ordered by how much of the time the code runs, worst first. `weight` ranks
-- findings later; it is a statement about frequency, not about quality.
Scan.CLASSES = {
  { dir = "/SCRIPTS/MIXES/",     kind = "mix",    when = "every cycle",  weight = 4 },
  { dir = "/SCRIPTS/FUNCTIONS/", kind = "func",   when = "switch on",    weight = 3 },
  { dir = "/WIDGETS/",           kind = "widget", when = "on screen",    weight = 2,
    folders = true },
  { dir = "/SCRIPTS/TELEMETRY/", kind = "telem",  when = "its page",     weight = 1 },
  { dir = "/SCRIPTS/TOOLS/",     kind = "tool",   when = "Tools menu",   weight = 0 },
}

-- Folder listing is capped well below any sane install. A radio with more
-- than this in one folder has a finding of its own, and walking it with fstat
-- is slow enough on real storage to be felt as a pause.
local MAX_PER_DIR = 24

local function isScript(name)
  return string.match(name, "%.lua$") ~= nil
      or string.match(name, "%.luac$") ~= nil
end

local function isCompiled(name)
  return string.match(name, "%.luac$") ~= nil
end

-- Strips the extension so a script shipping as both main.lua and main.luac is
-- not counted twice - EdgeTX runs one of them, not both.
local function stem(name)
  return (string.gsub(name, "%.luac?$", ""))
end

--------------------------------------------------------------------------

Scan.result = nil

local function emptyResult()
  return {
    ok       = false,
    reason   = nil,
    scripts  = {},
    counts   = { mix = 0, func = 0, widget = 0, telem = 0, tool = 0 },
    model    = {},
    unreadable = {},
  }
end

-- Scans one folder of plain scripts.
local function scanScripts(class, out)
  local files = Host.listFiles(class.dir, MAX_PER_DIR)
  if files == nil then
    -- Not there, or there and unlistable - dir() reports both the same way.
    -- Recorded rather than treated as an error: most radios have never had a
    -- /SCRIPTS/MIXES/ folder, and that is a clean bill of health, not a
    -- failure. The screen prints these as "not present".
    out.unreadable[#out.unreadable + 1] = class.dir
    return
  end
  local seen = {}
  for _, f in ipairs(files) do
    if isScript(f.name) then
      local key = stem(f.name)
      if not seen[key] then
        seen[key] = true
        out.scripts[#out.scripts + 1] = {
          name = key, dir = class.dir, kind = class.kind,
          when = class.when, weight = class.weight,
          size = f.size, compiled = isCompiled(f.name),
        }
        out.counts[class.kind] = out.counts[class.kind] + 1
      end
    end
  end
end

-- /WIDGETS/ holds a folder per widget, each with a main.lua inside. dir()
-- lists the folders; the size has to be fetched from the file within, and a
-- folder with no main.lua is not a widget at all.
local function scanWidgets(class, out)
  local names = Host.listDir(class.dir, MAX_PER_DIR)
  if names == nil then
    out.unreadable[#out.unreadable + 1] = class.dir
    return
  end
  for _, name in ipairs(names) do
    -- dir() lists "." and ".." on some builds and not others.
    if name ~= "." and name ~= ".." and not isScript(name) then
      local base = class.dir .. name .. "/main."
      local size, compiled = nil, false
      local f = Host.probeSize(base .. "luac")
      if f then
        size, compiled = f, true
      else
        size = Host.probeSize(base .. "lua")
      end
      if size ~= nil then
        out.scripts[#out.scripts + 1] = {
          name = name, dir = class.dir, kind = class.kind,
          when = class.when, weight = class.weight,
          size = size, compiled = compiled,
        }
        out.counts[class.kind] = out.counts[class.kind] + 1
      end
    end
  end
end

-- Heaviest-running first, then largest first inside a class. That ordering is
-- the advice: the top of this list is where to look.
local function sortScripts(scripts)
  table.sort(scripts, function(a, b)
    if a.weight ~= b.weight then return a.weight > b.weight end
    local sa, sb = a.size or 0, b.size or 0
    if sa ~= sb then return sa > sb end
    return a.name < b.name
  end)
end

-- Walks the storage and the model. EXPENSIVE - hundreds of firmware calls,
-- several of them touching storage. Called on demand and on first build,
-- never from a frame.
function Scan.run()
  local out = emptyResult()

  if not Host.hasDir then
    out.reason = "this firmware has no dir(), so installed scripts cannot be listed"
    Scan.result = out
    return out
  end

  for _, class in ipairs(Scan.CLASSES) do
    if class.folders then scanWidgets(class, out) else scanScripts(class, out) end
  end
  sortScripts(out.scripts)

  out.model = Host.modelInventory() or {}
  out.ok = true
  Scan.result = out
  return out
end

function Scan.get()
  return Scan.result or Scan.run()
end

-- Scripts that run without the pilot choosing to look at them. This is the
-- number the advice engine cares about most.
function Scan.alwaysRunning(result)
  result = result or Scan.get()
  local n = 0
  for _, s in ipairs(result.scripts) do
    if s.kind == "mix" then n = n + 1 end
  end
  return n
end

function Scan.uncompiled(result)
  result = result or Scan.get()
  local n = 0
  for _, s in ipairs(result.scripts) do
    if not s.compiled then n = n + 1 end
  end
  return n
end

return Scan

end

  end)()
  factory(ZD)
end

-- ======== src/perfadvice.lua ========
do
  local factory = (function()
-- ZelionPerf layer 4: findings.
--
-- Turns the measurement and the inventory into a ranked list of things worth
-- doing, in the order worth doing them.
--
-- Three rules, learned from the alert engine one layer over in ZelionDash,
-- where the same failure mode applies: the only way a diagnostic tool fails
-- in practice is by becoming noise.
--
--   * EVERY FINDING NAMES AN ACTION. "Lua heap low" is a reading, not a
--     finding. "Lua heap down to 8k; the collector is running every third
--     frame - remove a widget from this screen" is a finding. Anything that
--     cannot be turned into a sentence with a verb in it belongs on the
--     readings panel instead, and several things that started here ended up
--     there.
--   * NOTHING IS REPORTED THAT WAS NOT MEASURED OR READ. There is no table of
--     scripts known to be slow, and no guess at what a script costs from its
--     size - size ranks the list, it never becomes a claim. Where the API
--     cannot answer, the finding says so rather than estimating.
--   * A CLEAN RADIO GETS A CLEAN ANSWER. If the frame rate is fine, it says
--     so and stops. A tool that always finds five things to fix teaches the
--     pilot that its findings are decoration.

return function(ZD)

local Stats = ZD.PerfStats
local Scan  = ZD.PerfScan

local Advice = {}
ZD.PerfAdvice = Advice

-- Severity doubles as sort key and as colour on screen.
Advice.HIGH, Advice.MED, Advice.LOW, Advice.INFO = 3, 2, 1, 0

--------------------------------------------------------------------------
-- Thresholds
--------------------------------------------------------------------------
--
-- These are judgements about what a pilot notices, not firmware limits, so
-- they are gathered here to be argued with in one place rather than buried in
-- the rules below.

-- Under 15fps the UI reads as laggy on a colour radio: a menu cursor lags the
-- wheel visibly. Between 15 and 25 it is usable but not smooth. Above 25
-- nobody has ever complained.
Advice.FPS_BAD, Advice.FPS_FAIR = 15, 25

-- Stutters per minute. One is a coincidence; six is something running on a
-- timer, and a timer is findable.
Advice.STALLS_PER_MIN = 6

-- EdgeTX gives Lua a fixed heap. Under 12k free, allocation starts failing
-- scripts outright, and well before that the collector runs so often that its
-- pauses are the frame rate. 25k is where to start worrying.
Advice.HEAP_LOW, Advice.HEAP_CRITICAL = 25000, 12000

-- Bytes per frame across all scripts. A retained-mode widget should sit near
-- zero; a few hundred is a script rebuilding tables every frame.
Advice.ALLOC_HIGH = 400

-- getUsage() is a percentage of the instruction budget. At 90 the script is
-- being preempted mid-refresh, which is exactly when a frame goes missing.
Advice.USAGE_HIGH = 90

--------------------------------------------------------------------------

-- `tone` is presentation, not severity: "7 fps faster than the baseline" is
-- the lowest-priority thing on the list and the best news on it, and a screen
-- that greys it out alongside the other INFO rows buries the one result the
-- pilot is standing there waiting for.
local function finding(severity, title, detail, tone)
  return { severity = severity, title = title, detail = detail, tone = tone }
end

-- Frame rate, stutters, and the difference between them.
--
-- They are separate findings because they have different causes and different
-- fixes: a low average is too much work every frame, while stutters on a good
-- average are something periodic - an SD write, a collection, a script that
-- wakes on a timer.
local function frameRate(out, snap)
  local fps = snap.fps
  if fps == nil then return end

  if fps < Advice.FPS_BAD then
    out[#out + 1] = finding(Advice.HIGH,
      string.format("UI is running at %s fps", Stats.fmtFps(fps)),
      "Slow enough to feel in the menus. Work through the script list below "
      .. "from the top: those entries run most of the time.")
  elseif fps < Advice.FPS_FAIR then
    out[#out + 1] = finding(Advice.MED,
      string.format("UI is running at %s fps", Stats.fmtFps(fps)),
      "Usable but not smooth. Mark a baseline, remove one script from the "
      .. "list below, and see what it was worth.")
  end

  if snap.stalls and snap.stalls > 0 and snap.frames > 0 and fps > 0 then
    local minutes = (snap.frames / fps) / 60
    local perMin = minutes > 0 and (snap.stalls / minutes) or 0
    if perMin >= Advice.STALLS_PER_MIN then
      out[#out + 1] = finding(Advice.MED,
        string.format("%d stutters, worst %s", snap.stalls,
                      Stats.fmtMs(snap.worst)),
        "Frames this long are periodic, not steady load. Logged telemetry "
        .. "sensors writing to storage and garbage collection are the two "
        .. "usual causes; both are below.")
    end
  end
end

local function memory(out, snap)
  local free = snap.freeMemory
  if free ~= nil then
    if free < Advice.HEAP_CRITICAL then
      out[#out + 1] = finding(Advice.HIGH,
        string.format("Lua heap down to %s free", Stats.fmtBytes(free)),
        "This close to full, scripts start failing to load at all and the "
        .. "collector runs constantly. Take a widget off this screen.")
    elseif free < Advice.HEAP_LOW then
      out[#out + 1] = finding(Advice.MED,
        string.format("Lua heap at %s free", Stats.fmtBytes(free)),
        "Enough to run, not enough to run without frequent collection. "
        .. "Fewer widgets on one screen is the cheapest fix.")
    end
  end

  local alloc = snap.allocPerFrame
  if alloc ~= nil and alloc >= Advice.ALLOC_HIGH then
    out[#out + 1] = finding(Advice.MED,
      string.format("%s allocated per frame", Stats.fmtBytes(alloc)),
      "Something on this screen rebuilds its objects every frame instead of "
      .. "updating them. That is what the collector is being fed."
      .. (snap.selfAlloc and string.format(" This widget accounts for %s of it.",
                                           Stats.fmtBytes(snap.selfAlloc)) or ""))
  end
end

local function luaLoad(out, snap)
  local u = snap.usageMax
  if u ~= nil and u >= Advice.USAGE_HIGH then
    out[#out + 1] = finding(Advice.MED,
      string.format("Lua instruction budget peaked at %d%%", math.floor(u)),
      "At this point EdgeTX preempts a script part-way through and finishes "
      .. "it on the next cycle, which is a frame you do not get.")
  end
end

-- The inventory findings. These are the ones a measurement alone cannot
-- reach, because they are about code that is running whether or not the
-- analyser is on screen to see it.
local function inventory(out, scan)
  if not scan or not scan.ok then
    if scan and scan.reason then
      out[#out + 1] = finding(Advice.INFO, "Script list unavailable", scan.reason)
    end
    return
  end

  local mixes = scan.counts.mix or 0
  if mixes > 0 then
    out[#out + 1] = finding(Advice.HIGH,
      string.format("%d mix script%s running continuously",
                    mixes, mixes == 1 and "" or "s"),
      "Scripts in /SCRIPTS/MIXES/ run every mixer cycle on every screen, and "
      .. "keep running when you navigate away. They are the only kind you "
      .. "cannot get away from, so they are the first thing to test by "
      .. "removing.")
  end

  local widgets = scan.counts.widget or 0
  if widgets >= 6 then
    out[#out + 1] = finding(Advice.LOW,
      string.format("%d widgets installed", widgets),
      "Only the ones placed on the screen in front of you cost frames - but "
      .. "most also run background() when they are not showing. An installed "
      .. "widget you no longer use is free to delete.")
  end

  local raw = Scan.uncompiled(scan)
  if raw >= 3 then
    out[#out + 1] = finding(Advice.LOW,
      string.format("%d scripts are .lua rather than .luac", raw),
      "EdgeTX compiles each one on first run after a change, which is a pause "
      .. "and a peak in heap use. Shipping .luac avoids both. This costs "
      .. "startup, not steady frame rate.")
  end

  local m = scan.model or {}
  if (m.sensors or 0) >= 30 then
    out[#out + 1] = finding(Advice.MED,
      string.format("%d telemetry sensors on this model", m.sensors),
      "Every sensor is decoded on the main task as frames arrive. Deleting "
      .. "the ones you do not display or log is the one telemetry change that "
      .. "reliably buys frames back.")
  end
  if (m.loggedSensors or 0) > 0 and (m.sensors or 0) > 0 then
    out[#out + 1] = finding(Advice.LOW,
      string.format("%d of %d sensors are logged to storage",
                    m.loggedSensors, m.sensors),
      "Logging writes on the main task. If the stutter count above is high "
      .. "and steady, turn logging off for a flight and compare.")
  end
end

-- The before-and-after result, when there is one. Reported at the top,
-- because a pilot who has just changed something is looking for exactly this
-- and nothing else.
local function comparison(out, cmp, label)
  if not cmp or cmp.verdict == "unknown" then return end
  local was = label and (" (" .. label .. ")") or ""
  if cmp.verdict == "same" then
    out[#out + 1] = finding(Advice.INFO,
      "No measurable change since the baseline" .. was,
      string.format("Difference is %s fps against %s fps of run-to-run "
                    .. "spread, so it is not distinguishable from noise.",
                    Stats.fmtFps(math.abs(cmp.delta)), Stats.fmtFps(cmp.noise)))
  elseif cmp.verdict == "better" then
    out[#out + 1] = finding(Advice.INFO,
      string.format("%s fps faster than the baseline%s",
                    Stats.fmtFps(cmp.delta), was),
      string.format("Bigger than the %s fps run-to-run spread. Keep the "
                    .. "change.", Stats.fmtFps(cmp.noise)), "good")
  else
    out[#out + 1] = finding(Advice.MED,
      string.format("%s fps slower than the baseline%s",
                    Stats.fmtFps(math.abs(cmp.delta)), was),
      string.format("Bigger than the %s fps run-to-run spread. Whatever "
                    .. "changed since the mark cost that.", Stats.fmtFps(cmp.noise)))
  end
end

--------------------------------------------------------------------------

-- Build the ranked list.
--
-- `snap` comes from PerfProbe.snapshot(), `scan` from PerfScan.get(), `cmp`
-- from PerfProbe.comparison() or nil.
function Advice.build(snap, scan, cmp, baselineLabel)
  local out = {}
  snap = snap or {}

  comparison(out, cmp, baselineLabel)
  frameRate(out, snap)
  memory(out, snap)
  luaLoad(out, snap)
  inventory(out, scan)

  -- Stable sort by severity. table.sort is not stable in Lua, and the order
  -- within a severity is meaningful - the comparison result was put first
  -- deliberately - so the original position is carried as the tiebreak.
  for i, f in ipairs(out) do f.order = i end
  table.sort(out, function(a, b)
    if a.severity ~= b.severity then return a.severity > b.severity end
    return a.order < b.order
  end)

  if #out == 0 then
    local fps = snap.fps
    out[1] = finding(Advice.INFO, "Nothing worth changing",
      fps and string.format(
        "%s fps with no stutters and heap to spare. Measured over %d frames.",
        Stats.fmtFps(fps), snap.frames or 0)
      or "Still measuring. Leave this screen in front for a few seconds.",
      fps and "good" or nil)
  end
  return out
end

return Advice

end

  end)()
  factory(ZD)
end

-- ======== src/perfscreen.lua ========
do
  local factory = (function()
-- ZelionPerf layer 5: the screen.
--
-- Retained-mode LVGL, exactly as the dashboard does it and for the same
-- reason: a widget that declares useLvgl gets no immediate-mode drawing at
-- all - EdgeTX calls refresh(nullptr) on that path and every lcd.draw* bails
-- on the null buffer - so anything drawn with lcd.drawText appears nowhere.
--
-- The retained model matters twice as much here. Objects are created once and
-- only the properties whose values changed reach LVGL, so a frame of this
-- screen is mostly comparisons. It is not allocation-free - LVGL takes its
-- properties as a table, and the readings have to be formatted into strings -
-- but it is bounded and it does not grow with what is on screen. A profiler
-- built the naive way, tearing down and rebuilding its objects every frame,
-- would cost more frame time than most of what it is looking for and would
-- report its own garbage as the pilot's problem. Which is why the widget
-- measures its own per-frame heap use and puts it on the screen rather than
-- asking to be taken on trust.

return function(ZD)

local Host   = ZD.Host
local Theme  = ZD.Theme
local Stats  = ZD.PerfStats
local Advice = ZD.PerfAdvice

local Screen = {}
ZD.PerfScreen = Screen

local function flag(name, fallback)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
end
local ALIGN_RIGHT  = flag("RIGHT", 0)
local ALIGN_CENTER = flag("CENTER", 0)

local V, SHADOW = {}, {}
local L = nil
local mode = nil

local function fh(f) return Theme.fontHeight(f) end

-- Remembers what was last written to each object so update() can skip the
-- ones that did not change. LVGL property writes are the expensive part of a
-- frame here; the comparison that avoids them is not.
local function remember(obj, props)
  if obj then SHADOW[obj] = props end
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

-- Every font goes through Theme.safeFont. EdgeTX indexes its font array with
-- no bounds check, so an index it has no font for is a native fault and an
-- EMERGENCY MODE reboot rather than something pcall can catch.
local function label(x, y, w, text, font, color, align)
  local p = { x = x, y = y, w = w or 0, h = 0, text = text or "",
              font = Theme.safeFont(font or 0),
              color = color or Theme.ink, align = align or 0 }
  return remember(lvgl.label(p), p)
end

local function rectangle(x, y, w, h, color)
  local p = { x = x, y = y, w = w, h = h, color = color,
              filled = 1, rounded = 0, thickness = 0 }
  return remember(lvgl.rectangle(p), p)
end

--------------------------------------------------------------------------
-- Word wrapping
--------------------------------------------------------------------------
--
-- Character-budget wrapping, not pixel-measured. lcd.sizeText exists, but
-- measuring every line of advice on every frame costs more than the whole
-- rest of the screen, and the text changes as findings come and go so it
-- cannot be measured once at build time either.
--
-- The budget comes from the font's line height: across all three EdgeTX font
-- sets the average glyph of the small faces is close to half their height in
-- a proportional face. Being a few characters out puts a short word on the
-- next line, which is a cosmetic result; being exact would cost frames, which
-- is the thing this screen exists to protect.
function Screen.wrap(text, cols, maxLines)
  local out = {}
  -- nil in, nothing out. tostring(nil) would put the word "nil" on screen as
  -- though it were advice.
  if text == nil then return out end
  text = tostring(text)
  cols = math.max(8, math.floor(tonumber(cols) or 40))
  maxLines = math.max(1, math.floor(tonumber(maxLines) or 2))
  local line = ""
  for word in string.gmatch(text, "%S+") do
    local candidate = (line == "") and word or (line .. " " .. word)
    if #candidate <= cols then
      line = candidate
    else
      if line ~= "" then out[#out + 1] = line end
      if #out >= maxLines then break end
      -- A single word longer than the line gets cut rather than overflowing;
      -- a path or a sensor name can legitimately be that long.
      line = (#word > cols) and string.sub(word, 1, cols) or word
    end
  end
  if line ~= "" and #out < maxLines then out[#out + 1] = line end

  -- Say that something was dropped rather than ending mid-sentence as though
  -- that were the whole of the advice.
  if #out == maxLines then
    local consumed = 0
    for _, l in ipairs(out) do consumed = consumed + #l + 1 end
    if consumed < #text then
      local last = out[maxLines]
      if #last > cols - 3 then last = string.sub(last, 1, cols - 3) end
      out[maxLines] = last .. "..."
    end
  end
  return out
end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

-- Below this the readings would overlap. Said plainly rather than rendered as
-- a mess, the same way the dashboard handles a zone too small for it.
Screen.MIN_W, Screen.MIN_H = 300, 180

local LIST_LINES = 3          -- title plus two lines of detail, per entry

local function buildTooSmall(w, h)
  local F = Theme.font
  rectangle(0, 0, w, h, Theme.bg)
  local y = math.floor(h / 2) - fh(F.small)
  label(0, y, w, "ZELIONPERF", F.small, Theme.steel, ALIGN_CENTER)
  label(0, y + fh(F.small) + 2, w, "NEEDS A FULL SCREEN WIDGET SLOT",
        F.tiny, Theme.warn, ALIGN_CENTER)
end

-- w,h are the WIDGET ZONE, not the screen. LVGL objects are children of the
-- widget, so anything laid out against LCD_W/LCD_H is clipped at the zone
-- edge and the right-hand column simply goes missing.
function Screen.build(w, h)
  if type(lvgl) ~= "table" then return end
  Theme.build()
  lvgl.clear()
  V, SHADOW = {}, {}
  Host.collect()
  w = w or Host.lcdW
  h = h or Host.lcdH
  -- Which font set the firmware was compiled with follows the RADIO's screen,
  -- not the widget's zone.
  Theme.useMetricsFor(Host.lcdW or w)

  if w < Screen.MIN_W or h < Screen.MIN_H then
    mode = "toosmall"
    buildTooSmall(w, h)
    return
  end
  mode = "perf"

  local F = Theme.font
  local roomy = w >= 700
  local pad = roomy and 12 or 6
  L = { w = w, h = h, roomy = roomy, pad = pad }

  rectangle(0, 0, w, h, Theme.bg)

  -- Header ---------------------------------------------------------------
  local headerH = fh(F.small) + (roomy and 8 or 4)
  label(pad, roomy and 4 or 2, math.floor(w * 0.5), "ZELIONPERF",
        F.small, Theme.steel)
  V.scanNote = label(w - pad - math.floor(w * 0.45), roomy and 6 or 3,
                     math.floor(w * 0.45), "", F.tiny, Theme.dim, ALIGN_RIGHT)
  lvgl.hline({ x = 0, y = headerH, w = w, h = 1, color = Theme.rule })

  -- Hero: the frame rate, and the numbers that qualify it ----------------
  local heroFont = roomy and F.huge or F.large
  local heroTop  = headerH + (roomy and 6 or 3)
  V.fps = label(pad, heroTop, math.floor(w * 0.34), "--",
                heroFont, Theme.ink)
  local unitY = heroTop + fh(heroFont) - fh(F.tiny) - (roomy and 8 or 4)
  label(pad + math.floor(w * 0.34), unitY, 60, "fps", F.tiny, Theme.dim)

  -- Six readings in two rows beside it. These are qualifications on the big
  -- number, not independent facts: an average frame rate with no spread and
  -- no stall count beside it is the statistic that hides a stutter.
  local gx = math.floor(w * 0.44)
  local gw = math.floor((w - gx - pad) / 3)
  local gRow = fh(F.tiny) + fh(F.small) + (roomy and 8 or 4)
  local KEYS = {
    { "typical", "p50" }, { "slowest 5%", "p95" }, { "worst", "worst" },
    { "stutters", "stalls" }, { "Lua load", "usage" }, { "heap free", "heap" },
  }
  V.cells = {}
  for i, spec in ipairs(KEYS) do
    local col = (i - 1) % 3
    local row = math.floor((i - 1) / 3)
    local x = gx + col * gw
    local y = heroTop + row * gRow
    label(x, y, gw - 4, spec[1], F.tiny, Theme.dim)
    V.cells[spec[2]] = label(x, y + fh(F.tiny), gw - 4, "--",
                             F.small, Theme.ink)
  end

  local heroH = math.max(fh(heroFont), gRow * 2)

  -- Baseline line --------------------------------------------------------
  local baseY = heroTop + heroH + (roomy and 4 or 2)
  V.baseline = label(pad, baseY, w - pad * 2, "", F.tiny, Theme.dim)
  local ruleY = baseY + fh(F.tiny) + (roomy and 4 or 2)
  lvgl.hline({ x = 0, y = ruleY, w = w, h = 1, color = Theme.rule })

  -- Findings list --------------------------------------------------------
  local lineH   = fh(F.tiny) + 1
  local entryH  = lineH * LIST_LINES + (roomy and 6 or 3)
  local footerH = fh(F.tiny) + (roomy and 6 or 4)
  local listTop = ruleY + (roomy and 6 or 3)
  L.visible = math.max(1, math.floor((h - listTop - footerH) / entryH))
  L.cols    = math.floor((w - pad * 2) / math.max(4, fh(F.tiny) * 0.5))

  V.entries = {}
  for i = 1, L.visible do
    local y = listTop + (i - 1) * entryH
    V.entries[i] = {
      title = label(pad, y, w - pad * 2, "", F.tiny, Theme.ink),
      detail = {
        label(pad + 6, y + lineH, w - pad * 2 - 6, "", F.tiny, Theme.dim),
        label(pad + 6, y + lineH * 2, w - pad * 2 - 6, "", F.tiny, Theme.dim),
      },
    }
  end

  local fy = h - footerH + (roomy and 2 or 1)
  V.hint = label(pad, fy, w - pad * 2 - 110, "", F.tiny, Theme.dim)
  V.page = label(w - pad - 110, fy, 110, "", F.tiny, Theme.dim, ALIGN_RIGHT)
end

Screen.mode = function() return mode end
Screen.visibleEntries = function() return L and L.visible or 0 end

--------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------

local function severityColor(f)
  if f.tone == "good" then return Theme.lime end
  if f.severity == Advice.HIGH then return Theme.crit end
  if f.severity == Advice.MED  then return Theme.warn end
  if f.severity == Advice.LOW  then return Theme.steel end
  return Theme.dim
end

-- Colour the frame rate itself, so the screen answers "is this bad" before it
-- is read. The thresholds are the advice engine's, not a second set.
local function fpsColor(fps)
  if fps == nil then return Theme.dim end
  if fps < Advice.FPS_BAD  then return Theme.crit end
  if fps < Advice.FPS_FAIR then return Theme.warn end
  return Theme.lime
end

-- view: { snap, findings, comparison, baselineLabel, scan, scroll, hint }
-- Returns the clamped scroll position, which the caller stores back.
function Screen.update(view)
  if mode ~= "perf" then return 0 end
  view = view or {}
  local snap = view.snap or {}
  local findings = view.findings or {}
  local scroll = math.floor(tonumber(view.scroll) or 0)
  local n = L.visible
  if scroll > #findings - n then scroll = math.max(0, #findings - n) end
  if scroll < 0 then scroll = 0 end

  setp(V.fps, { text = Stats.fmtFps(snap.fps), color = fpsColor(snap.fps) })

  local c = V.cells
  setp(c.p50,   { text = Stats.fmtMs(snap.p50) })
  setp(c.p95,   { text = Stats.fmtMs(snap.p95) })
  setp(c.worst, { text = Stats.fmtMs(snap.worst),
                  color = (snap.stalls or 0) > 0 and Theme.warn or Theme.ink })
  setp(c.stalls, { text = tostring(snap.stalls or 0),
                   color = (snap.stalls or 0) > 0 and Theme.warn or Theme.ink })
  setp(c.usage, { text = snap.usageMax and (math.floor(snap.usageMax) .. "%")
                          or "n/a",
                  color = (snap.usageMax or 0) >= Advice.USAGE_HIGH
                          and Theme.warn or Theme.ink })
  setp(c.heap,  { text = snap.freeMemory and Stats.fmtBytes(snap.freeMemory)
                          or "n/a",
                  color = (snap.freeMemory or math.huge) < Advice.HEAP_LOW
                          and Theme.warn or Theme.ink })

  -- Header note: how much evidence is behind the numbers. A frame rate from
  -- four frames and one from four hundred look identical otherwise.
  local note
  if snap.frames and snap.frames > 0 then
    note = string.format("%d frames", snap.frames)
    if snap.spread then
      note = note .. string.format(", +/-%s", Stats.fmtFps(snap.spread))
    end
    if (snap.gaps or 0) > 0 then
      note = note .. string.format(", %d gap%s", snap.gaps,
                                   snap.gaps == 1 and "" or "s")
    end
  else
    note = "measuring"
  end
  setp(V.scanNote, { text = note })

  -- Baseline
  local cmp = view.comparison
  if cmp and cmp.delta then
    local sign = cmp.delta >= 0 and "+" or "-"
    local col = Theme.dim
    if cmp.verdict == "better" then col = Theme.lime
    elseif cmp.verdict == "worse" then col = Theme.crit end
    setp(V.baseline, {
      text = string.format("baseline %s fps -> now %s fps  (%s%s)",
                           Stats.fmtFps(view.baselineFps),
                           Stats.fmtFps(snap.fps), sign,
                           Stats.fmtFps(math.abs(cmp.delta))),
      color = col })
  else
    setp(V.baseline, { text = "no baseline - press ENTER to mark one",
                       color = Theme.dim })
  end

  for i = 1, n do
    local e = V.entries[i]
    local f = findings[i + scroll]
    if not f then
      setp(e.title, { text = "" })
      setp(e.detail[1], { text = "" })
      setp(e.detail[2], { text = "" })
    else
      setp(e.title, { text = f.title or "", color = severityColor(f) })
      local lines = Screen.wrap(f.detail, L.cols, 2)
      setp(e.detail[1], { text = lines[1] or "" })
      setp(e.detail[2], { text = lines[2] or "" })
    end
  end

  setp(V.hint, { text = view.hint or "" })
  setp(V.page, { text = (#findings > n)
                        and string.format("%d-%d/%d", scroll + 1,
                              math.min(#findings, scroll + n), #findings)
                        or "" })
  return scroll
end

return Screen

end

  end)()
  factory(ZD)
end

-- ======== src/perfwidget.lua ========
do
  local factory = (function()
-- ZelionPerf layer 6: the widget.
--
-- Owns the EdgeTX lifecycle and the key handling, and nothing else.
--
-- The ordering inside refresh() is the whole contract with the sampler:
-- frameStart() first, before any other work, so the period it measures is
-- frame-to-frame and not work-to-work; frameEnd() last, after the screen has
-- been written, so the heap difference across the two covers everything this
-- widget did and nothing it did not.

return function(ZD)

local Host   = ZD.Host
local Theme  = ZD.Theme
local Stats  = ZD.PerfStats
local Probe  = ZD.PerfProbe
local Scan   = ZD.PerfScan
local Advice = ZD.PerfAdvice
local Screen = ZD.PerfScreen

local Widget = {}
ZD.PerfWidget = Widget

local function flag(name, fallback)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
end
local BOOL = flag("BOOL", 2)
local EVT_NEXT  = flag("EVT_VIRTUAL_NEXT",  -1)
local EVT_PREV  = flag("EVT_VIRTUAL_PREV",  -2)
local EVT_ENTER = flag("EVT_VIRTUAL_ENTER", -3)

local built = nil
local zoneW, zoneH = nil, nil
local scroll = 0

-- The findings list is rebuilt on a timer, not every frame.
--
-- Building it means running every rule and formatting a dozen strings, and
-- the answers move on the scale of seconds, not frames - the frame rate it
-- reasons about is itself a mean over two-second sub-windows. Rebuilding it
-- 30 times a second would allocate 30 times as much to say the same thing,
-- inside the one widget whose findings include "something on this screen is
-- allocating per frame".
--
-- Half a second, so a change the pilot just made still appears immediately
-- enough to feel like a response to it.
local REBUILD_TICKS = 50

local listCache, listAt = nil, nil

-- Counted so the throttle is an assertion rather than an intention. On the
-- radio nobody reads this; in the test suite it is what proves a hundred
-- frames do not produce a hundred rebuilds.
Widget.listBuilds = 0

-- Anything that makes the current list wrong right now, rather than merely
-- stale: a new baseline, a rescan, switching between the two lists.
local function invalidateList()
  listCache, listAt = nil, nil
end

Widget.showScripts = false
Widget.lastMarkOption, Widget.lastRescanOption = false, false

local function readZone(widget)
  local z = widget and widget.zone
  local w = tonumber(z and z.w) or Host.lcdW
  local h = tonumber(z and z.h) or Host.lcdH
  if w <= 0 then w = Host.lcdW end
  if h <= 0 then h = Host.lcdH end
  return w, h
end

local function ensureScreen(widget)
  local w, h = readZone(widget)
  if w ~= zoneW or h ~= zoneH then
    zoneW, zoneH = w, h
    built = nil
  end
  if built ~= "perf" then
    pcall(Screen.build, zoneW, zoneH)
    built = "perf"
  end
end

--------------------------------------------------------------------------
-- The script inventory, as list entries
--------------------------------------------------------------------------
--
-- Rendered through the same list as the findings so there is one scrolling
-- widget on screen rather than two, and so a pilot who has read a finding
-- about mix scripts can switch straight to seeing which ones they have.
--
-- Severity here is not a judgement about the script. It is how much of the
-- time that KIND of script runs, which is the only thing this tool knows and
-- the only thing that should drive where the eye goes.
local KIND_SEVERITY = {
  mix = Advice.HIGH, func = Advice.MED, widget = Advice.LOW,
  telem = Advice.INFO, tool = Advice.INFO,
}

local function scriptEntries(scan)
  local out = {}
  if not scan or not scan.ok then
    out[1] = { severity = Advice.INFO, title = "No script list",
               detail = scan and scan.reason
                        or "The storage has not been scanned yet." }
    return out
  end

  local m = scan.model or {}
  local parts = {}
  local function add(n, word)
    if n ~= nil then parts[#parts + 1] = string.format("%d %s", n, word) end
  end
  add(m.sensors, "sensors")
  add(m.logicalSwitches, "logical switches")
  add(m.specialFunctions, "special functions")
  add(m.mixes, "mixes")
  out[#out + 1] = {
    severity = Advice.INFO,
    title = string.format("%d scripts installed", #scan.scripts),
    -- The model's own load shares the main task with every script here, so it
    -- belongs on the same page even though none of it is Lua.
    detail = (#parts > 0) and ("This model: " .. table.concat(parts, ", "))
             or "This firmware does not report the model's own counts.",
  }

  for _, s in ipairs(scan.scripts) do
    out[#out + 1] = {
      severity = KIND_SEVERITY[s.kind] or Advice.INFO,
      title = s.name,
      detail = string.format("%s  runs %s  %s%s", s.dir, s.when,
                             s.size and Stats.fmtBytes(s.size) .. "b" or "size unknown",
                             s.compiled and "  compiled" or ""),
    }
  end

  for _, dir in ipairs(scan.unreadable or {}) do
    out[#out + 1] = { severity = Advice.INFO, title = dir,
                      detail = "not present, or not readable on this radio" }
  end
  return out
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Widget.create(zone, options)
  pcall(Theme.build)
  -- Scanned here rather than on the first frame. The scan makes hundreds of
  -- firmware calls and touches storage; run from a refresh it would produce a
  -- stall of its own, which the sampler would then faithfully report to the
  -- pilot as their problem.
  pcall(Scan.run)
  pcall(Probe.reset)
  invalidateList()
  built = nil
  zoneW, zoneH = nil, nil
  scroll = 0
  return { zone = zone, options = options }
end

function Widget.update(widget, options)
  widget.options = options
  Widget.showScripts = (options and options.Scripts == 1) or false

  -- Edge-triggered, the way ZelionDash's Test Alert is: switching the option
  -- on performs the action once. EdgeTX widget options have no button type,
  -- so a toggle that acts on the transition is the nearest thing - and unlike
  -- acting on the value, a firmware that calls update() repeatedly cannot
  -- turn it into a loop.
  local mark = (options and options.Mark == 1) or false
  if mark and not Widget.lastMarkOption then pcall(Probe.mark, "settings") end
  Widget.lastMarkOption = mark

  local rescan = (options and options.Rescan == 1) or false
  if rescan and not Widget.lastRescanOption then pcall(Scan.run) end
  Widget.lastRescanOption = rescan

  invalidateList()
  built = nil
  ensureScreen(widget)
end

-- ENTER marks a baseline, or clears the one that is there. That single key is
-- the whole optimisation loop: mark, change one thing, read the delta.
local function handleEvent(event)
  if event == nil then return end
  if event == EVT_NEXT then
    scroll = scroll + 1
  elseif event == EVT_PREV then
    scroll = scroll - 1
  elseif event == EVT_ENTER then
    if Probe.baseline then
      Probe.clearBaseline()
      Probe.restart()
    else
      Probe.mark("marked")
    end
    invalidateList()
  end
end

function Widget.refresh(widget, event, touchState)
  Probe.frameStart(Host.now())
  ensureScreen(widget)
  handleEvent(event)

  local snap = Probe.snapshot()
  local cmp  = Probe.comparison(snap)
  local scan = Scan.result

  local now = Host.now()
  if listCache == nil or listAt == nil
     or now - listAt >= REBUILD_TICKS or now < listAt then
    if Widget.showScripts then
      local ok, entries = pcall(scriptEntries, scan)
      listCache = ok and entries or {}
    else
      local ok, findings = pcall(Advice.build, snap, scan, cmp,
                                 Probe.baselineLabel)
      listCache = ok and findings or {}
    end
    listAt = now
    Widget.listBuilds = Widget.listBuilds + 1
  end
  local list = listCache

  local ok, clamped = pcall(Screen.update, {
    snap = snap,
    findings = list,
    comparison = cmp,
    baselineFps = Probe.baseline and Probe.baseline.fps or nil,
    scroll = scroll,
    hint = Widget.showScripts and "heaviest-running first"
           or (Probe.baseline and "ENTER clears the baseline"
                              or "ENTER marks a baseline"),
  })
  if ok and clamped then scroll = clamped end

  Probe.frameEnd()
end

-- Deliberately empty of measurement. Off-screen there are no frames to time,
-- and the honest thing for an analyser to cost when it is not being looked at
-- is nothing at all.
function Widget.background(widget)
end

Widget.options = {
  -- Capture the current frame rate to compare against. Also available on the
  -- ENTER key, which is where it actually gets used - the settings page is
  -- for a radio whose ENTER does not reach the widget.
  { "Mark",    BOOL, 0 },
  -- Re-walk the storage and the model. Needed after installing or deleting a
  -- script, since the scan is deliberately not repeated per frame.
  { "Rescan",  BOOL, 0 },
  -- Swap the list from findings to the raw inventory.
  { "Scripts", BOOL, 0 },
}

Widget.OPTION_LABELS = {
  Mark    = "Mark Baseline (toggle)",
  Rescan  = "Rescan Scripts (toggle)",
  Scripts = "Show Script List",
}

function Widget.translate(name)
  return Widget.OPTION_LABELS[name] or name
end

-- Exposed for the tests and for tools/dump_screen.lua, so what is documented
-- is what the radio builds.
Widget.scriptEntries = scriptEntries

return Widget

end

  end)()
  factory(ZD)
end

return {
  name       = "ZelionPerf",
  options    = ZD.PerfWidget.options,
  create     = ZD.PerfWidget.create,
  update     = ZD.PerfWidget.update,
  refresh    = ZD.PerfWidget.refresh,
  background = ZD.PerfWidget.background,
  translate  = ZD.PerfWidget.translate,
  useLvgl    = true,
}
