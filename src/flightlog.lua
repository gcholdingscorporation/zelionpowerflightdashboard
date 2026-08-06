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
