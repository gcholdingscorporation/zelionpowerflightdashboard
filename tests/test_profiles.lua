-- Aircraft profile: what the widget assumes it is bolted to.
--
-- A profile decides which readings are plausible, what headspeed counts as
-- flying, and when the ESC is too hot. Every one of those is silent when
-- wrong, which is what these tests are for.

return function(H, Mock, Loader)

local function fresh(setup)
  Mock.reset()
  Mock.removeRf2()
  if setup then setup() end
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  ZD.Alerts.reset()
  -- Past the detection settle window. One reading is not a measurement, and
  -- a radio sits with the pack connected for seconds before anything happens.
  for _ = 1, 40 do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
  end
  return ZD
end

-- Stepped, the way the widget services it. The alert engine measures its
-- settle window across service passes, so one big jump in time is not the
-- same thing at all.
local function run(ZD, seconds)
  for _ = 1, math.floor(seconds * 10) do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.Alerts.service(Mock.state.time)
  end
end

-- A 700-size on 6S, and a 200-size on 2S. The pack voltage is the only thing
-- distinguishing them, which is the point.
local function big()
  Mock.addSensor("Hspd", 18, 1850)
  Mock.addSensor("Vbat", 1, 24.6)
  Mock.addSensor("Curr", 2, 60)
end

local function small()
  Mock.addSensor("Hspd", 18, 5000)
  Mock.addSensor("Vbat", 1, 7.9)
  Mock.addSensor("Curr", 2, 3)
end

H.group("profiles: choosing one")

H.test("a 6S pack reads as the large heli", function()
  local ZD = fresh(big)
  H.eq(ZD.Profiles.current().id, "rotorflight")
  H.eq(ZD.Profiles.how(), "auto")
end)

H.test("a 2S pack reads as the small one", function()
  local ZD = fresh(small)
  H.eq(ZD.Profiles.current().id, "osf03")
  H.eq(ZD.Profiles.how(), "auto")
end)

H.test("a 3S pack is still the small one", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 5000)
    Mock.addSensor("Vbat", 1, 12.4)
  end)
  H.eq(ZD.Profiles.current().id, "osf03")
end)

H.test("no pack voltage yet means no profile, not a guess", function()
  -- Narrowing the windows against an aircraft nobody has seen is how a real
  -- reading gets thrown away on the first pass.
  local ZD = fresh(function() Mock.addSensor("Hspd", 18, 0) end)
  H.nilv(ZD.Profiles.current())
  H.eq(ZD.Profiles.how(), "waiting")
  H.eq(ZD.Profiles.label(), "--")
end)

H.test("the option overrules detection", function()
  local ZD = fresh(big)
  H.eq(ZD.Profiles.current().id, "rotorflight", "detected first")
  ZD.Profiles.set(ZD.Profiles.SMALL)
  H.eq(ZD.Profiles.current().id, "osf03", "and the pilot overrode it")
  H.eq(ZD.Profiles.how(), "set")
end)

H.test("a garbage option value falls back to auto", function()
  local ZD = fresh(big)
  ZD.Profiles.set(7)
  H.eq(ZD.Profiles.selected, ZD.Profiles.AUTO)
end)

H.test("detection latches against a brownout", function()
  -- A pack dipping through the boundary must not reclassify the aircraft
  -- mid-flight and move every threshold underneath the pilot.
  local ZD = fresh(big)
  H.eq(ZD.Profiles.current().id, "rotorflight")
  Mock.setSensor("Vbat", 9.0)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  H.eq(ZD.Profiles.current().id, "rotorflight", "still the same helicopter")
end)

H.test("changing model re-detects", function()
  local ZD = fresh(big)
  H.eq(ZD.Profiles.current().id, "rotorflight")
  Mock.state.modelName = "LITTLE ONE"
  Mock.setSensor("Vbat", 7.9)
  run(ZD, 4)                            -- detection settles again
  H.eq(ZD.Profiles.current().id, "osf03", "the other heli on the bench")
end)

H.group("profiles: what it changes")

