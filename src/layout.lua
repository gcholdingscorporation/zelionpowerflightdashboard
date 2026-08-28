-- Layer 4: Layout engine.
--
-- Produces a table of {x,y,w,h} regions for the screen the widget is running
-- on. Pure arithmetic and no drawing, so the whole thing is testable off-radio.
--
-- Two density classes rather than one scaled layout. The targets are different
-- shapes, not one shape at two sizes: 800x480 on the TX16S Mk3 against 480x320
-- on the TX15 is 0.60 the width but 0.67 the height, and 40% of the area. More
-- to the point, EdgeTX has a fixed ladder of font sizes, so text cannot shrink
-- continuously - panels have to rearrange instead of scaling.
--
-- Other resolutions in the same class keep the class's fonts and paddings and
-- distribute the leftover height proportionally. tools/dump_screen.lua plus
-- tools/render_screen.py draw whatever this produces, at true resolution and
-- with EdgeTX's own font metrics.

return function(ZD)

local Layout = {}
ZD.Layout = Layout

Layout.ROOMY_MIN_WIDTH = 700

-- Per-class constants. Vertical figures marked "anchor" are the design values
-- at that class's reference height and are scaled when the screen differs.
-- The right column was widened at the hero column's expense. The three tiles
-- were 88px wide on a TX16S, which is barely three digits of MIDSIZE, and the
-- logo sat in a 252px box with the governor cramped above it. Taking that
-- width off the hero costs nothing: the hero only has to fit "1850" and "100",
-- and both still do.
--
-- valShare is the fraction of a hero tile's inner width the big number gets,
-- per tile, because a four-digit headspeed needs more of it than a
-- three-digit percentage. See buildHeroTile.
local CLASS = {
  roomy = {
    name = "roomy", refH = 480,
    pad = 10, gap = 10, barW = 96, rightW = 340,
    topH = 40, stripH = 44, contentGap = 6, stripGap = 8,
    chipH = 75, colGapV = 8,
    heroGapV = 8, batShare = 0.508,
    batValShare = 0.62, hsValShare = 0.78,
    govH = 82, rowGapV = 8, tileH = 110, tileGapH = 3,
    -- The headspeed tile may not be squeezed below this to make the
    -- battery tile line up: an XXLSIZE numeral is 102px on its own.
    minHeroH = 150,
  },
  tight = {
    name = "tight", refH = 320,
    pad = 6, gap = 6, barW = 64, rightW = 190,
    topH = 28, stripH = 36, contentGap = 6, stripGap = 8,
    chipH = 61, colGapV = 7,
    heroGapV = 6, batShare = 0.5,
    batValShare = 0.62, hsValShare = 0.82,
    govH = 52, rowGapV = 7, tileH = 74, tileGapH = 3,
    minHeroH = 108,
  },
}

-- Height over width of the Zelion lockup, from assets/zelion_lockup.png.
-- Everything that places the mark works from this rather than from a pair of
-- pixel dimensions, so the artwork can be regenerated at any size.
local LOGO_ASPECT = 1522 / 2708

local function rect(x, y, w, h)
  return { x = x, y = y, w = w, h = h }
end

local function round(v) return math.floor(v + 0.5) end

function Layout.classFor(w)
  return (w >= Layout.ROOMY_MIN_WIDTH) and "roomy" or "tight"
end

-- Build the layout for a screen. Returns a table of regions plus the class
-- name, so the renderer can pick fonts and decide what to abbreviate.
function Layout.build(w, h)
  local className = Layout.classFor(w)
  local C = CLASS[className]
  local L = { class = className, w = w, h = h, c = C }

  -- Bands
  L.top       = rect(0, 0, w, C.topH)
  L.topRule   = C.topH
  L.stripRule = h - C.stripH
  L.strip     = rect(0, L.stripRule + 1, w, C.stripH - 1)

  local contentTop = C.topH + C.contentGap
  local contentH   = (L.stripRule - C.stripGap) - contentTop
  L.content = rect(0, contentTop, w, contentH)

  -- Columns. Hero width is whatever is left, so the layout adapts to a screen
  -- wider than its anchor without stretching the fixed-width side columns.
  local barX   = C.pad
  local heroX  = barX + C.barW + C.gap
  local rightX = w - C.pad - C.rightW
  local heroW  = rightX - C.gap - heroX
  L.heroTooNarrow = heroW < 160

  -- --- left column: cell chip pinned top, gauge beneath -------------------
  local chipH = C.chipH
  L.cell = rect(barX, contentTop, C.barW, chipH)
  local barY = contentTop + chipH + C.colGapV
  L.bar = rect(barX, barY, C.barW, contentH - chipH - C.colGapV)

  -- --- right column: governor, tile row, logo -----------------------------
  -- Laid out before the hero column, because this side has the hard minimums.
  -- Every height here is a font: the governor holds a word at DBLSIZE, and
  -- each tile holds a title, a reading and a min/max footnote. Squeeze either
  -- and the text collides. The battery tile has no such floor, so it is the
  -- one that gives.
  local govH  = C.govH
  local tileH = C.tileH
  L.gov = rect(rightX, contentTop, C.rightW, govH)

  local tileY = contentTop + govH + C.rowGapV
  local tileW = math.floor((C.rightW - C.tileGapH * 2) / 3)
  L.tiles = {}
  for i = 1, 3 do
    L.tiles[i] = rect(rightX + (tileW + C.tileGapH) * (i - 1), tileY, tileW, tileH)
  end
  -- Give any rounding slack to the last tile so the row ends flush.
  L.tiles[3].w = (rightX + C.rightW) - L.tiles[3].x

  local logoY = tileY + tileH + C.rowGapV
  local logoBox = rect(rightX, logoY, C.rightW, (contentTop + contentH) - logoY)
  L.logoBox = logoBox

  -- --- hero column: battery above, headspeed below ------------------------
  -- The battery tile ends exactly where the tile row ends. Two columns of
  -- data stopping at different heights read as a mistake even when both are
  -- deliberate - the eye lands on that edge before it reads any number.
  --
  -- Derived rather than tuned. Two heights that happen to add up are a pair
  -- of numbers that drifts apart the first time either column changes, and
  -- these had already drifted 18px.
  local heroAvail = contentH - C.heroGapV
  local batH = govH + C.rowGapV + tileH
  if batH > heroAvail - C.minHeroH then batH = heroAvail - C.minHeroH end
  L.battery   = rect(heroX, contentTop, heroW, batH)
  L.headspeed = rect(heroX, contentTop + batH + C.heroGapV, heroW,
                     heroAvail - batH)


  -- The mark fills whatever space is left at its own aspect ratio, never
  -- stretched: an unevenly scaled logo is worse than a slightly smaller one.
  -- Derived from the box rather than from fixed dimensions, so widening the
  -- right column actually grows the logo instead of leaving it adrift in the
  -- middle of a bigger box.
  local lw, lh = logoBox.w, round(logoBox.w * LOGO_ASPECT)
  if lh > logoBox.h then
    lh = logoBox.h
    lw = round(lh / LOGO_ASPECT)
  end
  L.logo = rect(logoBox.x + round((logoBox.w - lw) / 2),
                logoBox.y + round((logoBox.h - lh) / 2), lw, lh)

  return L
end

return Layout

end
