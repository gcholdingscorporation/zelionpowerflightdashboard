-- Flight log: what gets written, when, and what survives a bad card.
--
-- The record is written once, at the moment a flight ends, and the file it
-- goes into is the only durable thing this widget produces. Most of these test
-- that it does not lose what was already there.

return function(H, Mock, Loader)

local PATH = "/LOGS/zeliondash.csv"

local function fresh(setup)
  Mock.reset()
  Mock.removeRf2()
  Mock.state.dateTime = { year = 2026, mon = 8, day = 5,
                          hour = 14, min = 32, sec = 9 }
  Mock.state.modelName = "GOBLIN 700"
  if setup then setup() end
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  ZD.FlightLog.reset()
  return ZD
end

local function run(ZD, seconds)
  for _ = 1, math.floor(seconds * 10) do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.FlightLog.service()
  end
end

-- Spool up, hold for `seconds`, land. The rotor is what marks a flight when
-- the flight controller publishes no ARM flags.
local function flight(ZD, seconds)
  Mock.setSensor("Hspd", 1850)
  run(ZD, seconds)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
end

local function loaded()
  Mock.addSensor("Hspd", 18, 0)
  Mock.addSensor("Vcel", 1, 3.95)
  Mock.addSensor("Vbat", 1, 47.4)
  Mock.addSensor("Curr", 2, 5)
  Mock.addSensor("Tesc", 11, 30)
  Mock.addSensor("Capa", 14, 0)
end

