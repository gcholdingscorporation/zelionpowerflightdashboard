Fixes from the first month of flying, and a sensor map you can read from arm's
length. Verified in the air over four flights on a Rotorflight OMPHOBBY M7R on
12S, with the earlier 1.0.0 verification on a TX15 and a 200-size OSF03 still
standing.

## Install

Download `ZelionDash-1.1.0.zip`, unzip it, and copy the `WIDGETS` folder onto
the radio's storage, merging with the one already there.

**If you had 1.0.0 installed, delete `main.luac`** next to the `main.lua` you
just replaced. The radio otherwise keeps running the stale compiled copy, and
nothing on screen will tell you so.

If you added `throttle = off` to `sensors.cfg` to stop the link-quality sensor
being read as throttle, you can leave it or remove it. The widget no longer
makes that guess on its own.

## Fixed

- **The aircraft profile decided on one reading.** A 12S pack that came up
  reading low for a moment was classified as a 200-size, and the widget then
  rejected its own pack voltage and capacity as out of range for the rest of
  the flight. Detection now watches for three seconds and decides on the
  highest reading seen. A profile that keeps rejecting readings the role
  itself accepts is abandoned and redetected.
- **Throttle bound to the wrong sensor.** Rotorflight does not publish a
  throttle sensor unless it is enabled in its CRSF telemetry list. Without one,
  the widget guessed the only spare percent sensor - `TQly`, transmitter link
  quality - and showed THR 100% on a disarmed heli. A sensor any role knows by
  name is never handed to a different role as a guess now. Throttle shows as
  unbound instead, which is the truth.
- **Safe mode could draw black on black.** The last-resort screen was the only
  one that did not build its own colour palette. Found by rendering it.

## Sensor map

The diagnostics screen is where you go when a tile shows dashes, and it was
spending more than half its first page on roles that had bound to nothing.

- Roles that bound to nothing fold into one counted line, names included.
  Every bound role and the whole status block now fit on the first page.
  Important roles that are unbound keep their own row, in amber.
- Governor reads `4 ACTIVE`, not `4`. Every value carries its unit - which is
  what caught the throttle binding above.
- On the TX16S the list is set one font size larger, 23px instead of 17px.
  The TX15 keeps its size: at 480 wide the columns cannot hold the text any
  larger without clipping.
- The flight controller's flight count sits in the RF Tool row. The artwork
  check moved to the bottom and leads the list only when a file failed to load.

## Documentation

- The README carries screenshots now, rendered from the code through the
  widget's own layout so they cannot drift from what the radio draws. All six
  are in `docs/screens.md`.
- Credits name the EdgeTX and Rotorflight source files each decision was
  checked against.

## Tests

281 automated tests, up from 268, run on every push. Each fix above has a test
that fails without it.
