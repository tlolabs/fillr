import datetime
import hashlib
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

import background_crawl


ROOT = Path(__file__).resolve().parents[1]
PSD = ROOT / "CNN Downloads/Chabot News Backgrounds/Text Crawl.psd"
MAGICK = shutil.which("magick")


class CrawlLayoutTests(unittest.TestCase):
    def test_distribution_uses_gaps_rather_than_equal_centers(self):
        layers = [{"name": "date", "width": 310}, {"name": "bullet", "width": 11},
                  {"name": "label", "width": 242}, {"name": "bullet", "width": 11}]
        result, gap = background_crawl.distribute_layers(layers, 2, 606)
        self.assertEqual(result[0]["left"], 2)
        self.assertEqual(result[-1]["left"] + result[-1]["width"], 606)
        actual = [b["left"] - a["left"] - a["width"] for a, b in zip(result, result[1:])]
        self.assertLessEqual(max(actual) - min(actual), 1)
        self.assertTrue(all(abs(value - gap) <= 1 for value in actual))
        self.assertTrue(all(value >= 0 for value in actual))

    def test_too_wide_date_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "overlapping"):
            background_crawl.distribute_layers([{"width": 10}, {"width": 1}], 0, 10)

    def test_date_formats_are_validated_independently_of_locale(self):
        for value in ("2026-11-12", "November 12, 2026", datetime.date(2026, 11, 12)):
            self.assertEqual(background_crawl._display_date(value), "November 12, 2026")
        for value in ("2026-02-29", "November 31, 2026", "@https://example.com"):
            with self.assertRaises(ValueError):
                background_crawl._display_date(value)

    def test_truncated_template_fails_explicitly(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "bad.psd"
            source.write_bytes(b"8BPS\x00\x01")
            with self.assertRaisesRegex(ValueError, "Truncated"):
                background_crawl.inspect_crawl(source)


@unittest.skipUnless(MAGICK and PSD.is_file(), "Local PSD template and ImageMagick are required")
class CrawlRasterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.source_hash = hashlib.sha256(PSD.read_bytes()).digest()

    def tearDown(self):
        self.assertEqual(hashlib.sha256(PSD.read_bytes()).digest(), self.source_hash)

    def assert_flat_rgb(self, output):
        data = output.read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        width, height, depth, color_type = struct.unpack_from(">IIBB", data, 16)
        self.assertEqual((width, height, depth, color_type), (2376, 32, 8, 2))

    def test_original_date_retains_every_flattened_pixel(self):
        output = self.folder / "original.png"
        metadata = background_crawl.generate_crawl(PSD, "2026-11-12", output, magick=MAGICK)
        self.assertFalse(metadata["date_changed"])
        self.assertFalse(metadata["antialiasing_approximation"])
        self.assertTrue(metadata["flatten"])
        self.assert_flat_rgb(output)
        expected = subprocess.check_output([MAGICK, f"{PSD}[0]", "-depth", "8", "rgb:-"])
        actual = subprocess.check_output([MAGICK, str(output), "-depth", "8", "rgb:-"])
        self.assertEqual(actual, expected)

    def test_changed_date_redistributes_all_type_layers_and_preserves_bounds(self):
        try:
            font = background_crawl._font_path(None)
        except FileNotFoundError as exc:
            self.skipTest(str(exc))
        output = self.folder / "changed.png"
        metadata = background_crawl.generate_crawl(
            PSD, "2026-12-25", output, magick=MAGICK, font_path=font,
        )
        self.assertTrue(metadata["date_changed"])
        self.assertTrue(metadata["antialiasing_approximation"])
        self.assert_flat_rgb(output)
        layers = metadata["layers"]
        self.assertEqual(len(layers), 20)
        self.assertEqual(layers[0]["name"], "Show Date")
        self.assertNotEqual(layers[0]["width"], 312)
        self.assertEqual(layers[0]["left"], 2)
        self.assertEqual(layers[-1]["left"] + layers[-1]["width"], 2365)
        gaps = [b["left"] - a["left"] - a["width"] for a, b in zip(layers, layers[1:])]
        self.assertLessEqual(max(gaps) - min(gaps), 1)
        self.assertGreater(min(gaps), 0)

    def test_existing_output_is_never_replaced(self):
        output = self.folder / "existing.png"
        output.write_bytes(b"keep this")
        with self.assertRaises(FileExistsError):
            background_crawl.generate_crawl(PSD, "2026-11-12", output, magick=MAGICK)
        self.assertEqual(output.read_bytes(), b"keep this")


if __name__ == "__main__":
    unittest.main()
