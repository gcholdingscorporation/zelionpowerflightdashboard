The documented config reference now ships with the widget.

## Install

`ZelionDash-1.6.2.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## `sensors.cfg.example` is in the zip

The download now carries the full configuration reference into
`/WIDGETS/ZelionDash/sensors.cfg.example` — every one of the 22 overridable
sensor roles, the `[battery]` settings, and what each one is for.

To use it: copy it to `sensors.cfg` in the same folder and uncomment what you
need. Everything in it is optional; sensor discovery is automatic and most
setups never need a line of it.

It ships as `sensors.cfg.example` and **never** as `sensors.cfg`. A live config
is per-radio, and one inside the download would overwrite a pilot's own
overrides on every upgrade — silently, because merging a folder onto a card
does not ask. Under this name it cannot collide with anything, and the
reference is on the card at the field rather than in a repository nobody can
reach from there.

## No code changes

Packaging and documentation only. The widget is byte-for-byte 1.6.1 apart from
its version string.

## Tests

341, unchanged.