H.test("a current a 200-size could not pull is rejected", function()
  local ZD = fresh(small)
  Mock.setSensor("Curr", 300)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  H.falsy(ZD.State.valid("current"), "300A on a 2S 400mAh is a bad frame")
  H.eq(ZD.State.status("current"), "insane")
end)

H.test("the same current is fine on the big heli", function()
  local ZD = fresh(big)
  Mock.setSensor("Curr", 300)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  H.truthy(ZD.State.valid("current"), "a 700 pulls that")
end)

H.test("a rejected reading does not become a session peak", function()
  -- The whole reason the windows exist: an extreme is written to the flight
  -- log and there is no second chance at it.
  local ZD = fresh(small)
  Mock.setSensor("Curr", 300)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  H.truthy((ZD.State.max("current") or 0) < 100, "peak untouched by the glitch")
end)

H.test("with no profile the wide role window still applies", function()
  local ZD = fresh(function()
    Mock.addSensor("Hspd", 18, 0)
    Mock.addSensor("Curr", 2, 300)
  end)
  H.nilv(ZD.Profiles.current())
  H.truthy(ZD.State.valid("current"), "nothing known, so nothing rejected")
end)

H.test("a profile only tightens, never widens", function()
  local ZD = fresh(small)
  Mock.setSensor("Vbat", 90)          -- past the role's own 72V ceiling
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  H.falsy(ZD.State.valid("packVoltage"))
end)

H.group("profiles: arming thresholds")

-- Started from a stopped rotor in each case: spunUp latches, so a test that
-- begins mid-flight is testing the landing delay instead of the trigger.
local function stopped(volts)
  return function()
    Mock.addSensor("Hspd", 18, 0)
    Mock.addSensor("Vbat", 1, volts)
  end
end

H.test("a 200-size spool-up is not a flight at 250 rpm", function()
  local ZD = fresh(stopped(7.9))
  Mock.setSensor("Hspd", 300)
  run(ZD, 1)
  H.falsy(ZD.State.armed, "300 rpm on a heli that flies at 5000 is spooling")
end)

H.test("and is a flight once the head is really turning", function()
  local ZD = fresh(stopped(7.9))
  Mock.setSensor("Hspd", 4800)
  run(ZD, 1)
  H.truthy(ZD.State.armed)
  H.eq(ZD.State.armSource, "rotor")
end)

H.test("the big heli keeps the thresholds it was proven at", function()
  local ZD = fresh(stopped(24.6))
  H.eq(ZD.Profiles.current().spinUp, 250)
  Mock.setSensor("Hspd", 300)
  run(ZD, 1)
  H.truthy(ZD.State.armed, "300 rpm on a 700 is the head turning")
end)

H.group("profiles: thresholds and who wins")

H.test("the small heli gets a lower ESC alert", function()
  local ZD = fresh(small)
  H.eq(ZD.Profiles.setting("alertEsc"), 90)
end)

H.test("the big heli keeps the higher one", function()
  local ZD = fresh(big)
  H.eq(ZD.Profiles.setting("alertEsc"), 110)
end)

H.test("sensors.cfg beats the profile", function()
  -- Someone who wrote a threshold down meant it. A profile inferred from pack
  -- voltage does not get to overrule that.
  local ZD = fresh(function()
    small()
    Mock.writeFile("/WIDGETS/ZelionDash/sensors.cfg",
      "[battery]\nalertEsc = 70\n")
  end)
  H.eq(ZD.Profiles.setting("alertEsc"), 70)
end)

