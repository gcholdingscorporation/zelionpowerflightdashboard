# ZelionDash

An RC helicopter telemetry dashboard widget for EdgeTX, targeting Rotorflight
electric setups on the RadioMaster TX16S Mk3 and TX15.

**Status: running on hardware.** The dashboard draws, telemetry binds, alerts
arm, and the flight log writes. Not yet flown — the alert engine has never
fired against a real sag, a hot ESC or a dropout.

## Requirements

- EdgeTX 2.11 or newer
- A full-screen widget slot

Target screen sizes:

| Size | Radio | Density class |
|---|---|---|
| 800×480 | RadioMaster TX16S Mk3 | roomy |
| 480×320 | RadioMaster TX15 | tight |
| 480×272 | other colour radios | tight |

The two primary targets are different shapes, not one layout scaled: width
differs by a factor of 0.60 but height by 0.67, and the smaller screen has
about 40% of the drawing area. Panels therefore *rearrange* between density
classes rather than shrinking uniformly — text cannot scale continuously,
since EdgeTX offers only a handful of fixed font sizes.

Layout adapts to whatever `LCD_W`/`LCD_H` the radio reports, so an untested
size still lands in the nearest sensible density class.

## Installing

Copy the built widget onto the radio's storage:

```
/WIDGETS/ZelionDash/main.lua
```

The file to copy is `dist/WIDGETS/ZelionDash/main.lua`. Then add ZelionDash to
a full-screen widget slot on the radio.

## What it shows

A single screen, no modes. Battery state and headspeed carry the two hero
tiles; cell voltage sits above the fuel gauge on the left; governor, current,
ESC temperature and BEC sit right of centre. The critical values are pinned
left, on the assumption you fly off a neck strap and glance down-left.

There is one screen and it is built once. A separate splash used to stand in
before the pack was plugged in, on the reasoning that a grid of dashes looks
broken — but the dashboard already tells "no sensor" apart from "reading zero",
and the real layout says more: you can see the widget is alive, laid out, and
waiting on named values. Removing it also removed the only screen-to-screen
transition, which is where an emergency-mode reboot used to live.

A mid-flight telemetry dropout blanks the live value but keeps the session
peak — blanking everything at exactly the wrong moment would be worse than
showing a reading that has stopped moving.

## Sensor diagnostics

Turn on **Show Sensor Map** in the widget settings. It lists every telemetry **role** the dashboard knows
about, which sensor on your model got bound to it, and how that binding
happened:

| Column | Meaning |
|---|---|
| Role | What the dashboard needs (Headspeed, ESC temp, …) |
| Sensor | Which of your telemetry sensors filled it |
| `cfg` | You named it explicitly in `sensors.cfg` |
| `auto` | Matched a known sensor name |
| `guess` | Inferred from the sensor's unit — **worth checking** |
| `off` | You switched it off in `sensors.cfg` |
| Value | Live reading, or why there isn't one |

Roles the dashboard considers important are shown in bold, and turn amber when
unbound. Use the scroll wheel to page through the list on the smaller screen.

This is the first place to look when a panel reads `--`.

A `guess` that picked the wrong sensor is corrected in `sensors.cfg`, either by
naming the right one or with `role = off` when there is no right one. Naming a
sensor the radio does not have will not do it — an unknown name falls through
to the same guess.

## Alerts

**Audio + Vibe Alerts** is on by default. Four conditions fire:

| | Fires at | Clears at | Says |
|---|---|---|---|
| Cell voltage | 3.40 V | 3.50 V | speaks the reading |
| ESC temperature | 110 °C | 102 °C | speaks the reading |
| Governor fault | THR-OFF, LOST-HS, AUTOROT | recovery | buzz only |
| Link | lost, or quality 30 | 45 | buzz only |

Readings are spoken through the radio's own number vocabulary, so there is no
sound file to install and you hear them in whatever language the radio is set
to. A sounding alert also names itself in the bottom strip, since the radio
may be muted.

Alerts clear at a different value from the one that triggers them, repeat on a
timer rather than on every frame, and stay silent for the first four seconds
of telemetry. Those three rules are what stop a cell sagging across the line
under load from alarming on every rotor beat.

They sound while another screen is in front, and the **Hold Switch** silences
them.

**Test Alert** sounds one on demand — that is the pre-flight check that the
volume is up and the haptic is on. It speaks the live cell voltage, so it also
confirms the right sensor is bound.

Thresholds are configurable; see `docs/sensors.cfg.example`.

## Flight log

**Log Flights** is on by default. One CSV line per flight, written once, when
the flight ends:

```
date,time,model,seconds,max_rpm,min_cell,min_pack,max_amps,max_esc_c,used_mah,end_pct
2026-08-05,14:14:09,GOBLIN 700,245,1850,3.58,44.10,88.0,71,1240,22
```

It lands at **`/LOGS/zeliondash.csv`**, next to EdgeTX's own telemetry logs,
opens in any spreadsheet, and keeps the most recent 200 flights. That location
survives reinstalling the widget, which the widget's own folder does not.