local function lines()
  local text = Mock.state.files[PATH]
  local out = {}
  for l in tostring(text or ""):gmatch("[^\r\n]+") do out[#out + 1] = l end
  return out
end

H.group("flightlog: writing a flight")

H.test("a flight becomes one line, with a header above it", function()
  local ZD = fresh(loaded)
  flight(ZD, 40)
  local l = lines()
  H.eq(#l, 2, "header plus one record")
  H.eq(l[1], ZD.FlightLog.HEADER)
  H.truthy(string.find(l[2], "2026-08-05", 1, true), "dated from the radio clock")
  H.truthy(string.find(l[2], "GOBLIN 700", 1, true), "and named")
end)

H.test("records the flight's peaks, not the day's", function()
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  run(ZD, 10)
  Mock.setSensor("Hspd", 2150); run(ZD, 2)
  Mock.setSensor("Vcel", 3.51);  run(ZD, 2)
  Mock.setSensor("Curr", 96);    run(ZD, 2)
  Mock.setSensor("Tesc", 74);    run(ZD, 2)
  Mock.setSensor("Hspd", 1850); run(ZD, 15)
  Mock.setSensor("Hspd", 0);    run(ZD, 8)

  local rec = lines()[2]
  H.truthy(string.find(rec, "2150", 1, true), "max headspeed")
  H.truthy(string.find(rec, "3.51", 1, true), "min cell")
  H.truthy(string.find(rec, "96.0", 1, true), "max current")
  H.truthy(string.find(rec, "74", 1, true),   "max ESC temp")
end)

H.test("a missing reading is blank, never zero", function()
  -- A spreadsheet column of zeroes that were really "no sensor" is worse than
  -- a gap, because it averages.
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 0) end)
  flight(ZD, 40)
  local rec = lines()[2]
  local fields = {}
  for f in (rec .. ","):gmatch("([^,]*),") do fields[#fields + 1] = f end
  H.eq(fields[6], "", "no cell sensor, so no cell figure")
  H.eq(fields[9], "", "no ESC temp either")
  H.truthy(tonumber(fields[5]) > 0, "but the headspeed it did have is there")
end)

H.test("flights accumulate", function()
  local ZD = fresh(loaded)
  flight(ZD, 40)
  flight(ZD, 40)
  flight(ZD, 40)
  H.eq(#lines(), 4, "header plus three")
  H.eq(ZD.FlightLog.written, 3)
end)

H.group("flightlog: staying quiet")

H.test("a spool-up test is not a flight", function()
  local ZD = fresh(loaded)
  flight(ZD, 8)
  H.eq(#lines(), 0, "nothing written at all")
  H.eq(ZD.FlightLog.skipped, 1)
end)

H.test("a short flight does not get written at the next landing", function()
  -- The latch has to be consumed either way, or the short flight reappears
  -- attached to the next one.
  local ZD = fresh(loaded)
  flight(ZD, 8)
  flight(ZD, 40)
  H.eq(#lines(), 2, "one header, one real flight")
end)

H.test("the card is touched once per flight, not on a timer", function()
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  run(ZD, 60)
  H.eq(#lines(), 0, "nothing yet - the flight has not ended")
  local writes = Mock.state.writes or 0
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  H.eq(#lines(), 2)
  H.truthy((Mock.state.writes or 0) - writes <= 3,
           "one record, not one per service pass")
end)

H.test("switching it off stops the writing but not the flying", function()
  local ZD = fresh(loaded)
  ZD.FlightLog.enabled = false
  flight(ZD, 40)
  H.eq(#lines(), 0)
  H.falsy(ZD.State.disarmPending, "the latch is still consumed")
end)

H.group("flightlog: not losing the file")

H.test("existing records survive a new one", function()
  local ZD = fresh(loaded)
  Mock.state.files[PATH] = ZD.FlightLog.HEADER ..
    "\n2026-08-01,10:00:00,GOBLIN 700,300,2100,3.60,44.0,90.0,70,1800,22\n"
  flight(ZD, 40)
  local l = lines()
  H.eq(#l, 3)
  H.truthy(string.find(l[2], "2026-08-01", 1, true), "the old one is still there")
  H.truthy(string.find(l[3], "2026-08-05", 1, true), "with the new one under it")
end)

H.test("oldest records fall off rather than growing forever", function()
  local ZD = fresh(loaded)
  ZD.FlightLog.MAX_RECORDS = 3
  for i = 1, 5 do flight(ZD, 40) end
  H.eq(#lines(), 4, "header plus the cap")
  ZD.FlightLog.MAX_RECORDS = 200
end)

H.test("a file with a foreign header is not appended to", function()
  -- Half a flight log is more confusing than a fresh one, and Host.writeFile
  -- leaves the previous file as a .bak.
  local ZD = fresh(loaded)
  Mock.state.files[PATH] = "something,else,entirely\n1,2,3\n"
  flight(ZD, 40)
  local l = lines()
  H.eq(l[1], ZD.FlightLog.HEADER)
  H.eq(#l, 2, "started over rather than producing nonsense")
end)

H.test("a comma in the model name does not shift the columns", function()
  local ZD = fresh(function()
    loaded()
    Mock.state.modelName = 'GOBLIN 700, "Red"'
  end)
  flight(ZD, 40)
  local rec = lines()[2]
  H.truthy(string.find(rec, '"GOBLIN 700, ""Red"""', 1, true),
           "quoted and escaped the CSV way")
end)

H.test("a card that will not take the write does not raise", function()
  local ZD = fresh(loaded)
  Mock.state.readOnly = true
  local ok = pcall(flight, ZD, 40)
  Mock.state.readOnly = nil
  H.truthy(ok, "a widget must never fault the transmitter")
  H.truthy(ZD.FlightLog.lastError, "but it should say so")
end)

H.group("flightlog: one bad field must not cost the flight")

-- A record is written once, at landing, and there is no second chance at it.
-- On hardware the whole record failed to format and took the flight with it,
-- which is the failure this group exists to make impossible.

H.test("a value with no integer representation blanks its column only", function()
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  run(ZD, 40)
  Mock.setSensor("Tesc", math.huge)      -- a glitched sensor
  run(ZD, 2)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  local l = lines()
  H.eq(#l, 2, "the flight was still written")
  H.truthy(string.find(l[2], "1850", 1, true), "and the good columns survived")
end)

H.test("a clock that returns nonsense still dates the row", function()
  local ZD = fresh(function()
    loaded()
    Mock.state.dateTime = { year = "not a year", mon = nil, day = 1 / 0 }
  end)
  flight(ZD, 40)
  local l = lines()
  H.eq(#l, 2, "written anyway")
  H.truthy(string.find(l[2], "1970-01-01", 1, true), "with the honest fallback")
end)

H.test("a clock that raises does not lose the flight", function()
  local ZD = fresh(loaded)
  _G.getDateTime = function() error("no RTC on this radio") end
  local ok = pcall(flight, ZD, 40)
  H.truthy(ok)
  H.eq(#lines(), 2, "the flight is what matters, not the timestamp")
end)

H.test("switching model mid-flight abandons the flight", function()
  -- Not a bug: a flight that spans two models is not a flight, and the peaks
  -- belong to whichever aircraft produced them. Pinned because it is
  -- surprising, and because it looks identical to a lost record.
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  run(ZD, 40)
  Mock.state.modelName = "SOMETHING ELSE"
  run(ZD, 1)
  H.truthy(ZD.State.flightSeconds < 5, "the session started over")
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  H.eq(#lines(), 0, "and nothing was written for the abandoned one")
end)

H.test("the real error is reported, not a generic one", function()
  -- "could not format the record" cost a round trip to hardware and said
  -- nothing about what had gone wrong.
  local ZD = fresh(loaded)
  ZD.FlightLog.record = function() error("something specific broke") end
  flight(ZD, 40)
  H.truthy(ZD.FlightLog.lastError, "reported")
  H.truthy(string.find(ZD.FlightLog.lastError, "something specific", 1, true),
           "and names what happened")
end)

H.group("flightlog: a folder that is not there yet")

-- /LOGS/ exists only if the radio has already logged telemetry. On a radio
-- where it did not, a real 27-second flight was lost and the status line still
-- read "no flight yet" - indistinguishable from never having taken off.

H.test("the folder is created before anything opens a file in it", function()
  local ZD = fresh(function()
    loaded()
    Mock.state.missingDirs["/LOGS/"] = true
  end)
  flight(ZD, 40)
  H.falsy(ZD.FlightLog.lastError, "no error: " .. tostring(ZD.FlightLog.lastError))
  H.eq(#lines(), 2, "header plus the flight")
  H.eq(ZD.FlightLog.written, 1)
end)

H.test("a flight that fails to write never reads as one that never happened", function()
  -- The whole point of the status line. "no flight yet" and "the write threw"
  -- are opposite problems and looked identical.
  local ZD = fresh(loaded)
  ZD.FlightLog.append = function() error("io: no such directory") end
  flight(ZD, 40)
  local _, verdict = ZD.FlightLog.status()
  H.eq(verdict, "FAILED")
  H.truthy(string.find(tostring(ZD.FlightLog.lastError), "no such directory",
                       1, true), "and it names the reason")
end)

H.test("an unenumerated failure still shows up", function()
  -- Neither record nor append raising, but nothing written either. Whatever
  -- that is, it must not present as a quiet success.
  local ZD = fresh(loaded)
  ZD.FlightLog.append = function() return false end
  flight(ZD, 40)
  local _, verdict = ZD.FlightLog.status()
  H.eq(verdict, "FAILED", "not 'no flight yet'")
end)

H.test("a flight recorded after a failed one clears the error", function()
  local ZD = fresh(loaded)
  Mock.state.readOnly = true
  flight(ZD, 40)
  H.truthy(ZD.FlightLog.lastError, "the first one failed")
  Mock.state.readOnly = nil
  flight(ZD, 40)
  H.falsy(ZD.FlightLog.lastError, "and the second one says so")
  H.eq(ZD.FlightLog.written, 1)
end)

H.test("no clock set is obvious rather than plausible", function()
  local ZD = fresh(function()
    loaded()
    Mock.state.dateTime = nil        -- no getDateTime at all
  end)
  flight(ZD, 40)
  H.truthy(string.find(lines()[2], "1970-01-01", 1, true),
           "reads as 'the clock was not set', which is the truth")
end)

H.group("flightlog: the columns added later")

-- These exist to be collected, not read. A trend needs flights behind it
-- before it is worth building anything on, and a flight flown without them is
-- a row that will always be blank.

H.test("records resting voltage, mean draw and worst link quality", function()
  local ZD = fresh(function()
    loaded()
    Mock.addSensor("RQly", 13, 100)
  end)
  -- Sit disarmed for a moment so a resting voltage is seen.
  run(ZD, 2)
  Mock.setSensor("Hspd", 1850)
  Mock.setSensor("Curr", 40)
  run(ZD, 20)
  Mock.setSensor("Curr", 60)
  Mock.setSensor("RQly", 62)
  run(ZD, 20)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)

  local f = {}
  for x in (lines()[2] .. ","):gmatch("([^,]*),") do f[#f + 1] = x end
  H.eq(#f, 15, "eleven original columns plus four")
  H.eq(f[12], "47.40", "pack at rest, before the rotor turned")
  H.eq(f[13], "3.95",  "and the cell with it")
  H.truthy(tonumber(f[14]) > 40 and tonumber(f[14]) < 60,
           "mean draw sits between the two, got " .. tostring(f[14]))
  H.eq(f[15], "62", "the worst link quality of the flight")
end)

H.test("resting voltage is taken before the rotor, not at arm", function()
  -- With rotor arming the head is already turning by the time we call it a
  -- flight, so a voltage read at that moment is a voltage under load - which
  -- is the one number this is useless without.
  local ZD = fresh(loaded)
  run(ZD, 2)                          -- resting at 47.4
  Mock.setSensor("Vbat", 44.0)        -- sags the instant it spools
  Mock.setSensor("Hspd", 1850)
  run(ZD, 40)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  local f = {}
  for x in (lines()[2] .. ","):gmatch("([^,]*),") do f[#f + 1] = x end
  H.eq(f[12], "47.40", "the resting figure, not the sagged one")
end)

H.test("a flight with no link sensor leaves that column blank", function()
  local ZD = fresh(loaded)
  flight(ZD, 40)
  local f = {}
  for x in (lines()[2] .. ","):gmatch("([^,]*),") do f[#f + 1] = x end
  H.eq(f[15], "", "blank, never zero - a zero averages into every trend")
end)

H.group("flightlog: widening the file without losing it")

local OLD_HEADER =
  "date,time,model,seconds,max_rpm,min_cell,min_pack,max_amps," ..
  "max_esc_c,used_mah,end_pct"

H.test("flights logged by an older build survive the new columns", function()
  -- Changing the header naively starts a fresh file and leaves the history in
  -- a .bak nobody thinks to look for. There were thirteen real flights in
  -- there when this column was added.
  local ZD = fresh(loaded)
  Mock.state.files[PATH] = OLD_HEADER ..
    "\n2026-08-09,08:27:38,>Rotorflight,220,6872,3.31,6.50,17.4,37,251,37\n" ..
    "2026-08-09,08:45:32,>Rotorflight,231,6864,3.33,6.60,14.4,36,261,34\n"
  flight(ZD, 40)

  local l = lines()
  H.eq(l[1], ZD.FlightLog.HEADER, "the file is now on the new header")
  H.eq(#l, 4, "both old flights kept, plus the new one")
  H.truthy(string.find(l[2], "08:27:38", 1, true), "the first is still there")
  H.truthy(string.find(l[3], "08:45:32", 1, true), "and the second")
end)

H.test("an old row is padded, not left short", function()
  local ZD = fresh(loaded)
  Mock.state.files[PATH] = OLD_HEADER ..
    "\n2026-08-09,08:27:38,>Rotorflight,220,6872,3.31,6.50,17.4,37,251,37\n"
  flight(ZD, 40)

  local f = {}
  for x in (lines()[2] .. ","):gmatch("([^,]*),") do f[#f + 1] = x end
  H.eq(#f, 15, "same width as every other row, so columns still line up")
  H.eq(f[12], "", "and honestly blank for a flight flown before they existed")
end)

H.test("a header from no version of this widget still starts over", function()
  local ZD = fresh(loaded)
  Mock.state.files[PATH] = "something,else,entirely\n1,2,3\n"
  flight(ZD, 40)
  local l = lines()
  H.eq(l[1], ZD.FlightLog.HEADER)
  H.eq(#l, 2, "half a flight log is more confusing than a fresh one")
end)

end