H.test("and the alert engine actually fires at the profile's figure", function()
  local ZD = fresh(function()
    small()
    Mock.addSensor("Tesc", 11, 30)
  end)
  run(ZD, 6)                          -- past the settle window
  Mock.played = {}
  Mock.setSensor("Tesc", 95)          -- over 90, under the large heli's 110
  run(ZD, 2)
  H.truthy(#Mock.played > 0, "a 200-size ESC at 95C is in trouble")
end)

H.test("and stays quiet at the same temperature on the big heli", function()
  local ZD = fresh(function()
    big()
    Mock.addSensor("Tesc", 11, 30)
  end)
  run(ZD, 6)
  Mock.played = {}
  Mock.setSensor("Tesc", 95)
  run(ZD, 2)
  H.eq(#Mock.played, 0, "95C is a normal day for a 700's ESC")
end)

H.test("cell voltage is chemistry and does not move with the aircraft", function()
  local big_, small_ = fresh(big), nil
  local a = big_.Config.setting("alertCell")
  small_ = fresh(small)
  H.eq(small_.Config.setting("alertCell"), a, "3.4V is 3.4V on any pack")
end)

H.group("profiles: a decision made on one bad reading")

-- Found in the field. A 12S M7R came up reading low for a moment, latched as
-- a 200-size, and then spent the flight rejecting its own pack voltage and
-- capacity as out of range - the windows doing exactly their job, aimed at
-- the wrong aircraft.

H.test("a low reading during power-up does not decide the aircraft", function()
  local ZD
  Mock.reset(); Mock.removeRf2()
  Mock.addSensor("Hspd", 18, 0)
  Mock.addSensor("Vbat", 1, 11.9)      -- the BEC rail, before the pack reports
  Mock.install()
  ZD = Loader.load(); ZD.State.reloadModel()
  run(ZD, 0.5)
  H.nilv(ZD.Profiles.current(), "nothing decided on half a second")

  Mock.setSensor("Vbat", 49.6)          -- the pack, once it is really talking
  run(ZD, 5)
  H.eq(ZD.Profiles.current().id, "rotorflight",
       "the peak is the honest figure, not the first sample")
end)

H.test("the peak wins even if the low reading comes back", function()
  local ZD
  Mock.reset(); Mock.removeRf2()
  Mock.addSensor("Hspd", 18, 0)
  Mock.addSensor("Vbat", 1, 49.6)
  Mock.install()
  ZD = Loader.load(); ZD.State.reloadModel()
  run(ZD, 1)
  Mock.setSensor("Vbat", 8.0)           -- a dropout mid-settle
  run(ZD, 5)
  H.eq(ZD.Profiles.current().id, "rotorflight",
       "a pack coming up can read too low, never too high")
end)

H.group("profiles: noticing it got it wrong")

H.test("a profile that keeps rejecting real readings gives up", function()
  -- The symptom in the field was a dashboard quietly showing "out of range"
  -- for an aircraft that was working perfectly. Nothing else notices: the
  -- windows are silent by design.
  local ZD = fresh(small)
  H.eq(ZD.Profiles.current().id, "osf03", "wrongly, as it happens")

  -- The real aircraft: a 12S pack, well past the small profile's 13.5V.
  Mock.setSensor("Vbat", 49.6)
  run(ZD, 5)

  H.eq(ZD.Profiles.current().id, "rotorflight", "corrected itself")
  H.truthy(ZD.State.valid("packVoltage"), "and the reading is accepted again")
end)

H.test("it says so afterwards rather than hiding the correction", function()
  local ZD = fresh(small)
  Mock.setSensor("Vbat", 49.6)
  run(ZD, 5)
  H.eq(ZD.Profiles.how(), "auto*",
       "a stretch of missing readings deserves an explanation")
end)

H.test("one glitched frame does not undo a correct decision", function()
  -- Which is the whole reason the windows exist. Rejections have to be
  -- consecutive: two seconds of them at 10 Hz is a mismatch, not a glitch.
  local ZD = fresh(small)
  Mock.setSensor("Vbat", 49.6)
  run(ZD, 0.2)                          -- a couple of bad frames
  Mock.setSensor("Vbat", 7.9)
  run(ZD, 3)
  H.eq(ZD.Profiles.current().id, "osf03", "still the small heli")
end)

H.test("a profile the pilot set is never second-guessed", function()
  -- They may be deliberately clamping an aircraft this would classify
  -- differently, and overriding that would be the widget arguing back.
  local ZD = fresh(small)
  ZD.Profiles.set(ZD.Profiles.SMALL)
  Mock.setSensor("Vbat", 49.6)
  run(ZD, 5)
  H.eq(ZD.Profiles.current().id, "osf03", "their choice stands")
  H.eq(ZD.Profiles.how(), "set")
end)

end
