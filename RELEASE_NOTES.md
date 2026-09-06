Two small changes to the sensor map, both answering questions this dashboard
could not previously answer about itself.

## Install

Download `ZelionDash-1.2.1.zip`, unzip it, and copy the `WIDGETS` folder onto
the radio's storage, merging with the one already there.

**Delete `main.luac`** next to the `main.lua` you just replaced, or the radio
keeps running the stale compiled copy — and after this release, the header will
tell you when that has happened.

## The version is on the screen

`ZELIONDASH 1.2.1 - SENSOR MAP`.

It was previously knowable only by spotting which features were present, which
is a guess dressed as a diagnosis. "Have you copied the new file across yet?"
now has an answer you can read off the radio.

## The flight log counts the file, not the session

The row read `1 written`, meaning *this session*. Directly above it sits the
flight controller's own lifetime total, `2 flights`. Those two numbers could
never be compared, because restarting the widget resets one and not the other —
so the question they exist to answer, *did a flight go unlogged?*, had no
answer.

It now reads `2 in log`: the number of records in the CSV. Two totals of the
same thing, on adjacent lines, that can be read against each other at a glance.
When they match, nothing was lost.

The count is read from the card once and then maintained by the writes, so it
costs one file read when you open the screen and nothing thereafter. The log
keeps the most recent 200 flights, so the two figures will part company on a
very well-used aircraft — the flight controller's total is a lifetime one and
never rolls.

## Tests

302, up from 297. Three mutations were run against the new behaviour and all
three are caught, including the one that mattered: a cached count that the
writes do not maintain, which would leave the row showing yesterday's total —
precisely the failure the change exists to prevent.
