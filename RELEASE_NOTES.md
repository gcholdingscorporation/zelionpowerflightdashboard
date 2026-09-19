The countdown now survives a landing, and the craft column stops hiding itself.

## Install

`ZelionDash-1.10.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## The second flight of a pack counted down in silence

Land with pack left, launch again, and the timer made no callouts.

On disarm the estimate was cleared along with its monotonic floor. Re-arming
rebuilt it from scratch, so the timer **jumped back up** — and EdgeTX announces
a threshold as a timer walks down through it, and will not speak one it has
already passed. The first flight said sixty, thirty, twenty, ten. The second
flight walked down through the same values in silence.

The floor now survives a landing. The rate is still re-measured every flight;
only the floor persists, because it belongs to the pack and the pack is still
on the aircraft.

## A pack change still wipes it

This is the trap, and it is worth being explicit about. Keeping the floor
across a landing is right. Keeping it across a **pack** is a full battery
reading forty seconds remaining, with no way back up, because a floor only
falls.

The existing new-pack guard could not catch it: it compares against the first
sample of the current flight, and the samples are cleared on every landing, so
it only ever saw a counter reset **mid**-flight. Two checks now bracket the
gap between flights:

- the consumed figure opening lower than the last flight closed at, which is a
  flight controller that lost power;
- a pack reading over 95%, which cannot be the one just landed on — belt and
  braces for a flight controller that kept power through the swap, or a
  percentage published from voltage rather than counted coulombs.

## No stale number on the timer

With no estimate, `driveTimer` used to write nothing, which leaves the previous
flight's value on the timer. Arm on a fresh pack and it read four minutes —
from the pack before it — until the new one fell below 95%. It writes zero now.
A stale number that looks live is the one thing this widget exists not to do.

## `craft` stops hiding itself

The column was suppressed when the resolved name matched the EdgeTX model name,
to avoid repeating the column beside it. That made an empty cell mean two
different things: "nothing named this aircraft" and "its name happens to match
the slot". A real log came back blank on every row of an aircraft the flight
controller had named perfectly well.

It is written whenever anything names the aircraft. Blank now means only that
nothing did.

## Tests

365, up four. Four mutations verified, including the naive version of this fix
— keep the floor, skip the cross-flight pack check — which passes every other
test in the file and fails exactly the two that matter.

One existing test had to be rewritten twice. It compared the two flights'
estimates directly, which proves nothing: the pack is emptier the second time,
so the number falls either way. It passed with the bug still in place.
