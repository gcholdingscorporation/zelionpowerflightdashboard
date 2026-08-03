-- Dashboard renderer, against a recording LVGL mock.
--
-- The mock does not draw; it records objects and property writes. That is
-- enough to check what got built, what values reached the screen, and that an
-- unchanged frame writes nothing - which is the entire point of retained mode.

return function(H, Mock, Loader)

local function boot(w, h, setup)
  Mock.reset()
  Mock.removeRf2()
  Mock.state.lcdW, Mock.state.lcdH = w or 800, h or 480
  if setup then setup() end
  Mock.install()
  Mock.installLvgl()
  Mock.installLogos()
  local ZD = Loader.load()
  ZD.State.reloadModel()
  Mock.advanceSeconds(0.2)
  ZD.State.service(Mock.state.time)
  return ZD
end

local function flying()
  Mock.addSensor("Hspd", 18, 1850)
  Mock.addSensor("Vcel", 1, 3.94)
  Mock.addSensor("Vbat", 1, 47.3)
  Mock.addSensor("Bat%", 13, 68)
  Mock.addSensor("Curr", 2, 42)
  Mock.addSensor("Tesc", 11, 71)
  Mock.addSensor("Vbec", 1, 8.1)
  Mock.addSensor("Gov", nil, 4)
  Mock.addSensor("Capa", 14, 1240)
end

H.group("dashboard: build")

H.test("builds the dashboard at 800x480", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false)
  H.eq(ZD.Dashboard.mode(), "dash")
  local t = Mock.lvglText()
  H.truthy(string.find(t, "BATTERY", 1, true), "battery tile present")
  H.truthy(string.find(t, "HEADSPEED", 1, true), "headspeed tile present")
  H.truthy(string.find(t, "GOVERNOR", 1, true), "governor present")
end)

H.test("builds the dashboard at 480x320", function()
  local ZD = boot(480, 320, flying)
  ZD.Dashboard.build(false)
  H.truthy(string.find(Mock.lvglText(), "HEADSPEED", 1, true))
end)

H.test("uses the right logo asset for each screen", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false)
  H.truthy(string.find(table.concat(Mock.lvglImages(), "|"), "logo_panel.png", 1, true))

  ZD = boot(480, 320, flying)
  ZD.Dashboard.build(false)
  -- The TX15 gets the 153px lockup, not the 800px one scaled down.
  H.truthy(string.find(table.concat(Mock.lvglImages(), "|"), "logo_small.png", 1, true))
end)

H.group("dashboard: values")

H.test("live telemetry reaches the screen", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "1850", 1, true), "headspeed")
  H.truthy(string.find(t, "68",   1, true), "battery percent")
  H.truthy(string.find(t, "3.94", 1, true), "cell voltage")
  H.truthy(string.find(t, "47.3", 1, true), "pack voltage")
  H.truthy(string.find(t, "ACTIVE", 1, true), "governor state")
end)

H.test("a missing sensor reads as -- rather than zero", function()
  local ZD = boot(800, 480, function()
    Mock.addSensor("Hspd", 18, 1850)
  end)
  ZD.Dashboard.build(false)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "1850", 1, true), "what we do have is shown")
  H.truthy(string.find(t, "--", 1, true), "what we do not have is blank, not 0")
  H.falsy(string.find(t, "|0|", 1, true), "no fabricated zeroes")
end)

H.test("session extremes appear in the footers", function()
  local ZD = boot(800, 480, flying)
  Mock.setSensor("Hspd", 2150)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  Mock.setSensor("Hspd", 1850)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  ZD.Dashboard.build(false)
  H.truthy(string.find(Mock.lvglText(), "MAX 2150", 1, true))
end)

H.test("sag is the drop from the flight's best cell voltage", function()
  local ZD = boot(800, 480, flying)      -- starts at 3.94
  Mock.setSensor("Vcel", 3.62)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  ZD.Dashboard.build(false)
  H.truthy(string.find(Mock.lvglText(), "SAG 0.32", 1, true))
end)

H.group("dashboard: battery gauge")

H.test("fill height tracks the percentage", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false)
  local function fillH()
    for _, o in ipairs(Mock.lv.objects) do
      if o.kind == "rect" and o.props.rounded == 5 and o.props.filled == 1
         and o.props.w and o.props.w < 100 and o.props.h and o.props.h > 1 then
        return o.props.h
      end
    end
  end
  local at68 = fillH()
  H.truthy(at68 and at68 > 0, "gauge has a fill")

  Mock.setSensor("Bat%", 20)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  ZD.Dashboard.build(false)
  H.truthy(fillH() < at68, "a flatter pack draws a shorter bar")
end)

H.test("missing artwork falls back to type and says so", function()
  local ZD = boot(800, 480, flying)
  Mock.state.files["/WIDGETS/ZelionDash/logo_panel.png"] = nil
  ZD.Dashboard.build(false, 800, 480)
  H.truthy(ZD.Dashboard.logoMissing)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "ZELION", 1, true), "wordmark stands in for the image")
  H.truthy(string.find(t, "LOGO PNG MISSING", 1, true),
           "a silently absent image is the likeliest first-run mistake")
end)

H.group("dashboard: host constant lookup")

