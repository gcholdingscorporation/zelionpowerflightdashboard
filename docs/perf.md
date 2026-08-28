# ZelionPerf

A widget that measures the frame rate of the EdgeTX UI, lists every Lua script
installed on the radio with a note on when each one runs, and tells you what to
change — with a before-and-after measurement so you can see whether the change
was worth anything.

It is a separate widget from ZelionDash, built from the same source tree. You
can install either, both, or neither.

```
/WIDGETS/ZelionPerf/main.lua
```

Copy `dist/WIDGETS/ZelionPerf/main.lua` onto the radio and put ZelionPerf in a
full-screen widget slot. EdgeTX 2.11 or newer, same as the dashboard.

**Status: runs on hardware.** Verified on a RadioMaster TX16S Mk3 across two
runs: frame timing, the stutter count, gap detection, `getUsage()`,
`getAvailableMemory()`, the storage scan, the model inventory, the script
list, the baseline comparison and the text wrapping all work as written.

Between them those two runs found five bugs, every one of them in this widget
rather than in the radio, and all five are fixed. That is the tool working:
the first thing a measuring instrument measures is itself. They are listed
under **What hardware changed** below, because the two classes they fall into
are worth knowing about before trusting any number on the screen.

The frame-rate thresholds are still NOT calibrated against a radio known to be
healthy.

## What it can and cannot see

This is the first thing to understand, because it decides what the whole tool
is for.

**EdgeTX's Lua API has no way to enumerate running scripts, and no way to ask
what another script costs.** There is no process table, no per-script timer,
nothing. `getUsage()` reports the caller's own execution cycle and
`getAvailableMemory()` reports one shared heap. That is the entire surface.

So a widget cannot do what a desktop profiler does — break a frame down by
which script spent it. Any EdgeTX widget claiming a per-script cost breakdown
is inventing the numbers.

What it *can* do, and what this one does:

| | How |
|---|---|
| **Measure the UI frame rate** | EdgeTX calls a visible widget's `refresh()` once per UI frame, so the interval between calls is the frame period of the screen the widget is on. This is a real, direct measurement, and it captures the cost of *everything* — other widgets, telemetry decoding, the mixer, audio — not just Lua. |
| **Measure stutter separately from slowness** | Frame periods go into a histogram, so a steady 30 fps and a 30 fps average with four 400 ms freezes in it do not look the same. They have different causes and different fixes. |
| **Measure Lua heap pressure** | Free heap sampled every frame. The useful figure is the sum of the *downward* moves, which is bytes actually allocated — a slope would average the allocation against the collector's step and report near zero for a script allocating hard. |
| **List what is installed, and when it runs** | `dir()` over the script folders. The classification is the valuable part (below). |
| **Read the model's own load** | Sensor, mix, logical switch and special function counts. None of it is Lua, but all of it shares the main task, so it sets the budget the scripts compete for. |
| **Attribute a change by experiment** | Mark a baseline, change one thing, read the difference — with a noise band, so a difference smaller than the run-to-run spread is reported as no change rather than as a small one. |

That last row is the answer to the attribution problem. You cannot ask the
radio what a script costs, but you can measure the radio with it and without
it, and that is a better number anyway.

## When each kind of script runs

This is the part that is not intuitive, and it decides where to look first.

| Folder | Runs |
|---|---|
| `/SCRIPTS/MIXES/` | **Every mixer cycle, on every screen**, from the moment the model is selected. Navigating away does not stop it. |
| `/SCRIPTS/FUNCTIONS/` | While its special function's switch is active. |
| `/WIDGETS/` | When it is on the screen in front of you — and most also run `background()` when it is not. |
| `/SCRIPTS/TELEMETRY/` | Only while its own telemetry page is showing. |
| `/SCRIPTS/TOOLS/` | Only while open from the Tools menu. |

A 30 KB telemetry script is nearly free until you open its page. A 2 KB mix
script is never free at all. A pilot hunting a slow UI reaches for the thing
they can see, which is usually the wrong end of that list — so the script list
is sorted by how much of the time each entry runs, not by size, and the top of
it is where to start.

