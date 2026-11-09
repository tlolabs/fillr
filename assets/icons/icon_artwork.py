"""Render the visible Icon Composer artwork with its saved layer layout."""

import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw

from build_needle_assets import polygon_points, path_fill

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "fillr-clean.icon"
SIZE = 1024
DOCK_LAYERS = (
    "01-housing", "02-inner-face", "03-bezel-edges", "04-status-scale",
    "05-gauge-ticks", "06-gauge-labels", "07-fillr-label", "08-pump", "09-pivot",
)


def render_layer(layer, project=PROJECT):
    path = project / "Assets" / layer["image-name"]
    if path.suffix == ".svg":
        image = Image.new("RGBA", (SIZE * 3,) * 2)
        draw = ImageDraw.Draw(image)
        for element in ET.parse(path).getroot().findall("{*}path"):
            draw.polygon([(x * 3, y * 3) for x, y in polygon_points(element.get("d"))], fill=path_fill(element))
        image = image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    else:
        image = Image.open(path).convert("RGBA")
    if image.size != (SIZE, SIZE):
        raise ValueError(f"Unexpected layer size: {path} {image.size}")
    position = layer.get("position", {})
    scale = position.get("scale", 1)
    x, y = position.get("translation-in-points", [0, 0])
    if scale != 1 or x or y:
        image = image.transform((SIZE, SIZE), Image.Transform.AFFINE,
            (1 / scale, 0, SIZE / 2 - (SIZE / 2 + x) / scale,
             0, 1 / scale, SIZE / 2 - (SIZE / 2 + y) / scale), Image.Resampling.BICUBIC)
    return image


def visible_layers(project=PROJECT):
    document = json.loads((project / "icon.json").read_text())
    return [layer for layer in reversed(document["groups"][0]["layers"]) if not layer.get("hidden", False)]


def composite(project=PROJECT):
    image = Image.new("RGBA", (SIZE, SIZE))
    for layer in visible_layers(project):
        image.alpha_composite(render_layer(layer, project))
    return image


def package_dock(destination, project=PROJECT):
    destination.mkdir(parents=True, exist_ok=True)
    # Always replace every slot. A hidden/deleted layer must not leave an older
    # visible PNG behind when regenerating into an existing output directory.
    transparent = Image.new("RGBA", (SIZE, SIZE))
    for name in DOCK_LAYERS:
        transparent.save(destination / (name + ".png"))
    needle = Image.new("RGBA", (SIZE, SIZE))
    layers = visible_layers(project)
    pivot_layer = next(layer for layer in layers if layer["name"] == "09-pivot")
    position = pivot_layer.get("position", {})
    scale = position.get("scale", 1)
    translation = position.get("translation-in-points", [0, 0])
    for layer in layers:
        artwork = render_layer(layer, project)
        if layer["name"].startswith("needle-facet-"):
            facet_position = layer.get("position", {})
            if (facet_position.get("scale", 1) != scale or
                facet_position.get("translation-in-points", [0, 0]) != translation):
                raise ValueError("Needle facets and pivot must share the same layout transform")
            needle.alpha_composite(artwork)
        else:
            artwork.save(destination / (Path(layer["image-name"]).stem + ".png"))
    needle.save(destination / "10-needle.png")
    geometry = json.loads((ROOT / "needle-layout.json").read_text())
    for name in ("pivot", "probePoint"):
        geometry[name] = [SIZE / 2 + scale * (value - SIZE / 2) + translation[i]
                          for i, value in enumerate(geometry[name])]
    geometry["sourceScale"] *= scale
    (destination / "artwork.json").write_text(json.dumps(geometry, indent=2) + "\n")


if __name__ == "__main__":
    package_dock(Path(sys.argv[1]))
