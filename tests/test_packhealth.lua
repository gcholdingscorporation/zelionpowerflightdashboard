-- Pack internal resistance, against packs whose resistance is known.
--
-- This is the only kind of test that would have caught the method it replaces.
-- Dividing the flight's voltage sag by its peak current produced a believable
-- 3.5 mOhm on a 12S and a 4x spread of nonsense on a 3S micro - and looked
-- entirely fine on the aircraft that happened to suit it. A synthetic pack with
-- an answer written on the tin is the difference between "the number seems
-- plausible" and "the number is right".

return function(H, Mock, Loader)

local function fresh()
  Mock.reset()
  Mock.removeRf2()
  Mock.addSensor("Vcel", 1, 4.10)
  Mock.addSensor("Vbat", 1, 49.2)
  Mock.addSensor("Curr", 2, 0)
  Mock.addSensor("Hspd", 18, 1850)   -- rotor turning: armed
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  return ZD
end

-- Fly a pack with a KNOWN per-cell resistance, at a current that moves the way
-- a helicopter's does. `drift` is how far the open-circuit voltage falls over
-- the whole flight, so the depletion the window has to survive is explicit.
local function fly(ZD, seconds, mohm, opts)
  opts = opts or {}
  local swing = opts.swing or 40      -- amps, peak to peak
  local base  = opts.base  or 60
  local vopen = opts.vopen or 4.10
  local drift = opts.drift or 0
  local steps = math.floor(seconds * 10)
  for k = 1, steps do
    local phase = (k % 20) / 20
    local amps  = base + swing * phase
    if opts.constant then amps = base end
    local oc = vopen - drift * (k / steps)
    Mock.setSensor("Curr", amps)
    -- Rounded to 0.01 V, which is what the sensor actually reports. Perfectly
    -- linear synthetic data makes every guard here look unnecessary: a line
    -- through two points is exact however close together they are, and it is
    -- the quantisation that turns a narrow current range into noise.
    local cell = (opts.mohm_at and opts.mohm_at(k, steps) or mohm)
    Mock.setSensor("Vcel", math.floor((oc - amps * cell / 1000) * 100 + 0.5) / 100)
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.PackHealth.service(Mock.state.time)
  end
end

H.group("packhealth: measuring a known pack")

H.test("finds the resistance of a 12S pack that has one", function()
  local ZD = fresh()
  fly(ZD, 60, 3.5, { base = 120, swing = 90 })
  H.truthy(ZD.PackHealth.milliohms ~= nil, "no figure at all after a minute")
  H.near(ZD.PackHealth.milliohms, 3.5, 0.2,
         "got " .. tostring(ZD.PackHealth.milliohms) .. " for a 3.5 mOhm pack")
end)

H.test("finds it on a 3S micro too, which is where the old method failed", function()
  -- Small pack, small currents, short punches. The previous approach spread
  -- 4x here while looking correct on the 12S.
  local ZD = fresh()
  fly(ZD, 60, 18.0, { base = 12, swing = 25, vopen = 4.20 })
  H.truthy(ZD.PackHealth.milliohms ~= nil, "no figure on the micro")
  H.near(ZD.PackHealth.milliohms, 18.0, 1.5,
         "got " .. tostring(ZD.PackHealth.milliohms) .. " for an 18 mOhm pack")
end)

H.test("a tired pack reads higher than a healthy one", function()
  -- The whole point: the number has to MOVE with the pack, not just look
  -- plausible. Same aircraft, same flight, twice the resistance.
  local a = fresh(); fly(a, 60, 3.5, { base = 120, swing = 90 })
  local b = fresh(); fly(b, 60, 7.0, { base = 120, swing = 90 })
  H.truthy(b.PackHealth.milliohms > a.PackHealth.milliohms * 1.6,
           string.format("healthy %.1f vs tired %.1f - the trend is the feature",
                         a.PackHealth.milliohms, b.PackHealth.milliohms))
end)

H.test("draining the pack does not masquerade as resistance", function()
  -- Open-circuit voltage falls all flight. A regression across the whole
  -- flight would blend that slope into the answer; a short window should not
  -- notice it. 0.35 V/cell is a full flight's worth of depletion.
  local ZD = fresh()
  fly(ZD, 60, 3.5, { base = 120, swing = 90, drift = 0.35 })
  H.near(ZD.PackHealth.milliohms, 3.5, 0.4,
         "depletion leaked into the resistance: got "
         .. tostring(ZD.PackHealth.milliohms))
end)

H.group("packhealth: refusing to answer")

H.test("says nothing when the current never moves", function()
  -- Every point shares one x. The line through them is undefined, and the
  -- arithmetic returns a huge confident number if nothing stops it.
  local ZD = fresh()
  fly(ZD, 60, 3.5, { base = 120, constant = true })
  H.nilv(ZD.PackHealth.milliohms,
         "a hover at fixed throttle cannot measure resistance")
end)

H.test("says nothing when the current barely moves", function()
  -- The realistic version of the guard above, and the one that matters. A
  -- steady hover wobbles the current by a few amps, which is not zero - so the
  -- arithmetic runs, and against a sensor quantised to 0.01 V it returns a
  -- number that is wrong and entirely plausible. Refusing to answer is the
  -- only correct output.
  local ZD = fresh()
  fly(ZD, 60, 3.5, { base = 120, swing = 4 })
  H.nilv(ZD.PackHealth.milliohms,
         "a 4 A wobble cannot measure resistance, but it will happily "
         .. "produce a number: got " .. tostring(ZD.PackHealth.milliohms))
end)

