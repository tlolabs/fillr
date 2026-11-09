"""Build the separate 1024-point artwork layers for the FILLR Icon Composer file."""

from __future__ import annotations

import argparse
import json
from math import atan2, cos, degrees, radians, sin
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from build_needle_assets import EMPTY_ANGLE, FULL_ANGLE, PIVOT, generate


ROOT = Path(__file__).resolve().parent / "fillr.icon" / "Assets"
ROOT.mkdir(parents=True, exist_ok=True)
ASSET_DIRECTORIES = [ROOT]
for project_name in ("fillr-clean.icon", "fillr-macos.icon"):
    assets = ROOT.parent.parent / project_name / "Assets"
    if assets.is_dir():
        ASSET_DIRECTORIES.append(assets)
S = 3
SIZE = 1024
FONT = "/Library/Fonts/SF-Pro-Display-Semibold.otf"
HALF_ANGLE = 0.0
# Each minor tick bisects its labeled interval; the two intervals differ in span.
TICK_MARKS = (
    (FULL_ANGLE, 69, 17),
    ((FULL_ANGLE + HALF_ANGLE) / 2, 54, 13),
    (HALF_ANGLE, 75, 18),
    ((HALF_ANGLE + EMPTY_ANGLE) / 2, 54, 13),
    (EMPTY_ANGLE, 56, 17),
)


def pt(value):
    return round(value * S)


def box(coords):
    return tuple(pt(v) for v in coords)


def canvas():
    return Image.new("RGBA", (SIZE * S, SIZE * S), (0, 0, 0, 0))


def save(im, name):
    image = im.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    for assets in ASSET_DIRECTORIES:
        image.save(assets / name)


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


def polar(degrees, radius):
    a = radians(degrees)
    return (pt(PIVOT[0] + radius * cos(a)), pt(PIVOT[1] + radius * sin(a)))


def arc_polygon(start, end, inner=421, outer=451):
    n = max(8, int((end - start) * 2))
    angles = [start + (end - start) * i / n for i in range(n + 1)]
    return [polar(a, outer) for a in angles] + [polar(a, inner) for a in reversed(angles)]


def generate_ticks():
    im = canvas()
    d = ImageDraw.Draw(im)
    for angle, length, width in TICK_MARKS:
        d.line((polar(angle, 330), polar(angle, 330 + length)), fill=(245, 248, 249, 255), width=pt(width))
    save(im, "05-gauge-ticks.png")


def scale_color(progress, colors, transition_width):
    """Keep each reference band solid except for a short smooth boundary blend."""
    progress = min(1, max(0, progress))
    for boundary in range(1, len(colors)):
        start = boundary / len(colors) - transition_width / 2
        if start <= progress <= start + transition_width:
            amount = (progress - start) / transition_width
            amount = amount * amount * (3 - 2 * amount)
            return tuple(round(left * (1 - amount) + right * amount)
                         for left, right in zip(colors[boundary - 1], colors[boundary]))
    return colors[min(len(colors) - 1, int(progress * len(colors)))]


def generate_scales():
    """Render a continuous annular scale for each colored variant only."""
    configuration = json.loads((ROOT.parent.parent / "status-scale-palettes.json").read_text())
    transition_width = configuration["transitionWidth"]
    mask = Image.new("L", (SIZE * S, SIZE * S))
    ImageDraw.Draw(mask).polygon(arc_polygon(FULL_ANGLE, EMPTY_ANGLE), fill=255)
    bounds = mask.getbbox()
    for variant in configuration["scales"].values():
        assets = ROOT.parent.parent / variant["project"] / "Assets"
        if not assets.is_dir():
            raise FileNotFoundError(f"Create the Icon Composer variant first: {assets.parent}")
        colors = [tuple(bytes.fromhex(configuration["colors"][name].lstrip("#")))
                  for name in variant["bands"]]
        im = canvas()
        pixels, coverage = im.load(), mask.load()
        for y in range(bounds[1], bounds[3]):
            for x in range(bounds[0], bounds[2]):
                if not coverage[x, y]:
                    continue
                angle = degrees(atan2((y + 0.5) / S - PIVOT[1], (x + 0.5) / S - PIVOT[0]))
                # Match DockIconArtwork's two unequal labeled half-sweeps.
                if angle >= HALF_ANGLE:
                    progress = (EMPTY_ANGLE - angle) / (EMPTY_ANGLE - HALF_ANGLE) / 2
                else:
                    progress = 0.5 + (HALF_ANGLE - angle) / (HALF_ANGLE - FULL_ANGLE) / 2
                pixels[x, y] = scale_color(progress, colors, transition_width) + (255,)
        im.resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(assets / "04-status-scale.png")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--ticks-only", action="store_true",
                        help="Regenerate only the shared white gauge tick layer")
    mode.add_argument("--scales-only", action="store_true",
                      help="Regenerate only the colored Classic and Mac OS scales")
    arguments = parser.parse_args()
    if arguments.ticks_only:
        generate_ticks()
        print(f"Updated white tick marks in {ASSET_DIRECTORIES}")
        raise SystemExit(0)
    if arguments.scales_only:
        generate_scales()
        print("Updated Classic and Mac OS color scales")
        raise SystemExit(0)


round_gradient("01-housing.png", (54, 54, 970, 970), 224,
               (112, 122, 134), (48, 56, 66), (160, 169, 180, 255))
round_gradient("02-inner-face.png", (101, 101, 923, 923), 177,
               (43, 52, 60), (24, 31, 38), (5, 9, 12, 255))

# A pair of very fine edges gives the bezel depth without a glossy coating.
im = canvas()
d = ImageDraw.Draw(im)
d.rounded_rectangle(box((66, 66, 958, 958)), radius=pt(212), outline=(196, 204, 212, 75), width=pt(3))
d.rounded_rectangle(box((93, 93, 931, 931)), radius=pt(185), outline=(4, 8, 11, 230), width=pt(8))
d.rounded_rectangle(box((103, 103, 921, 921)), radius=pt(175), outline=(96, 109, 119, 75), width=pt(2))
save(im, "03-bezel-edges.png")

generate_scales()

generate_ticks()

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
d.text((pt(205), pt(176)), "FILLR", font=f, fill=(248, 249, 250, 255), anchor="lt")
save(im, "07-fillr-label.png")
for assets in ASSET_DIRECTORIES:
    (assets / "07-fuel-label.png").unlink(missing_ok=True)

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

generate()

print(f"Created 10 separate 1024 × 1024 layers in {ASSET_DIRECTORIES}")
