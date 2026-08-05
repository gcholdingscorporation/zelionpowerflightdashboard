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
  ZD.Dashboard.build()
  H.eq(ZD.Dashboard.mode(), "dash")
  local t = Mock.lvglText()
  H.truthy(string.find(t, "BATTERY", 1, true), "battery tile present")
  H.truthy(string.find(t, "HEADSPEED", 1, true), "headspeed tile present")
  H.truthy(string.find(t, "GOVERNOR", 1, true), "governor present")
end)

H.test("builds the dashboard at 480x320", function()
  local ZD = boot(480, 320, flying)
  ZD.Dashboard.build()
  H.truthy(string.find(Mock.lvglText(), "HEADSPEED", 1, true))
end)

H.test("uses the right logo asset for each screen", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build()
  H.truthy(string.find(table.concat(Mock.lvglImages(), "|"), "logo_panel.png", 1, true))

  ZD = boot(480, 320, flying)
  ZD.Dashboard.build()
  -- The TX15 gets the 153px lockup, not the 800px one scaled down.
  H.truthy(string.find(table.concat(Mock.lvglImages(), "|"), "logo_small.png", 1, true))
end)

H.group("dashboard: values")

H.test("live telemetry reaches the screen", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build()
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
  ZD.Dashboard.build()
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
  ZD.Dashboard.build()
  H.truthy(string.find(Mock.lvglText(), "MAX 2150", 1, true))
end)

H.test("sag is the drop from the flight's best cell voltage", function()
  local ZD = boot(800, 480, flying)      -- starts at 3.94
  -- The rotor is turning in this fixture, so the first service pass arms and
  -- resets the extremes. Sag is measured from the best voltage seen *during*
  -- the flight, so let one pass land after that.
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  Mock.setSensor("Vcel", 3.62)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  ZD.Dashboard.build()
  H.truthy(string.find(Mock.lvglText(), "SAG 0.32", 1, true))
end)

H.group("dashboard: battery gauge")

H.test("fill height tracks the percentage", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build()
  -- Identify the gauge fill by its layout geometry rather than by guessing at
  -- its shape: panels are filled rectangles too now.
  local L = ZD.Layout.build(800, 480)
  local function fillH()
    for _, o in ipairs(Mock.lv.objects) do
      if o.kind == "rect" and o.props.x == L.bar.x + 3
         and o.props.w == L.bar.w - 6 then
        return o.props.h
      end
    end
  end
  local at68 = fillH()
  H.truthy(at68 and at68 > 0, "gauge has a fill")

  Mock.setSensor("Bat%", 20)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  ZD.Dashboard.build()
  H.truthy(fillH() < at68, "a flatter pack draws a shorter bar")
end)

H.test("missing artwork falls back to type and says so", function()
  local ZD = boot(800, 480, function()
    flying()
    Mock.noDefaultLogos = true
    Mock.state.files["/WIDGETS/ZelionDash/logo_standby.png"] = "PNG"
    Mock.state.files["/WIDGETS/ZelionDash/logo_small.png"]   = "PNG"
  end)
  ZD.Dashboard.build(800, 480)
  H.truthy(ZD.Dashboard.logoMissing)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "ZELION", 1, true), "wordmark stands in for the image")
  H.truthy(string.find(t, "NO IMAGE: /WIDGETS/ZelionDash/logo_panel.png", 1, true),
           "a silently absent image is the likeliest first-run mistake")
end)

H.test("finds the artwork in a differently named widget folder", function()
  -- EdgeTX names a widget from its Lua table, not its folder, so the folder
  -- can legitimately be called something else on any given card - the first
  -- radio this ran on used "zelion".
  local ZD = boot(800, 480, function()
    flying()
    Mock.noDefaultLogos = true
    Mock.state.files["/WIDGETS/zelion/logo_panel.png"]   = "PNG"
    Mock.state.files["/WIDGETS/zelion/logo_standby.png"] = "PNG"
    Mock.state.files["/WIDGETS/zelion/logo_small.png"]   = "PNG"
  end)
  ZD.Dashboard.build(800, 480)
  H.eq(ZD.Host.widgetDir(), "/WIDGETS/zelion/")
  H.falsy(ZD.Dashboard.logoMissing, "artwork found, so nothing to report")
  H.truthy(string.find(table.concat(Mock.lvglImages(), "|"),
                       "/WIDGETS/zelion/logo_panel.png", 1, true))
end)