If `/LOGS/` cannot be written it falls back to the widget folder rather than
losing the flight. Either way the sensor map's `-- FLIGHT LOG --` line shows
the path actually in use.

Note that "SD card" is the wrong word for any of this: EdgeTX presents one path
namespace whether the radio's storage is a card or internal flash, and a Lua
script cannot tell the difference. To get the file off, put the radio into USB
storage mode, or browse to it on the radio itself. A missing reading is left blank rather than
written as zero, because a column of zeroes that were really "no sensor"
averages into a lie.

Anything under 20 seconds is not logged — that is a spool-up test, not a
flight.

A flight starts and ends from the flight controller's ARM flags where they
exist. Where they do not, ZelionDash falls back to the **Arm Switch** option
if you have set one, and failing that to the rotor itself: above 250 rpm is a
flight, and it ends five seconds after the head drops below 100. That last
fallback is what makes the log, the flight timer and the session peaks work on
a non-Rotorflight stack.

## Rotorflight RF Tool integration (optional)

If Rotorflight's **RF Tool** widget is installed, ZelionDash uses it for two
things telemetry alone cannot provide:

- **Flight count and total airtime from the flight controller itself**, rather
  than a counter kept on the radio's storage. The FC's numbers match what
  Configurator reports and don't diverge when you fly the same heli with a
  second radio. Requires MSP API 12.9 or newer.
- **Authoritative connection state.** Without RF Tool the dashboard can only
  infer whether the link is up; RF Tool actually knows.

This is entirely optional — with RF Tool absent the dashboard is fully
functional and says nothing about it. Flight controller data is requested only
when the link connects and after each landing, never per frame, so it costs
almost no telemetry bandwidth.

## Configuring sensor names

Sensor discovery is automatic and usually needs no configuration. If your model
publishes a sensor under an unusual name, override it in:

```
/WIDGETS/ZelionDash/sensors.cfg
```

```ini
# Applies to all models
[*]
escTemperature = Tesc

# Just this model, matched against the model name in EdgeTX
[Goblin 700]
escTemperature = Tmp1
headspeed      = MyRPM
```

A model's own section wins over `[*]`. Section names are case-insensitive.
Unknown role names are reported at the bottom of the diagnostics screen rather
than silently ignored, so a typo is visible. See `docs/sensors.cfg.example` for
the full list of role names.

A missing config file is entirely normal — everything auto-detects.

## Development

Requires Lua 5.4 on the desktop (`apt install lua5.4`).

```sh
lua5.4 tools/build.lua    # src/*.lua  ->  dist/WIDGETS/ZelionDash/main.lua
lua5.4 tests/run.lua      # run the test suite
```

### Layout

```
src/       widget sources, one file per layer
tools/     build script, desktop EdgeTX mock, module loader
tests/     test suite (runs against both src/ and the built artifact)
dist/      the deployable widget — copy this to the radio
docs/      a ready-to-install sensors.cfg, and the full reference
```

`src/` is modular for development; `tools/build.lua` concatenates it into a
single `main.lua` for the radio, because EdgeTX's multi-file loading is fiddly
enough that every widget of this size ships as one file.

### Architecture

Seven layers, each talking only to its neighbours:

1. **Host adapter** (`host.lua`) — the only code that touches EdgeTX directly.
   Absorbs firmware differences, and lets everything above it run on a desktop
   against `tools/mock_edgetx.lua`.
2. **Sensor resolver** (`roles.lua`, `config.lua`, `sensors.lua`) — binds
   abstract roles to whatever sensors this model actually has.
3. **State model** (`state.lua`) — current values, session extremes, validity,
   arm detection, flight timing.
4. **Alert engine** (`alerts.lua`) — decides when a condition is worth
   interrupting the pilot for. Hysteresis, repeat timers and a settle window,
   because the only way an alert system fails in practice is by becoming noise.
5. **Layout engine** (`layout.lua`, `theme.lua`) — screen geometry as pure
   arithmetic. Two density classes rather than one scaled layout, because the
   targets are different shapes and EdgeTX fonts do not scale continuously.
6. **Renderer** (`dashboard.lua`) — retained-mode LVGL. Objects are created
   once; each frame writes only the properties whose values changed.
7. **Persistence** (`flightlog.lua`) — one CSV line per flight, written once at
   landing. Flight count also comes from the flight controller when RF Tool is
   available.

Two rules run through all of it:

- **A missing sensor and a sensor reading zero must never look the same.**
  Every value carries a validity flag, and readings outside a plausible range
  are rejected rather than displayed.
- **Fail loud, not silent.** An unresolvable sensor, a bad config line, or a
  failed write is shown on screen rather than swallowed. Harder than it sounds:
  three separate silent failures cost one flight record between them, and each
  only became visible once the previous was fixed.

## Credits

Design informed by two excellent existing dashboards: the KRC Dashboard
(Ben Ke and Thanh Tieu, adapted by Bert Krammer) and StacyDash (Kyle Stacy).
No code from either is used here.
