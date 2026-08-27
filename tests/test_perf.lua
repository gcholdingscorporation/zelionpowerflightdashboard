-- ZelionPerf: statistics, sampling, inventory, findings, screen and widget.
--
-- The statistics tests are the ones that matter most. Everything the analyser
-- says rests on getting a trustworthy frame rate out of a 10ms clock, and
-- that is arithmetic - so it is checked here against hand-computed answers
-- rather than eyeballed on a radio, where a 6% error in a frame rate looks
-- exactly like a correct one.

return function(H, Mock, Loader)

local function boot(w, h, setup)
  Mock.reset()
  Mock.state.lcdW, Mock.state.lcdH = w or 800, h or 480
  if setup then setup() end
  Mock.install()
  Mock.installLvgl()
  return Loader.loadPerf()
end

--------------------------------------------------------------------------
H.group("perf: frame timing")

H.test("frame rate comes from the window span, not the mean sample", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local w = S.newWindow()
  -- A real 28.6fps signal quantised by a 10ms clock: periods alternate 3 and
  -- 4 ticks. Averaging the samples gives 3.5 ticks and the right answer only
  -- by luck of this example; the span is what makes it right in general.
  for i = 1, 20 do S.add(w, (i % 2 == 0) and 3 or 4) end
  H.eq(w.frames, 20)
  H.eq(w.span, 70)
  H.near(S.fps(w), 20 * 100 / 70, 0.001)
end)

H.test("refuses a frame rate it does not have the evidence for", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local w = S.newWindow()
  S.add(w, 4)
  S.add(w, 4)
  H.nilv(S.fps(w), "two samples is not a frame rate")
  for i = 1, 10 do S.add(w, 4) end
  H.truthy(S.fps(w))
end)

H.test("a zero span reports nothing rather than infinity", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local w = S.newWindow()
  for i = 1, 12 do S.add(w, 0) end
  H.nilv(S.fps(w))
end)

H.test("percentiles come off the histogram in tick order", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local w = S.newWindow()
  for i = 1, 90 do S.add(w, 3) end
  for i = 1, 9  do S.add(w, 5) end
  S.add(w, 40)
  H.eq(S.percentile(w, 50), 3)
  H.eq(S.percentile(w, 95), 5)
  H.eq(w.worst, 40)
end)

H.test("stalls use an absolute floor on a fast radio", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local w = S.newWindow()
  for i = 1, 100 do S.add(w, 3) end
  S.add(w, 25)                      -- 250ms: a visible hitch
  S.add(w, 9)                       -- 90ms: three times typical, but not felt
  local n, threshold = S.stalls(w)
  H.eq(threshold, S.STALL_FLOOR_TICKS, "floor wins over 3x a 30ms frame")
  H.eq(n, 1)
end)

H.test("stalls scale with a slow radio's own baseline", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local w = S.newWindow()
  for i = 1, 100 do S.add(w, 12) end   -- about 8fps
  S.add(w, 25)                          -- above the floor, but normal here
  S.add(w, 40)                          -- more than 3x typical: a stall
  local n, threshold = S.stalls(w)
  H.eq(threshold, 36)
  H.eq(n, 1)
end)

--------------------------------------------------------------------------
H.group("perf: series and heap")

H.test("the series ring keeps the most recent samples", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local s = S.newSeries(4)
  for i = 1, 6 do S.push(s, i) end
  H.eq(s.n, 4)
  H.near(S.mean(s), (3 + 4 + 5 + 6) / 4, 0.001)
  H.eq(S.spread(s), 3)
end)

H.test("spread needs two samples", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local s = S.newSeries(4)
  H.nilv(S.spread(s))
  S.push(s, 30)
  H.nilv(S.spread(s))
  S.push(s, 32)
  H.eq(S.spread(s), 2)
end)

H.test("allocation is the sum of the falls, not the slope", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local h = S.newHeap()
  -- The sawtooth a collector produces: down 200 a frame, then one big step
  -- back up. First and last are equal, so a slope would report zero
  -- allocation for a script allocating 200 bytes every frame.
  local free = 40000
  for cycle = 1, 3 do
    for i = 1, 5 do
      S.heapSample(h, free)
      free = free - 200
    end
    free = free + 1000
  end
  S.heapSample(h, free)
  H.eq(h.collections, 3, "three rises above the noise threshold")
  -- 160, not the true 200: in each frame where the collector ran, the 1000
  -- handed back and the 200 taken arrive as one net rise and cannot be
  -- separated. The figure is a floor on what is being allocated, which is
  -- the honest thing for it to be - a slope would have said zero.
  H.near(S.allocPerFrame(h), 160, 1)
end)

