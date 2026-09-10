Pack internal resistance, measured in flight and logged per flight.

## Install

Download `ZelionDash-1.4.0.zip`, unzip it, and copy the `WIDGETS` folder onto
the radio's storage. **Delete `main.luac`** next to the `main.lua` you replaced;
the sensor map header will read `ZELIONDASH 1.4.0` once the new file is running.

Your existing `zeliondash.csv` is widened in place — the new column is blank for
every flight flown before it existed, which is the only honest value.

## Why resistance

A pack announces that it is finished long before its capacity does. What goes
first is internal resistance: the same punch sags further every month, and by
the time the mAh figure has visibly dropped the pack has been unpleasant to fly
for a while.

One new column, `ir_mohm` — milliohms per cell, so a 3S micro and a 12S 700 are
directly comparable. Nothing on screen: the value of this number is the trend
across flights, and there is no trend until there are flights behind it.

## Measured, not inferred

A cell under load reads `V_open − I × R`, so cell voltage against current is a
straight line whose slope is the resistance. The difficulty is `V_open`, which
falls as the pack empties — a fit across a whole flight blends the resistance
slope with the depletion slope and reports neither. So the fit runs over
three-second windows, short enough that the pack does not measurably deplete
inside one, and the flight's answer is the median across its windows.

**The shortcut this replaces looked fine.** Dividing the flight's voltage sag by
its peak current uses two columns already in the log. Against 47 real flights it
gave a believable 3.5 mΩ on a 12S pack and a 4× spread of nonsense on a 3S
micro. Those two figures are the extremes of the *whole flight* and need not
have happened at the same moment: on a heli flown in long pulls they nearly
coincide, and on one flown in short punches they do not. It was right on the
aircraft that happened to suit it, which is the most dangerous way for a
measurement to be wrong.

## When it refuses

Blank unless at least five windows agreed, the current genuinely moved during
them, and the result was physically possible. A steady hover cannot measure
resistance — every sample shares one current, the fit divides by nearly nothing,
and the answer would be large, confident and meaningless. It says nothing
instead.

## Tests

322, up from 308. Thirteen of them are new and they run against synthetic packs
whose resistance is written on the tin, because "the number looks plausible" is
exactly what the old method passed.

Seven mutations were run against the guards. **Four survived the first pass**,
and chasing them was worth more than the feature:

- One found a real design error. The first version skipped readings the collapse
  latch had not yet confirmed — which are the samples taken during a hard punch,
  the ones furthest along the current axis and the most informative in the whole
  flight. It was discarding the best half of its own data.
- One found a test that was physically absurd: an outlier window of 60 mΩ at
  120 A is a seven-volt sag, which the collapse detector threw out before the
  median ever saw it. The test proved nothing until the outlier was made real.
- One found a threshold that could not be justified — a minimum sample count per
  window that nothing could be made to fail without. It is gone. A number no
  test can defend is a number somebody later tunes in the dark.