H.test("resolves constants published through the read-only lookup", function()
  -- The radio does not put its constants in _G raw. A rawget-only lookup
  -- silently yields 0 for every font and alignment, which on hardware renders
  -- the whole dashboard in the default font, left-aligned, with no error.
  Mock.reset()
  Mock.removeRf2()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  flying()
  Mock.install()
  Mock.installLvgl()
  Mock.installLogos()
  Mock.hideConstants()
  local ZD = Loader.load()

  H.truthy(ZD.Theme.font.mid ~= 0, "MIDSIZE must resolve")
  H.truthy(ZD.Theme.font.huge ~= 0, "the hero font must resolve")

  ZD.State.reloadModel()
  Mock.advanceSeconds(0.2)
  ZD.State.service(Mock.state.time)
  ZD.Dashboard.build(false, 800, 480)

  local centred, sized = false, false
  for _, o in ipairs(Mock.lv.objects) do
    if o.kind == "label" then
      if (o.props.align or 0) ~= 0 then centred = true end
      if (o.props.font  or 0) ~= 0 then sized   = true end
    end
  end
  Mock.restoreConstants()
  H.truthy(centred, "centred labels must actually be centred")
  H.truthy(sized,   "sized labels must actually be sized")
end)

H.test("host API also survives the read-only lookup", function()
  Mock.reset()
  Mock.state.lcdW, Mock.state.lcdH = 800, 480
  Mock.addSensor("Hspd", 18, 1850)
  Mock.install()
  Mock.hideConstants()
  local ZD = Loader.load()
  H.eq(ZD.Host.lcdW, 800, "LCD_W comes through the same lookup")
  ZD.State.reloadModel()
  Mock.advanceSeconds(0.2)
  ZD.State.service(Mock.state.time)
  Mock.restoreConstants()
  H.eq(ZD.State.num("headspeed"), 1850, "telemetry still reads")
end)

H.group("dashboard: widget zone")

H.test("lays out against the zone, not the screen", function()
  -- The zone is only the whole screen in a full-screen slot. Laying out
  -- against LCD_W/LCD_H clips the dashboard at the zone edge.
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false, 480, 320)
  for _, o in ipairs(Mock.lv.objects) do
    if o.props.x and o.props.w then
      H.truthy(o.props.x + o.props.w <= 480,
               "object escaped the zone: x=" .. o.props.x .. " w=" .. o.props.w)
    end
  end
end)

H.test("a zone too small says so instead of drawing a mess", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false, 300, 180)
  H.eq(ZD.Dashboard.mode(), "toosmall")
  local t = Mock.lvglText()
  H.truthy(string.find(t, "FULL SCREEN", 1, true))
  H.truthy(string.find(t, "300x180", 1, true), "reports the actual zone size")
end)

H.test("update is inert on the too-small screen", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false, 300, 180)
  local before = Mock.lv.sets
  ZD.Dashboard.update()
  H.eq(Mock.lv.sets, before)
end)

H.group("dashboard: standby")

H.test("no telemetry at all means standby", function()
  local ZD = boot(800, 480)
  H.truthy(ZD.Dashboard.shouldStandby())
  ZD.Dashboard.build(true)
  H.eq(ZD.Dashboard.mode(), "standby")
  local t = Mock.lvglText()
  H.truthy(string.find(t, "WAITING FOR TELEMETRY", 1, true))
  H.truthy(string.find(table.concat(Mock.lvglImages(), "|"), "logo_standby.png", 1, true))
end)

H.test("any live flight value leaves standby", function()
  local ZD = boot(800, 480, flying)
  H.falsy(ZD.Dashboard.shouldStandby())
end)

H.test("a mid-flight dropout does NOT fall back to standby", function()
  local ZD = boot(800, 480, flying)
  H.falsy(ZD.Dashboard.shouldStandby())

  -- Everything goes stale at once, but RF Tool still reports a live link.
  for _, n in ipairs({"Hspd","Vcel","Vbat","Bat%","Curr","Tesc","Vbec","Gov","Capa"}) do
    Mock.setSensor(n, 0, false)
  end
  ZD.State.linkConnected = true
  Mock.advanceSeconds(0.3); ZD.State.service(Mock.state.time)
  ZD.State.linkConnected = true
  H.falsy(ZD.Dashboard.shouldStandby(),
          "blanking the screen during a dropout is exactly wrong")
end)

H.group("dashboard: retained mode")

H.test("an unchanged frame writes nothing to the host", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false)
  ZD.Dashboard.update()          -- settle
  local before = Mock.lv.sets
  ZD.Dashboard.update()
  ZD.Dashboard.update()
  H.eq(Mock.lv.sets, before, "identical values must not touch any object")
end)

H.test("a changed value writes, and only then", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false)
  ZD.Dashboard.update()
  local before = Mock.lv.sets

  Mock.setSensor("Hspd", 1900)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  ZD.Dashboard.update()
  H.truthy(Mock.lv.sets > before, "a real change must reach the screen")
  H.truthy(string.find(Mock.lvglText(), "1900", 1, true))
end)

H.test("building does not leak objects from the previous screen", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(false)
  local n = #Mock.lv.objects
  ZD.Dashboard.build(false)
  H.eq(#Mock.lv.objects, n, "rebuild clears first")
  H.truthy(Mock.lv.cleared >= 2)
end)

end
