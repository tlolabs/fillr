"""Runtime hardware attribution must not silently accept decoder fallback."""
import copy
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import background_gpu
from background_gpu import validate_hardware_decoding


class HardwareDecodeVerificationTests(unittest.TestCase):
    def setUp(self):
        self.report = {"sources": [
            {"comp": n, "cpu_decoded_nv12_packed_frames": 0,
             "segments": [{"reported_hardware_decoder": True}, {"reported_hardware_decoder": True}]}
            for n in [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        ]}

    def test_all_cuts_confirmed(self):
        validate_hardware_decoding(self.report)

    def test_cpu_frames_rejected(self):
        self.report["sources"][3]["cpu_decoded_nv12_packed_frames"] = 1
        with self.assertRaisesRegex(RuntimeError, "CPU decoding"):
            validate_hardware_decoding(self.report)

    def test_capability_without_backend_confirmation_rejected(self):
        for value in [None, False, "true"]:
            report = copy.deepcopy(self.report)
            report["sources"][5]["segments"][1]["reported_hardware_decoder"] = value
            report["sources"][5]["segments"][1]["hardware_decode_supported"] = True
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, "confirm hardware"):
                validate_hardware_decoding(report)

    def test_missing_panel_or_cut_reports_rejected(self):
        for change in [lambda r: r["sources"].pop(), lambda r: r["sources"][0].update(segments=[])]:
            report = copy.deepcopy(self.report)
            change(report)
            with self.assertRaises(RuntimeError):
                validate_hardware_decoding(report)

    def test_duplicate_unknown_or_missing_panel_ids_rejected(self):
        for comp in [1, 6, None, "16", True]:
            report = copy.deepcopy(self.report)
            report["sources"][-1]["comp"] = comp
            with self.subTest(comp=comp), self.assertRaisesRegex(RuntimeError, "unique expected panel"):
                validate_hardware_decoding(report)


class PreparedJobTests(unittest.TestCase):
    def test_resumed_job_enforces_current_or_saved_hardware_requirement(self):
        for saved, requested in [(False, True), (True, False), (False, False)]:
            with self.subTest(saved=saved, requested=requested), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                script = root / "script/background_gpu.py"
                script.parent.mkdir()
                script.touch()
                build_script = script.with_name("build_background_gpu.sh")
                build_script.touch()
                native = root / ".build/background_gpu/fillr-background-gpu"
                native.parent.mkdir(parents=True)
                native.touch()
                label = "prepared-test"
                job = {"pipeline": "metal-native-hybrid", "frames": 17982,
                       "duration_seconds": 599.9994, "test_label": label,
                       "require_hardware_decode": saved}
                background_gpu.write_json(root / "job.json", job)
                background_gpu.write_json(root / "report.json", {"preparation_seconds": 0,
                                                               "error": "Previous attempt failed"})
                background_gpu.write_json(native.parent / "build-manifest.json", {
                    "source_sha256": {str(path.relative_to(root)): background_gpu.sha256(path)
                                      for path in [script, build_script]},
                    "native_binary_sha256": background_gpu.sha256(native),
                })
                background_gpu.write_json(root / "native-report.json", {
                    "status": "encoded", "completed_frames": 17982,
                    "sources": [{"comp": number, "cpu_decoded_nv12_packed_frames": 1,
                                 "segments": [{"reported_hardware_decoder": False}]}
                                for number in [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]],
                })
                # Empty placeholders and mocked tools exercise control flow;
                # this test never builds native code or creates/reads media.
                (root / f"{label}.mp4").touch()
                source = root / "source-placeholder"
                source.write_bytes(b"original contents")
                log = root / "native-render.log"
                if saved:
                    log.hardlink_to(source)
                else:
                    log.symlink_to(source)
                required = saved or requested
                def launch(*args, **kwargs):
                    effective = json.loads((root / "job.json").read_text())
                    self.assertEqual(effective["require_hardware_decode"], required)
                    kwargs["stdout"].write("render log\n")
                    return mock.Mock(wait=mock.Mock(return_value=0))
                arguments = ["--output-dir", str(root), "--test-label", label,
                             "--run-prepared", "--skip-build"]
                if requested:
                    arguments.append("--require-hardware-decode")
                with mock.patch.object(background_gpu, "__file__", str(script)), \
                     mock.patch.object(background_gpu.subprocess, "Popen", side_effect=launch), \
                     mock.patch.object(background_gpu.subprocess, "run", side_effect=AssertionError("Unexpected tool launch")), \
                     mock.patch.object(background_gpu, "validate_output", return_value={}) as validate, \
                     mock.patch.object(background_gpu, "decode_check") as decode, \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    result = background_gpu.main(arguments)
                report = json.loads((root / "report.json").read_text())
                self.assertEqual(source.read_bytes(), b"original contents")
                self.assertFalse(log.is_symlink())
                self.assertEqual(log.read_text(), "render log\n")
                self.assertEqual(result, 1 if required else 0)
                self.assertEqual(report["status"], "failed" if required else "verified")
                if required:
                    self.assertIn("CPU decoding", report["error"])
                    validate.assert_not_called()
                    decode.assert_not_called()
                else:
                    self.assertNotIn("error", report)
                    validate.assert_called_once()
                    decode.assert_called_once()


class SavedJobTests(unittest.TestCase):
    def test_import_preserves_app_plan_and_copies_artwork_for_arbitrary_duration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "app-job.json"
            clip = root / "clip.mov"
            clip.touch()
            tile = root / "tile.png"
            tile.write_bytes(b"artwork")
            job = {"pipeline": "metal-native-hybrid", "frames": 23706,
                   "frame_rate": "30000/1001", "require_hardware_decode": True,
                   "panels": [{"segments": [{"path": str(clip), "frames": 23706}]} for _ in range(15)],
                   "bands": [{"tile_path": str(tile)} for _ in range(2)]}
            source.write_text(json.dumps(job))
            before = source.read_bytes()
            result = background_gpu.import_saved_job(source, root / "output", "HEVC", "hevc", False)
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(result["codec"], "hevc")
            self.assertEqual(result["duration_seconds"], 790.9902)
            self.assertTrue(result["require_hardware_decode"])
            for band in result["bands"]:
                self.assertEqual(Path(band["tile_path"]).read_bytes(), b"artwork")
                self.assertNotEqual(band["tile_path"], str(tile))
            with self.assertRaises(FileExistsError):
                background_gpu.import_saved_job(source, root / "output", "HEVC", "hevc", False)


if __name__ == "__main__":
    unittest.main()