H.test("a small rise is not counted as a collection", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local h = S.newHeap()
  S.heapSample(h, 40000)
  S.heapSample(h, 40100)          -- another script freed one object
  H.eq(h.collections, 0)
end)

--------------------------------------------------------------------------
H.group("perf: before and after")

H.test("a difference inside the noise is reported as no change", function()
  local ZD = boot()
  local S = ZD.PerfStats
  local c = S.compare({ fps = 30.0, spread = 2.0 }, { fps = 31.5, spread = 1.8 })
  H.eq(c.verdict, "same")
  H.near(c.delta, 1.5, 0.001)
  H.near(c.noise, 2.0, 0.001)
end)

H.test("a difference outside the noise is called", function()
  local ZD = boot()
  local S = ZD.PerfStats
  H.eq(S.compare({ fps = 20, spread = 1 }, { fps = 28, spread = 1 }).verdict,
       "better")
  H.eq(S.compare({ fps = 28, spread = 1 }, { fps = 20, spread = 1 }).verdict,
       "worse")
end)

H.test("a zero spread still gets a noise floor", function()
  local ZD = boot()
  local S = ZD.PerfStats
  -- Eight sub-windows that all landed on the same quantised figure give a
  -- spread of zero. Without a floor, 0.05fps would be declared an improvement.
  local c = S.compare({ fps = 30.0, spread = 0 }, { fps = 30.05, spread = 0 })
  H.eq(c.verdict, "same")
  H.near(c.noise, S.FPS_NOISE_FLOOR, 0.001)
end)

H.test("comparing against nothing says unknown rather than guessing", function()
  local ZD = boot()
  local S = ZD.PerfStats
  H.eq(S.compare(nil, { fps = 30 }).verdict, "unknown")
  H.eq(S.compare({ fps = nil }, { fps = 30 }).verdict, "unknown")
end)

--------------------------------------------------------------------------
H.group("perf: the sampler")

-- Drives the probe for a number of frames at a fixed period.
local function run(ZD, frames, ticksPerFrame)
  for i = 1, frames do
    Mock.advance(ticksPerFrame)
    ZD.PerfProbe.frameStart(Mock.state.time)
    ZD.PerfProbe.frameEnd()
  end
end

H.test("measures the frame rate it is driven at", function()
  local ZD = boot()
  ZD.PerfProbe.reset()
  run(ZD, 100, 4)                       -- 40ms frames: 25fps
  local snap = ZD.PerfProbe.snapshot()
  H.near(snap.fps, 25, 0.5)
  H.eq(snap.p50, 4)
  H.eq(snap.stalls, 0)
end)

H.test("a gap off-screen is not a slow frame", function()
  local ZD = boot()
  ZD.PerfProbe.reset()
  run(ZD, 60, 4)
  local before = ZD.PerfProbe.snapshot()

  -- The pilot spends forty seconds in the menus. refresh() is not called, so
  -- the next period spans the lot. Counting it would put a 4000-tick sample
  -- in the histogram and drag the average frame rate to nothing.
  Mock.advance(4000)
  ZD.PerfProbe.frameStart(Mock.state.time)
  ZD.PerfProbe.frameEnd()
  run(ZD, 60, 4)

  local after = ZD.PerfProbe.snapshot()
  H.eq(ZD.PerfProbe.gaps(), 1)
  H.truthy(after.worst < ZD.PerfProbe.GAP_TICKS, "gap kept out of the histogram")
  H.near(after.fps, before.fps, 1.5)
end)

H.test("a clock that went backwards is treated as a gap", function()
  local ZD = boot()
  ZD.PerfProbe.reset()
  run(ZD, 40, 4)
  ZD.PerfProbe.frameStart(10)          -- getTime() wrapped
  H.eq(ZD.PerfProbe.gaps(), 1)
  H.eq(ZD.PerfProbe.snapshot().worst, 4, "no negative period recorded")
end)

