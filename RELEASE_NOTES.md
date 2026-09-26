The logo comes back. Rebuilding the screen no longer runs out of the budget
EdgeTX gives it.

## What was wrong

EdgeTX allows a widget 20,000 Lua instructions per callback and kills anything
that runs longer. Rebuilding the dashboard after an options change was doing
its config reload, its sensor reload and the whole screen build inside one of
those, which came to 99.6% of the budget on 1.11.4 and tipped over it on a
radio carrying a lot of sensors.

Over the limit did not look like a fault. The widget's own fallback caught it
and rebuilt one step down, without artwork, so the screen came back looking
healthy with the ZELION POWER wordmark in place of the logo. If you saw that,
this is why, and the sensor map's top row said `no-logo - CPU limit`.

## What is different

The build now gets a callback to itself. The worst single call drops from
20,369 instructions to 13,753 - from over the ceiling to 69% of it. Steady
flight sits at 21%.

Nothing on screen changes, and no setting moves.

## Install

`ZelionDash-1.11.5.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

`sensors.cfg` is yours and is never shipped; the reference config is in the zip
as `sensors.cfg.example`.
