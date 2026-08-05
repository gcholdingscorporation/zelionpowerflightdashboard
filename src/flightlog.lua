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
  if v == nil then return "" end
  if fmt == "%d" then return string.format("%d", math.floor(v + 0.5)) end
  return string.format(fmt, v)
end

-- Commas and quotes in a model name would otherwise shift every column after
-- it. Quoting is the CSV answer; doubling the quote is how CSV escapes one.
local function field(s)
  s = tostring(s or ""):gsub('"', '""')
  if s:find('[,"\n]') then return '"' .. s .. '"' end
  return s
end

function FlightLog.record()
  local t = Host.dateTime()
  return table.concat({
    string.format("%04d-%02d-%02d", t.year, t.mon, t.day),
    string.format("%02d:%02d:%02d", t.hour, t.min, t.sec),
    field(State.modelName or Host.modelName()),
    num(State.flightSeconds, "%d"),
    num(State.max("headspeed"), "%d"),
    num(State.min("cellVoltage"), "%.2f"),
    num(State.min("packVoltage"), "%.2f"),
    num(State.max("current"), "%.1f"),
    num(State.max("escTemperature"), "%d"),
    num(State.max("capacity"), "%d"),
    num(State.valid("batteryPercent") and State.num("batteryPercent") or nil, "%d"),
  }, ",")
end

--------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------

local function splitLines(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
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
  local records = FlightLog.read()
  records[#records + 1] = line
  while #records > FlightLog.MAX_RECORDS do table.remove(records, 1) end
  local body = FlightLog.HEADER .. "\n" .. table.concat(records, "\n") .. "\n"

  Host.mkdir(FlightLog.DIR)      -- no-op when it already exists
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

  local ok, line = pcall(FlightLog.record)
  if not ok then
    FlightLog.lastError = "could not format the record"
    return false
  end
  local wrote
  ok, wrote = pcall(FlightLog.append, line)
  return ok and wrote == true
end

function FlightLog.reset()
  FlightLog.written, FlightLog.skipped = 0, 0
  FlightLog.lastWrite, FlightLog.lastError = nil, nil
  FlightLog.FALLBACK = nil
end

return FlightLog

end
