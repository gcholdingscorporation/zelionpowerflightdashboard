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
| **heap free** | Free Lua heap. Under about 25k, collection starts costing frames; under 12k scripts begin failing to load. |

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

**The analyser reports its own cost.** Its screen is retained-mode LVGL —
objects created once, only changed properties written to them — and the
findings list is rebuilt about once a second rather than every frame, so a
frame of it is mostly comparisons. It is not allocation-free, and it does not
claim to be: the heap difference across its own refresh is measured and shown
on screen, so you can check it against everything else rather than take it on
trust. Off screen it does no work at all.

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
