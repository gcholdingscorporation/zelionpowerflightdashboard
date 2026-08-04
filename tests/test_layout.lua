-- Layout engine: geometry only, no drawing.
--
-- The design is fixed at two anchor sizes, so most of these assertions are
-- against the numbers in tools/render_layout.py. The rest check that an
-- off-anchor screen still produces a sane, non-overlapping layout.

return function(H, Mock, Loader)

local function load(w, h)
  Mock.reset()
  Mock.state.lcdW, Mock.state.lcdH = w, h
  Mock.install()
  return Loader.load()
end

local function overlaps(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w
     and a.y < b.y + b.h and b.y < a.y + a.h
end

local function within(r, w, h)
  return r.x >= 0 and r.y >= 0 and r.x + r.w <= w and r.y + r.h <= h
end

H.group("layout: density classes")

H.test("800x480 is roomy, 480x320 and 480x272 are tight", function()
  local ZD = load(800, 480)
  H.eq(ZD.Layout.classFor(800), "roomy")
  H.eq(ZD.Layout.classFor(480), "tight")
  H.eq(ZD.Layout.classFor(320), "tight")
end)

H.group("layout: 800x480 matches the design")

H.test("columns land on the design coordinates", function()
  local L = load(800, 480).Layout.build(800, 480)
  H.eq(L.cell.x, 10);   H.eq(L.cell.w, 96)
  H.eq(L.battery.x, 116); H.eq(L.battery.w, 390)
  H.eq(L.gov.x, 516);   H.eq(L.gov.w, 274)
end)

H.test("vertical bands land on the design coordinates", function()
  local L = load(800, 480).Layout.build(800, 480)
  H.eq(L.topRule, 40)
  H.eq(L.stripRule, 436)
  H.eq(L.content.y, 46)
  H.eq(L.content.h, 382)
  H.eq(L.cell.y, 46);  H.eq(L.cell.h, 75)
  H.eq(L.bar.y, 129);  H.eq(L.bar.h, 299)
  H.eq(L.gov.h, 86)
  H.eq(L.tiles[1].y, 140); H.eq(L.tiles[1].h, 132)
end)

H.test("three tiles fill the right column exactly", function()
  local L = load(800, 480).Layout.build(800, 480)
  H.eq(L.tiles[1].x, 516)
  H.eq(L.tiles[3].x + L.tiles[3].w, 516 + 274, "row ends flush with the column")
  for i = 1, 2 do
    H.truthy(L.tiles[i].x + L.tiles[i].w <= L.tiles[i+1].x, "tiles must not overlap")
  end
end)

H.group("layout: 480x320 matches the design")

H.test("columns and bands land on the design coordinates", function()
  local L = load(480, 320).Layout.build(480, 320)
  H.eq(L.cell.x, 6);     H.eq(L.cell.w, 64)
  H.eq(L.battery.x, 76); H.eq(L.battery.w, 224)
  H.eq(L.gov.x, 306);    H.eq(L.gov.w, 168)
  H.eq(L.topRule, 28)
  H.eq(L.stripRule, 284)
  H.eq(L.content.y, 34); H.eq(L.content.h, 242)
  H.eq(L.bar.y, 102)
  H.eq(L.tiles[1].w, 54, "narrow tiles are what buys the logo its width")
end)

H.test("the logo gets its full 153px", function()
  local L = load(480, 320).Layout.build(480, 320)
  H.eq(L.logo.w, 153)
  H.eq(L.logo.h, 86)
  H.truthy(L.logo.x >= L.logoBox.x, "centred inside its box")
  H.eq(L.logo.x + L.logo.w <= L.logoBox.x + L.logoBox.w, true)
end)

H.group("layout: structural invariants")

local SIZES = { {800,480}, {480,320}, {480,272}, {800,600}, {1024,600} }

H.test("no region ever escapes the screen", function()
  for _, s in ipairs(SIZES) do
    local L = load(s[1], s[2]).Layout.build(s[1], s[2])
    for _, key in ipairs({"cell","bar","battery","headspeed","gov","logo"}) do
      H.truthy(within(L[key], s[1], s[2]),
               string.format("%s escaped at %dx%d", key, s[1], s[2]))
    end
    for i = 1, 3 do
      H.truthy(within(L.tiles[i], s[1], s[2]),
               string.format("tile %d escaped at %dx%d", i, s[1], s[2]))
    end
  end
end)

H.test("the three columns never overlap each other", function()
  for _, s in ipairs(SIZES) do
    local L = load(s[1], s[2]).Layout.build(s[1], s[2])
    local at = string.format(" at %dx%d", s[1], s[2])
    H.falsy(overlaps(L.cell, L.battery),   "cell/battery overlap" .. at)
    H.falsy(overlaps(L.bar, L.headspeed),  "bar/headspeed overlap" .. at)
    H.falsy(overlaps(L.battery, L.gov),    "hero/right overlap" .. at)
    H.falsy(overlaps(L.headspeed, L.tiles[1]), "hero/tile overlap" .. at)
    H.falsy(overlaps(L.gov, L.tiles[1]),   "gov/tile overlap" .. at)
    H.falsy(overlaps(L.tiles[3], L.logoBox), "tile/logo overlap" .. at)
  end
end)

H.test("stacked regions never overlap vertically", function()
  for _, s in ipairs(SIZES) do
    local L = load(s[1], s[2]).Layout.build(s[1], s[2])
    local at = string.format(" at %dx%d", s[1], s[2])
    H.truthy(L.cell.y + L.cell.h <= L.bar.y, "cell over bar" .. at)
    H.truthy(L.battery.y + L.battery.h <= L.headspeed.y, "battery over headspeed" .. at)
    H.truthy(L.headspeed.y + L.headspeed.h <= L.stripRule, "headspeed clears strip" .. at)
    H.truthy(L.bar.y + L.bar.h <= L.stripRule, "bar clears strip" .. at)
  end
end)

H.test("a shorter screen shrinks panels rather than overflowing", function()
  local tall  = load(480, 320).Layout.build(480, 320)
  local short = load(480, 272).Layout.build(480, 272)
  H.truthy(short.bar.h < tall.bar.h, "gauge absorbs the lost height")
  H.truthy(short.battery.h < tall.battery.h, "hero tiles shrink too")
  H.truthy(short.headspeed.y + short.headspeed.h <= short.stripRule)
end)

H.test("a wider screen grows the hero column, not the side columns", function()
  local a = load(800, 480).Layout.build(800, 480)
  local b = load(1024, 600).Layout.build(1024, 600)
  H.eq(b.cell.w, a.cell.w, "gauge column is fixed width")
  H.eq(b.gov.w, a.gov.w, "right column is fixed width")
  H.truthy(b.battery.w > a.battery.w, "the hero column takes the slack")
end)

H.group("layout: standby")

H.test("logo and text fit inside the screen at both sizes", function()
  for _, s in ipairs({ {800,480}, {480,320} }) do
    local L = load(s[1], s[2]).Layout.buildStandby(s[1], s[2])
    local at = string.format(" at %dx%d", s[1], s[2])
    H.truthy(within(L.logo, s[1], s[2]), "logo escaped" .. at)
    H.truthy(L.logo.y + L.logo.h < L.divider.y, "logo clears the rule" .. at)
    H.truthy(L.status.y + L.status.h <= L.stripRule, "status clears the strip" .. at)
  end
end)

H.test("the standby logo keeps its aspect ratio", function()
  for _, s in ipairs({ {800,480}, {480,320} }) do
    local L = load(s[1], s[2]).Layout.buildStandby(s[1], s[2])
    -- 500x281 asset: distortion would be far more obvious than a small mark.
    H.near(L.logo.w / L.logo.h, 500 / 281, 0.03,
           string.format("aspect drifted at %dx%d", s[1], s[2]))
  end
end)

end
