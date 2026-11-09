"""Check editable icon variants and the generated artwork shipped in builds."""

import json
from io import BytesIO
from math import atan2, cos, degrees, hypot, radians, sin
from pathlib import Path
import tempfile
import unittest

from PIL import Image, ImageCms

from icon_artwork import DOCK_LAYERS, ROOT, composite, package_dock, visible_layers

VARIANTS = (
    ("DockIcon", "fillr-clean.icon", "Default", "FILLR.icns"),
    ("DockIconClassic", "fillr.icon", "Classic", "FILLR-Classic.icns"),
    ("DockIconMacOS", "fillr-macos.icon", "MacOS", "FILLR-MacOS.icns"),
)
# These are the printed reference hex values, independent of the generator.
PALETTE = {
    "green": (0x61, 0xBB, 0x46), "yellow": (0xFD, 0xB8, 0x27),
    "orange": (0xF5, 0x82, 0x1F), "red": (0xE0, 0x3A, 0x3E),
    "purple": (0x96, 0x3D, 0x97), "blue": (0x00, 0x9D, 0xDC),
}
ARC_COLORS = {
    "Classic": ("red", "orange", "yellow", "green"),
    "MacOS": ("blue", "purple", "red", "orange", "yellow", "green"),
}


def arc_pixel(image, progress, pivot=(336, 526), scale=1, radius=436):
    """Sample the arc's centerline from the fixed 0 / 1/2 / 4/4 rays."""
    angle = radians(42 - 84 * progress if progress <= 0.5 else -94 * (progress - 0.5))
    x = round(pivot[0] + scale * radius * cos(angle) - 0.5)
    y = round(pivot[1] + scale * radius * sin(angle) - 0.5)
    return image.getpixel((x, y))


