A one-fix release. After the widget had been in fullscreen, tap-and-hold on
the home screen no longer opened the widget menu. It does again now.

## The widget menu opens again after fullscreen

EdgeTX redraws the widget when it goes fullscreen, and anything drawn in
fullscreen is allowed to catch touches. Nothing redrew it on the way out, so
the dashboard's panels stayed on the home screen catching every tap-and-hold
before it reached the widget's own menu. Only a restart or a model change
cleared it. Seen on EdgeTX 2.12.0.

The widget now redraws itself once when fullscreen ends. You may see a single
frame of the old screen as it does. Nothing else on the dashboard changes.

## Install

`ZelionDash-1.14.2.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

`sensors.cfg` is yours and is never shipped; the reference config is in the zip
as `sensors.cfg.example`.
