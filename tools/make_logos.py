#!/usr/bin/env python3
"""Regenerate the widget's artwork from assets/zelion_lockup.png.

The three PNGs used to be produced by hand, so their sizes drifted from what
the layout actually asks for. Sizes here must match src/layout.lua.

Two constraints, both learned on hardware:

  * Flatten onto the dashboard background and save 8-bit palettised. EdgeTX
    composites these itself and an alpha channel is wasted space.
  * Keep the pixel count modest. A 500x281 (140k pixel) standby logo rendered
    as corrupted scanlines on a TX16S Mk3 - a decode buffer overrun, not a
    load failure. 320x180 (58k) is verified good, and nothing here exceeds it.

    lua tools/dump_screen.lua ... tells you the sizes the layout wants;
    python3 tools/make_logos.py writes them.
"""
import os
import re
from PIL import Image

SRC = "assets/zelion_lockup.png"
OUT = "dist/WIDGETS/ZelionDash"
THEME = "src/theme.lua"
BUDGET = 320 * 180       # verified good on a TX16S Mk3

# name -> (width, height). Derived from src/layout.lua at each anchor size:
#   logo_panel   the right column's logo box on 800x480
#   logo_small   the same box on 480x320
TARGETS = {
    "logo_panel.png": (295, 166),
    "logo_small.png": (174, 98),
}


def background():
    """Read Theme.bg out of src/theme.lua.

    Hardcoding it here is how you get a logo carrying a box of the previous
    background around it: the two only have to disagree once, and the artwork
    is regenerated far less often than the palette is edited.
    """
    with open(THEME) as f:
        m = re.search(r"Theme\.bg\s*=\s*rgb\(\s*(\d+),\s*(\d+),\s*(\d+)\s*\)",
                      f.read())
    if not m:
        raise SystemExit("could not find Theme.bg in " + THEME)
    return tuple(int(g) for g in m.groups())


def main():
    BG = background()
    print("background %r from %s" % (BG, THEME))
    src = Image.open(SRC).convert("RGBA")
    os.makedirs(OUT, exist_ok=True)
    for name, (w, h) in TARGETS.items():
        if w * h > BUDGET:
            raise SystemExit(
                "%s at %dx%d is %d pixels, over the %d verified on hardware"
                % (name, w, h, w * h, BUDGET))
        # Fit inside the box at the source aspect ratio; never stretch.
        scale = min(w / src.width, h / src.height)
        fitted = src.resize((max(1, round(src.width * scale)),
                             max(1, round(src.height * scale))), Image.LANCZOS)
        canvas = Image.new("RGBA", (w, h), BG + (255,))
        canvas.alpha_composite(fitted, ((w - fitted.width) // 2,
                                        (h - fitted.height) // 2))
        out = canvas.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=255)
        path = os.path.join(OUT, name)
        out.save(path, optimize=True)
        print("wrote %s %dx%d (%d px, %d bytes)"
              % (path, w, h, w * h, os.path.getsize(path)))


if __name__ == "__main__":
    main()
