#!/usr/bin/env python3
"""Render the ZelionDash layout to PNGs at true device resolution."""
from PIL import Image, ImageDraw, ImageFont

F = "/usr/share/fonts/truetype/dejavu/"
def sans(s, b=True):  return ImageFont.truetype(F + ("DejaVuSans-Bold.ttf" if b else "DejaVuSans.ttf"), s)
def mono(s, b=True):  return ImageFont.truetype(F + ("DejaVuSansMono-Bold.ttf" if b else "DejaVuSansMono.ttf"), s)

BG    = (6, 8, 11)
PANEL = (16, 20, 26)
RULE  = (35, 42, 51)
INK   = (242, 245, 248)
DIM   = (118, 129, 143)
LIME  = (139, 224, 74)
LIMED = (78, 143, 34)
STEEL = (127, 196, 238)
WARN  = (245, 179, 1)
PEAK  = (185, 154, 74)
TRACK = (9, 12, 16)

D = "/home/user/zelionpowerflightdashboard/dist/WIDGETS/ZelionDash/"


class Screen:
    def __init__(self, w, h):
        self.im = Image.new("RGBA", (w, h), BG + (255,))
        self.d = ImageDraw.Draw(self.im)
        self.w, self.h = w, h

    def panel(self, x, y, w, h, border=RULE, fill=PANEL):
        self.d.rounded_rectangle([x, y, x + w - 1, y + h - 1], 5, fill=fill, outline=border)

    def rule(self, x, y, w):
        self.d.rectangle([x, y, x + w - 1, y], fill=RULE)

    def text(self, x, y, s, font, fill=INK, anchor="la", spacing=0):
        if spacing:
            # Manual letter-spacing for the uppercase micro-labels.
            cx = x
            for ch in s:
                self.d.text((cx, y), ch, font=font, fill=fill, anchor="la")
                cx += self.d.textlength(ch, font=font) + spacing
            return
        self.d.text((x, y), s, font=font, fill=fill, anchor=anchor)

    def logo(self, path, x, y, w, h):
        img = Image.open(path).convert("RGBA").resize((w, h), Image.LANCZOS)
        self.im.alpha_composite(img, (x, y))

    def save(self, p):
        self.im.convert("RGB").save(p)
        print("wrote", p, self.im.size)


def signal(s, x, y, bars=3, step=10, unit=6, hmax=18):
    for i in range(4):
        bh = 6 + i * 4
        col = LIME if i < bars else RULE
        s.d.rectangle([x + i * step, y + hmax - bh, x + i * step + unit - 1, y + hmax - 1], fill=col)


