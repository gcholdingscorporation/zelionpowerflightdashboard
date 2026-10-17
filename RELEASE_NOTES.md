Your packs' internal resistance is now on the screen. After every landing the
bottom-left corner shows the pack you just flew and its last reading, so a
pack that is wearing out shows up while it is still in your hand.

## What you see

```
PACK 4  IR 1.8 mOhm  LAST 1.6
```

- `IR` is this flight's measured internal resistance, milliohms per cell.
- `LAST` is the same pack's previous reading from the flight log: same model
  slot, same **Pack** number, same aircraft. It appears once the row is
  written, after the chime.
- No `PACK` when the Pack option is 0, and no `LAST` on a pack's first logged
  flight.

It stays until the next flight arms. The slogan steps aside for it.

It is two numbers, not a verdict. The reading moves with temperature and the
day (every pack on one aircraft can read higher together on a cool morning),
and it has not been checked against a charger. Compare packs flown on the same
day before deciding one is tired.

## 2S micros get a reading

A window used to need an 8 A current swing to count, which a 2S micro peaking
near 12 A rarely manages. It now scales to 30% of the flight's peak current,
never under 3 A. Anything pulling 27 A or more is unchanged.

## Cost

The worst callback after a landing is 11,025 instructions of EdgeTX's 20,000,
measured on a full 200-flight log. Nothing is added to the work done while you
fly.

## Install

`ZelionDash-1.12.0.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

`sensors.cfg` is yours and is never shipped; the reference config is in the zip
as `sensors.cfg.example`.
