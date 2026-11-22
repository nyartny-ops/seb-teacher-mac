#!/usr/bin/env python3
"""Рисует фон окна установщика .dmg (background.png и background@2x.png).
Нужны Pillow и шрифты: python3 make_background.py NIHONIUM.ttf ROBOTO.ttf FIRAMONO.ttf FIRAMONO-MEDIUM.ttf"""
import math
import random
import sys

from PIL import Image, ImageDraw, ImageFont

NI, RO, FM, FMB = sys.argv[1:5]
BLUE = (35, 0, 250)
LIME = (220, 255, 5)
PINK = (255, 2, 230)
BLACK = (0, 0, 0)
GRAY = (127, 127, 127)


def render(s):
    W, H = 660 * s, 400 * s
    im = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 18 * s, H], fill=BLUE)
    d.rectangle([W - 18 * s, 0, W, H], fill=BLUE)
    d.rectangle([18 * s, 296 * s, W - 18 * s, H], fill=LIME)
    d.line([18 * s, 296 * s, W - 18 * s, 296 * s], fill=BLACK, width=2 * s)

    d.text((40 * s, 22 * s), "SEBАСТЬЯН", font=ImageFont.truetype(NI, 46 * s), fill=BLACK)
    d.text((42 * s, 78 * s), "safe exam browser · бета", font=ImageFont.truetype(FM, 13 * s), fill=GRAY)

    fr = ImageFont.truetype(RO, 22 * s)
    try:
        fr.set_variation_by_axes([800])
    except Exception:
        pass
    txt = "перетащи сюда"
    tw = d.textlength(txt, font=fr)
    st = Image.new("RGBA", (int(tw + 24 * s), int(36 * s)), PINK + (255,))
    ImageDraw.Draw(st).text((12 * s, 3 * s), txt, font=fr, fill=(255, 255, 255))
    st = st.rotate(4, expand=True, resample=Image.BICUBIC)
    im.paste(st, (int(404 * s), int(70 * s)), st)

    random.seed(7)
    pts = []
    for i in range(61):
        t = i / 60
        x = 238 + t * (422 - 238)
        y = 200 - math.sin(t * math.pi) * 58 + random.uniform(-1.2, 1.2)
        pts.append((x * s, y * s))
    d.line(pts, fill=BLACK, width=int(3 * s), joint="curve")
    ex, ey = pts[-1]
    d.line([(ex, ey), (ex - 17 * s, ey - 10 * s)], fill=BLACK, width=int(3 * s))
    d.line([(ex, ey), (ex - 5 * s, ey - 19 * s)], fill=BLACK, width=int(3 * s))

    fb = ImageFont.truetype(FMB, 13 * s)
    f2 = ImageFont.truetype(FM, 12 * s)
    d.text((40 * s, 308 * s), "не открывается при первом запуске?", font=fb, fill=BLACK)
    d.text((40 * s, 328 * s), "Системные настройки → Конфиденциальность", font=f2, fill=BLACK)
    d.text((40 * s, 345 * s), "и безопасность → «Всё равно открыть»", font=f2, fill=BLACK)
    # знак SEBастьяна: «>_» в лаймовом квадрате с чёрной рамкой
    x0, y0 = W - 92 * s, 314 * s
    d.rectangle([x0, y0, x0 + 52 * s, y0 + 40 * s], fill=BLACK)
    d.rectangle([x0 + 3 * s, y0 + 3 * s, x0 + 49 * s, y0 + 37 * s], fill=LIME)
    d.text((x0 + 9 * s, y0 + 5 * s), ">_", font=ImageFont.truetype(FMB, 24 * s), fill=BLACK)
    return im


render(1).save("background.png")
render(2).save("background@2x.png")
print("ok")
