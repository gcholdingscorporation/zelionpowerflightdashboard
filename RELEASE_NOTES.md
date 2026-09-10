One correction to 1.5.0, found by a question rather than by a test.

## Install

`ZelionDash-1.5.1.zip`, `WIDGETS` folder onto the card, **delete `main.luac`**.

## A pending restart is not a fault

1.5.0 treated ESC signature `0xFF` as a critical fault and sounded the alarm on
it. Reading the call sites says otherwise: that signature is set only by
`paramEscNeedRestart()` in `esc_sensor.c`, which is reached from three places
and **all three are parameter flows** — the HobbyWing V5 ping and reset
responses, and the Tribunus UNC setup.

It means *"power-cycle the ESC to apply the settings you just changed"*. It
happens on the bench with a configurator open, and it never happens in flight.
Alarming on it would buzz at a pilot who is deliberately editing ESC settings —
the exact cry-wolf failure the rest of this feature was designed to avoid.

It now reads `restart to apply settings` and raises nothing.

The same reading corrects something said when 1.5.0 shipped: that signature is
**not** vendor-independent, so it was never a path an OMPHOBBY ESC could reach.

## Tests

337, unchanged in count. The test that asserted `0xFF` was a critical fault now
asserts the opposite, and says why in the place someone would look.
