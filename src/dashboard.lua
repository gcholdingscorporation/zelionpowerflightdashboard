-- Layer 6: The dashboard renderer.
--
-- Retained-mode LVGL: every object is created once in build(), and refresh()
-- pushes only the properties whose values actually changed. A shadow table
-- holds the last value written to each object so an unchanged frame costs no
-- host calls at all.
--
-- Reads State and Layout; owns no telemetry logic of its own. If a number
-- looks wrong on screen, this file is almost never where the bug is.

return function(ZD)

local Host   = ZD.Host
local State  = ZD.State
local Theme  = ZD.Theme
local Layout = ZD.Layout
local RF2    = ZD.RF2

local Dashboard = {}
ZD.Dashboard = Dashboard

local function assetDir() return Host.widgetDir() end

function Dashboard.assetDir() return assetDir() end

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
local ALIGN_CENTER = flag("CENTER", flag("CENTERED", 0))
local ALIGN_RIGHT  = flag("RIGHT", 0)

local V, SHADOW = {}, {}

--------------------------------------------------------------------------
-- Retained-object helpers
--------------------------------------------------------------------------

local function remember(obj, props)
  local st = {}
  for k, v in pairs(props) do st[k] = v end
  st.visible = true
  SHADOW[obj] = st
  return obj
end

-- A corner radius larger than half the shorter side is geometrically
-- impossible, and asking a graphics library to draw one is a classic way to
-- crash it natively. This code was doing exactly that: the battery gauge fill
-- is created one pixel tall with a radius of 5, and the TX battery fill one
-- pixel tall with a radius of 2. Both are clamped here rather than at every
-- call site, because the offending sizes are runtime values - a gauge at 0%
-- is one pixel tall no matter what radius the design asked for.
--
-- Declared before setp(), which calls it. It used to sit below, so the call in
-- setp() resolved to a nil global instead - harmless only because every radius
-- that reached it happened to have clamped to zero at build time.
Dashboard.noRound = false

local function safeRadius(w, h, rounded)
  if Dashboard.noRound then return 0 end
  local r = rounded or 0
  if r <= 0 then return 0 end
  local limit = math.floor(math.min(w or 0, h or 0) / 2)
  if limit < 0 then limit = 0 end
  if r > limit then return limit end
  return r
end

local function setp(obj, props)
  if not obj then return end
  local st = SHADOW[obj]
  if not st then st = {}; SHADOW[obj] = st end
  if props.font ~= nil then props.font = Theme.safeFont(props.font) end
  -- Resizing can make an existing radius illegal - a gauge shrinking to one
  -- pixel keeps the radius it was built with unless it is re-clamped.
  if props.w ~= nil or props.h ~= nil then
    local w = props.w or st.w
    local h = props.h or st.h
    if st.rounded and st.rounded > 0 and w and h then
      local r = safeRadius(w, h, st.rounded)
      if r ~= st.rounded then props.rounded = r end
    end
  end
  local changed = false
  for k, v in pairs(props) do
    if st[k] ~= v then st[k] = v; changed = true end
  end
  if changed then obj:set(props) end
end

-- Deliberately no hide()/show(). Those were the other construct safe mode
-- never exercises; an object that should not be seen is collapsed to a single
-- pixel in the colour behind it instead.
local function setHidden(obj, hidden, bgColor)
  if not obj then return end
  if hidden then
    setp(obj, { h = 1, color = bgColor })
  end
end

-- Every font passes through Theme.safeFont on its way to LVGL. EdgeTX indexes
-- its font style array with no bounds check, so an index it has no font for is
-- a native fault and an EMERGENCY MODE reboot - not something pcall can catch.
local function label(x, y, w, text, font, color, align)
  local p = { x=x, y=y, w=w or 0, h=0, text=text or "",
              font=Theme.safeFont(font or 0),
              color=color or Theme.ink, align=align or 0 }
  return remember(lvgl.label(p), p)
end

local function rectangle(x, y, w, h, color, filled, rounded, thickness)
  local p = { x=x, y=y, w=w, h=h, color=color,
              filled=filled and 1 or 0, rounded=safeRadius(w, h, rounded),
              thickness=thickness or 1 }
  return remember(lvgl.rectangle(p), p)
end

-- A panel is two FILLED rectangles, the outer one showing through a 1px inset
-- to read as a border.
--
-- Hardware verdict: safe mode - filled rectangles and labels only - does not
-- crash the radio, while the full dashboard does even with every image
-- disabled. Unfilled rectangles were one of only two constructs the dashboard
-- used that safe mode did not, so nothing draws with filled=0 any more.
-- Keeping two objects preserves independent recolouring for the governor.
local function panel(r, fill, border, rounded)
  local rd = rounded or 5
  return {
    border = rectangle(r.x, r.y, r.w, r.h, border, true, rd, 0),
    fill   = rectangle(r.x + 1, r.y + 1, r.w - 2, r.h - 2, fill, true,
                       rd > 1 and rd - 1 or rd, 0),
  }
