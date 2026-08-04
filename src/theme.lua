-- Layer 5a: Colours and font ladder.
--
-- Zelion lime doubles as the "healthy" state. Brand green and battery-OK green
-- would otherwise be two competing greens on one display; merged, there is
-- exactly one green on screen and it is the brand's. Amber and red stay
-- strictly reserved for a value that needs attention now, so an alarm keeps
-- its meaning.
--
-- Colours are built lazily: lcd.RGB does not exist until the widget is
-- created, so this cannot run at module load.

return function(ZD)

local Theme = {}
ZD.Theme = Theme

-- EdgeTX publishes its constants through a read-only global lookup table
-- rather than as raw entries in _G, so rawget() alone returns nil for every
-- one of them. Missing this silently collapses every font size and alignment
-- to 0: on hardware the dashboard rendered entirely in the default font,
-- left-aligned, with no error anywhere to say why.
local function flag(name, fallback)
  local v = rawget(_G, name)
  if v == nil then v = _G[name] end
  if v == nil then v = fallback end
  return v
end

-- EdgeTX packs the font into bits 8..11 of a text flag as an ENUMERATED INDEX,
-- not as independent bits (radio/src/gui/colorlcd/fonts.h):
--
--   0 STD   1 BOLD   2 TINSIZE   3 SMLSIZE   4 MIDSIZE   5 DBLSIZE   6 XXLSIZE
--
-- BOLD is a font in its own right - standard size, bold weight - and NOT a
-- modifier. Adding it to a size does plain arithmetic inside that field and
-- quietly selects a different font: SMLSIZE + BOLD is MIDSIZE, MIDSIZE + BOLD
-- is DBLSIZE, DBLSIZE + BOLD is XXLSIZE. Every one of those is legal, merely
-- wrong, which is why the mistake survived so long.
--
-- XXLSIZE + BOLD is index 7, and on EdgeTX 2.11 FONTS_COUNT is 7 - so index 7
-- is one past the end. LvglWidgetLabel::setFont calls etx_font(), which does
-- `etx_obj_add_style(obj, styles->font[fontIdx])` against `lv_style_t
-- font[FONTS_COUNT]` with no bounds check, handing LVGL a style read from off
-- the end of the array. That is a native fault, not a Lua error: no pcall can
-- catch it, and the transmitter reboots into EMERGENCY MODE.
--
-- Exactly two labels used XXLSIZE + BOLD - battery percent and headspeed - and
-- both live only on the dashboard. That is why safe mode (DBLSIZE + BOLD, which
-- lands on XXLSIZE) and standby (MIDSIZE + BOLD, which lands on DBLSIZE) both
-- ran fine while every render level that drew the dashboard took the radio down.
--
-- So each entry below is a COMPLETE font selection. Never add two together.
-- DBLSIZE and XXLSIZE are drawn from bold glyph sets already; there is no bold
-- variant of TINSIZE/SMLSIZE/MIDSIZE, which makes BOLD itself the only
-- emphasis available at text sizes.
Theme.font = {
  tiny      = flag("TINSIZE", 0),
  small     = flag("SMLSIZE", 0),
  smallBold = flag("BOLD", 0),      -- STD weight bold: the only small emphasis
  normal    = flag("STDSIZE", 0),
  mid       = flag("MIDSIZE", 0),
  midBold   = flag("MIDSIZE", 0),   -- no bold MIDSIZE exists
  large     = flag("DBLSIZE", 0),   -- already bold
  huge      = flag("XXLSIZE", flag("DBLSIZE", 0)),  -- already bold
}

-- 2.12 appends an eighth font; 2.11 stops at XXLSIZE. Clamping to 6 is correct
-- on both, and the extra one is a nicety nothing here asks for.
Theme.FONT_MAX_INDEX = 6
local FONT_SHIFT, FONT_STEPS = 256, 16

-- Last line of defence, applied to every font that reaches LVGL. A call site
-- that computes a size wrongly gets a cosmetic bug; one that computes an
-- out-of-range index reboots the radio, so the index is clamped rather than
-- trusted. Colour lives in bits 16+ and alignment in bits 0..7, so both pass
-- through untouched.
-- Counts how often it had to intervene. On the radio nobody reads this; in the
-- test suite it is the assertion. Clamping makes a bad font harmless, which
-- would also make a reintroduced `size + BOLD` invisible again - so the tests
-- assert this stays at zero across every screen rather than merely asserting
-- that nothing crashed.
Theme.fontClamps = 0

function Theme.safeFont(flags)
  flags = tonumber(flags) or 0
  local idx = math.floor(flags / FONT_SHIFT) % FONT_STEPS
  if idx <= Theme.FONT_MAX_INDEX then return flags end
  Theme.fontClamps = Theme.fontClamps + 1
  return flags - (idx - Theme.FONT_MAX_INDEX) * FONT_SHIFT
end

