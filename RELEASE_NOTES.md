The ESC usually knows before you do. This reads what it is already saying.

## Install

Download `ZelionDash-1.5.0.zip`, unzip it, copy the `WIDGETS` folder onto the
radio, and **delete `main.luac`** beside the `main.lua` you replaced.

**Then switch the sensors on.** `Esc#` and `EscF` are not in Rotorflight's CRSF
telemetry list by default, and without them this does nothing at all. Add both,
rediscover sensors on the radio, and an `-- ESC --` row appears on the sensor
map naming your ESC vendor and what it is reporting.

## What it does

Rotorflight publishes the vendor signature and the ESC's own status word. A
decoded fault — desync, over-temperature, a motor connection the ESC does not
like — now sounds an alert and names itself on the sensor map, rather than
waiting for you to notice a temperature climbing.

## What it deliberately does not do

**The firmware never interprets that status word.** Every decoder in
`esc_sensor.c` ends `escSensorData[0].status = tele->status1` — the bytes are
handed on exactly as the ESC sent them. The meaning belongs to the vendor, and
there are sixteen of them.

**Three have their bit layouts documented in the firmware**: HobbyWing V5,
Scorpion and OpenYGE. Those three are implemented from that documentation, bit
by bit, with a test for every bit.

**Every other ESC shows its code and raises nothing.** It is tempting to treat
any non-zero status as a fault — one rule, all sixteen vendors, done. It is
wrong on the first one you try. OpenYGE keeps the **motor state** in the low
nibble, so a perfectly healthy ESC running normally reports `0x0E` for the
entire flight. That rule would not degrade gracefully on an unknown ESC; it
would invent a fault on every flight, and an alert that cries wolf is worse than
no alert.

OpenYGE also shows why the state cannot be skipped: the same warning bit is a
*warning* or a *failure* depending on the motor state it arrives with, because
the firmware documents each as "Fail if Motor Status ...".

A vendor gets added when its layout can be read from somewhere authoritative,
not when a plausible guess is available.

## An ESC that sends no status is not reported as healthy

BLHeli32, HobbyWing V4, Castle, BLHeli_S and AM32 have no status field at all,
so `EscF` sits at zero for the whole flight. The row reads **no status sent**
rather than **ok**, because "ok" would be a claim and this is a fact.

## Tests

337, up from 322. Fifteen new, and every expectation traces to a comment block
in `esc_sensor.c` rather than to a plausible reading of one. Five mutations were
run against the decoder's judgement calls and all five are caught — including
the one that matters most, treating an unknown vendor's code as a fault.