end

local function setPanel(p, fill, border)
  setp(p.fill,   { color = fill })
  setp(p.border, { color = border })
end

--------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------

local function fmt(v, pattern, scale)
  if v == nil then return "--" end
  return string.format(pattern, v * (scale or 1))
end

local function fmtInt(role)
  local v, ok = State.get(role)
  if not ok then return "--" end
  return string.format("%d", math.floor(v + 0.5))
end

local function fmtExtreme(prefix, value, pattern)
  if value == nil then return prefix .. " --" end
  return prefix .. " " .. string.format(pattern, value)
end

local function clockText(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Sag is the gap between the pack's best cell voltage this flight and what it
-- is delivering now: the number that actually says how the pack is holding up.
local function cellSag()
  local now, ok = State.get("cellVoltage")
  local best = State.max("cellVoltage")
  if not ok or best == nil then return nil end
  local sag = best - now
  if sag < 0 then sag = 0 end
  return sag
end

-- Lives in State: the alert engine needs the same answer and has no business
-- reaching into the renderer for it.
local function govText() return State.governorText() end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

local L
local mode  -- "dash" | "minimal" | "toosmall"

-- There is one screen. A separate standby screen used to stand in until
-- telemetry arrived, on the reasoning that a grid of dashes looks broken - but
-- the dashboard already distinguishes "no sensor" from "reading zero" honestly,
-- and showing the real layout immediately says more than a splash does: you can
-- see the widget is alive, laid out, and waiting on named values. It also
-- removes the screen-to-screen transition, which is where the emergency-mode
-- reboot used to happen. The Zelion lockup is on the dashboard anyway, so the
-- branding never leaves the screen.


-- Artwork lives on the SD card, so it can simply be absent - a widget copied
-- without its PNGs is the likeliest first-run mistake. Check before asking
-- LVGL to load it: a missing image otherwise fails silently and leaves a hole
-- with nothing to explain it.
Dashboard.logoMissing = false
Dashboard.missingPath = nil

function Dashboard.placeLogo(r, filename)
  if Dashboard.noLogo then
    local F = Theme.font
    label(r.x, r.y + math.floor((r.h - Theme.fontHeight(F.mid)) / 2), r.w,
          "ZELION POWER", F.mid, Theme.steel, ALIGN_CENTER)
    return
  end
  local path = assetDir() .. filename
  -- Cached in Host, so a rebuild does not re-open (and re-allocate) the file.
  local ok = Host.imageExists(path)

  -- Draw the wordmark FIRST, then the image over it. A probe that says
  -- "missing" is evidence, not proof: it was wrong on hardware once already.
  -- Ordering it this way means a working image always wins, and the wordmark
  -- is only ever seen when nothing loaded at all.
  if not ok then
    Dashboard.logoMissing = true
    Dashboard.missingPath = path
    -- One label, not two stacked: without a way to measure text there is no
    -- safe gap between them, and a two-line version overlapped itself the
    -- moment the fonts started resolving.
    local F = Theme.font
    label(r.x, r.y + math.floor((r.h - Theme.fontHeight(F.mid)) / 2), r.w,
          "ZELION POWER", F.mid, Theme.steel, ALIGN_CENTER)
  end

  -- Attempted unconditionally: if LVGL can load it, it renders regardless of
  -- what the probes concluded.
  lvgl.image({ x=r.x, y=r.y, w=r.w, h=r.h, fill=false, file=path })
end

-- Text is placed from measured font heights, not from offsets tuned against a
-- design mock-up. EdgeTX's fonts are much larger than a mock-up implies -
-- SMLSIZE is 23px on a TX16S and XXLSIZE is 102px - so every panel on this
-- screen had its header sitting inside its own value. Asking Theme for the
-- height and stacking from that is the only version that holds on both radios.
local function fh(font) return Theme.fontHeight(font) end

local function buildTopBar()
  local F = Theme.font
  local roomy = L.class == "roomy"
  -- Three items share the top bar, so each gets a bounded box rather than the
  -- full width. A centred label spanning the whole screen looks fine until the
  -- craft name is long enough to reach the clock.
  local nameW = roomy and 260 or 150
  V.modelName = label(L.c.pad, L.top.y + (roomy and 5 or 4), nameW, "",
                      F.tiny, Theme.ink)
  local timerX = L.c.pad + nameW + 10
  V.timer = label(timerX, L.top.y + math.floor((L.c.topH - fh(F.small)) / 2),
                  L.w - timerX * 2, "", F.small, Theme.ink, ALIGN_CENTER)

  -- Signal bars, then the TX battery glyph at the far right.
  local barsX = L.w - L.c.pad - (L.class == "roomy" and 200 or 128)
  local step  = L.class == "roomy" and 10 or 8
  local unit  = L.class == "roomy" and 6 or 5
  local baseY = L.class == "roomy" and 30 or 22
  V.signal = {}
  for i = 1, 4 do
    local bh = 6 + (i - 1) * 4
    V.signal[i] = rectangle(barsX + (i - 1) * step, baseY - bh, unit, bh,
                            Theme.rule, true, 0, 0)
  end

  local bw, bh = (L.class == "roomy" and 16 or 13), (L.class == "roomy" and 22 or 16)
  local bx = L.w - L.c.pad - 36
  local by = L.class == "roomy" and 14 or 10
  rectangle(bx + math.floor((bw - 8) / 2), by - 4, 8, 3, Theme.dim, true, 1, 0)
  V.txBody = panel({x=bx, y=by, w=bw, h=bh}, Theme.track, Theme.dim, 3)
  V.txFill = rectangle(bx + 2, by + bh - 3, bw - 4, 1, Theme.lime, true, 2, 0)
  V.txGeom = { x=bx, y=by, w=bw, h=bh }
  -- Clear of the glyph itself: the reading used to be drawn on top of it.
  local txW = roomy and 44 or 34
  V.txText = label(bx - 6 - txW, by, txW, "", F.tiny, Theme.ink, ALIGN_RIGHT)

  lvgl.hline({ x=0, y=L.topRule, w=L.w, h=1, color=Theme.rule })
end

local function buildLeftColumn()
  local F = Theme.font
  local c, b = L.cell, L.bar

  local roomy = L.class == "roomy"
  V.cellPanel = panel(c, Theme.panel, Theme.panelBr, 6)
  local y = c.y + (roomy and 4 or 3)
  label(c.x, y, c.w, "CELL", F.tiny, Theme.lime, ALIGN_CENTER)
  -- smallBold, not large: DBLSIZE is 58px on a TX16S and this chip is 75 tall.
  V.cellValue = label(c.x, y + fh(F.tiny) + (roomy and 3 or 2), c.w, "",
                      F.smallBold, Theme.ink, ALIGN_CENTER)
  V.cellMin = label(c.x, c.y + c.h - fh(F.tiny) - (roomy and 3 or 2), c.w, "",
                    F.tiny, Theme.peak, ALIGN_CENTER)

  -- Brand-green border: the gauge is the Zelion instrument on this screen.
  -- Two filled rects rather than an outlined one, for the same reason as panel().
  rectangle(b.x, b.y, b.w, b.h, Theme.lime, true, 7, 0)
  rectangle(b.x + 2, b.y + 2, b.w - 4, b.h - 4, Theme.track, true, 5, 0)
  V.barFill = rectangle(b.x + 3, b.y + b.h - 4, b.w - 6, 1, Theme.lime, true, 5, 0)
  V.barGeom = { x=b.x + 3, y=b.y + 3, w=b.w - 6, h=b.h - 6 }
end

-- Both hero tiles share one shape: a header line, a very large number under it,
-- a rule, and a row of small footnotes on the floor of the tile. Only the
-- header's right-hand item and the number's unit differ, so build it once.
--
-- The number is left-aligned and its unit tracks it: the unit's x is recomputed
-- from the measured width of the reading whenever that reading changes width,
-- so "%" hugs "68" and "100" alike instead of sitting at a fixed offset with a
-- gap that grows as the value shortens.
--
-- valShare is now only a clamp - the widest the number is allowed to grow
-- before its unit would be pushed off the tile.
local function buildHeroTile(r, title, unitText, unitFont, slotCount, valShare)
  local F = Theme.font
  local roomy = L.class == "roomy"
  local padX  = roomy and 14 or 8
  local inner = r.w - padX * 2

  panel(r, Theme.panel, Theme.panelBr)

  local headY = r.y + (roomy and 6 or 4)
  local headH = math.max(fh(F.tiny), fh(F.small))
  label(r.x + padX, headY, math.floor(inner / 2), title, F.tiny, Theme.dim)

  local footH = fh(F.tiny)
  local footY = r.y + r.h - footH - (roomy and 6 or 4)
  local ruleY = footY - (roomy and 6 or 4)

  -- The number sits centred in the band between the header and the rule rather
  -- than tucked straight under the header, which left it riding high with all
  -- the slack pooled beneath it.
  local bandTop = headY + headH
  local valY = bandTop + math.max(0,
                 math.floor(((ruleY - bandTop) - fh(F.huge)) / 2))
  local valW = math.floor(inner * valShare)
  -- Left-aligned, flush with the panel title above it.
  local value = label(r.x + padX, valY, valW, "", F.huge, Theme.ink)

  -- The unit sits on the number's right shoulder, on its baseline. Both "%"
  -- and "RPM" belong to the number they qualify; at the tile's far edge they
  -- read as separate fields.
  local unit, unitGeom
  if unitText then
    local gap = roomy and 8 or 4
    unitGeom = { x0 = r.x + padX, gap = gap, font = F.huge,
                 lineH = fh(F.huge), maxX = r.x + padX + valW + gap,
                 width = inner - valW - gap }
    unit = label(unitGeom.maxX, valY + fh(F.huge) - fh(unitFont),
                 unitGeom.width, unitText, unitFont, Theme.dim)
  end

  lvgl.hline({ x=r.x + padX, y=ruleY, w=inner, h=1, color=Theme.rule })

  local foots, slotW = {}, math.floor(inner / slotCount)
  for i = 1, slotCount do
    foots[i] = label(r.x + padX + slotW * (i - 1), footY, slotW, "",
                     F.tiny, Theme.dim)
  end

  -- Returned so the caller can put its own reading on the header's right.
  return value, foots, { x = r.x + padX + math.floor(inner / 2),
                         y = headY, w = math.floor(inner / 2) },
         unit, unitGeom
end

-- Writes a hero reading and slides its unit up against it.
--
-- The measurement is the point: without it the unit has to sit at a fixed
-- offset chosen for the widest possible reading, which strands it half a panel
-- away from a two-digit value. lcd.sizeText is pure - it reads font metrics and
-- touches no draw buffer - so it is safe to call here.
local function setHeroValue(value, geom, unit, text)
  setp(value, { text = text })
  if not (unit and geom) then return end
  local w = Host.textWidth(text, geom.font, geom.lineH)
  local x = geom.x0 + w + geom.gap
  if x > geom.maxX then x = geom.maxX end
  setp(unit, { x = x, w = geom.width + (geom.maxX - x) })
end

local function buildHero()
  local F = Theme.font
  local roomy = L.class == "roomy"

  -- Three footnotes, not four. The hero column gave width to the right column,
  -- and a fourth slot no longer holds "MIN 47.3V" without touching its
  -- neighbour. Cell count was the one worth losing: it moves up beside the
  -- pack voltage, where it reads as the "12S" qualifying it.
  local packSlot
  V.batValue, V.batFoot, packSlot, V.batUnit, V.batUnitGeom =
    buildHeroTile(L.battery, "BATTERY", "%", F.mid, 3, L.c.batValShare)
  -- Total pack voltage shares the header line. It is the one reading with
  -- nowhere else to go once the percentage takes the whole value band, and it
  -- reads cleanly against the panel title.
  V.batPack = label(packSlot.x, packSlot.y, packSlot.w, "",
                    F.small, Theme.ink, ALIGN_RIGHT)

  -- "RPM" is a word, not a glyph, so it takes the smaller unit font. At F.mid
  -- it would be wider than the space a four-digit headspeed leaves.
  local _hsSlot
  V.hsValue, V.hsFoot, _hsSlot, V.hsUnit, V.hsUnitGeom =
    buildHeroTile(L.headspeed, "HEADSPEED", "RPM", F.small, roomy and 3 or 2,
                  L.c.hsValShare)
end

local function buildRightColumn()
  local F = Theme.font
  local roomy = L.class == "roomy"

  local g = L.gov
  V.govPanel = panel(g, Theme.govIdleBg, Theme.govIdleBr)
  -- The wider right column pays for a bigger governor and bigger tile values.
  -- Both were sized for a 274px column that had to hold three 88px tiles.
  local govFont = roomy and F.large or F.mid
  local gy = g.y + (roomy and 5 or 4)
  label(g.x, gy, g.w, "GOVERNOR", F.tiny, Theme.dim, ALIGN_CENTER)
  V.govState = label(g.x, gy + fh(F.tiny) + (roomy and 4 or 2), g.w, "",
                     govFont, Theme.dim, ALIGN_CENTER)

  -- Labels carry their units on both screens; at 54px wide there is no room
  -- for a separate unit glyph, and consistency beats a spare pixel. Abbreviated
  -- on the wide screen too: "CURRENT A" is 88px of tile and TINSIZE is 17px
  -- tall, so it ran off its own panel.
  local defs = { "CURR A", "ESC °C", "BEC V" }
  -- Centred, like the governor above them: three narrow tiles of one reading
  -- each read as a row, and a left-aligned value drifts away from its own
  -- label as the reading changes width.
  local tileFont = roomy and F.large or F.mid
  V.tiles = {}
  for i = 1, 3 do
    local t = L.tiles[i]
    local ty = t.y + (roomy and 6 or 4)
    panel(t, Theme.panel, Theme.panelBr)
    label(t.x + 6, ty, t.w - 12, defs[i], F.tiny, Theme.dim, ALIGN_CENTER)
    V.tiles[i] = {
      value = label(t.x + 6, ty + fh(F.tiny) + (roomy and 4 or 2), t.w - 12, "",
                    tileFont, Theme.ink, ALIGN_CENTER),
      foot  = label(t.x + 6, t.y + t.h - fh(F.tiny) - (roomy and 6 or 4),
                    t.w - 12, "", F.tiny, Theme.peak, ALIGN_CENTER),
    }
  end

  -- No frame: a panel border fought the mark's own outline.
  Dashboard.placeLogo(L.logo, roomy and "logo_panel.png" or "logo_small.png")
end

local function buildStrip()
  local F = Theme.font
  local roomy = L.class == "roomy"
  lvgl.hline({ x=0, y=L.stripRule, w=L.w, h=1, color=Theme.rule })
  local y = L.stripRule + (roomy and 10 or 7)
  V.flights = label(L.c.pad, y, 300, "", F.tiny, Theme.dim)
  if roomy then
    V.tagline = label(0, y, L.w, "NO HYPE / JUST VOLTAGE / REAL POWER",
                      F.tiny, Theme.dim, ALIGN_CENTER)
  end
  -- Wide enough for a full "NO IMAGE: <path>", which is the longest thing that
  -- can land here and the whole reason the notice names a path at all.
  V.link = label(L.c.pad, y, L.w - L.c.pad * 2, "", F.tiny, Theme.steel,
                 ALIGN_RIGHT)
end

-- Smallest zone the tight layout can be drawn into honestly. Below this the
-- panels would overlap, so say so rather than render a mess.
Dashboard.MIN_W, Dashboard.MIN_H = 440, 250

-- Last resort. A dozen objects, no bitmap, no panels: if even this cannot be
-- built the widget is not the problem. Reached only after a real build has
-- already failed.
function Dashboard.buildMinimal(w, h)
  if type(lvgl) ~= "table" then return end
  lvgl.clear()
  V, SHADOW = {}, {}
  Host.collect()
  mode = "minimal"
  local F = Theme.font
  Theme.useMetricsFor(Host.lcdW or w)
  rectangle(0, 0, w, h, Theme.bg, true, 0, 0)
  V.modelName = label(8, 6, w - 16, "", F.tiny, Theme.ink)
  local y = 6 + fh(F.tiny) + 4
  label(0, y, w, "ZELIONDASH - SAFE MODE", F.tiny, Theme.warn, ALIGN_CENTER)
  -- Three readings on a clear screen. Spaced by their own height, so the last
  -- one still lands above the bottom edge on a 320px-tall radio.
  local rest = h - (y + fh(F.tiny) + 4)
  local step = math.floor(rest / 3)
  local top  = y + fh(F.tiny) + 4
  V.minBat  = label(8, top + math.floor((step - fh(F.large)) / 2), w - 16, "",
                    F.large, Theme.ink, ALIGN_CENTER)
  V.minHs   = label(8, top + step + math.floor((step - fh(F.large)) / 2), w - 16, "",
                    F.large, Theme.ink, ALIGN_CENTER)
  V.minCell = label(8, top + step * 2 + math.floor((step - fh(F.mid)) / 2), w - 16, "",
                    F.mid, Theme.dim, ALIGN_CENTER)
  Dashboard.update()
end

local function buildTooSmall(w, h)
  local F = Theme.font
  rectangle(0, 0, w, h, Theme.bg, true, 0, 0)
  local y = math.floor(h / 2) - fh(F.mid)
  label(0, y, w, "ZELIONDASH", F.mid, Theme.steel, ALIGN_CENTER)
  y = y + fh(F.mid) + 2
  label(0, y, w, "NEEDS A FULL SCREEN WIDGET SLOT",
        F.tiny, Theme.warn, ALIGN_CENTER)
  label(0, y + fh(F.tiny) + 2, w,
        string.format("this zone is %dx%d, minimum is %dx%d",
                      w, h, Dashboard.MIN_W, Dashboard.MIN_H),
        F.tiny, Theme.dim, ALIGN_CENTER)
end

-- w,h are the WIDGET ZONE, not the screen. LVGL objects are children of the
-- widget, so anything drawn past the zone edge is silently clipped - laying
-- out against LCD_W/LCD_H produces a dashboard with its right half missing.
function Dashboard.build(w, h)
  if type(lvgl) ~= "table" then return end
  Theme.build()
  lvgl.clear()
  V, SHADOW = {}, {}
  -- lvgl.clear() drops the previous screen's objects and bitmaps; reclaim them
  -- before allocating the next screen rather than letting both coexist.
  Host.collect()
  Dashboard.logoMissing = false
  w = w or Host.lcdW
  h = h or Host.lcdH
  -- Which font set this firmware was compiled with follows the radio's screen,
  -- not the widget's zone, so ask the host rather than the zone we were given.
  Theme.useMetricsFor(Host.lcdW or w)

  if w < Dashboard.MIN_W or h < Dashboard.MIN_H then
    mode = "toosmall"
    buildTooSmall(w, h)
    return
  end

  mode = "dash"
  L = Layout.build(w, h)
  rectangle(0, 0, L.w, L.h, Theme.bg, true, 0, 0)
  buildTopBar()
  buildLeftColumn()
  buildHero()
  buildRightColumn()
  buildStrip()
  Dashboard.update()
end

Dashboard.mode = function() return mode end

--------------------------------------------------------------------------
-- Sensor map
--------------------------------------------------------------------------
--
-- Retained LVGL, like everything else on screen, because a widget that
-- declares useLvgl gets NO immediate-mode drawing at all. LuaWidget's
-- checkEvents calls refresh(nullptr) on the LVGL path, which leaves
-- luaLcdBuffer null, and every lcd.draw* guards on
-- `if (!luaLcdAllowed || !luaLcdBuffer) return 0`. This screen was written
-- with lcd.drawText and so drew precisely nothing - the widget looked like it
-- had vanished until the option was switched back off.
--
-- Rows are built once for however many fit on screen and then only have their
-- text rewritten, so scrolling costs nothing and the object count is bounded
-- by the screen rather than by the number of roles.

local SM = { rows = {}, visible = 0 }

Dashboard.sensorRows = 0

function Dashboard.buildSensorMap(w, h)
  if type(lvgl) ~= "table" then return end
  Theme.build()
  lvgl.clear()
  V, SHADOW = {}, {}
  Host.collect()
  w = w or Host.lcdW
  h = h or Host.lcdH
  Theme.useMetricsFor(Host.lcdW or w)
  mode = "sensors"

  local F = Theme.font
  local compact = w < 700
  local pad = compact and 6 or 12
  rectangle(0, 0, w, h, Theme.bg, true, 0, 0)

  local headerH = fh(F.small) + (compact and 4 or 8)
  label(pad, compact and 2 or 4, math.floor(w * 0.6),
        compact and "SENSOR MAP" or "ZELIONDASH - SENSOR MAP",
        F.small, Theme.steel)
  V.smCount = label(w - pad - 160, compact and 4 or 7, 160, "",
                    F.tiny, Theme.dim, ALIGN_RIGHT)
  lvgl.hline({ x = 0, y = headerH, w = w, h = 1, color = Theme.rule })

  local rowH    = fh(F.tiny) + (compact and 3 or 4)
  local footerH = fh(F.tiny) + (compact and 4 or 8)
  local listTop = headerH + (compact and 3 or 6)
  SM.visible = math.max(1, math.floor((h - listTop - footerH) / rowH))

  -- Three columns, not four. "how" is folded into the sensor cell as a
  -- suffix: it is worth knowing whether a binding came from the config file,
  -- a name match or a unit guess, but not worth a column of its own once
  -- every row costs a retained object.
  local colRole   = pad
  local colSensor = math.floor(w * 0.36)
  local sensorW   = math.floor(w * 0.34)
  local colValue  = w - pad

  SM.rows = {}
  for i = 1, SM.visible do
    local y = listTop + (i - 1) * rowH
    SM.rows[i] = {
      role   = label(colRole, y, colSensor - colRole - 4, "", F.tiny, Theme.ink),
      sensor = label(colSensor, y, sensorW, "", F.tiny, Theme.dim),
      value  = label(colValue - 120, y, 120, "", F.tiny, Theme.dim, ALIGN_RIGHT),
    }
  end

  local fy = h - footerH + (compact and 1 or 3)
  V.smNote = label(pad, fy, w - pad * 2 - 90, "", F.tiny, Theme.dim)
  V.smPage = label(w - pad - 90, fy, 90, "", F.tiny, Theme.dim, ALIGN_RIGHT)
end

-- rows: { { label, sensor, how, value, status, important }, ... }
function Dashboard.updateSensorMap(rows, scroll, bound, note, noteBad)
  if mode ~= "sensors" then return end
  rows = rows or {}
  Dashboard.sensorRows = #rows
  local n = SM.visible
  if scroll > #rows - n then scroll = math.max(0, #rows - n) end
  if scroll < 0 then scroll = 0 end

  setp(V.smCount, { text = string.format("%d bound", bound or 0) })
  setp(V.smNote, { text = note or "", color = noteBad and Theme.crit or Theme.dim })
  setp(V.smPage, { text = (#rows > n)
                          and string.format("%d-%d/%d", scroll + 1,
                                            math.min(#rows, scroll + n), #rows)
                          or "" })

  for i = 1, n do
    local r = SM.rows[i]
    local row = rows[i + scroll]
    if not row then
      setp(r.role, { text = "" }); setp(r.sensor, { text = "" })
      setp(r.value, { text = "" })
    else
      local color = Theme.dim
      if row.status == "ok" or row.status == "derived" then color = Theme.lime
      elseif row.status == "insane" then color = Theme.crit
      elseif row.important then color = Theme.warn end

      local sensor = row.sensor or "-"
      if row.how then sensor = sensor .. " (" .. row.how .. ")" end
      setp(r.role,   { text = row.label or "",
                       color = row.important and Theme.steel or Theme.ink })
      setp(r.sensor, { text = sensor, color = color })
      setp(r.value,  { text = row.value or "", color = color })
    end
  end
  return scroll
end

function Dashboard.sensorMapVisible() return SM.visible end

--------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------

local function flightsText()
  if RF2.statsStatus == "ok" and RF2.totalFlights then
    local t = string.format("%d FLIGHTS", RF2.totalFlights)
    if RF2.totalFlightSeconds then
      local s = RF2.totalFlightSeconds
      t = t .. string.format(" - %d:%02d:%02d", math.floor(s / 3600),
                             math.floor(s % 3600 / 60), s % 60)
    end
    return t
  end
  return ""
end

local function updateTopBar()
  setp(V.modelName, { text = RF2.craftName or Host.modelName() })
  setp(V.timer, { text = clockText(State.flightSeconds) })

  local lq = State.valid("linkQuality") and State.num("linkQuality") or nil
  local bars = 0
  if lq then
    bars = (lq >= 80 and 4) or (lq >= 60 and 3) or (lq >= 40 and 2)
           or (lq >= 20 and 1) or 0
  end
  local col = Theme.linkColor(lq)
  for i = 1, 4 do
    setp(V.signal[i], { color = (i <= bars) and col or Theme.rule })
  end

  local tx = State.valid("txVoltage") and State.num("txVoltage") or nil
  if tx then
    -- 2S: 7.0V empty, 8.4V full.
    local pct = math.max(0, math.min(1, (tx - 7.0) / 1.4))
    local fh = math.floor((V.txGeom.h - 4) * pct)
    setp(V.txFill, { y = V.txGeom.y + V.txGeom.h - 2 - fh,
                     h = math.max(1, fh),
                     color = fh <= 0 and Theme.track
                             or (pct > 0.5 and Theme.lime
                                 or (pct > 0.25 and Theme.warn or Theme.crit)) })
    setp(V.txText, { text = string.format("%.1f", tx) })
  else
    setHidden(V.txFill, true, Theme.track)
    setp(V.txText, { text = "--" })
  end
end

local function updateLeftColumn()
  local cell, ok = State.get("cellVoltage")
  setp(V.cellValue, { text = ok and string.format("%.2f", cell) or "--",
                      color = ok and Theme.cellColor(cell) or Theme.dim })
  setp(V.cellMin, { text = fmtExtreme("MIN", State.min("cellVoltage"), "%.2f") })

  local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
  if pct then
    local g = V.barGeom
    local fh = math.floor(g.h * math.max(0, math.min(100, pct)) / 100)
    setp(V.barFill, { y = g.y + g.h - fh, h = math.max(1, fh),
                      color = fh <= 0 and Theme.track or Theme.batteryColor(pct) })
  else
    setHidden(V.barFill, true, Theme.track)
  end
end

local function updateHero()
  local roomy = L.class == "roomy"

  local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
  setHeroValue(V.batValue, V.batUnitGeom, V.batUnit,
               pct and string.format("%d", math.floor(pct + 0.5)) or "--")
  setp(V.batValue, { color = pct and Theme.ink or Theme.dim })
  -- Cell count qualifies the pack voltage, so it rides with it: "12S 47.3 V".
  local pack, packOk = State.get("packVoltage")
  local packText = packOk and string.format("%.1f V", pack) or "--"
  if packOk and State.valid("cellCount") then
    packText = string.format("%dS %s", math.floor(State.num("cellCount")), packText)
  end
  setp(V.batPack, { text = packText,
                    color = packOk and Theme.ink or Theme.dim })

  local foots = {
    fmtExtreme("MIN", State.min("packVoltage"), "%.1fV"),
    fmtExtreme("SAG", cellSag(), "%.2f"),
    State.valid("capacity") and string.format("%d mAh", math.floor(State.num("capacity")))
      or "-- mAh",
  }
  for i = 1, #V.batFoot do
    setp(V.batFoot[i], { text = foots[i] or "" })
  end

  local hs, hsOk = State.get("headspeed")
  setHeroValue(V.hsValue, V.hsUnitGeom, V.hsUnit,
               hsOk and string.format("%d", math.floor(hs + 0.5)) or "--")
  setp(V.hsValue, { color = hsOk and Theme.ink or Theme.dim })
  local hfoots = {
    fmtExtreme("MAX", State.max("headspeed"), "%d"),
    State.valid("tailSpeed") and string.format("TAIL %d", math.floor(State.num("tailSpeed")))
      or "TAIL --",
    State.valid("throttle") and string.format("THR %d%%", math.floor(State.num("throttle")))
      or "THR --",
  }
  for i = 1, #V.hsFoot do
    setp(V.hsFoot[i], { text = hfoots[i] or "" })
  end
end

local function updateRightColumn()
  local g = govText()
  local fg, bg, br = Theme.govColors(g)
  setPanel(V.govPanel, bg, br)
  setp(V.govState, { text = g, color = fg })

  local cur, curOk = State.get("current")
  setp(V.tiles[1].value, { text = curOk and string.format("%d", math.floor(cur + 0.5)) or "--",
                           color = curOk and Theme.ink or Theme.dim })
  setp(V.tiles[1].foot, { text = fmtExtreme("MAX", State.max("current"), "%d") })

  local esc, escOk = State.get("escTemperature")
  setp(V.tiles[2].value, { text = escOk and string.format("%d", math.floor(esc + 0.5)) or "--",
                           color = escOk and Theme.tempColor(esc) or Theme.dim })
  setp(V.tiles[2].foot, { text = fmtExtreme("MAX", State.max("escTemperature"), "%d") })

  local bec, becOk = State.get("becVoltage")
  setp(V.tiles[3].value, { text = becOk and string.format("%.1f", bec) or "--",
                           color = becOk and Theme.becColor(bec) or Theme.dim })
  setp(V.tiles[3].foot, { text = fmtExtreme("MIN", State.min("becVoltage"), "%.1f") })
end

local function updateStrip()
  setp(V.flights, { text = flightsText() })
  local text, color = "", Theme.steel
  if Dashboard.logoMissing then
    -- Name the exact path that failed: "missing" is not actionable, a path is.
    -- It needs the whole strip, so the slogan stands down - an error outranks
    -- a tagline, and the two were printing through each other.
    setp(V.tagline, { text = "" })
    setp(V.link, { text = "NO IMAGE: " .. tostring(Dashboard.missingPath),
                   color = Theme.warn })
    return
  end
  -- A sounding alert takes the strip. The radio may be muted, the pilot may
  -- have missed it, and "which one was that" is a question worth answering
  -- without having to remember what the buzz pattern meant.
  local ZD_Alerts = ZD.Alerts
  local active = ZD_Alerts and ZD_Alerts.active() or {}
  if #active > 0 then
    setp(V.tagline, { text = "" })
    setp(V.link, { text = "ALERT: " .. string.upper(table.concat(active, " + ")),
                   color = Theme.crit })
    return
  end
  setp(V.tagline, { text = "NO HYPE / JUST VOLTAGE / REAL POWER" })
  if RF2.available() then
    if State.linkConnected == false then
      text, color = "RF2 DISCONNECTED", Theme.dim
    elseif RF2.registered then
      text = "RF2 LINKED"
    end
  end
  setp(V.link, { text = text, color = color })
end

function Dashboard.update()
  if type(lvgl) ~= "table" or mode == "toosmall" then return end
  if mode == "minimal" then
    setp(V.modelName, { text = RF2.craftName or Host.modelName() })
    local pct = State.valid("batteryPercent") and State.num("batteryPercent") or nil
    setp(V.minBat, { text = pct and (string.format("%d", math.floor(pct + 0.5)) .. "%") or "--",
                     color = pct and Theme.batteryColor(pct) or Theme.dim })
    local hs, hsOk = State.get("headspeed")
    setp(V.minHs, { text = hsOk and (string.format("%d", math.floor(hs + 0.5)) .. " RPM") or "-- RPM",
                    color = hsOk and Theme.ink or Theme.dim })
    local cv, cvOk = State.get("cellVoltage")
    setp(V.minCell, { text = cvOk and (string.format("%.2f", cv) .. " V/cell") or "-- V/cell",
                      color = cvOk and Theme.cellColor(cv) or Theme.dim })
    return
  end
  if not V.flights then return end
  updateTopBar()
  updateLeftColumn()
  updateHero()
  updateRightColumn()
  updateStrip()
end

return Dashboard

end
