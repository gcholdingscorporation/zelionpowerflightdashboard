-- Flight log: what gets written, when, and what survives a bad card.
--
-- The record is written once, at the moment a flight ends, and the file it
-- goes into is the only durable thing this widget produces. Most of these test
-- that it does not lose what was already there.

return function(H, Mock, Loader)

local PATH = "/LOGS/zeliondash.csv"

-- Derived from the header rather than written down. Every column added to this
-- log used to mean hunting the hard-coded widths in here and bumping them,
-- which is a test that fails for the one reason that is never interesting.
local function columns(ZD)
  local n = 1
  for _ in ZD.FlightLog.HEADER:gmatch(",") do n = n + 1 end
  return n
end

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

-- Spool up, hold for `seconds`, land, and wait out the settle window. The
-- rotor is what marks a flight when the flight controller publishes no ARM
-- flags.
--
-- The wait is not padding. The row is formatted at the landing but held back
-- until the pack has recovered, so end_cell is a rested voltage rather than one
-- still climbing - nothing reaches the card until then. Derived from the
-- constant so that tuning the window does not mean editing every test here.
local function settleSeconds(ZD)
  return ZD.FlightLog.SETTLE / 100 + 2
end

local function land(ZD)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)                      -- the disarm itself needs a moment to latch
  run(ZD, settleSeconds(ZD))
end

local function flight(ZD, seconds)
  Mock.setSensor("Hspd", 1850)
  run(ZD, seconds)
  land(ZD)
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
  land(ZD)

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

