A red band across the floor of the battery tile, for the two things on the
screen that are about what you do next rather than about the helicopter: the
flight still being written to the card, and a pack number nobody has looked at.

## The 45 second wait is now visible, and audible

A flight is written 45 seconds after you land, so `end_cell` is a rested
voltage rather than one still climbing. Switch the radio off inside that window
and the flight is gone. Until now the only sign the window existed was the
three rising notes at the end of it.

The band now counts it down - **KEEP POWER ON 38s** - and a **double beep every
ten seconds** says it is still running, for when the radio is under your arm and
the screen is pointing at the ground. The beep is a single high note, well clear
of the pitches the alerts use, so "not finished" cannot be mistaken for "something
is wrong". The three rising notes still mean what they have always meant: the
flight is on the card and the radio can go off.

## And it says when the pack number has not been checked

Nothing in telemetry knows which pack is on the aircraft, so the number is
yours to set - and the commonest way a log row goes wrong is that it was not
set, so the last flight's number rides into the next row and every per-pack
comparison built on the log quietly averages two packs together.

The band now reads **CHECK PACK 3**, with the number in it, so one glance is the
whole check. It appears on the ground, with a pack plugged in, when the number
has not been moved since the last flight ended - and it clears the moment you
set it. A radio that comes on with the number still at last session's value gets
it too, because the option comes back from the model file holding whatever it
held when the radio went off.

If you have never set a pack number, nothing changes: you are not keeping a pack
series, the log's `pack` column is honestly blank, and the band stays away. A box
that is up every time the radio comes on is a box that stops being read.

The three footnotes under the band (MIN, SAG, mAh) stand down while it is up and
come straight back after. Nothing else on the dashboard moves.

## Install

`ZelionDash-1.15.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

`sensors.cfg` is yours and is never shipped; the reference config is in the zip
as `sensors.cfg.example`.
