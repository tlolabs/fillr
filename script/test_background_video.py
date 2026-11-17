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
