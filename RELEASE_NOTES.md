One bug, found by the flight log itself.

## Install

`ZelionDash-1.5.2.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## `ir_mohm` was never written

1.4.0 added a measured pack internal resistance and a column to put it in. A
47-flight log, covering every build since, has that column **blank on every
single row** — including flights where the measurement certainly succeeded.

The measurement was fine. The handover was not.

A flight's row is written *after* the rotor stops. `State` knows this and
clears its extremes on the **arm** edge, so a landed flight still has its
minimum cell and peak current to report. `PackHealth` cleared itself on the
**disarm** edge instead — and `Widget.refresh` services `PackHealth` before
`FlightLog`, on the very frame that latches the disarm:

```
State.service    -> armed goes false, disarmPending = true
PackHealth.service -> not armed: reset(), milliohms = nil
FlightLog.service  -> writes the row, reads nil
```

So the column could never be filled, on any flight, on any aircraft. The reset
now happens when a flight starts, matching `State`.

## The test that asserted the bug

There was a test here named `each flight measures its own pack`, and it
required `milliohms` to be nil once the rotor stopped. That is precisely the
condition that guarantees an empty column — the bug was pinned in place by a
test that agreed with it.

It now checks the two things that actually matter, separately: the figure
**survives the disarm that writes it**, and the **next** flight starts from
nothing rather than inheriting the last one's answer. A third test formats a
real record and asserts the last field parses as a number near the synthetic
pack's known resistance — the assertion that would have caught this in 1.4.0.

## Tests

339, up two.
