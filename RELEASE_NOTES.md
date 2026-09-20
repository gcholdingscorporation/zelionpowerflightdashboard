The sensor map stops rebuilding itself every frame, and a degraded screen now
says so.

## Install

`ZelionDash-1.11.3.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## The sensor map was rebuilt on every frame

1.11.2 took the artwork probe out of that screen's refresh path. That was one
half of what it cost. Rebuilding the whole list was the other, and it went
untouched.

`sensorMapRows()` ran on every refresh: re-reading every role, re-formatting
every reading, re-measuring the folded names against the column width. Counting
what each screen asks the radio for, the dashboard makes two `lcd.sizeText`
calls per frame and the sensor map made eleven - five times the text
measurement, for the one screen nobody flies on.

The built list is kept and reused for half a second now. That is faster than
anyone reads a row and slow enough to cost nothing. Scrolling reuses it rather
than rebuilding, because scrolling picks a different slice of the same list.

## A screen that came back degraded now says which rung, and why

The widget catches every screen build, because an unhandled raise from a Lua
widget is what puts EdgeTX into emergency mode. When one fails it steps down -
first without the logo, then without rounded corners, then to a minimal screen -
and one of those usually works.

That is the right behaviour and it has a cost nobody had paid attention to: the
widget comes back a rung down looking perfectly healthy apart from whatever it
dropped, and the message naming the fault was thrown away by the `pcall` that
saved the radio. A logo quietly replaced by the ZELION POWER wordmark, with no
error anywhere, is what that looks like - and the sensor map's own artwork block
will happily report both files loading, because the probe (`Bitmap.open`) is not
the loader (`lvgl.image`) and only one of them has to fail.

The first attempt's error is kept now, and the sensor map carries a
`-- SCREEN --` row **above everything else** naming the rung and the reason. It
is the first row on the page, so it needs no scrolling to read.

## Tests

393, up three. Two hold the sensor map open and assert the list is built on a
clock rather than a frame; one breaks the image draw and asserts the screen
reports both the rung and the message. All verified failing without the change.
