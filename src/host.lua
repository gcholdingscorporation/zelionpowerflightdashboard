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
local MAX_OUTPUT_CHANNELS = 32
local MAX_INPUTS = 32

-- model.getMixesCount and model.getInputsCount are PER CHANNEL and PER INPUT
-- (radio/src/lua/api_model.cpp: both do luaL_checkinteger(L, 1)). Called with
-- no argument they raise, which the pcall swallowed - so the analyser showed
-- a model with no mix and no input count at all, on a radio that has plenty
-- of both, and said nothing about why.
--
-- Summed here rather than reported per channel: what the figure is for is
-- "how much does the mixer have to compute every cycle", and that is the
-- total. 32 calls each, on a scan that already runs once and never per frame.
local function sumOver(fn, limit)
  if type(fn) ~= "function" then return nil end
  local total, answered = 0, false
  for i = 0, limit - 1 do
    local ok, n = pcall(fn, i)
    if ok then
      n = tonumber(n)
      if n then
        total = total + n
        answered = true
      end
    end
  end
  -- nil rather than 0 when the firmware never answered once: "this radio does
  -- not report it" and "you have none" must not look the same.
  if not answered then return nil end
  return total
end

-- Returns a table of counts, each entry nil where the firmware would not say.
-- nil and 0 are kept apart deliberately: "this radio has no getMixesCount"
-- must not be presented to the pilot as "you have no mixes".
function Host.modelInventory()
  local out = { mixes = nil, inputs = nil, logicalSwitches = nil,
                specialFunctions = nil, sensors = nil, loggedSensors = nil }
  if type(modelTbl) ~= "table" then return out end

  out.mixes  = sumOver(modelTbl.getMixesCount, MAX_OUTPUT_CHANNELS)
  out.inputs = sumOver(modelTbl.getInputsCount, MAX_INPUTS)

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
    local n, answered = 0, false
    for i = 0, MAX_SPECIAL_FUNCTIONS - 1 do
      local ok, cf = pcall(modelTbl.getCustomFunction, i)
      -- An empty slot comes back as a FULLY POPULATED TABLE, not as nil:
      -- api_model.cpp pushes switch, func and active for every index below
      -- MAX_SPECIAL_FUNCTIONS whether or not anything is configured there.
      -- Testing `switch ~= nil` therefore counted all 64 slots, and a radio
      -- with a handful of special functions was told it had sixty-four - a
      -- number that was really this loop's own limit read back.
      --
      -- The firmware's own test is CFN_EMPTY(p) == !(p)->swtch: switch 0 is
      -- no switch, which is an unused slot. "Always on" is a real switch
      -- source with a non-zero index, so it is not caught by this.
      if ok and type(cf) == "table" then
        answered = true
        if (tonumber(cf.switch) or 0) ~= 0 then n = n + 1 end
      end
    end
    if answered then out.specialFunctions = n end
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