H.test("sub-windows close and give the spread", function()
  local ZD = boot()
  ZD.PerfProbe.reset()
  -- Six seconds at 25fps is three two-second sub-windows.
  run(ZD, 150, 4)
  local snap = ZD.PerfProbe.snapshot()
  H.truthy(snap.subWindows >= 2, "closed at least two sub-windows, got "
           .. tostring(snap.subWindows))
  H.truthy(snap.spread ~= nil, "a spread to compare against")
end)

H.test("reports the heap and what this widget allocated", function()
  local ZD = boot()
  ZD.PerfProbe.reset()
  for i = 1, 40 do
    Mock.advance(4)
    ZD.PerfProbe.frameStart(Mock.state.time)
    -- 64 bytes consumed between frameStart and frameEnd is this widget's own
    -- cost; the further 36 before the next frameStart is everything else.
    Mock.state.freeMemory = Mock.state.freeMemory - 64
    ZD.PerfProbe.frameEnd()
    Mock.state.freeMemory = Mock.state.freeMemory - 36
  end
  local snap = ZD.PerfProbe.snapshot()
  H.near(snap.selfAlloc, 64, 1)
  H.near(snap.allocPerFrame, 100, 2)
  -- The last frame's 64 and 36 both fall after the final sample, so the heap
  -- the snapshot reports is 100 bytes behind where the mock now stands.
  H.eq(snap.freeMemory, Mock.state.freeMemory + 100)
end)

H.test("survives firmware with neither probe", function()
  local ZD = boot(800, 480, function()
    Mock.state.hasUsage = false
    Mock.state.hasFreeMemory = false
  end)
  ZD.PerfProbe.reset()
  run(ZD, 60, 4)
  local snap = ZD.PerfProbe.snapshot()
  H.near(snap.fps, 25, 0.5, "the clock alone is enough for a frame rate")
  H.nilv(snap.usageMax)
  H.nilv(snap.freeMemory)
end)

H.test("a baseline needs evidence, and survives the restart", function()
  local ZD = boot()
  local P = ZD.PerfProbe
  P.reset()
  H.nilv(P.mark("too early"), "refuses to mark from nothing")

  run(ZD, 100, 4)
  local snap = P.mark("before")
  H.truthy(snap and snap.fps)
  H.truthy(P.baseline, "baseline kept")
  H.eq(P.snapshot().frames, 0, "measurement restarted")

  run(ZD, 100, 2)                      -- twice as fast
  local cmp = P.comparison()
  H.eq(cmp.verdict, "better")
  H.truthy(cmp.delta > 10, "delta was " .. tostring(cmp.delta))
end)

--------------------------------------------------------------------------
H.group("perf: the inventory")

local function installScripts()
  Mock.state.files["/SCRIPTS/MIXES/gyro.lua"]        = string.rep("x", 4000)
  Mock.state.files["/SCRIPTS/FUNCTIONS/announce.lua"] = string.rep("x", 900)
  Mock.state.files["/SCRIPTS/TELEMETRY/big.lua"]     = string.rep("x", 30000)
  Mock.state.files["/SCRIPTS/TOOLS/setup.lua"]       = string.rep("x", 500)
  Mock.state.files["/WIDGETS/ZelionPerf/main.lua"]   = string.rep("x", 90000)
  Mock.state.files["/WIDGETS/Tiny/main.luac"]        = string.rep("x", 1200)
  Mock.state.files["/WIDGETS/NotAWidget/readme.txt"] = "x"
end

H.test("classifies each folder by when its scripts run", function()
  local ZD = boot(800, 480, installScripts)
  local scan = ZD.PerfScan.run()
  H.truthy(scan.ok)
  H.eq(scan.counts.mix, 1)
  H.eq(scan.counts.func, 1)
  H.eq(scan.counts.telem, 1)
  H.eq(scan.counts.tool, 1)
  H.eq(scan.counts.widget, 2, "the folder with no main.lua is not a widget")

  local byName = {}
  for _, s in ipairs(scan.scripts) do byName[s.name] = s end
  H.eq(byName.gyro.when, "every cycle")
  H.eq(byName.setup.when, "Tools menu")
  H.eq(byName.gyro.size, 4000)
  H.eq(byName.Tiny.compiled, true)
  H.eq(byName.ZelionPerf.compiled, false)
end)

