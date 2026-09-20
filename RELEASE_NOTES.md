The radio no longer says "timer elapsed" every time you switch it on.

## Install

`ZelionDash-1.11.1.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## Zero is not a neutral value on a countdown timer

With no estimate to show, the widget wrote **0** into the timer it drives. That
was deliberate, and 1.10.0's notes explain why: writing nothing leaves the
previous pack's number sitting there, and arming a fresh battery to a timer
reading four minutes is exactly the kind of stale-but-plausible number this
widget exists not to produce.

Zero clears it. Zero also happens to be a state EdgeTX announces. Power the
radio on and the widget writes zero before anything has flown, so the radio
says **"timer elapsed"** on every boot - an alert with nothing behind it, which
is how alerts stop being believed.

It writes the timer's own **start** value now. A countdown sitting at its start
reads as ready rather than as spent, it is what EdgeTX itself puts there at
model load, and it is still not the last pack's number. A timer with no start
configured has nothing better available and keeps the zero.

Nothing else changed. The estimate, the monotonic floor and the pack-change
checks are all as they were in 1.11.0 - this is only what goes on the timer
when there is no estimate to put there.

## Tests

389, up two. Three mutations verified, including restoring the zero, which
fails exactly the two tests that describe the fault and no others.
