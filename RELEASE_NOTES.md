Two safety changes, both about the widget being honest when something has gone
wrong. Verified across three aircraft on the bench and in the air: a Rotorflight
OMPHOBBY M7R on 12S, an OMP M4 Max on 6S, and a 200-size OSF03 micro on 3S.

## Install

Download `ZelionDash-1.2.0.zip`, unzip it, and copy the `WIDGETS` folder onto
the radio's storage, merging with the one already there.

**Delete `main.luac`** next to the `main.lua` you just replaced, or the radio
keeps running the stale compiled copy and nothing on screen will tell you so.

## A pack that falls off is no longer read as a pack that is flat

A connector letting go in flight does not stop the telemetry. The flight
controller keeps talking on the ESC's capacitors, or on a backup buffer, while
the voltage walks down under it — 3.9 V per cell, then 3.3, then 2.4, then
nothing. Every one of those is a number a real cell could show.

They were being recorded as the flight's minimum and announced as a flat
battery. The second is worse than silence: the one alarm that has to be trusted,
saying something untrue.

Judging each reading by how far it dropped does not work, and the tests say so.
A decay does not arrive in one jump — 3.55, 2.95, 2.35, 1.75 — and every one of
those steps passes for sag. Four "ordinary" readings later the flight minimum
reads 1.75 V. A step rule is also secretly a rule about how fast your flight
controller sends telemetry, since one service pass may carry 100 ms of change or
500 ms of it.

What actually separates them is that a collapse never stops. Sag stops, and then
recovers, because the pilot eases off. So a falling reading is now **shown but
not trusted**: the tile stays live, because that is what a dashboard is for,
while the flight's minimum and the low-cell alarm wait for the fall to stop.
That wait is a fraction of a second of real sag, and never, for a decay.

Past 0.8 V per cell of unbroken fall it is a collapse. The reading is refused
outright, and **MAIN POWER LOST** sounds in place of the low-cell alarm,
repeating every six seconds and reading out the BEC voltage where the aircraft
publishes one — the buffer, counted down out loud. Armed only: a pack pulled on
the bench collapses identically and is not an emergency.

## A pack check before the flight, not after

Once per pack, on the ground, eight seconds after telemetry settles so the ESC's
inrush dip is not mistaken for the state of charge, cell voltage is compared
against `cellFull` and spoken if the pack is short. A half pack flies exactly
like a full one for the first minute, which is the whole problem with finding
out later.

Asked once and answered once, whichever way it goes. Plugging in the next pack
asks again.

Checked against a 4.31 V per cell LiHV reading off a real 3S micro, because a
check that flags the fullest pack you own is a check that gets switched off.

## Tests

297, up from 281. Eight mutations were run against the new guards; four survived
the first pass, and each one turned out to be a missing test rather than dead
code. They produced three cases the first version got wrong: a buffer that holds
the rail at 2 V per cell and stops there, which no plausibility floor can catch;
a rail already dead at power-up, which the fall logic cannot catch because there
is nothing to compare against; and a fresh pack after a telemetry gap, refused
forever as a decay because the widget still remembered the pack before it.

## Credit

The physical insight behind the first change — that a collapse is told from sag
by behaviour, not by magnitude — comes from reading
[flugifix/ultidash](https://github.com/flugifix/ultidash). No code is taken; it
is GPLv3 and this is not.