H.test("the heaviest-running script is first, whatever its size", function()
  local ZD = boot(800, 480, installScripts)
  local scan = ZD.PerfScan.run()
  -- The 30k telemetry script is by far the biggest and is nearly free until
  -- you open its page. The 4k mix script never stops. Ordering by size would
  -- point the pilot at the wrong one.
  H.eq(scan.scripts[1].name, "gyro")
  H.eq(scan.scripts[#scan.scripts].name, "setup")
end)

H.test("a script shipped as both .lua and .luac counts once", function()
  local ZD = boot(800, 480, function()
    Mock.state.files["/SCRIPTS/MIXES/gyro.lua"]  = "x"
    Mock.state.files["/SCRIPTS/MIXES/gyro.luac"] = "x"
  end)
  H.eq(ZD.PerfScan.run().counts.mix, 1)
end)

H.test("an empty radio scans clean rather than failing", function()
  local ZD = boot()
  local scan = ZD.PerfScan.run()
  H.truthy(scan.ok)
  H.eq(#scan.scripts, 0)
end)

H.test("a folder that is not there is noted, not treated as a failure", function()
  local ZD = boot(800, 480, function()
    Mock.state.files["/WIDGETS/ZelionPerf/main.lua"] = "x"
    -- EdgeTX raises rather than returning an empty iterator for a path inside
    -- a folder that does not exist. Most radios have never had a
    -- /SCRIPTS/MIXES/, and that is a clean bill of health, not an error.
    Mock.state.missingDirs["/SCRIPTS/"] = true
  end)
  local scan = ZD.PerfScan.run()
  H.truthy(scan.ok, "still a usable scan")
  H.eq(scan.counts.widget, 1)
  H.eq(#scan.unreadable, 4, "the four /SCRIPTS/ folders")
end)

H.test("firmware without dir() says so instead of reporting nothing", function()
  Mock.reset()
  Mock.install()
  _G.dir = nil
  local ZD = Loader.loadPerf()
  local scan = ZD.PerfScan.run()
  H.falsy(scan.ok)
  H.truthy(string.find(scan.reason, "dir()", 1, true))
end)

H.test("reads the model's own load, keeping absent apart from zero", function()
  local ZD = boot(800, 480, function()
    Mock.state.mixes = 24
    Mock.state.logicalSwitches = { [0] = { func = 3 }, [7] = { func = 5 } }
    Mock.state.customFunctions = { [0] = { switch = 1, func = 2 } }
    Mock.addSensor("Vbat", 1, 47.3)
    Mock.addSensor("Curr", 2, 42)
    Mock.state.sensors[1].logs = true
  end)
  local m = ZD.PerfScan.run().model
  H.eq(m.mixes, 24)
  H.eq(m.logicalSwitches, 2, "empty slots are not counted")
  H.eq(m.specialFunctions, 1)
  H.eq(m.sensors, 2)
  H.eq(m.loggedSensors, 1)
end)

--------------------------------------------------------------------------
H.group("perf: findings")

local function snapshotOf(fields)
  local s = { frames = 500, fps = 30, p50 = 3, p95 = 4, worst = 5,
              stalls = 0, freeMemory = 45000 }
  for k, v in pairs(fields or {}) do s[k] = v end
  return s
end

local CLEAN = { ok = true, scripts = {}, unreadable = {},
                counts = { mix = 0, func = 0, widget = 2, telem = 0, tool = 0 },
                model = { sensors = 8, loggedSensors = 0 } }

H.test("a clean radio gets one answer and no busywork", function()
  local ZD = boot()
  local f = ZD.PerfAdvice.build(snapshotOf(), CLEAN, nil, nil)
  H.eq(#f, 1)
  H.eq(f[1].title, "Nothing worth changing")
  H.eq(f[1].tone, "good")
end)

H.test("a slow UI is the top finding", function()
  local ZD = boot()
  local f = ZD.PerfAdvice.build(snapshotOf({ fps = 11 }), CLEAN, nil, nil)
  H.eq(f[1].severity, ZD.PerfAdvice.HIGH)
  H.truthy(string.find(f[1].title, "11", 1, true))
end)

H.test("mix scripts are called out even when the frame rate is fine", function()
  local ZD = boot()
  local scan = { ok = true, scripts = {}, unreadable = {},
                 counts = { mix = 2, func = 0, widget = 0, telem = 0, tool = 0 },
                 model = {} }
  local f = ZD.PerfAdvice.build(snapshotOf(), scan, nil, nil)
  H.eq(f[1].severity, ZD.PerfAdvice.HIGH)
  H.truthy(string.find(f[1].title, "2 mix scripts", 1, true))
  H.truthy(string.find(f[1].detail, "MIXES", 1, true))
end)

H.test("a low heap outranks a full sensor list", function()
  local ZD = boot()
  local scan = { ok = true, scripts = {}, unreadable = {},
                 counts = { mix = 0, func = 0, widget = 0, telem = 0, tool = 0 },
                 model = { sensors = 44, loggedSensors = 0 } }
  local f = ZD.PerfAdvice.build(snapshotOf({ freeMemory = 9000 }), scan, nil, nil)
  H.eq(f[1].severity, ZD.PerfAdvice.HIGH)
  H.truthy(string.find(f[1].title, "heap", 1, true))
  H.eq(f[2].severity, ZD.PerfAdvice.MED)
end)

H.test("stutters are judged per minute, not per session", function()
  local ZD = boot()
  -- 500 frames at 30fps is under 17 seconds. Two stalls in that is well over
  -- six a minute; the same two across ten minutes would not be.
  local busy = ZD.PerfAdvice.build(
    snapshotOf({ stalls = 2, worst = 30 }), CLEAN, nil, nil)
  local quiet = ZD.PerfAdvice.build(
    snapshotOf({ stalls = 2, worst = 30, frames = 18000 }), CLEAN, nil, nil)
  H.truthy(string.find(busy[1].title, "stutters", 1, true))
  H.eq(quiet[1].title, "Nothing worth changing")
end)

H.test("the comparison leads, and good news is toned as good", function()
  local ZD = boot()
  local cmp = ZD.PerfStats.compare({ fps = 20, spread = 1 },
                                   { fps = 29, spread = 1 })
  local f = ZD.PerfAdvice.build(snapshotOf({ fps = 29 }), CLEAN, cmp, "no gyro")
  H.truthy(string.find(f[1].title, "faster", 1, true))
  H.eq(f[1].tone, "good")
  H.truthy(string.find(f[1].title, "no gyro", 1, true))
end)

H.test("a regression is ranked as something to act on", function()
  local ZD = boot()
  local cmp = ZD.PerfStats.compare({ fps = 30, spread = 1 },
                                   { fps = 19, spread = 1 })
  local f = ZD.PerfAdvice.build(snapshotOf({ fps = 19 }), CLEAN, cmp, nil)
  H.eq(f[1].severity, ZD.PerfAdvice.MED)
  H.truthy(string.find(f[1].title, "slower", 1, true))
end)

H.test("nothing is claimed while there is still nothing measured", function()
  local ZD = boot()
  local f = ZD.PerfAdvice.build({ frames = 0, fps = nil }, CLEAN, nil, nil)
  H.eq(#f, 1)
  H.truthy(string.find(f[1].detail, "Still measuring", 1, true))
end)

--------------------------------------------------------------------------
H.group("perf: the screen")

H.test("wraps advice to the lines it has", function()
  local ZD = boot()
  local W = ZD.PerfScreen.wrap
  local lines = W("the quick brown fox jumps over the lazy dog", 12, 2)
  H.eq(#lines, 2)
  for _, l in ipairs(lines) do H.truthy(#l <= 12, "line too long: " .. l) end
  H.truthy(string.find(lines[2], "...", 1, true), "says it was cut")
end)

H.test("short advice is not marked as truncated", function()
  local ZD = boot()
  local lines = ZD.PerfScreen.wrap("all fine", 40, 2)
  H.eq(#lines, 1)
  H.eq(lines[1], "all fine")
end)

H.test("a word longer than the line is cut rather than overflowing", function()
  local ZD = boot()
  local lines = ZD.PerfScreen.wrap("/SCRIPTS/FUNCTIONS/verylongscriptname.lua",
                                   16, 2)
  for _, l in ipairs(lines) do H.truthy(#l <= 16) end
end)

H.test("builds on both screen sizes with no font clamped", function()
  for _, size in ipairs({ { 800, 480 }, { 480, 320 }, { 480, 272 } }) do
    local ZD = boot(size[1], size[2])
    ZD.Theme.fontClamps = 0
    ZD.PerfScreen.build(size[1], size[2])
    H.eq(ZD.PerfScreen.mode(), "perf",
         string.format("%dx%d", size[1], size[2]))
    H.eq(ZD.Theme.fontClamps, 0,
         string.format("%dx%d clamped a font", size[1], size[2]))
    H.truthy(ZD.PerfScreen.visibleEntries() >= 1)
  end
end)

H.test("says so rather than rendering a mess in a small zone", function()
  local ZD = boot()
  ZD.PerfScreen.build(160, 90)
  H.eq(ZD.PerfScreen.mode(), "toosmall")
  H.truthy(string.find(Mock.lvglText(), "FULL SCREEN", 1, true))
end)

H.test("puts the measurement on screen", function()
  local ZD = boot()
  ZD.PerfScreen.build(800, 480)
  ZD.PerfScreen.update({
    snap = { fps = 27.4, p50 = 3, p95 = 5, worst = 22, stalls = 1,
             frames = 400, usageMax = 41, freeMemory = 38000 },
    findings = { { severity = 2, title = "one thing", detail = "do this" } },
    scroll = 0,
  })
  local t = Mock.lvglText()
  H.truthy(string.find(t, "27.4", 1, true), "the frame rate")
  H.truthy(string.find(t, "30ms", 1, true), "typical frame, in 10ms steps")
  H.truthy(string.find(t, "one thing", 1, true), "the finding")
  H.truthy(string.find(t, "400 frames", 1, true), "how much evidence")
end)

H.test("clamps the scroll to the findings there are", function()
  local ZD = boot()
  ZD.PerfScreen.build(800, 480)
  local findings = {}
  for i = 1, 3 do findings[i] = { severity = 0, title = "f" .. i, detail = "" } end
  H.eq(ZD.PerfScreen.update({ snap = {}, findings = findings, scroll = 99 }), 0)
  H.eq(ZD.PerfScreen.update({ snap = {}, findings = findings, scroll = -5 }), 0)
end)

--------------------------------------------------------------------------
H.group("perf: the widget")

local function widget(ZD, w, h)
  return ZD.PerfWidget.create({ x = 0, y = 0, w = w or 800, h = h or 480 }, {})
end

H.test("a frame of the analyser allocates no LVGL objects", function()
  local ZD = boot()
  local wg = widget(ZD)
  ZD.PerfWidget.refresh(wg, nil, nil)
  local after = #Mock.lv.objects
  H.truthy(after > 0, "something was built")

  -- The entire point of retained mode, and the one property that decides
  -- whether this widget is a measuring instrument or part of the problem.
  for i = 1, 120 do
    Mock.advance(4)
    ZD.PerfWidget.refresh(wg, nil, nil)
  end
  H.eq(#Mock.lv.objects, after, "objects were created on a later frame")
  H.eq(Mock.lv.cleared, 1, "the screen was rebuilt")
end)

H.test("does not rebuild the findings on every frame", function()
  local ZD = boot()
  local wg = widget(ZD)
  ZD.PerfWidget.listBuilds = 0
  -- 300 frames at 30fps is ten seconds, so about twenty rebuilds at the
  -- half-second throttle. Rebuilding per frame would be 300 - inside the one
  -- widget whose findings include "something here is allocating per frame".
  for i = 1, 300 do
    Mock.advance(3)
    ZD.PerfWidget.refresh(wg, nil, nil)
  end
  H.truthy(ZD.PerfWidget.listBuilds < 30,
           "rebuilt " .. ZD.PerfWidget.listBuilds .. " times in 300 frames")
  H.truthy(ZD.PerfWidget.listBuilds > 5, "and it is still being refreshed")
end)

H.test("the wheel scrolls the list", function()
  local ZD = boot(480, 272, installScripts)
  local wg = ZD.PerfWidget.create({ x = 0, y = 0, w = 480, h = 272 }, {})
  ZD.PerfWidget.update(wg, { Scripts = 1 })
  Mock.advance(4)
  ZD.PerfWidget.refresh(wg, nil, nil)
  -- The page indicator, not the whole screen: the readings beside it change
  -- every frame by design, so comparing the lot would only ever prove that
  -- the frame rate moved.
  local function page()
    return string.match(Mock.lvglText(), "(%d+%-%d+/%d+)")
  end
  H.eq(page(), "1-3/7", "three of seven entries fit at 480x272")

  for i = 1, 3 do
    Mock.advance(4)
    ZD.PerfWidget.refresh(wg, _G.EVT_VIRTUAL_NEXT, nil)
  end
  H.eq(page(), "4-6/7", "the list moved")

  -- And cannot be wound off either end.
  for i = 1, 40 do
    Mock.advance(4)
    ZD.PerfWidget.refresh(wg, _G.EVT_VIRTUAL_NEXT, nil)
  end
  H.eq(page(), "5-7/7", "stops at the last full page")

  for i = 1, 40 do
    Mock.advance(4)
    ZD.PerfWidget.refresh(wg, _G.EVT_VIRTUAL_PREV, nil)
  end
  H.eq(page(), "1-3/7", "scrolled back to the top and stopped")
end)

H.test("drives to a settled frame rate and finds nothing wrong", function()
  local ZD = boot()
  local wg = widget(ZD)
  for i = 1, 200 do
    Mock.advance(3)                     -- about 33fps
    ZD.PerfWidget.refresh(wg, nil, nil)
  end
  local t = Mock.lvglText()
  H.truthy(string.find(t, "Nothing worth changing", 1, true), t)
end)

H.test("ENTER marks a baseline and ENTER again clears it", function()
  local ZD = boot()
  local wg = widget(ZD)
  for i = 1, 200 do
    Mock.advance(4)
    ZD.PerfWidget.refresh(wg, nil, nil)
  end
  H.truthy(string.find(Mock.lvglText(), "no baseline", 1, true))

  Mock.advance(4)
  ZD.PerfWidget.refresh(wg, _G.EVT_VIRTUAL_ENTER, nil)
  H.truthy(ZD.PerfProbe.baseline, "baseline captured")

  for i = 1, 200 do
    Mock.advance(2)                     -- the pilot removed something
    ZD.PerfWidget.refresh(wg, nil, nil)
  end
  H.truthy(string.find(Mock.lvglText(), "baseline", 1, true))
  H.truthy(string.find(Mock.lvglText(), "faster", 1, true), Mock.lvglText())

  Mock.advance(4)
  ZD.PerfWidget.refresh(wg, _G.EVT_VIRTUAL_ENTER, nil)
  H.falsy(ZD.PerfProbe.baseline, "baseline cleared")
end)

H.test("the script list is reachable and ordered by what runs most", function()
  local ZD = boot(800, 480, installScripts)
  local wg = widget(ZD)
  ZD.PerfWidget.update(wg, { Scripts = 1 })
  Mock.advance(4)
  ZD.PerfWidget.refresh(wg, nil, nil)
  local t = Mock.lvglText()
  H.truthy(string.find(t, "6 scripts installed", 1, true), t)
  H.truthy(string.find(t, "gyro", 1, true), "the mix script is listed")
  H.truthy(string.find(t, "every cycle", 1, true), "and when it runs")
end)

H.test("the settings toggles act once, on the transition", function()
  local ZD = boot()
  local wg = widget(ZD)
  for i = 1, 200 do
    Mock.advance(4)
    ZD.PerfWidget.refresh(wg, nil, nil)
  end
  ZD.PerfWidget.update(wg, { Mark = 1 })
  H.truthy(ZD.PerfProbe.baseline)
  local first = ZD.PerfProbe.baseline

  -- Held on. A firmware that calls update() again must not re-mark, which
  -- would silently throw away the baseline the pilot is comparing against.
  ZD.PerfWidget.update(wg, { Mark = 1 })
  H.eq(ZD.PerfProbe.baseline, first)
end)

H.test("survives a zone too small, and one with no telemetry at all", function()
  local ZD = boot(480, 272)
  local wg = ZD.PerfWidget.create({ x = 0, y = 0, w = 100, h = 60 }, {})
  Mock.advance(4)
  ZD.PerfWidget.refresh(wg, nil, nil)
  H.eq(ZD.PerfScreen.mode(), "toosmall")
end)

H.test("costs nothing off screen", function()
  local ZD = boot()
  local wg = widget(ZD)
  Mock.advance(4)
  ZD.PerfWidget.refresh(wg, nil, nil)
  local objects = #Mock.lv.objects
  for i = 1, 50 do
    Mock.advance(4)
    ZD.PerfWidget.background(wg)
  end
  H.eq(#Mock.lv.objects, objects)
  H.eq(ZD.PerfProbe.snapshot().frames, 0, "no frames invented off-screen")
end)

end