H.test("one bad window does not move the answer", function()
  -- An ESC hitting its own current limit, or a run of glitched frames, makes
  -- one window look like a very different pack. A mean would carry it into the
  -- result; the median should not notice.
  -- The outlier has to be PHYSICALLY POSSIBLE or a different guard eats it
  -- first. The first attempt here used 60 mOhm at 120 A - a seven volt drop -
  -- which the collapse detector rejected outright, so the median was never
  -- tested at all. 15 mOhm at these currents sags the cell about a volt: high,
  -- plausible, and inside every other guard.
  local ZD = fresh()
  fly(ZD, 60, 3.5, {
    base = 60, swing = 45,
    mohm_at = function(k, steps)
      return (k > steps * 0.8) and 15 or 3.5
    end,
  })
  H.truthy(ZD.PackHealth.milliohms ~= nil, "no figure at all")
  H.near(ZD.PackHealth.milliohms, 3.5, 0.3,
         "an outlier window reached the result: got "
         .. tostring(ZD.PackHealth.milliohms))
end)

H.test("says nothing after a flight too short to have windows", function()
  local ZD = fresh()
  fly(ZD, 8, 3.5, { base = 120, swing = 90 })
  H.nilv(ZD.PackHealth.milliohms, "two windows is not a measurement")
end)

H.test("says nothing on the ground", function()
  local ZD = fresh()
  Mock.setSensor("Hspd", 0)
  for _ = 1, 300 do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.PackHealth.service(Mock.state.time)
  end
  H.nilv(ZD.PackHealth.milliohms)
end)

H.test("a window where voltage rose with current is thrown out", function()
  -- Physically impossible: more load cannot mean more volts. It happens when
  -- the two sensors update out of step, and it fits a line with a positive
  -- slope, which is a negative resistance. Nothing downstream would know.
  local ZD = fresh()
  fly(ZD, 60, 3.5, {
    base = 60, swing = 45,
    mohm_at = function(k, steps)
      return (k > steps * 0.8) and -4 or 3.5
    end,
  })
  -- Asserted on the WINDOW COUNT, not on the answer. The median would hide a
  -- minority of impossible windows all by itself, so checking only the result
  -- proves nothing about whether they were rejected - it proves the median
  -- works, which is a different test. A window that fitted a negative
  -- resistance must never have been counted in the first place.
  H.truthy(ZD.PackHealth.windows > 0, "no windows at all")
  H.truthy(ZD.PackHealth.windows <= 16,
           "impossible windows were counted: " .. ZD.PackHealth.windows
           .. " of 20, when only the 16 real ones should stand")
  H.near(ZD.PackHealth.milliohms, 3.5, 0.3, "and the real pack still measured")
end)

H.test("a window that collected nothing at all does not crash", function()
  -- Armed, servicing, and no cell sensor on the model. The window still closes
  -- on its timer with an empty sample list, and fitting a line to no points is
  -- an index into nothing. This is the case the sample-count guard is really
  -- for; the rest of its job is done by the median.
  Mock.reset(); Mock.removeRf2()
  Mock.addSensor("Curr", 2, 90)
  Mock.addSensor("Hspd", 18, 1850)      -- armed, but nothing to measure
  Mock.install()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  for _ = 1, 200 do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.PackHealth.service(Mock.state.time)
  end
  H.nilv(ZD.PackHealth.milliohms)
  H.eq(ZD.PackHealth.windows, 0)
end)

H.test("telemetry dropping out mid-flight neither crashes nor counts", function()
  local ZD = fresh()
  fly(ZD, 40, 3.5, { base = 120, swing = 90 })
  local before, windows = ZD.PackHealth.milliohms, ZD.PackHealth.windows
  Mock.setSensor("Vcel", 3.68, false)          -- link lost, value stale
  for _ = 1, 100 do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.PackHealth.service(Mock.state.time)
  end
  H.eq(ZD.PackHealth.windows, windows, "a dropout is not data")
  H.near(ZD.PackHealth.milliohms, before, 0.01, "and must not move the answer")
end)

H.test("a supply collapse is not a resistance", function()
  -- The rail falls away while the current is doing whatever it was doing. That
  -- is a very steep voltage-against-current slope and a completely fictional
  -- pack, so the readings must be refused rather than fitted.
  local ZD = fresh()
  fly(ZD, 40, 3.5, { base = 120, swing = 90 })
  local before = ZD.PackHealth.milliohms
  local v = 3.90
  for _ = 1, 20 do
    v = v - 0.45
    Mock.setSensor("Vcel", math.max(v, 0))
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.PackHealth.service(Mock.state.time)
  end
  H.truthy(ZD.State.powerLost, "the collapse should have been recognised")
  H.near(ZD.PackHealth.milliohms, before, 0.5,
         "the decay was fitted as a pack resistance")
end)

H.test("each flight measures its own pack", function()
  local ZD = fresh()
  fly(ZD, 60, 3.5, { base = 120, swing = 90 })
  H.truthy(ZD.PackHealth.milliohms ~= nil)
  Mock.setSensor("Hspd", 0)                 -- land
  for _ = 1, 100 do
    Mock.advanceSeconds(0.1)
    ZD.State.service(Mock.state.time)
    ZD.PackHealth.service(Mock.state.time)
  end
  H.nilv(ZD.PackHealth.milliohms, "the next pack starts from nothing")
end)

end
