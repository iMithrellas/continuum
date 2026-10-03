"""Original Continuum field-guide art. Rebuild with Python, Pillow and numpy.

All random generators have explicit seeds. No downloaded or third-party art.
Terrain panels are seamless multiscale fields; object sheets have transparent
silhouettes, top-left lighting and distinct silhouettes at native map scale.
"""
from pathlib import Path
import math
import random
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parents[1] / "assets/world"
OUT.mkdir(parents=True, exist_ok=True)
N = 256
rng = np.random.default_rng(70672)


def field(scale):
    grid = rng.random((scale, scale))
    # Periodic bilinear value field, with smooth cubic interpolation.
    pos = np.arange(N) * scale / N
    k = pos.astype(int)
    t = pos - k
    t = t * t * (3 - 2 * t)
    a = grid[k[:, None] % scale, k[None, :] % scale]
    b = grid[k[:, None] % scale, (k[None, :] + 1) % scale]
    c = grid[(k[:, None] + 1) % scale, k[None, :] % scale]
    d = grid[(k[:, None] + 1) % scale, (k[None, :] + 1) % scale]
    return (a * (1-t)[None, :] + b * t[None, :]) * (1-t)[:, None] + (c * (1-t)[None, :] + d * t[None, :]) * t[:, None]


atlas = Image.new("RGB", (N * 6, N))
# Loam/moss, blue-grey bedrock, sand, iron clay, gravel, rich turf.
palettes = [((66, 82, 49), (124, 136, 79)), ((77, 91, 96), (139, 150, 146)),
            ((143, 123, 82), (202, 183, 124)), ((114, 72, 51), (175, 122, 79)),
            ((97, 93, 81), (154, 151, 130)), ((42, 79, 49), (95, 132, 65))]
for material, (low, high) in enumerate(palettes):
    coarse, medium, fine = field(4), field(17), field(64)
    v = coarse * .35 + medium * .4 + fine * .25
    y, x = np.mgrid[:N, :N]
    if material in (0, 5):
        # Broken fibrous strokes, never a per-cell repeating marker.
        blades = np.maximum(0, np.sin(x * math.tau / 4 + medium * 13)) ** 14
        v += blades * np.maximum(0, fine - .47) * .45
    elif material in (1, 4):
        veins = np.abs(np.sin((x + y * 2) * math.tau / 64 + medium * 5))
        v -= np.maximum(0, .12 - veins) * 1.7
        v += np.maximum(0, fine - .68) * .45
    elif material == 2:
        v += np.sin(y * math.tau / 16 + coarse * 6) * .05
    else:
        v -= np.maximum(0, .2 - fine) * .6
    v += (rng.random((N, N)) - .5) * .065
    a = np.array(low)[None, None, :] + np.clip(v, 0, 1)[:, :, None] * (np.array(high) - low)
    atlas.paste(Image.fromarray(np.uint8(a)), (material * N, 0))
atlas.save(OUT / "materials.png")

INK = "#23362f"
WOOD = "#a87c4c"
LIGHT = "#e3c990"


