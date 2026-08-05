#!/usr/bin/env python3
"""Draw what tools/dump_screen.lua dumped, at true resolution.

Drawn with EdgeTX's own font line heights and the real artwork, so the picture
is the size and shape the radio will actually produce. There was once a
separate script that drew the intended layout from a mock-up; it was deleted
once it had drifted far enough from the code to mislead rather than inform.

    lua tools/dump_screen.lua 800 480 dash > /tmp/s.txt
    python3 tools/render_screen.py /tmp/s.txt out.png
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

DEJAVU = "/usr/share/fonts/truetype/dejavu/"

# EdgeTX line heights per font set, indexed the way EdgeTX indexes them:
#   0 STD  1 BOLD  2 XXS  3 XS  4 L  5 XL  6 XXL
# Read out of radio/src/fonts/lvgl/{lrg,std,sml}/lv_font_en_*.c in v2.11.0.
LINE_HEIGHT = {
    "lrg": [29, 29, 17, 23, 46, 58, 102],
    "std": [21, 20, 12, 17, 29, 40, 69],
    "sml": [14, 14, 10, 12, 18, 26, 44],
}
# XL and XXL are compiled from bold glyph sets; BOLD obviously is.
IS_BOLD = [False, True, False, False, False, True, True]

_cache = {}


def pil_font(index, metrics):
    key = (index, metrics)
    if key not in _cache:
        lh = LINE_HEIGHT[metrics][index]
        # PIL sizes by em; DejaVu's line height is about 1.17 em.
        size = max(6, round(lh / 1.17))
        name = "DejaVuSans-Bold.ttf" if IS_BOLD[index] else "DejaVuSans.ttf"
        _cache[key] = ImageFont.truetype(DEJAVU + name, size)
    return _cache[key]


def rgb(v):
    v = int(v)
    return (v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF)


def main(src, dest):
    rows = [l.rstrip("\n").split("\t") for l in open(src) if l.strip()]
    head = rows.pop(0)
    w, h, kind, metrics = int(head[1]), int(head[2]), head[3], head[4]

    im = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(im)

    for r in rows:
        kindr = r[0]
        x, y, rw, rh = (int(float(v)) for v in r[1:5])
        color = rgb(r[5])
        font_flags = int(float(r[6]))
        align = int(float(r[7]))
        rounded = int(float(r[8]))
        text = r[10] if len(r) > 10 else ""

        if kindr == "rect":
            if rounded > 0:
                d.rounded_rectangle([x, y, x + rw - 1, y + rh - 1],
                                    radius=rounded, fill=color)
            else:
                d.rectangle([x, y, x + rw - 1, y + rh - 1], fill=color)
        elif kindr in ("hline", "vline"):
            d.rectangle([x, y, x + max(rw, 1) - 1, y + max(rh, 1) - 1], fill=color)
        elif kindr == "image":
            # The real PNG, so the artwork's flattened background can be seen
            # to match the screen's. A placeholder box hides exactly the
            # mismatch this is worth checking for.
            # The dump carries the radio's own SD-card path; the file lives
            # under dist/ here.
            path = os.path.join("dist", text.lstrip("/"))
            if os.path.exists(path):
                logo = Image.open(path).convert("RGB")
                if logo.size != (rw, rh):
                    logo = logo.resize((rw, rh), Image.LANCZOS)
                im.paste(logo, (x, y))
            else:
                d.rectangle([x, y, x + rw - 1, y + rh - 1], outline=(60, 70, 80))
                d.text((x + rw / 2, y + rh / 2), "[no logo]", fill=(90, 100, 110),
                       font=pil_font(2, metrics), anchor="mm")
        elif kindr == "label" and text:
            idx = (font_flags // 256) % 16
            if idx >= len(LINE_HEIGHT[metrics]):
                idx = 0
            f = pil_font(idx, metrics)
            # EdgeTX aligns inside the label's own box: 0x04 centre, 0x08 right.
            if align & 0x04:
                d.text((x + rw / 2, y), text, fill=color, font=f, anchor="ma")
            elif align & 0x08:
                d.text((x + rw, y), text, fill=color, font=f, anchor="ra")
            else:
                d.text((x, y), text, fill=color, font=f, anchor="la")

    im.save(dest)
    print("wrote", dest, im.size, "(%s, %s fonts)" % (kind, metrics))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
