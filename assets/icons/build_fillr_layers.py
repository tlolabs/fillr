"""Build the separate 1024-point artwork layers for the FILLR Icon Composer file."""

from __future__ import annotations

from math import cos, radians, sin
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parent / "fillr.icon" / "Assets"
ROOT.mkdir(parents=True, exist_ok=True)
S = 3
SIZE = 1024
FONT = "/Library/Fonts/SF-Pro-Display-Semibold.otf"


def pt(value):
    return round(value * S)


def box(coords):
    return tuple(pt(v) for v in coords)


def canvas():
    return Image.new("RGBA", (SIZE * S, SIZE * S), (0, 0, 0, 0))


def save(im, name):
    im.resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(ROOT / name)


def round_gradient(name, rect, radius, top, bottom, border=None):
    im = canvas()
    pixels = Image.new("RGBA", im.size)
    d = ImageDraw.Draw(pixels)
    top = tuple(top)
    bottom = tuple(bottom)
    for y in range(pt(rect[1]), pt(rect[3])):
        t = (y / S - rect[1]) / (rect[3] - rect[1])
        color = tuple(round(a * (1 - t) + b * t) for a, b in zip(top, bottom)) + (255,)
        d.line((pt(rect[0]), y, pt(rect[2]), y), fill=color, width=1)
    mask = Image.new("L", im.size)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle(box(rect), radius=pt(radius), fill=255)
    im.paste(pixels, (0, 0), mask)
    if border:
        ImageDraw.Draw(im).rounded_rectangle(box(rect), radius=pt(radius), outline=border, width=pt(2))
    save(im, name)


round_gradient("01-housing.png", (54, 54, 970, 970), 171,
               (112, 122, 134), (48, 56, 66), (160, 169, 180, 255))
round_gradient("02-inner-face.png", (101, 101, 923, 923), 137,
               (30, 38, 44), (9, 14, 18), (5, 9, 12, 255))

# A pair of very fine edges gives the bezel depth without a glossy coating.
im = canvas()
d = ImageDraw.Draw(im)
d.rounded_rectangle(box((66, 66, 958, 958)), radius=pt(162), outline=(196, 204, 212, 75), width=pt(3))
d.rounded_rectangle(box((93, 93, 931, 931)), radius=pt(146), outline=(4, 8, 11, 230), width=pt(8))
d.rounded_rectangle(box((103, 103, 921, 921)), radius=pt(136), outline=(96, 109, 119, 75), width=pt(2))
save(im, "03-bezel-edges.png")

def polar(degrees, radius):
    a = radians(degrees)
    return (pt(336 + radius * cos(a)), pt(526 + radius * sin(a)))


def arc_polygon(start, end, inner=421, outer=451):
    n = max(8, int((end - start) * 2))
    angles = [start + (end - start) * i / n for i in range(n + 1)]
    return [polar(a, outer) for a in angles] + [polar(a, inner) for a in reversed(angles)]


im = canvas()
d = ImageDraw.Draw(im)
for start, end, color in [
    (-39, -25, (11, 180, 76, 255)),
    (-23.3, -9.3, (87, 217, 54, 255)),
    (-7.5, 4.6, (244, 218, 39, 255)),
    (6.4, 17, (247, 143, 22, 255)),
    (19, 41, (236, 45, 46, 255)),
]:
    d.polygon(arc_polygon(start, end), fill=color)
save(im, "04-status-scale.png")

im = canvas()
d = ImageDraw.Draw(im)
for angle, length, width in [(-47, 69, 17), (-19, 54, 13), (0, 75, 18), (20, 54, 13), (42, 56, 17)]:
    d.line((polar(angle, 330), polar(angle, 330 + length)), fill=(245, 248, 249, 255), width=pt(width))
save(im, "05-gauge-ticks.png")

im = canvas()
d = ImageDraw.Draw(im)
for label, x, y, size in [
    ("4/4", 641, 151, 82),
    ("1/2", 795, 454, 77),
    ("0", 735, 762, 88),
]:
    f = ImageFont.truetype(FONT, pt(size))
    d.text((pt(x), pt(y)), label, font=f, fill=(246, 248, 250, 255), anchor="lt", stroke_width=0)
save(im, "06-gauge-labels.png")

im = canvas()
d = ImageDraw.Draw(im)
f = ImageFont.truetype(FONT, pt(103))
d.text((pt(205), pt(176)), "FUEL", font=f, fill=(248, 249, 250, 255), anchor="lt")
save(im, "07-fuel-label.png")

# A simplified pump keeps its silhouette clear at 32–64 pt.
im = canvas()
d = ImageDraw.Draw(im)
white = (247, 249, 250, 255)
d.rounded_rectangle(box((250, 314, 326, 429)), radius=pt(11), fill=white)
d.rounded_rectangle(box((263, 326, 313, 363)), radius=pt(3), fill=(21, 28, 33, 255))
d.rounded_rectangle(box((241, 425, 336, 442)), radius=pt(7), fill=white)
d.line([polar for polar in [(pt(327), pt(337)), (pt(343), pt(347)), (pt(350), pt(363)),
                             (pt(348), pt(385)), (pt(355), pt(407)), (pt(371), pt(408)),
                             (pt(377), pt(396)), (pt(373), pt(372)), (pt(370), pt(353))]],
       fill=white, width=pt(13), joint="curve")
save(im, "08-pump.png")

im = canvas()
d = ImageDraw.Draw(im)
d.ellipse(box((273, 462, 404, 593)), fill=(6, 10, 13, 255), outline=(85, 99, 111, 255), width=pt(4))
d.ellipse(box((284, 473, 393, 582)), fill=(17, 24, 29, 255), outline=(35, 45, 53, 255), width=pt(2))
save(im, "09-pivot.png")

im = canvas()
d = ImageDraw.Draw(im)
# The main needle overlaps the pivot; three planar facets add only a little depth.
d.polygon([box((299, 477))[:2], box((331, 456))[:2], box((650, 772))[:2], box((630, 790))[:2]],
          fill=(232, 237, 241, 255))
d.polygon([box((299, 477))[:2], box((331, 456))[:2], box((624, 769))[:2]],
          fill=(253, 253, 253, 255))
d.polygon([box((331, 456))[:2], box((650, 772))[:2], box((630, 790))[:2], box((624, 769))[:2]],
          fill=(183, 193, 201, 255))
save(im, "10-needle.png")

print(f"Created 10 separate 1024 × 1024 layers in {ROOT}")
