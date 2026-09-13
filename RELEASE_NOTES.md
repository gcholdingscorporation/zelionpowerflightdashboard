The log now records what the pack settles to after a flight.

## Install

`ZelionDash-1.7.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## `end_pack` and `end_cell`

Two new columns: the **rested** voltages after a flight.

Nothing in the log had them. `start_pack` and `start_cell` are the resting
voltages *before* a flight, `min_cell` is under load, and the voltage a pilot
actually reads off the screen after landing — the one that says whether the
timer is ending where it should — existed nowhere on the card. Calibrating the
reserve against a voltage meant transcribing numbers off photographs.

## The row now waits 45 seconds

A pack straight off a hard flight reads low and climbs for a minute, so a
voltage read at the landing is not a rested voltage. The record is formatted
when the rotor stops and held until the pack has recovered.

**This is the one place this widget trades reliability for data.** Before, a
flight was on the card the instant it ended and could not be lost. Now a radio
switched off inside that window loses it.

Everything else is handled. Telemetry dropping, the pack being unplugged, the
next flight starting — each writes the row early rather than risking it. Only a
power switch cannot be caught.

**So a three-note chime says the row is on the card.** That is the answer to
the window: it is the sound of the flight being saved, and the moment it is
safe to switch off. The sensor map reads `HOLDING a landing for its rested
voltage` until then.

The tone is synthesised, not played from a file. Which system sounds exist
depends on the firmware build and the installed language pack, and a
confirmation that is silent on somebody's radio is worse than none — the same
reasoning that has always kept `.wav` files out of the alerts. It is a rising
major arpeggio, deliberately unlike the alerts, which are a haptic buzz and a
spoken number.

## Blank rather than nearly

When a row goes early the flight is still written in full, and those two
columns are left **empty**. A voltage read seconds after a landing sits several
hundredths below a settled one and is indistinguishable from it in the column —
and this column exists to calibrate a reserve against a voltage. Blank, never
nearly.

The chime stays silent if the card refuses the write. A confirmation for a lost
flight would be worse than no confirmation.

## Tests

348, up seven. Verified by mutation: removing the wait, never flushing early,
and chiming regardless of the write each fail tests that name what broke.
