A pack now has a name, and the alert self-test moved to a key.

## Install

`ZelionDash-1.6.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

**Check the Pack option after upgrading.** It occupies the slot Test Alert used
to, so a radio coming from 1.5.x will read its old Test Alert setting as pack 0
or pack 1. Both are harmless, and the sensor map shows which.

## Which pack was that

Five packs were flown on one afternoon and the log could not tell them apart.
Nothing about a pack reaches telemetry — not its capacity, not its C rating,
not its age — so a resistance trend was an average over whichever packs
happened to fly that day.

The new **Pack** widget option is the one number only the pilot can supply. It
is written to the log as a `pack` column, and together with the `model` column
it is a pack's identity: pack 2 on the M7R and pack 2 on the micro are two
different packs. Unset logs blank, never 0 — a pack numbered zero and a pack
nobody named are different things and should not group.

The sensor map gained a `-- PACK --` row, which is both the readout and the
reminder: an unset pack is not an error, but every flight logged without one is
a flight that cannot be attributed afterwards.

## Test Alert became a key press

EdgeTX 2.11 allows ten widget options per widget. This one already had ten.

The least valuable slot paid for the pack number: the alert self-test is now
**ENTER on the sensor map**, and a new `-- ALERTS --` row says so — a control
nobody can discover is not a control. It still sounds one alert and speaks the
live cell voltage, so it still proves the volume is up, the haptic is on and
the right sensor is bound.

A press is the better home regardless. A toggle that fires on its rising edge
is a control whose position means nothing, and it took two bugs to make that
one behave like a button — including the phantom "3.40 volts" from a heli that
was not even powered. ENTER on the dashboard does nothing, deliberately: that
is the screen in front of a pilot in the air.

The option was replaced **in place** rather than removed. EdgeTX stores widget
options positionally, so appending after a removal would have shifted Log
Flights up a slot and read its setting out of the one beside it.

## Tests

340, up one. The two tests that drove the old option now drive the key, and a
new one checks the dashboard ignores it. The test that reads `ir_mohm` out of a
formatted record now finds the column by name — it was reading the last field,
which broke the moment a column was appended after it, and a test that fails
when an unrelated column is added is a test people learn to edit rather than
believe.
