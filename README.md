# ZelionDash

An RC helicopter telemetry dashboard widget for EdgeTX, targeting Rotorflight
electric setups on the RadioMaster TX16S Mk3 and TX15.

**Status: early development.** Layers 1–3 (host adapter, sensor resolver, state
model) are implemented and tested. The dashboard UI is not built yet — what
currently renders is a sensor diagnostics screen.

## Requirements

- EdgeTX 2.11 or newer
- A full-screen widget slot

Target screen sizes:

| Size | Radio |
|---|---|
| 480×320 | RadioMaster TX15 |
| 480×272 | RadioMaster TX16S Mk3 |
| 800×480 | larger colour radios |

Layout adapts to whatever `LCD_W`/`LCD_H` the radio reports, so an untested
size still lands in the nearest sensible density class.

## Installing

Copy the built widget onto the radio's SD card:

```
/WIDGETS/ZelionDash/main.lua
```

The file to copy is `dist/WIDGETS/ZelionDash/main.lua`. Then add ZelionDash to
a full-screen widget slot on the radio.

## What it does today

The diagnostics screen lists every telemetry **role** the dashboard knows
about, which sensor on your model got bound to it, and how that binding
happened:

| Column | Meaning |
|---|---|
| Role | What the dashboard needs (Headspeed, ESC temp, …) |
| Sensor | Which of your telemetry sensors filled it |
| `cfg` | You named it explicitly in `sensors.cfg` |
| `auto` | Matched a known sensor name |
| `guess` | Inferred from the sensor's unit — **worth checking** |
| Value | Live reading, or why there isn't one |

Roles the dashboard considers important are shown in bold, and turn amber when
unbound. Use the scroll wheel to page through the list on the smaller screen.

This screen exists first on purpose: it proves sensor discovery works against
real hardware before any layout work depends on it.

## Rotorflight RF Tool integration (optional)

If Rotorflight's **RF Tool** widget is installed, ZelionDash uses it for two
things telemetry alone cannot provide:

- **Flight count and total airtime from the flight controller itself**, rather
  than a counter kept on the radio's SD card. The FC's numbers match what
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
dist/      the deployable widget — copy this to the SD card
docs/      configuration reference
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
4. **Alert engine** — *not yet built.*
5. **Layout engine** — *not yet built.*
6. **Renderer** — *not yet built.* Will use LVGL; the current diagnostics
   screen uses `lcd.draw*` as scaffolding.
7. **Persistence** — *not yet built.*

Two rules run through all of it:

- **A missing sensor and a sensor reading zero must never look the same.**
  Every value carries a validity flag, and readings outside a plausible range
  are rejected rather than displayed.
- **Fail loud, not silent.** An unresolvable sensor, a bad config line, or a
  failed SD write is shown on screen rather than swallowed.

## Credits

Design informed by two excellent existing dashboards: the KRC Dashboard
(Ben Ke and Thanh Tieu, adapted by Bert Krammer) and StacyDash (Kyle Stacy).
No code from either is used here.