class IconArtworkTests(unittest.TestCase):
    def test_raster_ticks_bisect_each_labeled_half(self):
        source_geometry = json.loads((ROOT / "needle-layout.json").read_text())
        paths_and_pivots = [
            (ROOT / project / "Assets" / "05-gauge-ticks.png", source_geometry["pivot"])
            for _, project, _, _ in VARIANTS
        ]
        for directory, _, _, _ in VARIANTS:
            geometry = json.loads((ROOT / directory / "artwork.json").read_text())
            paths_and_pivots.append((ROOT / directory / "05-gauge-ticks.png", geometry["pivot"]))
        for path, pivot in paths_and_pivots:
            with self.subTest(path=str(path)):
                # Measure the five actual raster shapes, independently of the
                # generator's angle list. The centroid of each radial tick lies
                # on its ray from the needle axle, including after packaging.
                with Image.open(path) as image:
                    alpha = image.getchannel("A")
                    pixels = {(x, y) for y in range(image.height) for x in range(image.width)
                              if alpha.getpixel((x, y)) > 128}
                angles = []
                while pixels:
                    point = pixels.pop()
                    component = [point]
                    pending = [point]
                    while pending:
                        x, y = pending.pop()
                        for dx, dy in ((-1, -1), (0, -1), (1, -1), (-1, 0),
                                       (1, 0), (-1, 1), (0, 1), (1, 1)):
                            neighbor = (x + dx, y + dy)
                            if neighbor in pixels:
                                pixels.remove(neighbor)
                                component.append(neighbor)
                                pending.append(neighbor)
                    center_x = sum(x + 0.5 for x, _ in component) / len(component)
                    center_y = sum(y + 0.5 for _, y in component) / len(component)
                    angles.append(degrees(atan2(center_y - pivot[1], center_x - pivot[0])))
                angles.sort()
                self.assertEqual(len(angles), 5, "Expected five separate white gauge ticks")
                # Keep the three labeled rays fixed. The upper and lower halves
                # deliberately span different angles; each gets its own midpoint.
                for index, expected in ((0, -47), (2, 0), (4, 42)):
                    self.assertAlmostEqual(angles[index], expected, delta=0.15)
                self.assertAlmostEqual(angles[1], (angles[0] + angles[2]) / 2, delta=0.15,
                                       msg="Upper tick does not bisect 4/4 and 1/2")
                self.assertAlmostEqual(angles[3], (angles[2] + angles[4]) / 2, delta=0.15,
                                       msg="Lower tick does not bisect 1/2 and 0")

    def test_composer_exports_have_corrected_intermediate_ticks(self):
        raw_geometry = json.loads((ROOT / "needle-layout.json").read_text())
        geometry = json.loads((ROOT / "DockIcon" / "artwork.json").read_text())
        pivot_x, pivot_y = geometry["pivot"]
        scale = geometry["sourceScale"] / raw_geometry["sourceScale"]
        for _, _, appearance, _ in VARIANTS:
            with self.subTest(appearance=appearance):
                with Image.open(ROOT / f"FILLR-{appearance}-1024.png") as exported:
                    image = exported.convert("RGB")
                ticks = [[], []]
                for y in range(image.height):
                    for x in range(image.width):
                        color = image.getpixel((x, y))
                        if min(color) < 220 or max(color) - min(color) > 20:
                            continue
                        dx, dy = x + 0.5 - pivot_x, y + 0.5 - pivot_y
                        # Restrict the measurement to the tick's inner radial
                        # band, excluding labels, colored bars, and the needle.
                        if not 335 * scale <= hypot(dx, dy) <= 380 * scale:
                            continue
                        angle = degrees(atan2(dy, dx))
                        for index, (start, end) in enumerate(((-35, -10), (10, 30))):
                            if start < angle < end:
                                ticks[index].append((dx, dy))
                for pixels, expected in zip(ticks, (-23.5, 21)):
                    self.assertTrue(pixels, "Exported intermediate tick is missing")
                    measured = degrees(atan2(sum(y for _, y in pixels), sum(x for x, _ in pixels)))
                    self.assertAlmostEqual(measured, expected, delta=0.15,
                                           msg="Composer export has stale tick spacing")

    def test_variants_only_change_color_bars(self):
        clean = {layer["name"]: layer for layer in visible_layers()}
        self.assertNotIn("04-status-scale", clean)
        for _, project, appearance, _ in VARIANTS[1:]:
            with self.subTest(appearance=appearance):
                colored = {layer["name"]: layer for layer in visible_layers(ROOT / project)}
                self.assertIn("04-status-scale", colored)
                colored.pop("04-status-scale")
                self.assertEqual(clean, colored, "Other artwork or layout changed between variants")
                self.assertNotEqual(composite().tobytes(), composite(ROOT / project).tobytes())

    def test_arc_palette_order_and_smooth_continuous_blends(self):
        source_scale = json.loads((ROOT / "needle-layout.json").read_text())["sourceScale"]
        for directory, project, appearance, _ in VARIANTS[1:]:
            geometry = json.loads((ROOT / directory / "artwork.json").read_text())
            colors = [PALETTE[name] for name in ARC_COLORS[appearance]]
            inputs = ((ROOT / project / "Assets" / "04-status-scale.png", (336, 526), 1),
                      (ROOT / directory / "04-status-scale.png", geometry["pivot"],
                       geometry["sourceScale"] / source_scale))
            for path, pivot, scale in inputs:
                with self.subTest(path=str(path)), Image.open(path) as artwork:
                    image = artwork.convert("RGBA")
                    for index, expected in enumerate(colors):
                        progress = (index + 0.5) / len(colors)
                        self.assertEqual(arc_pixel(image, progress, pivot, scale), (*expected, 255),
                                         "Incorrect reference color or direction")
                        # Allow antialiasing at the inside/outside edges while
                        # requiring the original 421–451 px ring geometry.
                        for radius in (423, 449):
                            actual = arc_pixel(image, progress, pivot, scale, radius)
                            self.assertGreaterEqual(actual[3], 245)
                        for radius in (418, 454):
                            self.assertLessEqual(arc_pixel(image, progress, pivot, scale, radius)[3], 2,
                                                 "Color scale exceeds its original radial band")
                    for step in range(5, 996):
                        self.assertGreaterEqual(arc_pixel(image, step / 1000, pivot, scale)[3], 250,
                                                "A gap interrupts the continuous color scale")
                    for index in range(1, len(colors)):
                        boundary = index / len(colors)
                        before, after = colors[index - 1], colors[index]
                        # Plateaus resume just beyond each narrow blend. The
                        # midpoint must mix both colors, without an abrupt step.
                        for progress, expected in ((boundary - 0.035, before), (boundary + 0.035, after)):
                            self.assertEqual(arc_pixel(image, progress, pivot, scale), (*expected, 255))
                        middle = arc_pixel(image, boundary, pivot, scale)
                        for actual, left, right in zip(middle[:3], before, after):
                            self.assertAlmostEqual(actual, (left + right) / 2, delta=16)
                        for offset, weight in ((-0.015, 0.15625), (0.015, 0.84375)):
                            sample = arc_pixel(image, boundary + offset, pivot, scale)
                            for actual, left, right in zip(sample[:3], before, after):
                                self.assertAlmostEqual(actual, left + weight * (right - left), delta=16)
                        samples = [arc_pixel(image, boundary + step / 1000, pivot, scale)
                                   for step in range(-40, 41)]
                        for left, right in zip(samples, samples[1:]):
                            self.assertLessEqual(max(abs(a - b) for a, b in zip(left[:3], right[:3])), 24,
                                                 "The color scale has an abrupt transition")

    def test_composer_exports_retain_arc_color_order(self):
        raw_scale = json.loads((ROOT / "needle-layout.json").read_text())["sourceScale"]
        geometry = json.loads((ROOT / "DockIcon" / "artwork.json").read_text())
        for _, _, appearance, _ in VARIANTS:
            with self.subTest(appearance=appearance), Image.open(ROOT / f"FILLR-{appearance}-1024.png") as artwork:
                profile = artwork.info.get("icc_profile")
                self.assertIsNotNone(profile, "Composer export lost its embedded color profile")
                # Composer exports Display P3. Compare the printed reference
                # values in their intended sRGB space, preserving the profile.
                image = ImageCms.profileToProfile(
                    artwork.convert("RGBA"), ImageCms.ImageCmsProfile(BytesIO(profile)),
                    ImageCms.createProfile("sRGB"), outputMode="RGBA")
                colors = ARC_COLORS.get(appearance, ARC_COLORS["MacOS"])
                for index, name in enumerate(colors):
                    pixel = arc_pixel(image, (index + 0.5) / len(colors), geometry["pivot"],
                                      geometry["sourceScale"] / raw_scale)
                    self.assertEqual(pixel[3], 255)
                    if appearance == "Default":
                        self.assertLess(max(pixel[:3]), 100, "Clean export contains a color scale")
                        continue
                    self.assertLessEqual(max(abs(a - b) for a, b in zip(pixel[:3], PALETTE[name])), 3,
                                         "Composer export has incorrect reference color or direction")

    def test_generated_dock_variants(self):
        for directory, project, _, _ in VARIANTS:
            with self.subTest(directory=directory), tempfile.TemporaryDirectory() as temporary:
                destination = Path(temporary)
                package_dock(destination, ROOT / project)
                for name in (*DOCK_LAYERS, "10-needle"):
                    with Image.open(destination / (name + ".png")) as expected:
                        with Image.open(ROOT / directory / (name + ".png")) as packaged:
                            self.assertEqual(packaged.size, (1024, 1024))
                            self.assertEqual(expected.tobytes(), packaged.tobytes(), name)
                self.assertEqual(json.loads((destination / "artwork.json").read_text()),
                                 json.loads((ROOT / directory / "artwork.json").read_text()))
        with Image.open(ROOT / "DockIcon" / "04-status-scale.png") as clean:
            self.assertIsNone(clean.getbbox(), "Default icon contains color bars")
        for directory, _, _, _ in VARIANTS[1:]:
            with Image.open(ROOT / directory / "04-status-scale.png") as colored:
                self.assertIsNotNone(colored.getbbox(), "Alternate icon lost its color scale")
            for name in (*DOCK_LAYERS, "10-needle", "artwork"):
                if name == "04-status-scale":
                    continue
                suffix = ".json" if name == "artwork" else ".png"
                self.assertEqual((ROOT / "DockIcon" / (name + suffix)).read_bytes(),
                                 (ROOT / directory / (name + suffix)).read_bytes(), name)

    def test_hidden_layer_clears_existing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            package_dock(destination, ROOT / "fillr.icon")
            self.assertIsNotNone(Image.open(destination / "04-status-scale.png").getbbox())
            package_dock(destination)
            self.assertIsNone(Image.open(destination / "04-status-scale.png").getbbox())

    def test_platform_icons_use_default_artwork(self):
        image = composite()
        for size in (16, 24, 32, 48, 64, 128, 256, 512):
            expected = image.resize((size, size), Image.Resampling.LANCZOS)
            expected.putalpha(expected.getchannel("A").point(lambda value: 0 if value <= 2 else value))
            path = ROOT / "linux" / "hicolor" / f"{size}x{size}" / "apps" / "com.tlolabs.fillr.png"
            with Image.open(path) as packaged:
                self.assertEqual(expected.tobytes(), packaged.tobytes(), str(path))
        with Image.open(ROOT / "FILLR.ico") as windows:
            self.assertEqual(windows.ico.sizes(), {(size, size) for size in (16, 24, 32, 48, 64, 128, 256)})
            self.assertEqual(image.resize((256, 256), Image.Resampling.LANCZOS).tobytes(),
                             windows.ico.getimage((256, 256)).tobytes())
        for _, _, _, name in VARIANTS:
            data = (ROOT / name).read_bytes()
            self.assertEqual(data[:4], b"icns")
            self.assertEqual(int.from_bytes(data[4:8], "big"), len(data))
        for _, _, appearance, name in VARIANTS:
            with Image.open(ROOT / f"FILLR-{appearance}-1024.png") as exported:
                with Image.open(ROOT / name) as packaged:
                    self.assertEqual(exported.convert("RGBA").tobytes(), packaged.convert("RGBA").tobytes())


if __name__ == "__main__":
    unittest.main()
