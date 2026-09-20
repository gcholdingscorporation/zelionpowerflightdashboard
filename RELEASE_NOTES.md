A reserve can now belong to one helicopter instead of to the whole radio, and a
corrupted row in the flight log is moved aside rather than deleted.

## Install

`ZelionDash-1.11.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## One reserve could never suit the whole fleet

`reservePct` decides where the countdown reaches zero, and it lived in
`[battery]`, which means it applied to every aircraft the radio flew. On a fleet
that is the wrong shape of setting. The number that lands a 6S 2200 with
something left in the pack lands a 2S micro several minutes early, and a number
between the two satisfies neither.

The five `[battery]` settings — `cellFull`, `cellMin`, `alertCell`, `alertEsc`
and `reservePct` — can now be written inside an ordinary section as well:

```
[battery]
reservePct = 40        # the radio-wide default, as before

[OMP M4 Max]
reservePct = 45        # this helicopter only
```

They resolve through the same chain the sensor bindings already used,
`[*]` → `[model]` → `[cells:N]` → `[craft]`, with `[battery]` underneath all of
it. Most specific wins, and a reported craft name always beats a cell count,
because a name is what the flight controller says and a cell count is something
the widget worked out.

Nothing changes for a radio that flies one helicopter. `[battery]` on its own
resolves to exactly the numbers it did before, defaults included.

A section whose header does not match what the flight controller reports is
inert, not wrong: that aircraft falls back to `[battery]`. The sensor map's
`-- CONFIG --` row is still the place to check which sections actually applied.

## The reserve can move while you fly, and only downwards

The craft name arrives from the flight controller a moment after the link comes
up, so a reserve scoped to a craft lands slightly after power-on — which means
it can change under a countdown that is already running.

In practice you will never see it. The name arrives within a second or two,
long before the pack is under 95% and long before eight seconds of flight have
been measured, so there is no estimate on screen yet to move.

Forced anyway, it is safe in both directions. A helicopter-specific reserve is
usually the higher number, so the countdown gets shorter — you land earlier,
which is the side to be wrong on. A lower one would, on the arithmetic alone,
hand back time you have already been told you do not have; the monotonic floor
refuses, and there are now tests saying so out loud in both directions.

## A row that is not a row is moved, not deleted

The flight log is rewritten whole on every flight. A row that cannot be parsed
back — a card pulled mid-write, a file opened in something that mangled it —
used to be dropped on the next rewrite, taking whatever was still readable in
it with it.

Unreadable rows are now written to `zeliondash.bad.csv` beside the log first,
and only then left out of the rewrite. If that file cannot be written the log is
left exactly as it was, wreckage included. Losing a flight to a failed recovery
is worse than carrying a bad line.

The sensor map gains a row when it happens, naming the file rather than
reporting a count and leaving you to guess where the rows went.

A row is only wreckage if it carries a control character. A column-count check
was written first and two existing tests caught it: columns are only ever
appended to this log, and a spreadsheet drops trailing empty fields when it
saves, so a genuinely short record is a record. That check would have
quarantined real flights.

## The shipped `sensors.cfg.example` is worth re-reading

It previously stated that a setting could not be scoped, which is now the
opposite of true. It has a worked section on scoping one, and the reference
copy lands on the card as `sensors.cfg.EXAMPLE`, never as `sensors.cfg` — your
own overrides are never overwritten by an upgrade.

## Also

The README now says that EdgeTX holds 60 telemetry sensors, which is the cap
that matters on a radio flying several aircraft from one model slot.

## Tests

387, up 22 on 1.10.0. Every behavioural change was mutation-verified, including
the two that had no coverage at all until a mutation proved it: the call that
re-scopes the settings when the bindings reload, and the monotonic floor holding
a reserve that arrives late.
