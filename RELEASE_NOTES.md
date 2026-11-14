A safety and performance release from a full audit of 1.14.0. Nothing changes
on the dashboard you fly with. Your flight log is now protected from being
erased, and the heaviest moments drop well clear of EdgeTX's limit.

## Your flight log can no longer be wiped

Before this release, one save of `zeliondash.csv` from a spreadsheet could
erase it. If Excel added its hidden byte-order mark, quoted the column names,
or left a stray space, the next landing replaced every flight with one. The
backup that was meant to catch this was deleted as soon as the write
succeeded. A log bloated past 64 KB by card damage was cut down the same way.

Now:

- A header touched by a spreadsheet is read as the same header, and every
  flight is kept.
- A log the widget still cannot read is left exactly as it is. The flight goes
  to `zeliondash.held.csv` beside it, and the sensor map's FLIGHT LOG row says
  why.
- Every rewrite leaves the previous log as `zeliondash.csv.bak`.
- `zeliondash.bad.csv` is renamed aside whole once it passes 32 KB, never cut
  short.

## Lighter where it was heaviest

Measured on a 46-sensor model with a real 318-line `sensors.cfg` and a full
200-flight log, counting the widget's own instructions out of EdgeTX's 20,000
per callback:

| Moment | 1.14.0 | 1.14.1 |
| --- | --- | --- |
| Opening the sensor map | 20,032 | 13,416 |
| Changing any widget option | 13,096 | 5,390 |
| Radio start | 13,428 | 9,574 |
| First frame after start | 14,137 | 10,888 |
| Landing write | 13,970 | 10,737 |
| Building the screen | 8,537 | 7,254 |

- `sensors.cfg` is parsed again only when it has changed, and comment lines
  are skipped cheaply.
- The sensor map no longer reads every row of the log to print how many there
  are.
- Roles your model never has (tail speed, BEC and so on) are probed every
  15 seconds instead of every second. A newly found sensor still binds within
  a second, and a reading lost to a dropout is looked for every second.

## Fixes

- The `MAX` figures under headspeed, current and ESC temperature are rounded
  before display. A peak with decimals (such as 42.3 A) could freeze the
  label, and on stricter Lua it sent the screen to safe mode after a Pack
  Number change.
- A byte-order mark at the top of `sensors.cfg` no longer drops the first
  section. That could reset `reservePct` to 20 when the file started with
  `[battery]`.
- A comment at the end of a setting line is now named as the problem, rather
  than reported as a range error.

## Install

`ZelionDash-1.14.1.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

`sensors.cfg` is yours and is never shipped; the reference config is in the zip
as `sensors.cfg.example`.
