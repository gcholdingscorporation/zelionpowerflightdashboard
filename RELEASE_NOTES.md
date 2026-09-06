Two changes to the sensor map. One is cosmetic; the other tells you when a
config file you wrote is quietly doing nothing.

## Install

Download `ZelionDash-1.3.0.zip`, unzip it, and copy the `WIDGETS` folder onto
the radio's storage, merging with the one already there. **Delete `main.luac`**
next to the `main.lua` you replaced — the header will read `ZELIONDASH 1.3.0`
once the new file is actually running.

## A config file that applied nothing now says so

Section headers in `sensors.cfg` are **EdgeTX model names**, not aircraft
names. A section written for the helicopter rather than for the model it flies
on matches nothing — and it fails completely silently: the overrides never
happen, the roles fall back to guessing, and the sensor map shows `(guess)`
where you expected `(cfg)`.

When a `sensors.cfg` exists, a `-- CONFIG --` row now names the sections that
actually applied to this model and counts the overrides they carried. It reads
amber as `no section for this model / 0 overrides` when none of it reached the
model you are flying.

Only sections that carried something count. The parser opens an implicit `[*]`
for any lines before the first header, so that section exists even in a file
that never mentions it — and naming a section that contributed nothing is
exactly the false reassurance this row exists to prevent.

No row at all when there is no file. That is the normal case, everything
auto-detects, and a row saying so every time is a row spent on nothing.

## Volts read as volts

The value column rounded anything within 0.05 of a whole number to an integer,
which is right for rpm and mAh and wrong for a voltage: the same field read
`45 V` one moment and `45.09 V` the next. Pack, cell, BEC and TX voltages now
always carry two decimals.

## Tests

307, up from 302. Four mutations were run against the new behaviour and all
four are caught — including the one that mattered least on paper and most in
practice: drawing a config that applied nothing in the same colour as one that
worked. The words alone are not a diagnostic when the row is read at a glance
among a dozen others.
