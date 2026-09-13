The aircraft that cannot name themselves are now identified by their cell count.

## Install

`ZelionDash-1.9.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## When the flight controller will not say

1.8.0 let the flight controller identify the aircraft, so one EdgeTX model
could fly several helicopters. That works on Rotorflight, which reports a craft
name. OMPHOBBY's **OSF03 has no provision for one**, so those aircraft arrive
anonymous — and on one model slot, anonymous means indistinguishable.

What they do bring is a **cell count**. A fleet whose unnamed aircraft differ
in cells is fully separable by it:

```ini
[cells:3]
craftName = Omphobby M2 V3

[cells:2]
craftName = Omphobby M1 V3
```

That name is written to the log's `craft` column exactly as a reported one
would be. A `[cells:N]` section takes role overrides like any other, so an
aircraft on a different flight controller can have its own sensor bindings
without its own model slot.

Layering is `[*]` → `[model slot]` → `[cells:N]` → `[craft]`, most specific
last. **A reported craft name always wins over a cell count** — a name is a
fact and a count is an inference. That is what keeps two aircraft that share a
cell count apart when only their names differ.

## `cells` column

The cell count is now logged in its own right. It is the discriminator of last
resort, it costs four characters a row, and it is what separated five aircraft
in a log that had been flying them all under one model name.

## A reload that was far too big

The first version of this reloaded the model when the cell count changed. The
cell count is derived from pack voltage over cell voltage, so a **supply
collapse moves it** — and a model reload resets the session, throwing away the
flight's recorded minimum at the exact moment that minimum was worth having.

It re-resolves the sensor bindings now and nothing else. A different cell count
means different overrides; it does not mean a different flight.

## Tests

361, up five. Three mutations verified. Restoring the oversized reload fails 35
tests, which is a fair measure of what it was doing.