def sprite(kind, variant):
    im = Image.new("RGBA", (64, 64))
    d = ImageDraw.Draw(im)
    r = random.Random(1981 + kind * 101 + variant * 173)
    d.ellipse((9, 42, 57, 58), fill=(19, 34, 27, 65))
    if kind == 0:  # farm: planted beds with paired leaves
        d.rounded_rectangle((3, 7, 60, 59), 6, fill="#695237")
        for yy in (16, 30, 44):
            d.line((7, yy + 8, 56, yy + 8), fill="#342f24", width=3)
            d.line((8, yy + 10, 56, yy + 10), fill="#927345", width=1)
            for xx in (13, 27, 42, 53):
                h = r.randrange(1, 5)
                d.line((xx, yy+5, xx, yy-h), fill="#bdd077", width=2)
                d.polygon([(xx, yy+3), (xx-6, yy-2-h), (xx-4, yy-5-h), (xx, yy-h)], fill="#789b4b")
                d.polygon([(xx, yy+2), (xx+5, yy-5-h), (xx+8, yy-4-h), (xx+3, yy+2)], fill="#b2c773")
    elif kind == 1:  # forest: irregular layered deciduous crowns
        d.polygon([(27, 53), (30, 29), (36, 28), (38, 52), (44, 57), (25, 57)], fill="#453e2b")
        d.line((32, 48, 33, 30), fill="#ba9360", width=3)
        palette = ["#284a36", "#365c3c", "#4c7446", "#668650", "#8c9f5b"]
        for cx, cy, rr in [(31, 32, 24), (18, 28, 15), (45, 28, 15), (31, 16, 15)]:
            cx += r.randrange(-3, 4)
            cy += r.randrange(-2, 3)
            d.ellipse((cx-rr, cy-rr, cx+rr, cy+rr), fill=INK)
            d.ellipse((cx-rr+2, cy-rr+1, cx+rr-2, cy+rr-4), fill=palette[1])
            d.ellipse((cx-rr+3, cy-rr+2, cx+rr-6, cy+rr-9), fill=palette[2 + variant % 2])
            d.arc((cx-rr+5, cy-rr+3, cx+rr-8, cy+rr-8), 185, 290, fill=palette[4], width=2)
        for _ in range(12):
            xx, yy = r.randrange(16, 47), r.randrange(14, 38)
            d.line((xx, yy, xx+3, yy-1), fill=palette[3], width=2)
    elif kind == 2:  # dining: timber trestle table, benches, bowls
        for yy in (10, 47):
            d.rounded_rectangle((9, yy, 55, yy+8), 2, fill=INK)
            d.rectangle((11, yy+1, 53, yy+4), fill=WOOD)
        d.rounded_rectangle((5, 20, 59, 45), 3, fill=INK)
        d.rectangle((7, 20, 56, 39), fill="#bc8c56")
        d.line((8, 21, 55, 21), fill=LIGHT, width=2)
        d.line((8, 29, 55, 29), fill="#946941")
        d.rectangle((29, 20, 37, 39), fill="#bb6449")
        for xx in (16, 47):
            d.ellipse((xx-5, 25, xx+5, 34), fill="#e2d8ae")
            d.ellipse((xx-3, 27, xx+3, 32), fill="#728752")
    elif kind == 3:  # sleep: canvas shelter over a raised timber deck
        d.rounded_rectangle((8, 39, 57, 57), 2, fill=INK)
        d.rectangle((11, 41, 54, 53), fill=WOOD)
        d.polygon([(7, 43), (28, 7), (36, 7), (59, 43), (48, 49), (16, 49)], fill=INK)
        d.polygon([(10, 42), (29, 10), (32, 13), (30, 45), (16, 46)], fill="#93a6a0")
        d.polygon([(32, 12), (35, 10), (56, 42), (46, 46), (32, 44)], fill="#5d7e7b")
        d.polygon([(24, 46), (32, 24), (40, 46)], fill="#243e3d")
        d.line((30, 12, 13, 42), fill="#d1cfac", width=2)
        d.line((32, 9, 32, 48), fill="#c4b589", width=2)
    elif kind == 4:  # recreation: small stone well and flower garden
        d.ellipse((8, 15, 58, 57), fill="#456345")
        d.ellipse((17, 25, 48, 54), fill=INK)
        d.ellipse((17, 21, 48, 48), fill="#a5a48d")
        d.ellipse((23, 25, 43, 41), fill="#314748")
        d.ellipse((26, 28, 40, 37), fill="#66938c")
        d.line((19, 36, 19, 12), fill=WOOD, width=4)
        d.line((46, 36, 46, 12), fill=WOOD, width=4)
        d.polygon([(12, 17), (31, 5), (53, 17), (53, 21), (12, 21)], fill="#b78053")
        d.line((16, 15, 31, 7, 49, 16), fill=LIGHT, width=2)
        for xx, yy in [(11, 43), (54, 39), (12, 27), (50, 51)]:
            d.ellipse((xx-2, yy-2, xx+2, yy+2), fill="#d4c182")
    elif kind == 5:  # mining: fractured outcrop and iron pick
        d.polygon([(7, 48), (10, 22), (23, 10), (43, 14), (57, 36), (51, 54), (23, 56)], fill=INK)
        d.polygon([(10, 45), (13, 23), (24, 13), (37, 21), (32, 42)], fill="#98a6a0")
        d.polygon([(32, 42), (37, 21), (44, 18), (54, 37), (48, 51)], fill="#61777a")
        d.polygon([(11, 46), (32, 43), (48, 52), (23, 53)], fill="#738680")
        d.line((17, 26, 27, 32, 24, 43), fill="#4c6667", width=2)
        d.line((23, 50, 45, 22), fill=INK, width=6)
        d.line((23, 49, 44, 23), fill="#c09860", width=3)
        d.arc((27, 16, 58, 40), 195, 300, fill="#d4d9bd", width=4)
    else:  # storage: braced crates, grain sack, wood pile
        for xx, yy in [(8, 13), (31, 28)]:
            d.rounded_rectangle((xx, yy, xx+25, yy+26), 2, fill=INK)
            d.rectangle((xx+2, yy+2, xx+22, yy+21), fill=WOOD)
            d.line((xx+3, yy+3, xx+21, yy+20), fill=LIGHT, width=3)
            for z in (5, 17):
                d.line((xx+z, yy+1, xx+z, yy+22), fill="#705236", width=2)
            d.line((xx+2, yy+2, xx+22, yy+2), fill=LIGHT, width=2)
        d.ellipse((9, 35, 31, 57), fill=INK)
        d.ellipse((11, 34, 29, 54), fill="#c5b383")
        d.line((16, 36, 25, 36), fill="#6e6247", width=2)
    return im


