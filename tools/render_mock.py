#!/usr/bin/env python3
"""Renders MOCK previews of the GasTray icon, tooltip and menu with Pillow.
System.Drawing/WinForms cannot run on Linux, so this mimics GasTray.ps1's New-GasIcon
(rounded square, level colour, largest bold font that fits) and the menu layout.
These are NOT Windows screenshots."""
import json, sys, os
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[2] if len(sys.argv) > 2 else 'screenshots'
live = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else {}
os.makedirs(OUT, exist_ok=True)
BOLD = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
REG = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
COL = {'Green': ((46,125,50),(255,255,255)), 'Amber': ((249,168,37),(0,0,0)),
       'Red': ((198,40,40),(255,255,255)), 'Unknown': ((97,97,97),(255,255,255))}

def icon(text, level, size=32):
    back, fore = COL[level]
    im = Image.new('RGBA', (size, size), (0,0,0,0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0,0,size-1,size-1], radius=size//5, fill=back)
    fs = size*0.75
    while fs >= 6:
        f = ImageFont.truetype(BOLD, int(fs))
        l,t,r,b = d.textbbox((0,0), text, font=f)
        if r-l <= size-2 and b-t <= size: break
        fs -= 0.5
    l,t,r,b = d.textbbox((0,0), text, font=f)
    d.text(((size-(r-l))/2 - l, (size-(b-t))/2 - t), text, font=f, fill=fore)
    return im

# 1) icon gallery
samples = [('.06','Green','ETH 0.06'),('7.4','Amber','ETH 7.4'),('25','Red','ETH 25'),
           ('671K','Green','PLS 671K'),('1.2M','Amber','PLS 1.2M'),('3.5M','Red','PLS 3.5M'),('?','Unknown','no data')]
W = 140*len(samples); g = Image.new('RGB', (W, 210), (32,32,32)); d = ImageDraw.Draw(g)
sf = ImageFont.truetype(REG, 13)
d.text((10,6), 'MOCK icon render (Pillow on Linux, mimics New-GasIcon) - 64px / 32px / 16px', font=sf, fill=(255,200,0))
for i,(t,l,cap) in enumerate(samples):
    x = 140*i + 20
    g.paste(icon(t,l,32).resize((64,64), Image.NEAREST), (x, 35), icon(t,l,32).resize((64,64), Image.NEAREST))
    i32 = icon(t,l,32); g.paste(i32, (x, 115), i32)
    i16 = i32.resize((16,16), Image.LANCZOS); g.paste(i16, (x+50, 123), i16)
    d.text((x, 165), cap, font=sf, fill=(230,230,230)); d.text((x, 182), l, font=sf, fill=(160,160,160))
g.save(os.path.join(OUT, 'mock-icons.png'))

# 2) tray + tooltip + context menu with live data
eth_icon, eth_level = live.get('ethIcon','.06'), live.get('ethLevel','Green')
lines_menu = [
    ('GasTray 1.0.0 - ETH / PLS gas', 'dis'), ('-',None),
    (live.get('eth','ETH ...'), ''), (live.get('pls','PLS ...'), ''),
    ('Updated %s - every 30s' % live.get('time','--:--:--'), 'dis'), ('-',None),
    ('Icon shows  \u25b8   [x] Ethereum (ETH)  [ ] PulseChain (PLS)', ''),
    ('Refresh interval  \u25b8   15 / [x] 30 / 60 seconds', ''),
    ('Refresh now', ''), ('Start with Windows', ''), ('Open settings file', ''), ('Reload settings',''), ('-',None), ('Exit',''),
]
mf = ImageFont.truetype(REG, 14)
mw = max(int(ImageDraw.Draw(Image.new('RGB',(1,1))).textlength(t, font=mf)) for t,_ in lines_menu if t!='-') + 60
mh = sum(9 if t=='-' else 26 for t,_ in lines_menu) + 8
img = Image.new('RGB', (max(mw+80, 760), mh + 210), (90,110,140))
d = ImageDraw.Draw(img)
d.text((10,8), 'MOCK - rendered with Python Pillow on Linux from LIVE data; NOT a Windows screenshot', font=ImageFont.truetype(BOLD,14), fill=(255,230,0))
# menu
mx, my = img.width - mw - 30, 40
d.rectangle([mx, my, mx+mw, my+mh], fill=(249,249,249), outline=(160,160,160))
y = my + 4
for t,k in lines_menu:
    if t == '-': d.line([mx+30, y+4, mx+mw-6, y+4], fill=(215,215,215)); y += 9; continue
    d.text((mx+34, y+5), t, font=mf, fill=(150,150,150) if k=='dis' else (20,20,20)); y += 26
# tooltip
tip = live.get('tooltip','ETH ...\nPLS ...')
tf = ImageFont.truetype(REG, 13)
tl = tip.split('\n'); tw = max(int(d.textlength(s, font=tf)) for s in tl) + 16
ty = my + mh + 25; tx = img.width - tw - 60
d.rectangle([tx, ty, tx+tw, ty+18*len(tl)+10], fill=(255,255,255), outline=(118,118,118))
for i,s in enumerate(tl): d.text((tx+8, ty+5+18*i), s, font=tf, fill=(0,0,0))
d.text((10, ty), 'Tooltip (hover):', font=tf, fill=(255,255,255))
# taskbar
tb = img.height - 48
d.rectangle([0, tb, img.width, img.height], fill=(32,32,32))
ic = icon(eth_icon, eth_level, 32).resize((24,24), Image.LANCZOS)
ix = img.width - 190; img.paste(ic, (ix, tb+12), ic)
d.rectangle([ix-4, tb+8, ix+28, tb+40], outline=(120,120,120))
d.text((ix+45, tb+8), live.get('time','')[:5], font=tf, fill=(255,255,255))
d.text((ix+45, tb+25), '18/10/2026', font=tf, fill=(255,255,255))
d.text((10, tb+16), 'Taskbar: icon shows ETH avg gwei "%s" (%s)' % (eth_icon, eth_level), font=tf, fill=(220,220,220))
img.save(os.path.join(OUT, 'mock-tray-menu-tooltip.png'))
print('wrote', os.path.join(OUT,'mock-icons.png'), os.path.join(OUT,'mock-tray-menu-tooltip.png'))
