# Draws docs/img/serial-console.png: python3 serial-console.py serial-console.png (Pillow, DejaVu fonts)
from PIL import Image, ImageDraw, ImageFont
W,H=1600,1230
im=Image.new('RGB',(W,H),(255,255,255)); d=ImageDraw.Draw(im)
B='/usr/share/fonts/TTF/DejaVuSans-Bold.ttf'; R='/usr/share/fonts/TTF/DejaVuSans.ttf'
F=lambda p,s:ImageFont.truetype(p,s)
t1,t2,t3,t4=F(B,40),F(B,30),F(R,26),F(B,24)
BLUE=(30,100,230); GREEN=(20,160,70); RED=(220,40,40); GREY=(150,150,150); BLK=(30,30,30)
d.text((W//2,25),"DS923+ serial console",fill=BLK,font=t1,anchor='ma')
d.text((W//2,80),"115200 8N1 · 3.3 V USB-UART adapter · 3 wires",fill=(90,90,90),font=t3,anchor='ma')
hx,hy,p=230,270,130
d.text((140,125),"Header on the mainboard (seen from the front)",fill=BLK,font=t2,anchor='la')
d.rounded_rectangle((hx-90,hy-95,hx+2*p+90,hy+p+105),radius=16,outline=BLK,width=4,fill=(232,238,250))
pins={(0,0):('5','n.c.',GREY),(1,0):('3','n.c.',GREY),(2,0):('1','3.3 V',RED),
      (0,1):('6','RX',BLUE),(1,1):('4','TX',GREEN),(2,1):('2','GND',BLK)}
pos={}
for (c,r),(n,s,col) in pins.items():
    x,y=hx+c*p,hy+r*p; pos[n]=(x,y); filled=n in '64'
    d.ellipse((x-36,y-36,x+36,y+36),fill=col if filled else (255,255,255),outline=col,width=6)
    d.text((x,y),n,fill=(255,255,255) if filled else col,font=t2,anchor='mm')
    if r==0: d.text((x,y-48),s,fill=col,font=t4,anchor='md')
    elif n=='2': d.text((x,y+50),"GND",fill=col,font=t4,anchor='ma')
    else: d.text((x-14,y+62),s,fill=col,font=t4,anchor='rm')
d.text((hx+2*p+110,hy),"outer row",fill=GREY,font=t4,anchor='lm')
d.text((hx+2*p+110,hy+32),"pin 1 = 3.3 V: do NOT connect",fill=RED,font=F(R,22),anchor='lm')
d.text((hx+2*p+110,hy+p),"row next to the board",fill=BLK,font=t4,anchor='lm')
d.text((hx+2*p+110,hy+p+32),"pin 2 = GND (not measured)",fill=(90,90,90),font=F(R,22),anchor='lm')
yx,y0,st=1180,580,70
names=['DTR','RXD','TXD','VCC','CTS','GND']
d.rounded_rectangle((yx-50,y0-110,yx+320,y0+5*st+50),radius=16,outline=(180,30,30),width=4,fill=(255,236,236))
d.text((yx+135,y0-95),"USB-UART adapter",fill=(180,30,30),font=t2,anchor='ma')
d.text((yx+135,y0-58),"(e.g. FT232RL, CP2102, set to 3.3 V)",fill=(180,30,30),font=F(R,17),anchor='ma')
yp={}
for i,nm in enumerate(names):
    y=y0+i*st; yp[nm]=y
    col={'GND':BLK,'TXD':BLUE,'RXD':GREEN}.get(nm,GREY); used=col!=GREY
    d.rectangle((yx-18,y-18,yx+18,y+18),fill=col if used else (255,255,255),outline=col,width=4)
    d.text((yx+40,y),nm if used else nm+"  n.c.",fill=col,font=t2 if used else t4,anchor='lm')
def wire(x,y,ty,col,lab):
    d.line([(x,y+36),(x,ty),(yx-18,ty)],fill=col,width=9,joint='curve')
    d.text((x+(yx-x)//2+40,ty-12),lab,fill=col,font=t4,anchor='md')
wire(*pos['4'],yp['RXD'],GREEN,"pin 4 (NAS TX) → RXD")
wire(*pos['6'],yp['TXD'],BLUE,"pin 6 (NAS RX) → TXD")
ux,uy=330,yp['GND']+110
d.rounded_rectangle((ux-140,uy-50,ux+140,uy+50),radius=8,outline=BLK,width=5,fill=(225,225,225))
d.rectangle((ux-105,uy-32,ux+105,uy-6),fill=(70,130,220))
d.text((ux,uy+62),"front USB port of the NAS",fill=BLK,font=t4,anchor='ma')
d.line([(ux+140,uy),(900,uy),(900,yp['GND']),(yx-18,yp['GND'])],fill=BLK,width=9,joint='curve')
d.text((1015,yp['GND']-12),"shell → GND",fill=BLK,font=t4,anchor='md')
d.text((ux+160,uy+30),"metal shell only, never the contacts inside (5 V)",fill=RED,font=F(R,22),anchor='lm')
d.text((40,H-45),"Pins 4 and 6 tested on a DS923+; pins 1, 2, 3, 5 follow the DS1522+ layout and were not measured.",fill=(90,90,90),font=F(R,22))
import sys; im.save(sys.argv[1])