H.test("a rebuild does not re-open the artwork", function()
  -- Bitmap.open allocates. Probing on every rebuild, on top of the copy
  -- lvgl.image loads, exhausted the radio's Lua heap and put the transmitter
  -- into emergency mode.
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(800, 480)
  local after = Mock.bitmapOpens
  for _ = 1, 10 do ZD.Dashboard.build(800, 480) end
  H.eq(Mock.bitmapOpens, after, "probe results must be cached, not re-taken")
end)

H.test("no rectangle is ever drawn with an impossible corner radius", function()
  -- A radius greater than half the shorter side cannot be drawn and can fault
  -- the renderer natively. The gauge fill is one pixel tall at 0%, and was
  -- being created with a radius of 5.
  local ZD = boot(800, 480, flying)
  for _, pct in ipairs({ 0, 1, 50, 100 }) do
    Mock.setSensor("Bat%", pct)
    Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
    ZD.Dashboard.build(800, 480)
    ZD.Dashboard.update()
    for _, o in ipairs(Mock.lv.objects) do
      if o.kind == "rect" and (o.props.rounded or 0) > 0 then
        local limit = math.floor(math.min(o.props.w, o.props.h) / 2)
        H.truthy(o.props.rounded <= limit,
                 string.format("radius %d on a %dx%d rect at %d%%",
                               o.props.rounded, o.props.w, o.props.h, pct))
      end
    end
  end
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
  ZD.Dashboard.build(800, 480)

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
  ZD.Dashboard.build(480, 320)
  for _, o in ipairs(Mock.lv.objects) do
    if o.props.x and o.props.w then
      H.truthy(o.props.x + o.props.w <= 480,
               "object escaped the zone: x=" .. o.props.x .. " w=" .. o.props.w)
    end
  end
end)

H.test("a zone too small says so instead of drawing a mess", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(300, 180)
  H.eq(ZD.Dashboard.mode(), "toosmall")
  local t = Mock.lvglText()
  H.truthy(string.find(t, "FULL SCREEN", 1, true))
  H.truthy(string.find(t, "300x180", 1, true), "reports the actual zone size")
end)

H.test("update is inert on the too-small screen", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(300, 180)
  local before = Mock.lv.sets
  ZD.Dashboard.update()
  H.eq(Mock.lv.sets, before)
end)

H.group("dashboard: retained mode")

H.test("an unchanged frame writes nothing to the host", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build()
  ZD.Dashboard.update()          -- settle
  local before = Mock.lv.sets
  ZD.Dashboard.update()
  ZD.Dashboard.update()
  H.eq(Mock.lv.sets, before, "identical values must not touch any object")
end)

