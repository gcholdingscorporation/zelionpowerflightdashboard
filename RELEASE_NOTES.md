Fixes a false link alarm: a red `ALERT: LINK` and constant beeping while the
heli flies normally, on a model where Rotorflight's RF Tool reports
"disconnected".

## What was wrong

The link alert listened to two different things. It fired when RF Tool said
the flight controller was disconnected, and it cleared when link quality was
fine. With RF Tool disconnected and a good radio link, both were true at once,
so the alert fired, cleared and fired again several times a second. The footer
flipped between `RF2 DISCONNECTED` and `ALERT: LINK` and the radio beeped
without a break.

RF Tool's "disconnected" is its own handshake with the flight controller, not
the radio link. A flight controller that is not Rotorflight never completes
that handshake, so it reads disconnected all flight.

## What changed

- The link alert now fires and clears on **link quality only**: fires at 30%,
  clears at 45%, and repeats no more than once every 12 seconds while it stays
  low.
- RF Tool's state still shows in the footer and on the sensor map. It no
  longer sounds an alarm, and it no longer silences a real low-link alarm
  either.

Nothing else changes. The worst callback is unchanged at 17,823 instructions
of EdgeTX's 20,000.

## Install

`ZelionDash-1.13.1.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

`sensors.cfg` is yours and is never shipped; the reference config is in the zip
as `sensors.cfg.example`.
