The dashboard only redraws the readings that actually changed.

## What is different

Every refresh used to rewrite the whole screen and rebuild every number on it,
whether or not anything had moved. Now a reading that has not changed costs a
comparison instead of a redraw, and is not re-formatted at all.

Measured against 1.11.3 on a flying model: about two thirds less memory churn
per frame on the dashboard, and eighty-five percent less on the sensor map.
A still screen builds 6 strings where 1.11.3 built 236.

Nothing looks different. Every screen is byte-identical to 1.11.3.

## Install

`ZelionDash-1.11.4.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

`sensors.cfg` is yours and is never shipped; the reference config is in the zip
as `sensors.cfg.example`.