H.test("the count keeps up with the file after a landing", function()
  -- The count is cached, because counting it is a file read in the same loop
  -- that draws the screen. A cache that is not maintained by the writes is
  -- worse than no cache: the row sits there showing yesterday's total, which
  -- is precisely the "did I lose a flight?" question it exists to answer.
  local ZD = fresh(loaded)
  local _, before = ZD.FlightLog.status()      -- asks, and so caches
  H.eq(before, "no flight yet")

  flight(ZD, 40)
  local _, after = ZD.FlightLog.status()
  H.eq(after, "1 in log", "the landing must move the count")

  flight(ZD, 40)
  local _, again = ZD.FlightLog.status()
  H.eq(again, "2 in log")
  H.eq(#lines(), 3, "and the file really does hold both")
end)

H.test("the count is the file's, not this session's", function()
  -- Records already on the card from previous sessions count. This is the
  -- whole difference: it can be read against the flight controller's own
  -- lifetime total on the row above, and a session counter cannot.
  local ZD = fresh(loaded)
  -- Written after load so the header is this build's, taken from the module
  -- itself: a hard-coded copy here would go stale on the next column and
  -- quietly start testing the migration path instead of this.
  Mock.writeFile(PATH, ZD.FlightLog.HEADER .. "\n"
                 .. "2026-01-01,09:00,OLD,300" .. string.rep(",", 11) .. "\n")
  ZD.FlightLog.reset()
  local _, verdict = ZD.FlightLog.status()
  H.eq(verdict, "1 in log", "before this session has flown anything")

  flight(ZD, 40)
  local _, after = ZD.FlightLog.status()
  H.eq(after, "2 in log", "and the new flight adds to it")
  H.eq(ZD.FlightLog.written, 1, "though only one was written this session")
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
  land(ZD)
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
  land(ZD)
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
  land(ZD)
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
  land(ZD)

  local f = {}
  for x in (lines()[2] .. ","):gmatch("([^,]*),") do f[#f + 1] = x end
  H.eq(#f, columns(ZD), "a record is exactly as wide as the header")
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
  land(ZD)
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
  H.eq(#f, columns(ZD),
       "same width as every other row, so columns still line up")
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


H.group("flightlog: the settle window")

-- The row is formatted at the landing and written 45 seconds later, so the
-- rested voltage has recovered. Everything here is about that gap: what is in
-- it, what gets out of it early, and what must not change inside it.

local function column(ZD, rec, want)
  local at, k = nil, 0
  for name in string.gmatch(ZD.FlightLog.HEADER, "[^,]+") do
    k = k + 1
    if name == want then at = k end
  end
  H.truthy(at ~= nil, "no " .. want .. " column")
  k = 0
  for field in string.gmatch(rec .. ",", "([^,]*),") do
    k = k + 1
    if k == at then return field end
  end
end

H.test("nothing reaches the card until the pack has recovered", function()
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  run(ZD, 40)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  H.eq(#lines(), 0, "written before the pack could possibly have rested")
  H.truthy(ZD.FlightLog.waiting(), "and nothing says it is being held")

  run(ZD, settleSeconds(ZD))
  H.eq(#lines(), 2, "the wait never ended")
  H.falsy(ZD.FlightLog.waiting())
end)

H.test("the rested voltage is the one after the flight, not before it", function()
  local ZD = fresh(loaded)
  Mock.setSensor("Vcel", 4.15); Mock.setSensor("Vbat", 49.8)
  run(ZD, 5)                                  -- resting, full, before the flight
  Mock.setSensor("Hspd", 1850)
  Mock.setSensor("Vcel", 3.55); Mock.setSensor("Vbat", 42.6)
  run(ZD, 40)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  -- The pack recovers while the row is held. This is the whole point: read at
  -- the landing it would say 3.55, and 3.55 is not a rested voltage.
  Mock.setSensor("Vcel", 3.78); Mock.setSensor("Vbat", 45.4)
  run(ZD, settleSeconds(ZD))

  local rec = lines()[2]
  H.eq(column(ZD, rec, "end_cell"), "3.78", "row: " .. rec)
  H.eq(column(ZD, rec, "end_pack"), "45.40")
  H.eq(column(ZD, rec, "start_cell"), "4.15", "and the pre-flight pair is intact")
end)

H.test("a chime says the row is on the card", function()
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  run(ZD, 40)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  H.eq(#Mock.played, 0, "sounded before the write")
  run(ZD, settleSeconds(ZD))
  H.truthy(#Mock.played > 0, "the pilot has no way to know it is safe to switch off")
  for _, p in ipairs(Mock.played) do H.eq(p.op, "tone", "not a spoken alert") end
end)

H.test("and stays silent when the card refuses the write", function()
  -- Worse than no confirmation: a confirmation for a flight that was lost.
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  run(ZD, 40)
  Mock.state.readOnly = true
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  run(ZD, settleSeconds(ZD))
  Mock.state.readOnly = false
  H.eq(#Mock.played, 0, "chimed for a flight that never reached the card")
end)

H.test("relighting inside the window writes the flight first", function()
  -- The case that would lose data. State resets its extremes the moment the
  -- next flight arms, so a row still waiting to be formatted would be formatted
  -- from the NEW flight - or from nothing at all.
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  Mock.setSensor("Hspd", 2150)
  run(ZD, 40)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  H.eq(#lines(), 0, "still holding")

  Mock.setSensor("Hspd", 1850)              -- straight back up
  run(ZD, 3)
  H.eq(#lines(), 2, "the held flight was not written before the next one began")
  H.truthy(string.find(lines()[2], "2150", 1, true),
           "the wrong flight's peak: " .. lines()[2])
  H.eq(column(ZD, lines()[2], "end_cell"), "",
       "a pack back under load never rested")
end)

H.test("an unplugged pack writes the flight rather than waiting for it", function()
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  run(ZD, 40)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  H.eq(#lines(), 0, "still holding")

  -- Nothing left to read a rested voltage from, so waiting only risks the row.
  Mock.removeSensor("Vcel"); Mock.removeSensor("Vbat")
  run(ZD, 1)
  H.eq(#lines(), 2, "waited for a reading that was never coming")
  -- Blank, not the last thing State happened to be holding. That value was
  -- read seconds after a landing with the pack still climbing, and in this
  -- column it would be indistinguishable from a settled one.
  H.eq(column(ZD, lines()[2], "end_cell"), "",
       "passed off a half-recovered voltage as a rested one")
  H.truthy(string.find(lines()[2], "1850", 1, true), "and the flight survived")
end)

H.test("a flight too short to log is not held either", function()
  local ZD = fresh(loaded)
  Mock.setSensor("Hspd", 1850)
  run(ZD, 5)
  Mock.setSensor("Hspd", 0)
  run(ZD, 8)
  H.falsy(ZD.FlightLog.waiting(), "a spool-up test is not a landing to wait on")
  run(ZD, settleSeconds(ZD))
  H.eq(#lines(), 0)
  H.eq(#Mock.played, 0, "and nothing to announce")
end)



H.group("flightlog: one model slot, four helicopters")

-- A radio can be set up with one EdgeTX model per aircraft, or with ONE model
-- and the configuration kept on the flight controllers - which is a deliberate
-- choice, not an oversight: it stops four model slots drifting apart. Under
-- that setup the EdgeTX model name is a constant and says nothing about which
-- helicopter flew, so the flight controller's craft name is what identifies
-- the aircraft.

-- fresh() calls Mock.reset(), so the model name has to be set inside the setup
-- rather than around it.
local function withFc(craft, slot)
  return function()
    loaded()
    Mock.state.modelName = slot or ">Rotorflight"
    Mock.installRf2({ apiVersion = 12.09, modelName = craft })
  end
end

H.test("the craft name is logged beside the model name, not instead of it", function()
  local ZD = fresh(withFc("Omphobby M7R"))
  flight(ZD, 40)
  local rec = lines()[2]
  H.eq(column(ZD, rec, "craft"), "Omphobby M7R", "row: " .. rec)
  -- Both. The model column has meant "the radio's model slot" for every row
  -- already on the card, and quietly redefining a column is how a log stops
  -- being comparable with itself.
  H.eq(column(ZD, rec, "model"), ">Rotorflight")
end)

H.test("two helicopters on one model slot are told apart", function()
  local ZD = fresh(withFc("Omphobby M7R"))
  flight(ZD, 40)

  -- Land, power down, plug in the other helicopter. The model slot never
  -- changed; only the flight controller did. RF Tool re-reads on its own
  -- retry, so the new name arrives a few seconds after the link does - which
  -- is why this is watched every service pass and not only at power-on.
  _G.rf2.modelName = "ALZRC Devil 380"
  run(ZD, 12)
  flight(ZD, 40)

  local a, b = lines()[2], lines()[3]
  H.eq(column(ZD, a, "craft"), "Omphobby M7R")
  H.eq(column(ZD, b, "craft"), "ALZRC Devil 380",
       "both flights logged as the same aircraft: " .. b)
end)

H.test("the craft is written even when it matches the model slot", function()
  -- It used to be suppressed in that case, to avoid repeating the column
  -- beside it - which made an empty cell mean two different things: "nothing
  -- named this aircraft" and "its name happens to match the slot". A real log
  -- came back with the craft column blank on every row of an aircraft the
  -- flight controller had named perfectly well.
  local ZD = fresh(withFc("OMP M4 Max", "OMP M4 Max"))
  flight(ZD, 40)
  local rec = lines()[2]
  H.eq(column(ZD, rec, "craft"), "OMP M4 Max",
       "the flight controller named it and the log dropped it: " .. rec)
end)

H.test("a craft with no flight controller name still logs the flight", function()
  local ZD = fresh(loaded)                  -- no RF Tool at all
  flight(ZD, 40)
  local rec = lines()[2]
  H.eq(column(ZD, rec, "craft"), "", "invented a craft name from nowhere")
  H.eq(column(ZD, rec, "model"), "GOBLIN 700", "and the slot name carries it")
end)


end