objects = Image.new("RGBA", (256, 448))
for kind in range(7):
    for variant in range(4):
        objects.alpha_composite(sprite(kind, variant), (variant * 64, kind * 64))
objects.save(OUT / "colony_objects.png")

workers = Image.new("RGBA", (128, 32))
for frame in range(4):
    im = Image.new("RGBA", (32, 32))
    d = ImageDraw.Draw(im)
    bob = 1 if frame in (1, 3) else 0
    stride = [0, 2, 0, -2][frame]
    d.ellipse((7, 26, 26, 30), fill=(17, 35, 29, 100))
    # Boots, backpack, coat, sleeves, scarf and readable cream brim.
    d.rectangle((10-stride//2, 22, 14-stride//2, 28), fill=INK)
    d.rectangle((19+stride//2, 22, 23+stride//2, 28), fill=INK)
    d.rectangle((11-stride//2, 23, 13-stride//2, 26), fill="#647a73")
    d.rectangle((7, 13+bob, 25, 23+bob), fill=INK)
    d.rectangle((8, 14+bob, 24, 20+bob), fill="#9c8052")
    d.rounded_rectangle((10, 12+bob, 23, 25+bob), 3, fill=INK)
    d.rectangle((11, 13+bob, 21, 23+bob), fill="#477e78")
    d.rectangle((12, 14+bob, 15, 21+bob), fill="#79a296")
    d.rectangle((15, 14+bob, 21, 16+bob), fill="#d6ab5f")
    d.rectangle((19, 16+bob, 21, 21+bob), fill="#d6ab5f")
    for xx, yy in [(7, 18+stride//2), (23, 18-stride//2)]:
        d.rectangle((xx, yy, xx+3, yy+5), fill=INK)
        d.rectangle((xx+1, yy+1, xx+2, yy+3), fill="#d8b687")
    d.rounded_rectangle((10, 3+bob, 23, 15+bob), 4, fill=INK)
    d.rectangle((12, 8+bob, 21, 13+bob), fill="#d8b687")
    d.rectangle((12, 8+bob, 14, 11+bob), fill="#f0d6a4")
    d.rectangle((19, 9+bob, 20, 10+bob), fill=INK)
    d.rounded_rectangle((10, 3+bob, 22, 8+bob), 2, fill="#c9ccad")
    d.line((9, 8+bob, 25, 8+bob), fill="#f0e1b4", width=2)
    d.line((12, 4+bob, 20, 4+bob), fill="#f4eccb")
    workers.alpha_composite(im, (frame * 32, 0))
workers.save(OUT / "colonist_walk.png")
print("Generated original terrain, colony and worker sheets in", OUT)