Size is only ever used to break ties within a class. It never becomes a claim
about cost: this tool does not guess what a script costs from how big it is.

## Using it

The screen shows the frame rate, six numbers qualifying it, and a ranked list
of findings.

**The optimisation loop is one key.** Press **ENTER** to mark a baseline. Go
and change one thing — delete a script, take a widget off the screen, turn off
sensor logging. Come back, and the top of the list tells you what it bought:

```
7.4 fps faster than the baseline (marked)
Bigger than the 1.2 fps run-to-run spread. Keep the change.
```

or, just as usefully:

```
No measurable change since the baseline (marked)
Difference is 0.6 fps against 1.4 fps of run-to-run spread, so it is not
distinguishable from noise.
```

Press ENTER again to clear the baseline and start over.

**Change one thing at a time.** The tool measures the radio, not your
intentions; two changes at once give you one number and no way to split it.

### The numbers

| | |
|---|---|
| **fps** | Frames per second, from the span of the measurement window. Green above 25, amber above 15, red below. |
| **typical / slowest 5% / worst** | Frame periods, in 10 ms steps. |
| **stutters** | Frames long enough to be seen as a hitch — over 200 ms, or over three times the typical frame on a radio that is already slow. |
| **Lua load** | Peak `getUsage()`. `n/a` on firmware that does not have it. |
| **heap free** | Free Lua heap. Under about 25k, collection starts costing frames; under 12k scripts begin failing to load. A colour radio with external SDRAM has far more than that - a TX16S reports around 19M - so on those radios this reading is context, and the heap findings correctly never fire. |

The header says how many frames are behind the figures and how much they moved
run to run (`400 frames, +/-1.2`). A frame rate from four frames and one from
four hundred otherwise look identical.

`gaps` in that line counts the times the widget was off screen. Those
intervals are detected and discarded rather than recorded as enormous frames.

### Settings

| Option | |
|---|---|
| **Mark Baseline (toggle)** | Same as ENTER, for a radio whose ENTER does not reach the widget. Acts on the transition, so leaving it on does not re-mark. |
| **Rescan Scripts (toggle)** | Re-walk the storage. Needed after installing or deleting a script — the scan is deliberately not repeated per frame. |
| **Show Script List** | Swaps the list from findings to the raw inventory. |

## Why the readings are trustworthy

**The clock is the hard part.** EdgeTX gives Lua one time source, `getTime()`,
counting 10 ms ticks. A colour radio runs its UI at 20–40 fps, so one frame
period is 3 or 4 ticks and any single measurement of it is wrong by up to a
third.

- The frame rate comes from the **span** of the window, not the mean of its
  samples. Consecutive periods telescope, so a window of 60 frames carries one
  rounding error in total rather than 60 — under 1% over two seconds.
- Percentiles are reported in whole 10 ms steps, because that is how they were
  measured. A p95 quoted as "37.4 ms" off this clock would be a fiction.
- Stalls are counted with an absolute floor far above the quantisation noise.
- No frame rate is reported at all from fewer than 8 frames.

**A difference is only called when it beats the noise.** The measurement is
split into two-second sub-windows; the spread across them is the run-to-run
noise, and a before-and-after difference smaller than that is reported as no
change. A pilot who removes a script, is told "3 fps faster", and finds it was
noise will not trust the next reading either.

**A clean radio gets a clean answer.** If nothing is wrong the list says
"Nothing worth changing" and stops. A tool that always finds five things
teaches you its findings are decoration.

**A slow radio gets names.** The measurement and the inventory are
cross-referenced rather than reported side by side: below the smooth
threshold, the frame-rate finding names the two entries that run the most and
tells you to baseline one of them, and the widget count stops being trivia and
says why a widget you are not looking at still costs frames. Entries that only
run on their own page or from the Tools menu are never named, however large —
sending you to the biggest file on the radio when it cannot be costing you
anything right now is the fastest way to waste an afternoon.

