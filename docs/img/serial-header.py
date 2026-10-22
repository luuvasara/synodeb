# Draws docs/img/serial-header.png from the photo of the header (taken through the front grille,
# from below): python3 serial-header.py PHOTO OUT.png (Pillow, DejaVu fonts)
import sys
from PIL import Image, ImageDraw, ImageFont
src, out = sys.argv[1:]
ph = Image.open(src).convert('RGB').rotate(180)
W, H = ph.size
# pin tips in the rotated photo
# row near the board (connected): 6-4-2 from the left; outer row: 5-3-1
PINS = {'6': (551, 435), '4': (593, 435), '2': (636, 434),
        '5': (550, 396), '3': (592, 395), '1': (636, 395)}
box = (420, 270, 820, 545)
S = 1032 / (box[2] - box[0])
crop = ph.crop(box).resize((1032, round((box[3] - box[1]) * S)), Image.LANCZOS)
B = '/usr/share/fonts/TTF/DejaVuSans-Bold.ttf'
R = '/usr/share/fonts/TTF/DejaVuSans.ttf'
F = lambda p, s: ImageFont.truetype(p, s)
BLUE, GREEN, WHITE, RED, GREY = (60, 140, 255), (40, 200, 90), (240, 240, 240), (235, 60, 60), (150, 150, 150)
COL = {'6': BLUE, '4': GREEN, '2': WHITE, '1': RED, '3': GREY, '5': GREY}
legend = [('6', 'RX of the NAS', '→ TXD of the adapter'), ('4', 'TX of the NAS', '→ RXD of the adapter'),
          ('2', 'GND', 'or the shell of the front USB port'), ('1', '3.3 V', 'do NOT connect'),
          ('3, 5', '', 'not connected')]
LH = 48
im = Image.new('RGB', (1032, crop.height + 70 + len(legend) * LH + 110), (24, 24, 28))
im.paste(crop, (0, 70))
d = ImageDraw.Draw(im)
d.text((20, 18), 'DS923+ serial header, seen through the front grille from below', fill=WHITE, font=F(B, 27))
for n, (x, y) in PINS.items():
    cx, cy = (x - box[0]) * S, (y - box[1]) * S + 70
    c = COL[n]
    d.ellipse((cx - 22, cy - 22, cx + 22, cy + 22), outline=c, width=5)
    near = n in '642'
    d.text((cx, cy + 30 if near else cy - 30), n, fill=c, font=F(B, 30), anchor='ma' if near else 'md',
           stroke_width=4, stroke_fill=(0, 0, 0))
y = crop.height + 70 + 25
for n, name, what in legend:
    c = COL[n[0]] if n != '3, 5' else GREY
    d.ellipse((20, y + 4, 46, y + 30), outline=c, width=4)
    d.text((64, y + 17), f'{n}  {name}'.rstrip(), fill=c, font=F(B, 24), anchor='lm')
    d.text((330, y + 17), what, fill=WHITE, font=F(R, 24), anchor='lm')
    y += LH
d.text((20, y + 15), '3.3 V USB-UART adapter, 115200 8N1. Pins 4 and 6 tested on a DS923+;',
       fill=(200, 200, 200), font=F(R, 22))
d.text((20, y + 45), 'pins 1, 2, 3 and 5 follow the DS1522+ layout and were not measured.',
       fill=(200, 200, 200), font=F(R, 22))
im.save(out)
