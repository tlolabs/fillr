"""Checks independent of the owner's media tree or Adobe installation."""
import json
import contextlib
import io
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import background_video
from background_video import (RATE, concat_file, decode_check, encode_master,
                              frame_count, normalize_clip, panel_geometry,
                              sequence_segments, validate_output)


class TimelineTests(unittest.TestCase):
    def test_reference_has_exact_frame_count(self):
        self.assertEqual(frame_count(600), 17982)
        self.assertEqual(frame_count(10.01), 300)
        for value in [0, -1, 601, float("nan")]:
            with self.assertRaises(ValueError):
                frame_count(value)

    def test_truncate_last_cut_without_changing_order(self):
        sequence = {"unsupported": [], "gaps": [], "overlaps": [], "segments": [
            {"path": "z.mpg", "source_in_seconds": 2, "duration_frames": 300, "frame_rate_mismatch": False},
            {"path": "a.mpg", "source_in_seconds": 0, "duration_frames": 300, "frame_rate_mismatch": False}]}
        actual = sequence_segments(sequence, 382)
        self.assertEqual([item["path"] for item in actual], ["z.mpg", "a.mpg"])
        self.assertEqual([item["frames"] for item in actual], [300, 82])
        self.assertEqual(actual[0]["source_in_seconds"], 2)
        with self.assertRaises(ValueError):
            sequence_segments(sequence, 601)
        sequence["gaps"] = [{"start_seconds": 0, "duration_seconds": 1}]
        with self.assertRaises(ValueError):
            sequence_segments(sequence, 1)

    def test_panel_borders_are_in_final_output_space(self):
        large, small = panel_geometry(1), panel_geometry(7)
        self.assertEqual((large["x"], large["y"], large["visible_width"], large["visible_height"]), (9, 10, 940, 520))
        self.assertEqual((small["x"], small["y"], small["visible_width"], small["visible_height"]), (969, 550, 220, 115))

    def test_concat_escaping_and_newline_rejection(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "list.ffconcat"
            concat_file(path, [Path(temp) / "it's a clip.mkv"])
            self.assertIn("it'\\''s a clip.mkv", path.read_text())
            with self.assertRaises(ValueError):
                concat_file(path, ["a\nb.mkv"])


class PlanningMetadataTests(unittest.TestCase):
    def plan_intro(self, stream, container):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            intro = folder / "intro-placeholder"
            intro.touch()
            output = folder / "plan"
            sequence = {"unsupported": [], "gaps": [], "overlaps": [],
                        "frame_rate": {"numerator": 30000, "denominator": 1001},
                        "segments": [{"path": "source-placeholder", "source_in_seconds": 0,
                                      "duration_frames": 30, "frame_rate_mismatch": False}]}
            project = {f"Comp {number}": sequence for number in background_video.LAYOUT if number != 1}
            with mock.patch.object(background_video.shutil, "which", return_value="/mock/tool"), \
                 mock.patch.object(background_video.subprocess, "check_output", return_value="mock tool version\n"), \
                 mock.patch.object(background_video.subprocess, "run", side_effect=AssertionError("Unexpected tool launch")), \
                 mock.patch.object(background_video, "probe", return_value={"streams": [stream], "format": container}), \
                 mock.patch.object(background_video, "load_project", return_value=project), \
                 mock.patch.object(background_video, "sha256", return_value="fixture-hash"), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                result = background_video.main([
                    "--date", "2026-11-16", "--intro", str(intro), "--duration", "1",
                    "--pipeline", "direct", "--plan-only", "--output-dir", str(output),
                ])
            self.assertEqual(result, 0, (output / "report.json").read_text())
            return json.loads((output / "job.json").read_text())["panels"][0]["segments"]

    def test_stream_duration_does_not_require_container_duration(self):
        segments = self.plan_intro({"codec_type": "video", "duration": "1.0"}, {})
        self.assertEqual([segment["frames"] for segment in segments], [30])

    def test_missing_stream_duration_uses_container_duration(self):
        segments = self.plan_intro({"codec_type": "video"}, {"duration": "0.5"})
        self.assertEqual([segment["frames"] for segment in segments], [15, 15])


class OutputVerificationTests(unittest.TestCase):
    def metadata(self, codec="hevc"):
        return {"streams": [{
            "codec_type": "video", "codec_name": codec,
            "profile": "Main" if codec == "hevc" else "High",
            "level": 120 if codec == "hevc" else 42,
            "width": 1920, "height": 1080, "pix_fmt": "yuv420p",
            "r_frame_rate": RATE, "color_space": "bt709", "color_transfer": "bt709",
            "color_primaries": "bt709", "color_range": "tv", "field_order": "progressive",
            "sample_aspect_ratio": "1:1", "nb_frames": "3", "nb_read_packets": "3",
            "duration": "0.100100",
        }]}

    def validate(self, metadata, **kwargs):
        with mock.patch.object(background_video, "probe", return_value=metadata) as probe:
            result = validate_output(Path("encoded.mp4"), 3, "ffprobe", **kwargs)
        probe.assert_called_once_with(Path("encoded.mp4"), "ffprobe", count=True)
        self.assertIs(result, metadata)

    def test_h264_default_still_requires_high_level_42(self):
        self.validate(self.metadata("h264"))
        for key, value in [("profile", "Main"), ("level", 41)]:
            metadata = self.metadata("h264")
            metadata["streams"][0][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, key):
                self.validate(metadata)

    def test_hevc_main_accepts_encoder_selected_level(self):
        for level in [120, 123, 150]:
            metadata = self.metadata()
            metadata["streams"][0]["level"] = level
            with self.subTest(level=level):
                self.validate(metadata, codec="hevc")

    def test_hevc_rejects_codec_profile_format_and_timeline_changes(self):
        changes = [
            ("codec_name", "h264"), ("profile", "Main 10"), ("pix_fmt", "yuv420p10le"),
            ("width", 1280), ("height", 720), ("r_frame_rate", "30/1"),
            ("color_space", "bt2020nc"), ("color_transfer", "smpte2084"),
            ("color_primaries", "bt2020"), ("color_range", "pc"),
            ("field_order", "tt"), ("sample_aspect_ratio", "4:3"),
            ("nb_frames", "2"), ("nb_read_packets", "2"),
            ("duration", "0.2"), ("duration", "nan"), ("duration", "inf"),
        ]
        for key, value in changes:
            metadata = self.metadata()
            metadata["streams"][0][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                self.validate(metadata, codec="hevc")

    def test_hevc_rejects_additional_streams(self):
        metadata = self.metadata()
        metadata["streams"].append({"codec_type": "audio", "codec_name": "aac"})
        with self.assertRaisesRegex(RuntimeError, "exactly one video stream"):
            self.validate(metadata, codec="hevc")

    def test_unknown_codec_rejected_before_probing(self):
        with mock.patch.object(background_video, "probe") as probe:
            with self.assertRaisesRegex(ValueError, "Unsupported output codec"):
                validate_output(Path("encoded.mp4"), 3, "ffprobe", codec="av1")
        probe.assert_not_called()


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg tools unavailable")
class RenderChecks(unittest.TestCase):
    def test_software_contract_and_corrupt_frame_count_rejection(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            source = folder / "master.mkv"
            # Deliberately include audio: the encoder must omit it entirely.
            subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-f", "lavfi", "-i",
                f"color=blue:s=1920x1080:r={RATE}", "-f", "lavfi", "-i", "sine=frequency=440",
                "-frames:v", "3", "-t", "0.1001", "-c:v", "ffv1", "-c:a", "pcm_s16le", str(source)], check=True)
            output = folder / "software.mp4"
            commands = []
            encode_master(source, output, "libx264", "ffmpeg", commands)
            metadata = validate_output(output, 3, "ffprobe")
            self.assertEqual(len(metadata["streams"]), 1)
            decode_check(output, "ffmpeg", commands)
            with self.assertRaises(RuntimeError):
                validate_output(output, 4, "ffprobe")

    def test_short_source_is_not_silently_frozen(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            source = folder / "short.mkv"
            subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-f", "lavfi", "-i",
                            f"color=red:s=64x64:r={RATE}", "-frames:v", "3", "-c:v", "ffv1", str(source)], check=True)
            with self.assertRaisesRegex(RuntimeError, "Incomplete normalized clip"):
                normalize_clip({"path": str(source), "source_in_seconds": 0, "frames": 30},
                               {"width": 64, "height": 64}, folder / "normalized.mkv", "ffmpeg", "ffprobe", [])


if __name__ == "__main__":
    unittest.main()
