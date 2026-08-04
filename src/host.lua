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
