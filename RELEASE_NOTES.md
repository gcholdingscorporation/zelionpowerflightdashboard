After landing, the screen now says `RISING`, in amber, when the pack you just
flew reads well above its own earlier flights.

## What you see

```
PACK 4  IR 2.6 mOhm  LAST 1.9  RISING
```

- `RISING` replaces the `HIGH OF` / `#2 OF 4` ranking on that flight. A pack
  reading high against its own history matters more than where it sits today.
- The pack is only compared with its own earlier flights that were no harder
  than this one (an average current up to 1.2 times this flight's). A gentle
  flight reads higher, and would otherwise look like a tired pack.
- It needs at least two such flights. It takes the median of the last six and
  fires when this reading is 1.3 times that or more.

Replayed against a real log of 75 readings, it fired once: on the M2 V3 pack
that went from 8.2 and 7.2 to 14.0. It did not fire on a gentle M7R flight
that read 2.0 against a hard-flight history of 1.2.

It is a prompt to check the pack on a charger, not a verdict. There is no
"replace this pack" yet. No pack in the logs has failed, so there is nothing
to set that line by. A worn plug still counts as resistance, and a wrong
**Pack** number still compares the wrong pack.

## Cost

The worst callback after a landing is 12,453 instructions of EdgeTX's 20,000,
measured on a full 200-flight log all flown on the same day. Nothing is added
to the work done while you fly.

## Install

`ZelionDash-1.14.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

`sensors.cfg` is yours and is never shipped; the reference config is in the zip
as `sensors.cfg.example`.
