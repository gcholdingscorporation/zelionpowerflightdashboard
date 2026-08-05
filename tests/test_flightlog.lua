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

H.test("no clock set is obvious rather than plausible", function()
  local ZD = fresh(function()
    loaded()
    Mock.state.dateTime = nil        -- no getDateTime at all
  end)
  flight(ZD, 40)
  H.truthy(string.find(lines()[2], "1970-01-01", 1, true),
           "reads as 'the clock was not set', which is the truth")
end)

end
