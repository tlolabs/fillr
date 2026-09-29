"""Derive Windows and Linux icons from the editable Icon Composer layers.

The macOS export contains platform-specific masking and shadow. Compositing the
project's artwork layers directly preserves their transparent rounded housing
for Windows and Linux without adding those macOS effects a second time.
"""

import json
from pathlib import Path

from PIL import Image


root = Path(__file__).resolve().parent
project = root / "fillr.icon"
document = json.loads((project / "icon.json").read_text())
layers = document["groups"][0]["layers"]
image = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
for layer in reversed(layers):
    artwork = Image.open(project / "Assets" / layer["image-name"]).convert("RGBA")
    if artwork.size != image.size:
        raise ValueError(f"Unexpected layer size: {layer['image-name']} {artwork.size}")
    image.alpha_composite(artwork)

# Pillow derives every ICO frame from this original-size composite.
image.save(root / "FILLR.ico", format="ICO", sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)])

linux = root / "linux" / "hicolor"
linux_icon_name = "edu.chabot.news.backgrounder.png"
for size in (16, 24, 32, 48, 64, 128, 256, 512):
    destination = linux / f"{size}x{size}" / "apps"
    destination.mkdir(parents=True, exist_ok=True)
    resized = image.resize((size, size), Image.Resampling.LANCZOS)
    # Eliminate one-bit Lanczos fringes outside the transparent housing.
    resized.putalpha(resized.getchannel("A").point(lambda value: 0 if value <= 2 else value))
    resized.save(destination / linux_icon_name)

print(f"Created {root / 'FILLR.ico'} and Linux hicolor PNGs")
