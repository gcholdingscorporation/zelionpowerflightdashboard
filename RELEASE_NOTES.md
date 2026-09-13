The helicopter identifies itself, so one model slot can fly all of them.

## Install

`ZelionDash-1.8.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## One EdgeTX model, several helicopters

A radio can be set up with one model per aircraft, or with **one model** and the
configuration kept on the flight controllers — deliberately, so that several
model slots cannot drift apart from each other. This release is for the second
kind, which everything here previously assumed away.

Under that setup the EdgeTX model name is a constant. It says nothing about
which helicopter flew, and every part of this widget that identified an
aircraft was reading it.

RF Tool already knew better. The flight controller reports its own craft name,
and the widget was already displaying it in the sensor map footer — it just was
not used for anything that mattered.

### `craft` column

New log column: what the flight controller calls the aircraft, blank when there
is no RF Tool or no link.

`model` keeps its meaning — the radio's model slot. Both are written. That
column has meant one thing for every row already on the card, and quietly
redefining it is how a log stops being comparable with itself.

A pack's identity is now `craft` + `pack`, falling back to `model` + `pack`. On
a one-model radio, number every physical pack uniquely across the fleet rather
than restarting at 1 per aircraft.

### `sensors.cfg` sections can name the craft

```ini
[ALZRC Devil 380]
escTemperature = Tmp1
```

Layered `[*]` → `[model slot]` → `[craft]`, most specific last. The craft
section wins where both name the same role, because it describes exactly one
helicopter and the slot describes every aircraft flown from it.

Applied the moment the flight controller reports a different craft, so swapping
helicopters rebinds without touching the radio. The `-- PACK --` row names the
craft too.

## A bug in the path this depends on

RF Tool's craft name was only re-read when the **API version** changed. That
happens to cover swapping helicopters, because the link drops in between and
the version goes away and comes back. Happens to.

Two aircraft on the same Rotorflight build, or a rename in the configurator,
and the widget went on reporting the previous helicopter's name — which matters
most to exactly the setup that needs it, where that name is the only thing
identifying what flew. The name is now watched in its own right.

## Tests

356, up eight. Four mutations verified: not re-reading the craft name, not
reloading when it changes, ignoring craft sections, and layering the craft
before the slot instead of after.
