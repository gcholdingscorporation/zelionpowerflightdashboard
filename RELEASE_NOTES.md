The sensor map no longer costs the dashboard its logo.

## Install

`ZelionDash-1.11.2.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## Holding the sensor map open was decoding the artwork at the frame rate

The sensor map rebuilds its rows on every refresh, which is the right thing for
rows that read live telemetry. One block in it was not live telemetry: the
`-- ARTWORK --` summary, which lists the folder and opens each PNG to report
whether it loads and how wide it measures.

`Bitmap.open` allocates. Probing a file costs as much memory as displaying it,
and `Host.imageLoads` has carried that warning since the heap exhaustion that
faulted the script - which is why the dashboard's rebuild path has a test named
"a rebuild does not re-open the artwork". The sensor map's path never had one.
So leaving the sensor map on screen opened and dropped the whole artwork set
several times a second.

Two things came out of that, and pilots reported both without knowing they were
the same fault. The frame rate fell while the sensor map was up. And the heap
it churned was no longer enough for `Dashboard.build` to afford its own bitmap,
so the degradation ladder caught the raise and rebuilt without it - leaving the
**ZELION POWER wordmark in place of the logo**, with everything else looking
healthy and nothing on screen saying why.

`Host.probeImage` now caches per path and drops its bitmap through
`Host.collect`, which is what `imageLoads` already did. `assetRows` memoises the
block it builds. `Host.resetImageProbes()` clears both, and the options screen
calls it, so swapping a PNG over USB is still picked up without a reboot.

Caching the probe has a second effect worth naming: the sensor map and the
dashboard now agree about the same file. The screen you consult when something
is wrong should not be reading a different answer from the screen that is wrong.

## Tests

390, up one. The new guard holds the sensor map open for thirty refreshes and
asserts `Bitmap.open` is not called again - verified failing on the code this
release fixes.
