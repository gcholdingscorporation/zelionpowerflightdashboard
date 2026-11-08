After landing, the screen now says where the pack you just flew sits among the
packs you have flown on that heli today, so the weakest one stands out while
it is still in your hand.

## What you see

```
PACK 4  IR 2.4 mOhm  LAST 1.9  HIGH OF 4
```

- `HIGH OF 4` means this pack had the highest resistance of the 4 packs flown
  on this aircraft today. `#2 OF 4` means one other was higher.
- It shows once at least 3 packs have a reading today. Against one other pack
  the order is a coin toss.
- A pack flown twice today counts once, as its latest reading.
- Only today's flights on the same aircraft are compared. Readings drift from
  day to day, but the order of packs holds.

Replayed against a real log, 27 Oct's M7R flights read `HIGH OF 3`, then
`HIGH OF 4` for pack 4, then `#2 OF 5` for pack 5 - the same order a charger's
IR test gave.

It is a prompt to check a pack, not a verdict. A gentle flight reads higher
than a hard one, a worn plug counts as resistance, and a wrong **Pack** number
compares the wrong pack.

## Cost

The worst callback after a landing is 12,411 instructions of EdgeTX's 20,000,
measured on a full 200-flight log all flown on the same day. Nothing is added
to the work done while you fly.

## Install

`ZelionDash-1.13.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

`sensors.cfg` is yours and is never shipped; the reference config is in the zip
as `sensors.cfg.example`.
