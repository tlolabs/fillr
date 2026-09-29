"""Package Icon Composer's FILLR PNG export for the SwiftPM macOS bundle."""

from pathlib import Path
import subprocess
import tempfile

from PIL import Image


root = Path(__file__).resolve().parent
source = root / "FILLR-Default-1024.png"
image = Image.open(source).convert("RGBA")

with tempfile.TemporaryDirectory() as temporary:
    iconset = Path(temporary) / "FILLR.iconset"
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            suffix = "@2x" if scale == 2 else ""
            name = f"icon_{points}x{points}{suffix}.png"
            image.resize((pixels, pixels), Image.Resampling.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "FILLR.icns")], check=True)
print(root / "FILLR.icns")