H.test("a changed value writes, and only then", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build()
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
  ZD.Dashboard.build()
  local n = #Mock.lv.objects
  ZD.Dashboard.build()
  H.eq(#Mock.lv.objects, n, "rebuild clears first")
  H.truthy(Mock.lv.cleared >= 2)
end)

--------------------------------------------------------------------------
-- Fonts
--------------------------------------------------------------------------
--
-- This is the bug that put the transmitter into EMERGENCY MODE. EdgeTX stores
-- the font in bits 8..11 of a text flag as an enumerated INDEX, and BOLD is
-- index 1 - a font, not a modifier. Every `size + BOLD` in the renderer was
-- therefore arithmetic that landed on some other font, and XXLSIZE + BOLD
-- landed on index 7, one past the end of EdgeTX 2.11's seven-entry font table.
-- etx_font() indexes that array unchecked, so LVGL got a style read from off
-- the end of it and the radio faulted natively - beneath anything pcall can
-- see.

H.group("dashboard: fonts")

local FONT_MASK_STEP, FONT_STEPS = 256, 16
local function fontIndex(flags)
  return math.floor((tonumber(flags) or 0) / FONT_MASK_STEP) % FONT_STEPS
end

H.test("every font in the ladder is a real EdgeTX font", function()
  local ZD = boot(800, 480, flying)
  for name, flags in pairs(ZD.Theme.font) do
    local idx = fontIndex(flags)
    H.truthy(idx <= ZD.Theme.FONT_MAX_INDEX,
             string.format("Theme.font.%s is index %d, max is %d",
                           name, idx, ZD.Theme.FONT_MAX_INDEX))
  end
end)

H.test("adding two fonts together is what breaks, and is detectable", function()
  local ZD = boot(800, 480, flying)
  local F = ZD.Theme.font
  -- The exact combination that took the radio down. Kept as a test so the
  -- reasoning survives even if every call site is later rewritten.
  H.eq(fontIndex(F.huge + F.smallBold), 7,
       "XXLSIZE + BOLD is index 7 - past the end of the 2.11 font table")
  H.eq(ZD.Theme.safeFont(F.huge + F.smallBold), F.huge,
       "and the guard has to bring it back into range")
end)

H.test("no screen asks LVGL for a font EdgeTX does not have", function()
  -- Not just "did it crash": the guard would hide that. Assert instead that
  -- the guard never had to fire, so a reintroduced `size + BOLD` fails here
  -- rather than silently rendering at the wrong size.
  for _, size in ipairs({ {800, 480}, {480, 320} }) do
    for _, standby in ipairs({ true, false }) do
      local ZD = boot(size[1], size[2], flying)
      ZD.Theme.fontClamps = 0
      ZD.Dashboard.build(size[1], size[2])
      ZD.Dashboard.update()
      H.eq(ZD.Theme.fontClamps, 0,
           string.format("%dx%d %s clamped a font",
                         size[1], size[2], standby and "standby" or "dashboard"))
      for _, o in ipairs(Mock.lv.objects) do
        if o.props.font ~= nil then
          H.truthy(fontIndex(o.props.font) <= ZD.Theme.FONT_MAX_INDEX,
                   "object built with an out-of-range font index")
        end
      end
    end
  end
end)

H.test("safe mode's fonts are legal too", function()
  local ZD = boot(800, 480, flying)
  ZD.Theme.fontClamps = 0
  ZD.Dashboard.buildMinimal(800, 480)
  H.eq(ZD.Theme.fontClamps, 0)
end)

-- Text placement was tuned against a design mock-up whose "small" was 9pt.
-- EdgeTX's SMLSIZE is 23px on a TX16S and XXLSIZE is 102px, so every panel had
-- its header inside its own value and the standby diagnostics printed through
-- the tagline. None of that is visible from a mock that does not draw - unless
-- the real line heights are used to check for it, which is what this does.
-- The span a label's glyphs actually occupy, not the box it was given. A
-- label's width is a bound, and several are deliberately wider than their
-- text: the hero numbers reserve room for their widest possible reading, and
-- their unit sits inside that reservation. Comparing boxes flags those as
-- collisions when nothing overlaps on screen.
local function labelBoxes(ZD)
  local out = {}
  for _, o in ipairs(Mock.lv.objects) do
    local text = o.props.text
    if o.kind == "label" and (text or "") ~= "" then
      local h = ZD.Theme.fontHeight(o.props.font)
      local box = (o.props.w or 0) > 0 and o.props.w or nil
      local tw = ZD.Host.textWidth(text, o.props.font, h)
      if box and tw > box then tw = box end
      local align = (o.props.align or 0)
      local x = o.props.x
      if box then
        if align % 8 >= 4 then          -- CENTER 0x04
          x = x + math.floor((box - tw) / 2)
        elseif align % 16 >= 8 then     -- RIGHT 0x08
          x = x + box - tw
        end
      end
      out[#out + 1] = { x = x, y = o.props.y, w = tw, h = h, t = text }
    end
  end
  return out
end

local function assertNoCollisions(ZD, h, what)
  local boxes = labelBoxes(ZD)
  H.truthy(#boxes > 0, what .. " drew no text at all")
  for i = 1, #boxes do
    local a = boxes[i]
    H.truthy(a.y + a.h <= h,
             string.format("%s: %q runs off the bottom (y%d..%d of %d)",
                           what, a.t, a.y, a.y + a.h, h))
    for j = i + 1, #boxes do
      local b = boxes[j]
      if a.x < b.x + b.w and b.x < a.x + a.w
         and a.y < b.y + b.h and b.y < a.y + a.h then
        H.truthy(false, string.format("%s: %q (y%d..%d) overlaps %q (y%d..%d)",
                 what, a.t, a.y, a.y + a.h, b.t, b.y, b.y + b.h))
      end
    end
  end
end

-- EdgeTX's fonts are subsetted, and a codepoint they do not carry draws as
-- nothing at all - no error, no box, just a gap. The tagline shipped with
-- U+00B7 middle dots as separators and rendered on hardware as
-- "NO HYPE  JUST VOLTAGE  REAL POWER".
--
-- Covered ranges, from the cmap table in the generated
-- radio/src/fonts/lvgl/lrg/lv_font_en_*.c (v2.11.0):
--   32..126    ASCII
--   128..131, 136..148   EdgeTX's own symbol glyphs
--   176        U+00B0 DEGREE SIGN, on its own - which is why "ESC °C" works
--   192..383   Latin-1 upper + Latin Extended-A
--   8226+      a sparse set of 62, starting at U+2022 BULLET
-- Anything outside 32..126 and 176 has to be a deliberate decision, so the
-- test rejects it rather than trying to model the sparse tail.
local function codepoints(s)
  local out, i = {}, 1
  while i <= #s do
    local b = s:byte(i)
    local cp, n
    if b < 0x80 then cp, n = b, 1
    elseif b < 0xE0 then cp, n = (b - 0xC0) * 64 + (s:byte(i + 1) - 0x80), 2
    elseif b < 0xF0 then
      cp = (b - 0xE0) * 4096 + (s:byte(i + 1) - 0x80) * 64 + (s:byte(i + 2) - 0x80)
      n = 3
    else cp, n = -1, 4 end
    out[#out + 1] = cp
    i = i + n
  end
  return out
end

H.group("dashboard: text renders")

H.test("no string uses a glyph EdgeTX's fonts do not carry", function()
  for _, size in ipairs({ {800, 480}, {480, 320} }) do
    for _, standby in ipairs({ false, true }) do
      local ZD = boot(size[1], size[2], flying)
      ZD.RF2.statsStatus, ZD.RF2.totalFlights = "ok", 137
      ZD.RF2.totalFlightSeconds = 40630        -- exercises the flights line
      ZD.Dashboard.build(size[1], size[2])
      ZD.Dashboard.update()
      for _, o in ipairs(Mock.lv.objects) do
        local t = o.props.text
        if o.kind == "label" and t and t ~= "" then
          for _, cp in ipairs(codepoints(t)) do
            H.truthy((cp >= 32 and cp <= 126) or cp == 176,
                     string.format("%q uses U+%04X, which draws as a blank",
                                   t, cp))
          end
        end
      end
    end
  end
end)

H.group("dashboard: text fits")

H.test("no two labels overlap on either radio", function()
  for _, size in ipairs({ {800, 480}, {480, 320} }) do
    local w, h = size[1], size[2]
    for _, standby in ipairs({ false, true }) do
      local ZD = boot(w, h, flying)
      ZD.Dashboard.build(w, h)
      ZD.Dashboard.update()
      assertNoCollisions(ZD, h, string.format("%dx%d %s", w, h,
                                              standby and "standby" or "dashboard"))
    end
  end
end)

H.test("the missing-artwork wordmark does not collide with the panel", function()
  -- When a logo fails to load the mark is replaced by type in the same box.
  -- That is exactly the run where nobody is in a position to notice a layout
  -- bug before shipping it.
  for _, size in ipairs({ {800, 480}, {480, 320} }) do
    local w, h = size[1], size[2]
    Mock.reset(); Mock.removeRf2()
    Mock.state.lcdW, Mock.state.lcdH = w, h
    Mock.noDefaultLogos = true
    Mock.install(); Mock.installLvgl()
    local ZD = Loader.load()
    ZD.State.reloadModel()
    ZD.Dashboard.build(w, h)
    ZD.Dashboard.update()
    Mock.noDefaultLogos = nil
    H.truthy(ZD.Dashboard.logoMissing, "the artwork was supposed to be absent")
    assertNoCollisions(ZD, h, string.format("%dx%d without artwork", w, h))
  end
end)

H.test("a unit follows its number instead of waiting at a fixed offset", function()
  -- "%" a third of a panel away from "68" was the visible symptom. The unit's
  -- x is recomputed from the measured width of the reading, so it closes up on
  -- a short value and steps out for a long one.
  local function unitX(ZD, label)
    for _, o in ipairs(Mock.lv.objects) do
      if o.kind == "label" and o.props.text == label then return o.props.x end
    end
  end

  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(800, 480)

  Mock.setSensor("Bat%", 8)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  ZD.Dashboard.update()
  local narrow = unitX(ZD, "%")

  Mock.setSensor("Bat%", 100)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  ZD.Dashboard.update()
  local wide = unitX(ZD, "%")

  H.truthy(narrow and wide, "the % glyph must exist on the dashboard")
  H.truthy(wide > narrow,
           string.format("100%% should push the unit right of 8%% (%d vs %d)",
                         wide, narrow))

  -- And it has to stay beside the digits, not drift off with them.
  local h = ZD.Theme.fontHeight(ZD.Theme.font.huge)
  local gap = wide - (narrow + ZD.Host.textWidth("100", ZD.Theme.font.huge, h)
                      - ZD.Host.textWidth("8", ZD.Theme.font.huge, h))
  H.truthy(math.abs(gap) < 2, "the gap must be the same at both widths")
end)

H.test("a reading too wide for its tile cannot shove the unit off the edge", function()
  local ZD = boot(800, 480, flying)
  ZD.Dashboard.build(800, 480)
  local L = ZD.Layout.build(800, 480)
  Mock.setSensor("Hspd", 99999)
  Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
  ZD.Dashboard.update()
  assertNoCollisions(ZD, 480, "800x480 with an absurd headspeed")
  for _, o in ipairs(Mock.lv.objects) do
    if o.kind == "label" and o.props.text == "RPM" then
      H.truthy(o.props.x + o.props.w <= L.headspeed.x + L.headspeed.w,
               "the unit stays inside its tile")
    end
  end
end)

H.test("safe mode fits too", function()
  for _, size in ipairs({ {800, 480}, {480, 320} }) do
    local ZD = boot(size[1], size[2], flying)
    ZD.Dashboard.buildMinimal(size[1], size[2])
    assertNoCollisions(ZD, size[2],
                       string.format("%dx%d safe mode", size[1], size[2]))
  end
end)

H.test("the colour and alignment bits survive the guard", function()
  local ZD = boot(800, 480, flying)
  local F = ZD.Theme.font
  -- Colour lives in bits 16+, alignment in bits 0..7. Clamping the font must
  -- not disturb either, or a fix for the crash becomes a rendering bug.
  local colour, align = 0x00AB0000, 0x08
  H.eq(ZD.Theme.safeFont(F.huge + F.smallBold + colour + align),
       F.huge + colour + align)
end)

end