**The analyser reports its own cost, and that is not decoration.** Its screen
is retained-mode LVGL — objects created once, and a property written only when
its value has actually moved — the advice text is wrapped when the findings
list is built rather than on every frame, and the list itself is rebuilt on a
half-second timer. A settled screen writes about one property per frame: the
header note, which carries the frame count and so legitimately changes.

It is still not allocation-free and does not claim to be. The heap difference
across its own refresh is measured and put on screen, which is the point — on
the first hardware run that figure read 10k per frame, against this widget's
own name, and that is how the two causes above were found. Off screen it does
no work at all.

## What hardware changed

The first run on a TX16S found three faults, all in this widget:

- **The part exceeded the whole.** The screen read "2.5k allocated per frame …
  This widget accounts for 10k of it". The total was measured across whole
  frames and this widget's share across the inner part of one, and on a radio
  where the collector runs most frames a whole-frame span hides a collection
  far more often. The heap is now sampled on both sides of the widget's own
  work, so every segment of time belongs to exactly one of the two and the
  total is the sum of the parts by construction.
- **`19695k` of free heap.** No megabyte tier; the formatter assumed the 64k
  heap of a radio without SDRAM.
- **10k allocated per frame by the analyser itself.** A properties table built
  for LVGL on every label whether or not the value had moved, and the advice
  re-wrapped for every visible entry on every frame. Both fixed above.

### The second run

With those fixed, the same radio went from **7.9 fps to 12.5 fps** — typical
frame 100 ms to 70 ms. The analyser had been costing about a third of the
frame time it was reporting on. That is the single strongest argument for the
self-cost figure being on the screen at all.

The script list worked, and promptly showed two more faults — both the same
mistake in a different place, and both worse than a crash because they look
like data:

- **"64 special functions"**, on a model with two. `model.getCustomFunction(i)`
  returns a fully populated table for every slot below the maximum, configured
  or not, so testing "did I get a table back" was true 64 times out of 64. The
  number on screen was this code's own loop limit read back as a finding. The
  firmware's own test is switch ≠ 0, and that is what is used now.
- **No mix or input count at all.** `model.getMixesCount` takes a *channel* and
  `getInputsCount` takes an *input*; called with no argument they raise, the
  guarding `pcall` swallowed it, and the model quietly reported neither. Both
  are now summed across all channels and inputs.

The lesson both times: a number that comes back from the firmware is not
evidence that the question was understood. A count that exactly equals a
constant in your own source is the tell.

### The thresholds, calibrated

That radio measures **12.5 fps** with this widget full-screen, and its owner
confirms the menus feel laggy — the cursor lags the wheel. So `FPS_BAD` = 15
and `FPS_FAIR` = 25 are keeping their original values: the red is correct, and
the finding is telling the truth about a radio that really is slow.

That is the first threshold in this file backed by someone looking at the
radio rather than by a guess, and it is one data point. A colour radio that
measures below 15 and feels fine would be worth hearing about.

## What it will not tell you

- **Which script cost what.** Use the baseline to measure that yourself.
- **What a script does.** It reads names and sizes, never contents.
- **Anything about non-Lua load, itemised.** The mixer, telemetry decoding and
  audio all cost frames and all show up in the measured frame rate, but the
  API cannot break them out. The model counts on the script list are the
  closest thing available.

## Development

Same toolchain as the dashboard.

```sh
lua5.4 tools/build.lua    # builds both widgets into dist/
lua5.4 tests/run.lua      # runs the whole suite
```

`src/perf*.lua` are the analyser's layers, mirroring the dashboard's:

1. `perfstats.lua` — frame-timing arithmetic. Pure; no host, no EdgeTX types.
2. `perfprobe.lua` — the per-frame sampler.
3. `perfscan.lua` — the script and model inventory.
4. `perfadvice.lua` — findings and their ranking.
5. `perfscreen.lua` — retained-mode LVGL.
6. `perfwidget.lua` — the EdgeTX lifecycle.

`host.lua` and `theme.lua` are shared with ZelionDash; nothing else is.
