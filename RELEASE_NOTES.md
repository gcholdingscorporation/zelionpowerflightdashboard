Housekeeping. No behaviour change — every one of the 308 tests passes unaltered,
which is the point: this is a shape change, not a functional one.

## Install

Download `ZelionDash-1.3.2.zip`, unzip it, and copy the `WIDGETS` folder onto
the radio's storage. **Delete `main.luac`** next to the `main.lua` you replaced.

The version bump exists so the file on the card and the version on the sensor
map stay in one-to-one correspondence. Nothing on screen changes.

## Dead code removed

Eight definitions with no callers anywhere in the widget, the tools or the
tests: `Dashboard.assetDir`, `Dashboard.sensorMapVisible`, `Host.radioMatches`,
`Host.sourceName`, `Host.rssi`, `Host.widgetDirCandidates`, and two unused
formatters in the renderer. Three of those were dead *chains* — the resolved
EdgeTX function and its only consumer — so `getSourceName` and `getRSSI` are no
longer looked up at all.

## One writer for session extremes

Widening a recorded min/max was written out three times, in `sampleRole`,
`derivePower` and `deriveFuel`, identically apart from the variable name. The
copies had already begun to drift as guards were added to one and not the
others. There is now one `recordExtreme`, and the callers keep their own guards
because what disqualifies a reading genuinely differs between them.

## The sensor map row builder, taken apart

`sensorMapRows` had grown to 168 lines doing five jobs, and spliced its optional
rows in by position — `table.insert(rows, statsRow and 3 or 2, cfgRow)`. That
arithmetic is right until a third optional row exists.

It is now 51 lines over five named builders, each returning a row or nil, with
nil rows simply not added. Nothing counts positions any more. A shadowed local
went with it.

## What was looked at and left alone

A line-level pass flagged the `== true` and `~= false` comparisons as
redundant. They are not: `powerLost`, `linkConnected` and the sensor flags are
genuinely three-state, and nil is not false. Collapsing them would have been a
bug, so they stand.

The comment density — around 30% of the source — was also left alone. Those
comments carry the hardware findings this widget was built out of, and the
count of them is not the measure of anything.

## Net

3232 lines of code to 3203. The line count is not the story; the longest
function going from 168 lines to 51 is.
