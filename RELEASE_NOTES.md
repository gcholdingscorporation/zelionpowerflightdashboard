One fix, reported from the field: the widget announced "3.40 volts" when
switching to a model, from a helicopter that was not powered on.

## Install

Download `ZelionDash-1.3.1.zip`, unzip it, and copy the `WIDGETS` folder onto
the radio's storage, merging with the one already there. **Delete `main.luac`**
next to the `main.lua` you replaced — the sensor map header will read
`ZELIONDASH 1.3.1` once the new file is running.

## A phantom low-cell callout on every model change

Two faults stacked into one convincing lie.

**The Test Alert option fired on every model switch.** It is meant to be
edge-triggered: switch it on, hear one alert. The memory of its previous state
lived on the module rather than on the widget, and module state does not
survive the widget being rebuilt — which is exactly what changing model does.
So an option left switched on read as a fresh off-to-on transition every single
time, and the widget sounded a test alert on each switch to that model.

**And the test invented a voltage.** With no telemetry it fell back to speaking
the low-cell alert threshold itself. So a test with nothing connected sounded
exactly like the real low-cell alarm: the right voice, a plausible number, for
a reading nobody had.

Together: change to that model, and a helicopter sitting unpowered on the bench
appeared to report a flat cell.

The memory now lives on the widget and is seeded from the option as found, so
an option already on is a state rather than a transition. The test speaks the
live cell voltage and says **nothing** when there is not one — the buzz alone
proves the alert path works without asserting a reading that does not exist.

Toggling the option off and on still sounds one alert, as it always did.

## Tests

308, up from 307. The model switch is reproduced in a test that fails without
the fix. One existing test had to be rewritten: it asserted the fallback
threshold was spoken, which was pinning the bug rather than the behaviour.
Three mutations were run against the fix and all three are caught.
