"""Place the official Affinity needle and axle in the gauge's coordinate system."""

import json
from math import cos, radians, sin
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
SIZE = 1024
SUPERSAMPLE = 3
PIVOT = (336.0, 526.0)
SCALE = 3.25
EMPTY_ANGLE = 42.0
FULL_ANGLE = -47.0
SWEEP = FULL_ANGLE - EMPTY_ANGLE
ICON_FILLS = {"needle-bottom": "#ffffff", "needle-left": "#dce1e5", "needle-right": "#afb7bf"}
PIVOT_OUTLINE = "#87919b"
PIVOT_OUTLINE_WIDTH = 4.0


def polygon_points(path):
    if re.search(r"[A-KN-Yac-z]", path):
        raise ValueError("Needle source must contain only absolute M/L/Z segments")
    values = [float(value) for value in re.findall(r"[-+]?(?:\d*\.\d+|\d+)", path)]
    return list(zip(values[::2], values[1::2]))


def path_fill(element):
    style = dict(item.split(":", 1) for item in element.get("style", "").split(";") if ":" in item)
    return element.get("fill", style.get("fill", "black"))


def generate():
    source = ET.parse(ROOT / "needle-affinity-finished.svg").getroot()
    circle = source.find("{*}circle")
    axle = (float(circle.get("cx")), float(circle.get("cy")))
    angle = radians(EMPTY_ANGLE + 90)

    def placed(point):
        x, y = ((point[i] - axle[i]) * SCALE for i in range(2))
        return (PIVOT[0] + x * cos(angle) - y * sin(angle),
                PIVOT[1] + x * sin(angle) + y * cos(angle))

    assets = ROOT / "fillr.icon" / "Assets"
    needle = Image.new("RGBA", (SIZE * SUPERSAMPLE,) * 2)
    draw = ImageDraw.Draw(needle)
    names = {"needle-bottom": "needle-facet-base", "needle-left": "needle-facet-light",
             "needle-right": "needle-facet-shadow"}
    for element in source.findall("{*}path"):
        name = names[element.get("id")]
        points = [placed(point) for point in polygon_points(element.get("d"))]
        fill = ICON_FILLS[element.get("id")]
        path = "M " + " L ".join(f"{x:.6f} {y:.6f}" for x, y in points) + " Z"
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
               f'<path d="{path}" fill="{fill}"/>\n</svg>\n')
        (ROOT / (name + ".svg")).write_text(svg)
        (assets / (name + ".svg")).write_text(svg)
        draw.polygon([(x * SUPERSAMPLE, y * SUPERSAMPLE) for x, y in points], fill=fill)
    needle.resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(assets / "10-needle.png")
    pivot = Image.new("RGBA", needle.size)
    radius = float(circle.get("r")) * SCALE
    draw = ImageDraw.Draw(pivot)
    outer_radius = radius + PIVOT_OUTLINE_WIDTH
    draw.ellipse(tuple(value * SUPERSAMPLE for value in
        (PIVOT[0] - outer_radius, PIVOT[1] - outer_radius, PIVOT[0] + outer_radius, PIVOT[1] + outer_radius)), fill=PIVOT_OUTLINE)
    # The outline sits outside the original black disk, preserving its size
    # and exact relationship to the needle from the Affinity drawing.
    draw.ellipse(tuple(value * SUPERSAMPLE for value in
        (PIVOT[0] - radius, PIVOT[1] - radius, PIVOT[0] + radius, PIVOT[1] + radius)), fill="#000000")
    pivot.resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(assets / "09-pivot.png")
    layout = {"pivot": list(PIVOT), "sweepDegrees": SWEEP, "halfSweepDegrees": -EMPTY_ANGLE,
              "probePoint": list(placed((axle[0], 30.0))), "sourceScale": SCALE,
              "emptyAngle": EMPTY_ANGLE, "halfAngle": 0.0, "fullAngle": FULL_ANGLE}
    (ROOT / "needle-layout.json").write_text(json.dumps(layout, indent=2) + "\n")
    print("Generated official needle facets, pivot, and shared animation geometry")


if __name__ == "__main__":
    generate()
