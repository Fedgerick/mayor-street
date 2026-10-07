"""Draws the ground-wear and graffiti atlas the street dresser lays on roads, sidewalks
and walls: art/dresser/decals.png, 4 x 4 tiles of 256 px (all drawn here, so CC0).

    python3 art/tools/make_decals.py

Tiles 0-7 lie on the ground (cracks, oil, tyre marks, stains, patches), tiles 8-15 go on
walls (graffiti tags and throw-ups). Wall tiles are drawn at 2:1 and squeezed into the
square tile; the dresser stretches them back on a 2:1 quad. The alpha channel is the
decal's coverage; colours are straight (not premultiplied).
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "dresser", "decals.png"))
T = 256
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def blank(w=T, h=T):
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def crack(seed):
    rng = random.Random(seed)
    im = blank()
    d = ImageDraw.Draw(im)
    for _ in range(3):
        x, y = rng.uniform(40, 216), rng.uniform(40, 216)
        a = rng.uniform(0, math.tau)
        for _ in range(rng.randint(8, 16)):
            a += rng.uniform(-0.7, 0.7)
            nx, ny = x + math.cos(a) * rng.uniform(8, 20), y + math.sin(a) * rng.uniform(8, 20)
            nx, ny = min(max(nx, 8), T - 8), min(max(ny, 8), T - 8)
            d.line((x, y, nx, ny), fill=(25, 24, 22, 200), width=rng.choice([2, 3, 3, 4]))
            if rng.random() < 0.25:  # a little branch
                b = a + rng.choice([-1, 1]) * rng.uniform(0.6, 1.2)
                d.line((nx, ny, nx + math.cos(b) * 14, ny + math.sin(b) * 14), fill=(25, 24, 22, 160), width=2)
            x, y = nx, ny
    return im.filter(ImageFilter.GaussianBlur(0.6))


def stain(seed, col, blobs=14, spread=60, alpha=150):
    rng = random.Random(seed)
    im = blank()
    d = ImageDraw.Draw(im)
    for _ in range(blobs):
        r = rng.uniform(12, 38)
        x, y = T / 2 + rng.gauss(0, spread * 0.45), T / 2 + rng.gauss(0, spread * 0.45)
        d.ellipse((x - r, y - r * rng.uniform(0.6, 1.0), x + r, y + r), fill=(*col, alpha))
    im = im.filter(ImageFilter.GaussianBlur(10))
    # soften the edge to nothing at the tile border
    mask = Image.new("L", (T, T), 0)
    ImageDraw.Draw(mask).ellipse((10, 10, T - 10, T - 10), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(14))
    a = Image.composite(im.getchannel("A"), Image.new("L", (T, T), 0), mask)
    im.putalpha(a)
    return im


def tyre_marks(seed):
    rng = random.Random(seed)
    im = blank()
    d = ImageDraw.Draw(im)
    for off in (-34, 34):
        pts = []
        for i in range(30):
            t = i / 29
            x = T / 2 + off + math.sin(t * 2.6 + seed) * 30
            pts.append((x, 8 + t * (T - 16)))
        d.line(pts, fill=(15, 15, 15, 130), width=16, joint="curve")
    return im.filter(ImageFilter.GaussianBlur(3))


def patch(seed):
    """A darker square of newer asphalt / concrete where the road was dug up."""
    rng = random.Random(seed)
    im = blank()
    d = ImageDraw.Draw(im)
    x0, y0 = rng.uniform(30, 60), rng.uniform(30, 60)
    pts = [(x0, y0), (T - rng.uniform(30, 60), y0 + rng.uniform(-8, 8)),
           (T - rng.uniform(30, 60), T - rng.uniform(30, 60)), (x0 + rng.uniform(-8, 8), T - rng.uniform(30, 60))]
    d.polygon(pts, fill=(18, 18, 20, 120), outline=(10, 10, 10, 190))
    return im.filter(ImageFilter.GaussianBlur(1.0))


def gum(seed):
    rng = random.Random(seed)
    im = blank()
    d = ImageDraw.Draw(im)
    for _ in range(40):
        x, y, r = rng.uniform(20, 236), rng.uniform(20, 236), rng.uniform(2, 6)
        d.ellipse((x - r, y - r, x + r, y + r), fill=(30, 30, 30, rng.randint(70, 140)))
    return im.filter(ImageFilter.GaussianBlur(0.8))


PALETTES = [
    ((255, 70, 160), (40, 20, 60), (255, 230, 60)),
    ((60, 200, 255), (10, 30, 70), (255, 255, 255)),
    ((120, 230, 70), (20, 50, 20), (250, 250, 250)),
    ((255, 140, 30), (60, 20, 10), (255, 240, 200)),
    ((200, 90, 255), (25, 10, 45), (120, 255, 220)),
    ((250, 250, 250), (20, 20, 20), (255, 60, 60)),
]
WORDS = ["MAYOR", "KINGS", "ZAP!", "RIOT", "SKOR", "WAVE", "DUKE", "NOPE"]


def graffiti(seed, word):
    """Bubble-letter tag: outlined, filled with a gradient, a highlight and a few drips."""
    rng = random.Random(seed)
    fill, line, hi = PALETTES[seed % len(PALETTES)]
    W, H = T * 2, T
    im = blank(W, H)
    font = ImageFont.truetype(FONT, 150 if len(word) <= 4 else 120)
    lay = blank(W, H)
    d = ImageDraw.Draw(lay)
    bbox = d.textbbox((0, 0), word, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x, y = (W - tw) / 2 - bbox[0], (H - th) / 2 - bbox[1]
    # letters wobble: draw each letter on its own with a small tilt
    cx = x
    for ch in word:
        cb = d.textbbox((0, 0), ch, font=font)
        cw = cb[2] - cb[0]
        tile = blank(cw + 60, H)
        td = ImageDraw.Draw(tile)
        td.text((30 - cb[0], y), ch, font=font, fill=fill, stroke_width=12, stroke_fill=line)
        tile = tile.rotate(rng.uniform(-12, 12), resample=Image.BICUBIC, center=(tile.width / 2, H / 2))
        lay.alpha_composite(tile, (int(cx - 30), int(rng.uniform(-10, 10))))
        cx += cw * 0.92
    d2 = ImageDraw.Draw(lay)
    for _ in range(4):  # drips
        dx = rng.uniform(W * 0.25, W * 0.75)
        top = H / 2 + th * 0.35
        d2.line((dx, top, dx, top + rng.uniform(20, 50)), fill=(*fill, 255), width=6)
    for _ in range(3):  # spray highlights
        hx, hy = rng.uniform(W * 0.25, W * 0.75), rng.uniform(H * 0.35, H * 0.5)
        d2.ellipse((hx - 10, hy - 4, hx + 10, hy + 4), fill=(*hi, 230))
    im.alpha_composite(lay)
    # overspray halo
    halo = im.getchannel("A").filter(ImageFilter.GaussianBlur(8)).point(lambda a: int(a * 0.35))
    under = Image.new("RGBA", (W, H), (*line, 0))
    under.putalpha(halo)
    under.alpha_composite(im)
    return under.resize((T, T), Image.LANCZOS)


def main():
    tiles = [
        crack(1), crack(2), stain(3, (12, 12, 14)), stain(4, (20, 16, 10), blobs=8, spread=40, alpha=170),
        tyre_marks(5), gum(6), patch(7), stain(8, (40, 38, 34), blobs=20, spread=90, alpha=90),
    ]
    tiles += [graffiti(10 + i, WORDS[i]) for i in range(8)]
    atlas = Image.new("RGBA", (T * 4, T * 4), (0, 0, 0, 0))
    for i, t in enumerate(tiles):
        atlas.paste(t, ((i % 4) * T, (i // 4) * T))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    atlas.save(OUT)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
