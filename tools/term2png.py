#!/usr/bin/env python3
"""Render a terminal capture (text with ANSI colours) as a PNG terminal window.

    term2png.py capture.txt out.png [--title TITLE] [--cols N]

Needs pyte and Pillow. Used for the screenshots in docs/img.
"""
import argparse
import pyte
from PIL import Image, ImageDraw, ImageFont

FONT = "/usr/share/fonts/TTF/DejaVuSansMono.ttf"
FONT_BOLD = "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf"
BG, FG, BAR = (30, 32, 40), (220, 223, 228), (48, 51, 62)
COLOURS = {"default": FG, "black": (40, 42, 54), "red": (255, 110, 110), "green": (120, 220, 120),
           "brown": (240, 200, 110), "yellow": (240, 220, 120), "blue": (110, 160, 255),
           "magenta": (220, 140, 240), "cyan": (100, 215, 230), "white": (240, 240, 240)}
# backgrounds (the Debian installer draws blue screens and white/grey dialogs)
BGCOLOURS = {"black": (0, 0, 0), "red": (170, 40, 40), "green": (40, 140, 40), "brown": (170, 120, 30),
             "blue": (24, 56, 140), "magenta": (130, 50, 130), "cyan": (40, 140, 150), "white": (205, 205, 205)}
FGONBG = {"black": (0, 0, 0), "white": (250, 250, 250), "blue": (24, 56, 140), "red": (190, 30, 30),
          "yellow": (250, 230, 90), "brown": (160, 110, 20)}

ap = argparse.ArgumentParser()
ap.add_argument("src")
ap.add_argument("out")
ap.add_argument("--title", default="ssh admin@nas")
ap.add_argument("--cols", type=int, default=92)
ap.add_argument("--screen", default="", help="background colour of the whole screen (e.g. blue)")
a = ap.parse_args()

text = open(a.src, "rb").read().decode("utf-8", "replace").replace("\r\n", "\n").replace("\n", "\r\n")
rows = text.count("\n") + 2
screen = pyte.Screen(a.cols, rows)
pyte.Stream(screen).feed(text)
# drop trailing empty lines
last = max((y for y in range(rows) if screen.display[y].strip()), default=0)

size = 16
font, bold = ImageFont.truetype(FONT, size), ImageFont.truetype(FONT_BOLD, size)
cw = font.getbbox("M")[2]
lh = int(size * 1.45)
pad, bar = 18, 34
W = pad * 2 + cw * a.cols
H = bar + pad * 2 + lh * (last + 1)
img = Image.new("RGB", (W, H), BGCOLOURS.get(a.screen, BG))
d = ImageDraw.Draw(img)
d.rectangle([0, 0, W, bar], fill=BAR)
for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
    d.ellipse([14 + i * 22, 11, 26 + i * 22, 23], fill=c)
d.text((W // 2, bar // 2), a.title, fill=(170, 174, 184), font=font, anchor="mm")
for y in range(last + 1):
    line = screen.buffer[y]
    for x in range(a.cols):
        ch = line[x]
        fg, bg = (ch.bg, ch.fg) if ch.reverse else (ch.fg, ch.bg)
        if bg != "default" and bg in BGCOLOURS:
            x0, y0 = pad + x * cw, bar + pad + y * lh
            d.rectangle([x0, y0, x0 + cw, y0 + lh], fill=BGCOLOURS[bg])
        if ch.data in (" ", ""):
            continue
        if bg != "default":
            col = FGONBG.get(fg, FG)
        elif a.screen and fg == "default":
            col = (235, 235, 235)
        else:
            col = COLOURS.get(fg, FG)
        d.text((pad + x * cw, bar + pad + y * lh), ch.data, fill=col, font=bold if ch.bold else font)
img.save(a.out, optimize=True)
print(a.out, img.size)
