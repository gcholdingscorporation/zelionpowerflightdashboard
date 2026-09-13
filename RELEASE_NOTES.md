One fix, found while checking the install instructions for 1.6.0 were true.

## Install

`ZelionDash-1.6.1.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## A settings-only `sensors.cfg` read as one that did nothing

The `-- CONFIG --` row exists to catch a file that is silently doing nothing —
a section header naming the aircraft rather than the EdgeTX model it flies on
applies nothing at all and is otherwise completely invisible.

It counted only role-to-sensor sections. `[battery]` is a reserved settings
section, so a file like

```ini
[battery]
reservePct = 40
```

read **`no section for this model`, `0 overrides`, in amber** — while that
reserve was in force and moving the flight timer.

That is the row's own failure mode pointed the wrong way: it told a pilot their
config was doing nothing at the moment it started working. It now counts named
settings too, and reads `[battery]  1 override`.

The settings themselves were always applied correctly. Only the diagnostic was
wrong — but a diagnostic nobody can trust is worse than none.

## Tests

341, up one. It fails without the fix.
