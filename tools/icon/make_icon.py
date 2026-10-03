#!/usr/bin/env python3
"""Draws the Mayor Street icon: a golden-hour skyline over a street running into town.

    python3 tools/icon/make_icon.py

Writes assets/icon/icon.png (256 px, the window icon), assets/icon/icon.ico (16-256 px, the
Windows exe and shortcuts) and tools/installer/welcome.bmp (the installer's side panel).
Small sizes get a simpler drawing (fewer, bigger towers, no window grid) so they stay crisp.
"""
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

SKY = [(0.0, (30, 36, 88)), (0.42, (120, 70, 128)), (0.62, (236, 120, 96)), (0.72, (255, 178, 92))]
TOWER = (26, 27, 50)
TOWER_EDGE = (44, 40, 72)
LIT = (255, 206, 120)
GROUND = (28, 28, 44)
ROAD = (58, 58, 76)
CURB = (150, 140, 150)
LINE = (255, 204, 48)
SUN = (255, 222, 140)

# (left, right, top) in units of the canvas, bottoms on the horizon
TOWERS_FULL = [(0.04, 0.19, 0.42), (0.17, 0.33, 0.17), (0.35, 0.47, 0.44), (0.49, 0.62, 0.27),
               (0.64, 0.77, 0.47), (0.76, 0.93, 0.33)]
TOWERS_SIMPLE = [(0.06, 0.30, 0.30), (0.34, 0.56, 0.40), (0.60, 0.92, 0.22)]
HORIZON = 0.66


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def sky_color(t):
    for (t0, c0), (t1, c1) in zip(SKY, SKY[1:]):
        if t <= t1:
            return lerp(c0, c1, (t - t0) / (t1 - t0))
    return SKY[-1][1]


def scene(w, h, simple=False, seed=5, squash=1.0):
    """The picture itself, edge to edge, w x h pixels. squash < 1 lowers the towers."""
    rng = random.Random(seed)
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    hy = HORIZON * h
    for y in range(h):
        d.line([(0, y), (w, y)], fill=sky_color(y / hy * SKY[-1][0]) if y < hy else GROUND)

    # Sun with a soft glow, low over the towers.
    glow = Image.new("L", (w, h), 0)
    sx, sy, sr = 0.70 * w, 0.55 * h, 0.13 * min(w, h)
    ImageDraw.Draw(glow).ellipse([sx - sr * 2.2, sy - sr * 2.2, sx + sr * 2.2, sy + sr * 2.2], fill=110)
    glow = glow.filter(ImageFilter.GaussianBlur(sr * 0.9))
    ImageDraw.Draw(glow).rectangle([0, hy, w, h], fill=0)  # the glow stays in the sky
    img.paste(Image.new("RGB", (w, h), SUN), (0, 0), glow)
    d.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=SUN)
    d.rectangle([0, hy, w, h], fill=GROUND)  # the sun sets behind the ground

    for x0, x1, top in (TOWERS_SIMPLE if simple else TOWERS_FULL):
        X0, X1, Y0 = x0 * w, x1 * w, hy - (HORIZON - top) * h * squash
        d.rectangle([X0, Y0, X1, hy], fill=TOWER)
        d.rectangle([X1 - (X1 - X0) * 0.16, Y0, X1, hy], fill=TOWER_EDGE)  # sunlit side
        if simple:
            continue
        cols = 3
        cw = (X1 - X0) / cols
        rows = int((hy - Y0) / (cw * 1.15))
        for r in range(rows):
            for c in range(cols):
                if rng.random() < 0.38:
                    wx, wy = X0 + c * cw + cw * 0.28, Y0 + cw * 0.5 + r * cw * 1.15
                    if wy + cw * 0.55 < hy - cw * 0.2:
                        d.rectangle([wx, wy, wx + cw * 0.42, wy + cw * 0.55], fill=LIT)

    # The street runs from the bottom edge to the middle of town.
    vx, by = 0.5 * w, h
    road = [(vx - 0.035 * w, hy), (vx + 0.035 * w, hy), (0.86 * w, by), (0.14 * w, by)]
    d.polygon(road, fill=ROAD)
    for side in (-1, 1):
        d.line([(vx + side * 0.035 * w, hy), (0.5 * w + side * 0.36 * w, by)], fill=CURB,
               width=max(1, int(w * 0.012)))
    # Dashes shrink with distance.
    dashes = [(0.80, 0.97), (0.70, 0.76)] if simple else [(0.86, 0.99), (0.76, 0.82), (0.70, 0.735)]
    for a, b in dashes:
        ya, yb = a * h, b * h
        ka, kb = (ya - hy) / (h - hy), (yb - hy) / (h - hy)
        wa, wb = 0.006 * w + 0.024 * w * ka, 0.006 * w + 0.024 * w * kb
        d.polygon([(vx - wa, ya), (vx + wa, ya), (vx + wb, yb), (vx - wb, yb)], fill=LINE)
    return img


def icon(size, simple):
    """Rounded-square icon with a little transparent margin, drawn 4x and scaled down."""
    s = size * 4
    pic = scene(s, s, simple)
    mask = Image.new("L", (s, s), 0)
    m = round(s * 0.03)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, s - 1 - m, s - 1 - m], radius=s * 0.2, fill=255)
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(pic, (0, 0), mask)
    return out.resize((size, size), Image.LANCZOS)


def welcome_panel(path):
    """NSIS welcome/finish side panel: 164 x 314, the scene with the game's name on top."""
    w, h = 164, 314
    pic = scene(w * 3, h * 3, squash=0.62).resize((w, h), Image.LANCZOS)
    d = ImageDraw.Draw(pic)
    for text, y, size in (("MAYOR", 22, 28), ("STREET", 52, 28)):
        font = ImageFont.truetype(FONT, size)
        tw = d.textlength(text, font=font)
        d.text(((w - tw) / 2 + 1, y + 2), text, font=font, fill=(10, 10, 24))
        d.text(((w - tw) / 2, y), text, font=font, fill=(255, 236, 200))
    pic.save(path)


def main():
    out = os.path.join(ROOT, "assets", "icon")
    os.makedirs(out, exist_ok=True)
    sizes = [16, 24, 32, 48, 64, 128, 256]
    images = {s: icon(s, simple=s <= 32) for s in sizes}
    images[256].save(os.path.join(out, "icon.png"))
    images[256].save(os.path.join(out, "icon.ico"), sizes=[(s, s) for s in sizes],
                     append_images=[images[s] for s in sizes if s != 256])
    inst = os.path.join(ROOT, "tools", "installer")
    os.makedirs(inst, exist_ok=True)
    welcome_panel(os.path.join(inst, "welcome.bmp"))
    # A contact sheet to eyeball every size at once (not committed).
    sheet = Image.new("RGBA", (sum(sizes) + 8 * len(sizes), 256), (236, 236, 240, 255))
    x = 0
    for s in sizes:
        sheet.paste(images[s], (x, 256 - s), images[s])
        x += s + 8
    sheet.save(os.path.join("/tmp", "mayor_icon_sheet.png"))
    print("wrote", out, "and", inst)


if __name__ == "__main__":
    main()