def txbatt(s, x, y, w, h, frac=0.6):
    s.d.rectangle([x + (w - 8) // 2, y - 4, x + (w - 8) // 2 + 7, y - 2], fill=DIM)
    s.d.rounded_rectangle([x, y, x + w - 1, y + h - 1], 3, fill=TRACK, outline=RULE)
    fh = int((h - 4) * frac)
    s.d.rounded_rectangle([x + 2, y + h - 2 - fh, x + w - 3, y + h - 3], 2, fill=LIME)


# ----------------------------------------------------------------- 800 x 480
def render_800(standby=False):
    s = Screen(800, 480)
    L10, L12, L13 = sans(10), sans(12), sans(13)
    M13, M24 = mono(13), mono(24)

    s.text(12, 11, "GOBLIN 700", L12, INK)
    s.text(352, 6, "00:00" if standby else "02:14", M24, DIM if standby else INK)
    if not standby:
        signal(s, 600, 12)
        s.text(644, 13, "78%", M13, DIM)
    txbatt(s, 738, 14, 16, 22)
    s.text(762, 14, "7.9", M13, INK)
    s.rule(0, 40, 800)

    if standby:
        s.logo(D + "logo_standby.png", 150, 58, 500, 281)
        s.rule(200, 352, 400)
        s.text(400, 366, "NO HYPE  ·  JUST VOLTAGE  ·  REAL POWER", mono(12), DIM, anchor="ma")
        s.text(400, 400, "WAITING FOR TELEMETRY", sans(16), WARN, anchor="ma")
        s.rule(0, 436, 800)
        s.text(12, 451, "137 FLIGHTS · 11:27:10 TOTAL", mono(10), DIM)
        s.text(788, 451, "RF2 IDLE", mono(10), DIM, anchor="ra")
        return s

    # --- cell voltage: pinned to the top of the column ---
    s.d.rounded_rectangle([10, 46, 105, 121], 6, fill=(6, 8, 11), outline=LIMED)
    s.text(58, 53, "CELL", sans(9), LIME, anchor="ma")
    s.text(58, 64, "3.94", mono(26), INK, anchor="ma")
    s.text(58, 99, "MIN 3.62", mono(9), PEAK, anchor="ma")

    # --- battery bar: starts below the chip, brand-green border ---
    s.d.rounded_rectangle([10, 129, 105, 427], 7, fill=TRACK, outline=LIME, width=2)
    s.d.rounded_rectangle([13, 226, 102, 424], 5, fill=LIME)

    # --- battery percentage: upper hero tile ---
    s.panel(116, 46, 390, 190)
    s.text(132, 59, "BATTERY", L10, DIM, spacing=1.3)
    s.text(130, 74, "68", mono(92), INK)
    s.text(268, 130, "%", mono(34), DIM)
    s.text(408, 148, "47.3 V", sans(15), INK, spacing=.6)
    s.rule(132, 186, 358)
    s.text(132, 196, "MIN 44.8V", mono(10), PEAK)
    s.text(222, 196, "SAG 0.32", mono(10), DIM)
    s.text(312, 196, "1240 mAh", mono(10), DIM)
    s.text(402, 196, "12S · 85C", mono(10), DIM)

    # --- headspeed: lower hero tile ---
    s.panel(116, 244, 390, 184)
    s.text(132, 257, "HEADSPEED", L10, DIM, spacing=1.3)
    s.text(130, 270, "1850", mono(92), INK)
    s.text(408, 344, "RPM", sans(11), DIM, spacing=.9)
    s.rule(132, 382, 358)
    s.text(132, 392, "MAX 2150", mono(10), PEAK)
    s.text(248, 392, "TAIL 8420", mono(10), DIM)
    s.text(388, 392, "THR 74%", mono(10), DIM)

    # --- governor ---
    s.d.rounded_rectangle([516, 46, 789, 131], 5, fill=(21, 42, 12), outline=(61, 107, 31))
    s.text(653, 57, "GOVERNOR", L10, DIM, anchor="ma")
    s.text(653, 74, "ACTIVE", sans(36), LIME, anchor="ma")

    # --- tiles ---
    for i, (x, lab, val, foot) in enumerate([
            (516, "CURRENT A", "42",  "MAX 118"),
            (609, "ESC °C",    "71",  "MAX 84"),
            (702, "BEC V",     "8.1", "MIN 7.9")]):
        s.panel(x, 140, 88, 132)
        s.text(x + 10, 151, lab, sans(9), DIM, spacing=.8)
        s.text(x + 10, 172, val, mono(38), INK)
        s.text(x + 10, 240, foot, mono(9), PEAK)

    # --- Zelion lockup: no frame, the mark stands on the ground itself ---
    s.logo(D + "logo_panel.png", 527, 283, 252, 142)

    s.rule(0, 436, 800)
    s.text(12, 451, "137 FLIGHTS · 11:27:10 TOTAL", mono(10), DIM)
    s.text(300, 451, "NO HYPE · JUST VOLTAGE · REAL POWER", mono(10), DIM)
    s.text(788, 451, "RF2 LINKED", mono(10), STEEL, anchor="ra")
    return s


# ----------------------------------------------------------------- 480 x 320
def render_480(wide_logo=False):
    s = Screen(480, 320)
    s.text(8, 8, "GOBLIN 700", sans(11), INK)
    s.text(196, 4, "02:14", mono(18), INK)
    signal(s, 352, 8, step=8, unit=5, hmax=14)
    txbatt(s, 425, 10, 13, 16)
    s.text(444, 10, "7.9", mono(11), INK)
    s.rule(0, 28, 480)

    # cell voltage pinned top, bar below it
    s.d.rounded_rectangle([6, 34, 69, 95], 5, fill=(6, 8, 11), outline=LIMED)
    s.text(37, 38, "CELL", sans(8), LIME, anchor="ma")
    s.text(37, 48, "3.94", mono(18), INK, anchor="ma")
    s.text(37, 74, "MIN 3.62", mono(8), PEAK, anchor="ma")

    s.d.rounded_rectangle([6, 102, 69, 275], 6, fill=TRACK, outline=LIME, width=2)
    s.d.rounded_rectangle([9, 161, 66, 272], 4, fill=LIME)

    s.panel(76, 34, 224, 118)
    s.text(88, 43, "BATTERY", sans(9), DIM, spacing=1)
    s.text(86, 54, "68", mono(56), INK)
    s.text(174, 88, "%", mono(22), DIM)
    s.text(250, 92, "47.3 V", sans(12), INK)
    s.rule(88, 122, 200)
    s.text(88, 129, "MIN 44.8V", mono(9), PEAK)
    s.text(155, 129, "SAG 0.32", mono(9), DIM)
    s.text(222, 129, "1240 mAh", mono(9), DIM)

    s.panel(76, 158, 224, 118)
    s.text(88, 167, "HEADSPEED", sans(9), DIM, spacing=1)
    s.text(86, 178, "1850", mono(56), INK)
    s.text(250, 220, "RPM", sans(10), DIM)
    s.rule(88, 246, 200)
    s.text(88, 253, "MAX 2150", mono(9), PEAK)
    s.text(196, 253, "TAIL 8420", mono(9), DIM)

    s.d.rounded_rectangle([306, 34, 473, 87], 5, fill=(21, 42, 12), outline=(61, 107, 31))
    s.text(390, 40, "GOVERNOR", sans(9), DIM, anchor="ma", spacing=0)
    s.text(390, 53, "ACTIVE", sans(24), LIME, anchor="ma")

    if wide_logo:
        # Three narrower tiles free the whole bottom row for the lockup, which
        # goes from 80px wide to 153px - about four times the area.
        for x, lab, val, foot in [(306, "CURR A", "42",  "MAX 118"),
                                  (363, "ESC °C", "71",  "MAX 84"),
                                  (420, "BEC V",  "8.1", "MIN 7.9")]:
            s.panel(x, 94, 54, 88)
            s.text(x + 6, 101, lab, sans(7), DIM)
            s.text(x + 6, 117, val, mono(24), INK)
            s.text(x + 6, 161, foot, mono(8), PEAK)
        s.logo(D + "logo_tx15wide.png", 313, 190, 153, 86)
    else:
        for x, y, w, hh, lab, val, foot in [
                (306,  94, 80, 88, "CURRENT A", "42",  "MAX 118"),
                (394,  94, 80, 88, "ESC °C",    "71",  "MAX 84"),
                (306, 190, 80, 86, "BEC V",     "8.1", "MIN 7.9")]:
            s.panel(x, y, w, hh)
            s.text(x + 7, y + 7, lab, sans(8), DIM)
            s.text(x + 7, y + 23, val, mono(28), INK)
            s.text(x + 7, y + 63, foot, mono(9), PEAK)
        s.logo(D + "logo_small.png", 394, 211, 80, 45)

    s.rule(0, 284, 480)
    # The lockup is unreadable below ~110px wide, and the strip is only 36px
    # tall. Set the wordmark as type instead; the lion badge above carries the
    # mark itself.
    s.text(8, 294, "ZELION", sans(11), INK)
    s.text(62, 294, "POWER", sans(11), STEEL)
    s.text(250, 295, "137 FLIGHTS", mono(9), DIM)
    s.text(472, 295, "RF2 LINKED", mono(9), STEEL, anchor="ra")
    return s


O = "/tmp/claude-0/-home-user-zelionpowerflightdashboard/f6f3c57b-5b54-5436-9af8-d3abc1676ed5/scratchpad/"
render_800().save(O + "zeliondash_800x480.png")
render_480().save(O + "zeliondash_480x320.png")
render_480(wide_logo=True).save(O + "zeliondash_480x320_widelogo.png")
render_800(standby=True).save(O + "zeliondash_standby.png")
