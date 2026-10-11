"""Derive Windows and Linux icons from the editable Icon Composer layers.

The macOS export contains platform-specific masking and shadow. Compositing the
project's artwork layers directly preserves their transparent rounded housing
for Windows and Linux without adding those macOS effects a second time.
"""

from pathlib import Path

from PIL import Image
from icon_artwork import composite, package_dock


root = Path(__file__).resolve().parent
image = composite()

# Pillow derives every ICO frame from this original-size composite.
image.save(root / "FILLR.ico", format="ICO", sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)])

linux = root / "linux" / "hicolor"
linux_icon_name = "com.tlolabs.fillr.png"
for size in (16, 24, 32, 48, 64, 128, 256, 512):
    destination = linux / f"{size}x{size}" / "apps"
    destination.mkdir(parents=True, exist_ok=True)
    resized = image.resize((size, size), Image.Resampling.LANCZOS)
    # Eliminate one-bit Lanczos fringes outside the transparent housing.
    resized.putalpha(resized.getchannel("A").point(lambda value: 0 if value <= 2 else value))
    resized.save(destination / linux_icon_name)

package_dock(root / "DockIcon")
print(f"Created {root / 'FILLR.ico'}, Linux hicolor PNGs, and animated Dock artwork")