--------------------------------------------------------------------------
-- Font metrics
--------------------------------------------------------------------------
--
-- EdgeTX compiles ONE of three font sets into the firmware, chosen by the
-- radio's screen size at build time (radio/src/fonts/CMakeLists.txt): "lrg"
-- for 800x480, "sml" for 320x240, "std" for everything else - which is where
-- the TX15's 480x320 lands. The line heights below are read out of the
-- generated lv_font_en_*.c files in v2.11.0.
--
-- These are far larger than a design mock-up suggests. SMLSIZE is 23px tall on
-- a TX16S, not the ~11px "small" usually means, and XXLSIZE is 102px. Without
-- the real numbers the layout is guesswork, and guessed text positions are how
-- two labels 24px apart ended up on top of each other on hardware.
local FONT_HEIGHTS = {
  --      STD BOLD XXS  XS   L   XL  XXL
  lrg = { [0]=29, 29, 17, 23, 46, 58, 102 },
  std = { [0]=21, 20, 12, 17, 29, 40,  69 },
  sml = { [0]=14, 14, 10, 12, 18, 26,  44 },
}

Theme.metrics = "std"

function Theme.useMetricsFor(w)
  Theme.metrics = ((tonumber(w) or 0) >= 800) and "lrg" or "std"
  return Theme.metrics
end

-- Height of one line in the given font flags, in pixels on the current radio.
function Theme.fontHeight(flags)
  local idx = math.floor((tonumber(flags) or 0) / FONT_SHIFT) % FONT_STEPS
  local set = FONT_HEIGHTS[Theme.metrics] or FONT_HEIGHTS.std
  return set[idx] or set[0]
end

Theme.built = false

function Theme.build()
  if Theme.built then return end
  if type(lcd) ~= "table" or type(lcd.RGB) ~= "function" then return end
  local rgb = lcd.RGB

  -- Navy, not near-black. The three greys have to stay separable on a screen
  -- being read in daylight: track is darker than bg so the empty part of the
  -- gauge reads as a hole, and panel is lighter so a tile lifts off the page.
  --
  -- tools/make_logos.py flattens the artwork onto Theme.bg. Change this and
  -- the PNGs have to be regenerated, or every logo carries a box of the old
  -- background around it.
  Theme.bg     = rgb( 10,  18,  42)
  Theme.panel  = rgb( 18,  30,  62)
  Theme.rule   = rgb( 42,  58, 100)
  Theme.track  = rgb(  6,  11,  28)
  Theme.ink    = rgb(242, 245, 248)
  Theme.dim    = rgb(148, 163, 190)

  -- Brand
  Theme.lime     = rgb(139, 224,  74)
  Theme.limeDark = rgb( 78, 143,  34)
  Theme.steel    = rgb(127, 196, 238)

  -- Status. Reserved: never used for decoration.
  Theme.warn = rgb(245, 179,   1)
  Theme.crit = rgb(239,  68,  68)

  -- Recorded extremes. Deliberately desaturated so a session peak never
  -- reads as a live warning.
  Theme.peak = rgb(185, 154,  74)

  -- Every panel is outlined in the brand green, matching the battery gauge.
  -- That makes green decorative rather than a signal, which is fine as long as
  -- amber and red keep their meaning - so the governor still overrides its
  -- border when the state is one that needs attention.
  Theme.panelBr = Theme.lime

  -- Governor panel backgrounds, keyed by the severity of the state.
  Theme.govRunBg  = rgb( 21,  52,  22)
  Theme.govRunBr  = Theme.lime
  Theme.govWarnBg = rgb( 52,  40,  10)
  Theme.govWarnBr = rgb(160, 118,  20)
  Theme.govCritBg = rgb( 58,  16,  16)
  Theme.govCritBr = rgb(170,  50,  50)
  Theme.govIdleBg = Theme.panel
  Theme.govIdleBr = Theme.lime

  Theme.built = true
end

--------------------------------------------------------------------------
-- Value -> colour
--------------------------------------------------------------------------

function Theme.batteryColor(pct)
  if pct == nil then return Theme.dim end
  if pct >= 50 then return Theme.lime end
  if pct >= 20 then return Theme.warn end
  return Theme.crit
end

-- 3.50V/cell is the conventional "land now" threshold on a LiPo.
function Theme.cellColor(v)
  if v == nil then return Theme.dim end
  if v <= 3.50 then return Theme.crit end
  if v <= 3.65 then return Theme.warn end
  return Theme.ink
end

function Theme.tempColor(c)
  if c == nil then return Theme.dim end
  if c >= 110 then return Theme.crit end
  if c >= 95  then return Theme.warn end
  return Theme.ink
end

function Theme.becColor(v)
  if v == nil then return Theme.dim end
  if v < 4.8 then return Theme.crit end
  if v < 5.1 then return Theme.warn end
  return Theme.ink
end

function Theme.linkColor(pct)
  if pct == nil or pct <= 0 then return Theme.crit end
  if pct >= 60 then return Theme.lime end
  if pct >= 40 then return Theme.warn end
  return Theme.crit
end

-- Governor states that mean the rotor is driven, in trouble, or stopped.
local GOV_RUNNING = { ACTIVE=true, SPOOLUP=true, RECOVERY=true, BAILOUT=true, BYPASS=true }
local GOV_CRIT    = { ["THR-OFF"]=true, ["LOST-HS"]=true }

function Theme.govColors(state)
  if GOV_RUNNING[state] then
    return Theme.lime, Theme.govRunBg, Theme.govRunBr
  elseif GOV_CRIT[state] then
    return Theme.crit, Theme.govCritBg, Theme.govCritBr
  elseif state == "IDLE" or state == "AUTOROT" then
    return Theme.warn, Theme.govWarnBg, Theme.govWarnBr
  end
  return Theme.dim, Theme.govIdleBg, Theme.govIdleBr
end

return Theme

end
