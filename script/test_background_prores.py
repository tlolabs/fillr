"""Destructive-source guards use temporary fixtures and mocked media tools.

These checks never touch owner footage, submit Compressor jobs, or time encodes.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import background_prores as prores


class ProResFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fillr-prores-guard-test-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name).resolve()
        self.media = self.repo / "CNN Downloads"
        self.canonical = self.media / "Chabot News Comps 2026-11-09_231235" / "Comp 2" / "clip.mpg"
        self.root = self.media / "Chabot News Comps 2026-11-09_231235 ProRes 422"
        self.source = self.root / "Comp 2" / "clip.mpg"
        self.output = self.source.with_suffix(".mov")
        for path, payload in [(self.canonical, b"original MPEG2"),
                              (self.source, b"original MPEG2"), (self.output, b"converted ProRes")]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)

    def entry(self):
        digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
        return {"source": str(self.source), "output": str(self.output),
                "canonical": str(self.canonical), "status": "verified",
                "compressor_status": "Successful",
                "source_identity": prores.identity(self.source),
                "output_identity": prores.identity(self.output),
                "source_sha256": digest(self.source), "output_sha256": digest(self.output),
                "output_metadata": {"full_decode_check": "passed"}}


class ProResGuardTests(ProResFixture):
    def test_member_rejects_escape_and_root_itself(self):
        prores.ensure_member(self.root, self.source)
        for path in [self.root, self.canonical, self.root / ".." / "outside.mpg"]:
            with self.subTest(path=path):
                with self.assertRaises((ValueError, RuntimeError)):
                    prores.ensure_member(self.root, path)

    def test_member_rejects_symlink_file_and_directory(self):
        file_link = self.root / "alias.mpg"
        file_link.symlink_to(self.source)
        folder_link = self.root / "alias-folder"
        folder_link.symlink_to(self.source.parent, target_is_directory=True)
        for path in [file_link, folder_link / self.source.name]:
            with self.subTest(path=path):
                with self.assertRaises((ValueError, RuntimeError)):
                    prores.ensure_member(self.root, path)

    def test_identity_rejects_directory_and_symlink(self):
        link = self.root / "alias.mpg"
        link.symlink_to(self.source)
        self.assertEqual(prores.identity(self.source)["bytes"], self.source.stat().st_size)
        for path in [self.root, link]:
            with self.subTest(path=path):
                with self.assertRaises((ValueError, RuntimeError)):
                    prores.identity(path)

    def test_only_matching_explicit_profile_folder_is_allowed(self):
        prores.guard_profile_root(self.repo, "422", self.root)
        for profile, root in [("422", self.canonical.parents[1]),
                              ("lt", self.root),
                              ("422", self.repo / self.root.name)]:
            root.mkdir(parents=True, exist_ok=True)
            with self.subTest(profile=profile, root=root):
                with self.assertRaises((ValueError, RuntimeError)):
                    prores.guard_profile_root(self.repo, profile, root)

    def test_profile_root_symlink_is_rejected(self):
        actual = self.repo / "elsewhere"
        actual.mkdir()
        link_repo = self.repo / "symlink-repo"
        (link_repo / "CNN Downloads").mkdir(parents=True)
        link = link_repo / "CNN Downloads" / self.root.name
        link.symlink_to(actual, target_is_directory=True)
        with self.assertRaises((ValueError, RuntimeError)):
            prores.guard_profile_root(link_repo, "422", link)

    def test_verified_conversion_deletes_only_its_experiment_copy(self):
        prores.delete_verified_source(self.root, self.entry())
        self.assertFalse(self.source.exists())
        self.assertEqual(self.canonical.read_bytes(), b"original MPEG2")
        self.assertEqual(self.output.read_bytes(), b"converted ProRes")

    def test_unverified_or_failed_job_never_deletes(self):
        for field, value in [("status", "converted"), ("status", "failed"),
                             ("compressor_status", "Failed"), ("compressor_status", None),
                             ("output_metadata", {"full_decode_check": "failed"})]:
            entry = self.entry()
            entry[field] = value
            with self.subTest(field=field, value=value):
                with self.assertRaises((ValueError, RuntimeError)):
                    prores.delete_verified_source(self.root, entry)
                self.assertTrue(self.source.exists())

    def test_mutating_source_or_output_with_same_size_and_mtime_is_rejected(self):
        for path in [self.source, self.output]:
            entry = self.entry()
            original = path.read_bytes()
            before = path.stat()
            path.write_bytes(b"X" * len(original))
            os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
            with self.subTest(path=path):
                with self.assertRaisesRegex(ValueError, "checksum"):
                    prores.delete_verified_source(self.root, entry)
                self.assertTrue(self.source.exists())
                self.assertTrue(self.canonical.exists())
            path.write_bytes(original)

    def test_replaced_source_inode_is_rejected_even_with_identical_bytes(self):
        entry = self.entry()
        replacement = self.source.with_name("replacement.mpg")
        replacement.write_bytes(self.source.read_bytes())
        replacement.replace(self.source)
        with self.assertRaisesRegex(ValueError, "changed"):
            prores.delete_verified_source(self.root, entry)
        self.assertTrue(self.source.exists())

    def test_missing_or_different_canonical_copy_blocks_deletion(self):
        entry = self.entry()
        self.canonical.write_bytes(b"different bytes")
        with self.assertRaisesRegex(ValueError, "canonical"):
            prores.delete_verified_source(self.root, entry)
        self.assertTrue(self.source.exists())
        self.canonical.unlink()
        with self.assertRaises(FileNotFoundError):
            prores.delete_verified_source(self.root, entry)
        self.assertTrue(self.source.exists())

    def test_canonical_and_outside_source_paths_are_never_deleted(self):
        for path in [self.canonical, self.repo / "outside.mpg"]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"original MPEG2")
            entry = self.entry()
            entry.update(source=str(path), output=str(path.with_suffix(".mov")))
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    prores.delete_verified_source(self.root, entry)
                self.assertTrue(path.exists())

    def test_hardlinked_source_is_retained(self):
        self.source.unlink()
        os.link(self.canonical, self.source)
        with self.assertRaisesRegex(ValueError, "hardlinked"):
            prores.delete_verified_source(self.root, self.entry())
        self.assertTrue(self.source.exists())
        self.assertTrue(self.canonical.exists())

    def test_unlink_failure_preserves_source_and_does_not_claim_deleted(self):
        entry = self.entry()
        with mock.patch.object(Path, "unlink", side_effect=PermissionError("fixture read-only")):
            with self.assertRaises(PermissionError):
                prores.delete_verified_source(self.root, entry)
        self.assertTrue(self.source.exists())
        self.assertEqual(entry["status"], "verified")


class ProResValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fillr-prores-validation-test-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name).resolve()
        self.output = self.folder / "clip.mov"
        self.output.write_bytes(b"fixture, no video encoding")
        self.log = self.folder / "decode.log"
        self.fields = {"interlaced_frame": 1, "top_field_first": 1}
        self.source = {"width": 1920, "height": 1080, "r_frame_rate": "30000/1001",
                       "avg_frame_rate": "30000/1001", "nb_read_frames": "300",
                       "sample_aspect_ratio": "1:1", "color_space": "bt709",
                       "color_transfer": "bt709", "color_primaries": "bt709",
                       "color_range": "tv", "decoded_field_flags": self.fields}
        self.output_metadata = {**self.source, "codec_name": "prores", "profile": "Standard",
                                "codec_tag_string": "apcn", "pix_fmt": "yuv422p10le",
                                "nb_frames": "300", "duration": "10.010000"}

    def validate(self, metadata=None, fields=None, run_effect=None):
        if run_effect is None:
            run_effect = lambda command, **kwargs: subprocess.CompletedProcess(
                command, 0, stdout="frame=300\nprogress=end\n")
        with mock.patch.object(prores, "_probe", return_value=copy.deepcopy(metadata or self.output_metadata)), \
             mock.patch.object(prores, "_field_flags", return_value=fields or self.fields), \
             mock.patch.object(prores.subprocess, "run", side_effect=run_effect) as run:
            value = prores.verify_output(self.source, self.output, "422", self.log)
            self.assertTrue(run.called, "A metadata-only check cannot authorize deletion")
            return value

    def test_valid_output_requires_full_decode(self):
        value = self.validate()
        self.assertEqual(value["full_decode_check"], "passed")

    def test_wrong_codec_profile_dimensions_or_timing_is_rejected(self):
        cases = [("codec_name", "h264"), ("profile", "Proxy"), ("codec_tag_string", "apco"),
                 ("pix_fmt", "yuv420p"), ("width", 1280), ("height", 720),
                 ("r_frame_rate", "30/1"), ("avg_frame_rate", "30/1"),
                 ("nb_frames", "299"),
                 ("duration", "10.0"), ("sample_aspect_ratio", "4:3"),
                 ("color_range", "pc")]
        for key, value in cases:
            metadata = {**self.output_metadata, key: value}
            with self.subTest(key=key, value=value):
                with self.assertRaises((ValueError, RuntimeError)):
                    self.validate(metadata)

    def test_deinterlaced_or_reversed_parity_output_is_rejected(self):
        for fields in [{"interlaced_frame": 0, "top_field_first": 0},
                       {"interlaced_frame": 1, "top_field_first": 0}]:
            with self.subTest(fields=fields):
                with self.assertRaisesRegex(ValueError, "parity"):
                    self.validate(fields=fields)

    def test_decode_process_failure_is_not_a_pass(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.validate(run_effect=subprocess.CalledProcessError(1, "ffmpeg"))

    def test_decode_errors_with_zero_process_status_are_rejected(self):
        def decode_error(*args, **kwargs):
            kwargs["stderr"].write("Invalid frame while decoding\n")
            return subprocess.CompletedProcess(args[0], 0, stdout="frame=300\nprogress=end\n")
        with self.assertRaisesRegex(RuntimeError, "decode reported"):
            self.validate(run_effect=decode_error)

    def test_partial_decode_or_missing_end_marker_is_rejected(self):
        for progress in ["frame=299\nprogress=end\n", "frame=300\nprogress=continue\n", "progress=end\n"]:
            with self.subTest(progress=progress):
                effect = lambda command, **kwargs: subprocess.CompletedProcess(command, 0, stdout=progress)
                with self.assertRaisesRegex(ValueError, "decoded frame count"):
                    self.validate(run_effect=effect)

    def test_only_count_failures_receive_the_repairable_exception_type(self):
        with self.assertRaises(prores.FrameCountMismatch):
            self.validate({**self.output_metadata, "nb_frames": "299"})
        for change in [{"codec_name": "h264"}, {"profile": "Proxy"}, {"color_range": "pc"}]:
            with self.subTest(change=change):
                with self.assertRaises(ValueError) as failure:
                    self.validate({**self.output_metadata, **change})
                self.assertNotIsInstance(failure.exception, prores.FrameCountMismatch)


class ProResJournalTests(ProResFixture):
    def plan(self):
        source_id = prores.identity(self.source)
        item = {"relative_path": "Comp 2/clip.mpg", "path": str(self.source),
                "canonical_path": str(self.canonical), **source_id}
        entry = {**self.entry(), "inventory_identity": {
            key: source_id[key] for key in ("device", "inode", "bytes")}}
        return {"entries": {"Comp 2/clip.mpg": entry}}, {"files": [item]}

    def test_valid_journal_preserves_canonical_mapping(self):
        journal, folder = self.plan()
        prores.validate_journal_plan(journal, folder, self.root, self.canonical.parents[1])

    def test_journal_cannot_drop_or_add_inventory_entries(self):
        journal, folder = self.plan()
        for entries in [{}, {**journal["entries"], "Comp 2/uninventoried.mpg": self.entry()}]:
            with self.subTest(keys=list(entries)):
                with self.assertRaisesRegex(ValueError, "entry set"):
                    prores.validate_journal_plan({"entries": entries}, folder, self.root, self.canonical.parents[1])

    def test_journal_source_output_and_canonical_cannot_be_redirected(self):
        for field, path in [("source", self.root / "other.mpg"),
                            ("output", self.root / "other.mov"),
                            ("canonical", self.repo / "other.mpg")]:
            journal, folder = self.plan()
            journal["entries"]["Comp 2/clip.mpg"][field] = str(path)
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, "paths differ"):
                    prores.validate_journal_plan(journal, folder, self.root, self.canonical.parents[1])

    def test_resumed_inventory_identity_must_match_original(self):
        journal, folder = self.plan()
        journal["entries"]["Comp 2/clip.mpg"]["inventory_identity"]["inode"] += 1
        with self.assertRaisesRegex(ValueError, "identity differs"):
            prores.validate_journal_plan(journal, folder, self.root, self.canonical.parents[1])


class ProResResumeTests(ProResFixture):
    def config(self, entry_status=None):
        entry = self.entry()
        entry["inventory_identity"] = {key: entry["source_identity"][key]
                                       for key in ("device", "inode", "bytes")}
        item = {"relative_path": "Comp 2/clip.mpg", "path": str(self.source),
                "canonical_path": str(self.canonical), **entry["source_identity"]}
        inventory = {"canonical_folder": str(self.canonical.parents[1]), "folders": [{
            "name": self.root.name, "path": str(self.root), "files": [item]}]}
        inventory_path = self.repo / "inventory.json"
        inventory_path.write_text(json.dumps(inventory))
        preset_dir = self.repo / "presets"
        preset_dir.mkdir()
        preset = preset_dir / prores.PROFILES["422"]["preset"]
        preset.write_text("fixture preset")
        state = self.repo / "state"
        journal_path = state / "conversion-422" / "journal.json"
        if entry_status:
            entry["status"] = entry_status
            entry["deletion_intent_unix"] = 1
            journal = {"profile": "422", "root": str(self.root), "entries": {"Comp 2/clip.mpg": entry},
                       "preset_sha256": prores.sha256(preset), "batches": [],
                       "source_preparation_seconds": 0, "conversion_wait_seconds": 0,
                       "verification_wall_seconds": 0, "deletion_wall_seconds": 0}
            journal_path.parent.mkdir(parents=True)
            journal_path.write_text(json.dumps(journal))
        args = ["--profile", "422", "--inventory", str(inventory_path), "--state-dir", str(state)]
        return args, preset_dir, journal_path

    def invoke(self, args, preset_dir):
        with mock.patch.object(prores, "__file__", str(self.repo / "script/background_prores.py")), \
             mock.patch.object(prores, "PRESETS", preset_dir), \
             mock.patch.object(prores, "source_metadata", return_value={"codec_name": "mpeg2video"}), \
             mock.patch.object(prores.subprocess, "run") as run:
            try:
                return prores.main(args)
            finally:
                self.assertFalse(run.called, "Resume/no-overwrite fixtures must not launch media tools")

    def test_existing_untracked_output_is_never_overwritten(self):
        args, preset_dir, _ = self.config()
        before = self.output.read_bytes()
        with self.assertRaisesRegex(FileExistsError, "refusing to overwrite"):
            self.invoke(args, preset_dir)
        self.assertEqual(self.output.read_bytes(), before)
        self.assertTrue(self.source.exists())

    def test_same_identity_corrupt_output_is_rejected_on_resume(self):
        args, preset_dir, _ = self.config(entry_status="deleted")
        self.source.unlink()
        before = self.output.stat()
        self.output.write_bytes(b"X" * before.st_size)
        os.utime(self.output, ns=(before.st_atime_ns, before.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, "checksum changed"):
            self.invoke(args, preset_dir)
        self.assertTrue(self.canonical.exists())

    def test_interrupted_deletion_recovers_without_resubmission(self):
        args, preset_dir, journal_path = self.config(entry_status="verified")
        self.source.unlink()
        self.assertEqual(self.invoke(args, preset_dir), 0)
        saved = json.loads(journal_path.read_text())
        self.assertEqual(saved["entries"]["Comp 2/clip.mpg"]["status"], "deleted")
        self.assertTrue(saved["entries"]["Comp 2/clip.mpg"]["recovered_absent_source"])
        mapping = json.loads((journal_path.parent / "source-map.json").read_text())
        self.assertEqual(mapping, {str(self.canonical): str(self.output)})


class ProResRepairTests(ProResFixture):
    def repair_fixture(self, stage):
        directory = self.repo / "state" / "conversion-422"
        work = directory / "timing-repairs" / hashlib.sha256(str(self.source).encode()).hexdigest()[:20]
        work.mkdir(parents=True)
        preset_dir = self.repo / "presets"
        preset_dir.mkdir()
        preset = preset_dir / prores.PROFILES["422"]["preset"]
        preset.write_text("unchanged Compressor preset")
        paths = {"input_path": str(work / "source-streamcopy-genpts.mov"),
                 "output_path": str(work / "repaired-prores.mov"),
                 "archive_path": str(work / "original-frame-count-mismatch.mov"),
                 "receipt_path": str(work / "compressor-submission.stdout")}
        remux = Path(paths["input_path"])
        remux.write_bytes(b"lossless timestamp-only remux fixture")
        entry = self.entry()
        entry.update(status="converted", frame_count_mismatch="1888 != 1889",
                     source_metadata={"nb_read_frames": "3"})
        repair = {**paths, "stage": stage, "profile": "422", "source_sha256": entry["source_sha256"],
                  "preset": str(preset), "preset_sha256": prores.sha256(preset),
                  "original_output_identity": prores.identity(self.output),
                  "original_output_sha256": prores.sha256(self.output),
                  "batch_name": "fixture batch", "batch_id": "fixture-batch-id",
                  "input_identity": prores.identity(remux), "input_sha256": prores.sha256(remux)}
        entry["timing_repair"] = repair
        replacement = Path(paths["output_path"])
        if stage in ("submitting", "submitted", "converted", "verified", "adopting"):
            replacement.write_bytes(b"fully verified repaired ProRes fixture")
            repair.update(output_identity=prores.identity(replacement), output_sha256=prores.sha256(replacement),
                          output_metadata={"full_decode_check": "passed", "nb_read_frames": "3"})
        journal = {"conversion_wait_seconds": 0, "verification_wall_seconds": 0}
        return entry, directory, preset_dir, journal

    def repair(self, entry, directory, preset_dir, journal, **patches):
        options = {"verify_output": mock.Mock(return_value={"full_decode_check": "passed", "nb_read_frames": "3"}),
                   "_monitor": mock.Mock(return_value={"status": "Successful"}), **patches}
        saves = []
        with mock.patch.object(prores, "PRESETS", preset_dir), \
             mock.patch.multiple(prores, **options), \
             mock.patch.object(prores.subprocess, "run") as run:
            try:
                return prores.repair_frame_count(entry, "422", directory, journal,
                    lambda: saves.append(entry["timing_repair"]["stage"]), 1)
            finally:
                self.assertFalse(run.called, "Repair fixtures must not launch remux or Compressor jobs")

    def test_packet_mismatch_or_missing_packet_blocks_submission(self):
        for proof in [{"count": 3, "sha256": "different"}, {"count": 2, "sha256": "original"}]:
            # Each independent fixture has deterministic work paths.
            entry, directory, preset_dir, journal = self.repair_fixture("planned")
            source_proof = {"count": 3, "sha256": "original"}
            packet_probe = mock.Mock(side_effect=[source_proof, proof])
            with self.subTest(proof=proof):
                with self.assertRaisesRegex(ValueError, "byte-for-byte"):
                    self.repair(entry, directory, preset_dir, journal, video_packet_manifest=packet_probe)
                self.assertEqual(self.output.read_bytes(), b"converted ProRes")
                self.assertTrue(self.source.exists())
                self.assertFalse(Path(entry["timing_repair"]["archive_path"]).exists())
            # Reset only fixture working data between subcases.
            shutil.rmtree(directory)
            shutil.rmtree(preset_dir)

    def test_untracked_repair_output_is_not_overwritten_or_submitted(self):
        entry, directory, preset_dir, journal = self.repair_fixture("remuxed")
        replacement = Path(entry["timing_repair"]["output_path"])
        replacement.write_bytes(b"untracked file")
        with self.assertRaisesRegex(FileExistsError, "refusing to overwrite"):
            self.repair(entry, directory, preset_dir, journal)
        self.assertEqual(replacement.read_bytes(), b"untracked file")
        self.assertEqual(self.output.read_bytes(), b"converted ProRes")
        self.assertTrue(self.source.exists())

    def test_failed_repaired_output_validation_preserves_existing_files(self):
        entry, directory, preset_dir, journal = self.repair_fixture("converted")
        validator = mock.Mock(side_effect=prores.FrameCountMismatch("repair still short"))
        with self.assertRaises(prores.FrameCountMismatch):
            self.repair(entry, directory, preset_dir, journal, verify_output=validator)
        self.assertEqual(self.output.read_bytes(), b"converted ProRes")
        self.assertTrue(self.source.exists())
        self.assertFalse(Path(entry["timing_repair"]["archive_path"]).exists())
        self.assertEqual(entry["status"], "converted")

    def test_success_archives_old_mov_and_preserves_mpeg_source(self):
        entry, directory, preset_dir, journal = self.repair_fixture("converted")
        result = self.repair(entry, directory, preset_dir, journal)
        self.assertEqual(result["full_decode_check"], "passed")
        self.assertEqual(entry["timing_repair"]["stage"], "adopted")
        self.assertEqual(entry["status"], "verified")
        self.assertEqual(self.output.read_bytes(), b"fully verified repaired ProRes fixture")
        self.assertEqual(Path(entry["timing_repair"]["archive_path"]).read_bytes(), b"converted ProRes")
        self.assertEqual(self.source.read_bytes(), b"original MPEG2")
        self.assertEqual(entry["output_sha256"], prores.sha256(self.output))

    def test_submission_receipt_is_resumed_without_another_job(self):
        entry, directory, preset_dir, journal = self.repair_fixture("submitting")
        Path(entry["timing_repair"]["receipt_path"]).write_text(json.dumps({"batch": {"batchID": "recovered-id"}}))
        monitor = mock.Mock(return_value={"status": "Successful"})
        self.repair(entry, directory, preset_dir, journal, _monitor=monitor)
        self.assertEqual(monitor.call_args.args[0], "recovered-id")
        self.assertEqual(entry["timing_repair"]["stage"], "adopted")
        self.assertTrue(self.source.exists())

    def test_missing_submission_receipt_refuses_duplicate_job(self):
        entry, directory, preset_dir, journal = self.repair_fixture("submitting")
        with self.assertRaisesRegex(RuntimeError, "refusing duplicate"):
            self.repair(entry, directory, preset_dir, journal)
        self.assertEqual(self.output.read_bytes(), b"converted ProRes")
        self.assertTrue(self.source.exists())

    def test_interrupted_archive_rename_recovers_verified_replacement(self):
        entry, directory, preset_dir, journal = self.repair_fixture("adopting")
        archive = Path(entry["timing_repair"]["archive_path"])
        self.output.rename(archive)
        self.repair(entry, directory, preset_dir, journal)
        self.assertEqual(self.output.read_bytes(), b"fully verified repaired ProRes fixture")
        self.assertEqual(archive.read_bytes(), b"converted ProRes")
        self.assertTrue(self.source.exists())

    def test_unrecognized_target_is_never_replaced(self):
        entry, directory, preset_dir, journal = self.repair_fixture("verified")
        self.output.write_bytes(b"new user output, do not overwrite")
        with self.assertRaisesRegex(ValueError, "preserved original"):
            self.repair(entry, directory, preset_dir, journal)
        self.assertEqual(self.output.read_bytes(), b"new user output, do not overwrite")
        self.assertTrue(self.source.exists())

    def main_fixture(self, entry, directory, preset_dir, journal, verify_error=None):
        source_id = prores.identity(self.source)
        entry["inventory_identity"] = {key: source_id[key] for key in ("device", "inode", "bytes")}
        item = {"relative_path": "Comp 2/clip.mpg", "path": str(self.source),
                "canonical_path": str(self.canonical), **source_id}
        inventory = {"canonical_folder": str(self.canonical.parents[1]), "folders": [{
            "name": self.root.name, "path": str(self.root), "files": [item]}]}
        inventory_path = self.repo / "inventory.json"
        inventory_path.write_text(json.dumps(inventory))
        preset = preset_dir / prores.PROFILES["422"]["preset"]
        journal.update(profile="422", root=str(self.root), preset_sha256=prores.sha256(preset),
                       entries={"Comp 2/clip.mpg": entry}, batches=[], source_preparation_seconds=0,
                       deletion_wall_seconds=0)
        journal_path = directory / "journal.json"
        journal_path.write_text(json.dumps(journal))
        args = ["--profile", "422", "--inventory", str(inventory_path),
                "--state-dir", str(directory.parent), "--keep-mpeg"]
        validator = mock.Mock(side_effect=verify_error,
                              return_value={"full_decode_check": "passed", "nb_read_frames": "3"})
        with mock.patch.object(prores, "__file__", str(self.repo / "script/background_prores.py")), \
             mock.patch.object(prores, "PRESETS", preset_dir), \
             mock.patch.object(prores, "source_metadata", return_value={"nb_read_frames": "3"}), \
             mock.patch.object(prores, "verify_output", validator), \
             mock.patch.object(prores.subprocess, "run") as run:
            try:
                code = prores.main(args)
            finally:
                self.assertFalse(run.called, "Main recovery fixture must not submit media work")
        return code, json.loads(journal_path.read_text()), validator

    def test_main_resumes_adoption_before_accessing_missing_target(self):
        entry, directory, preset_dir, journal = self.repair_fixture("adopting")
        archive = Path(entry["timing_repair"]["archive_path"])
        self.output.rename(archive)
        code, saved, validator = self.main_fixture(entry, directory, preset_dir, journal)
        self.assertEqual(code, 0)
        self.assertFalse(validator.called, "Already verified replacement should be adopted directly")
        self.assertEqual(saved["entries"]["Comp 2/clip.mpg"]["timing_repair"]["stage"], "adopted")
        self.assertEqual(self.output.read_bytes(), b"fully verified repaired ProRes fixture")
        self.assertEqual(archive.read_bytes(), b"converted ProRes")
        self.assertTrue(self.source.exists())

    def test_main_does_not_repair_wrong_codec_or_color_failures(self):
        entry, directory, preset_dir, journal = self.repair_fixture("converted")
        entry.pop("timing_repair")
        entry.pop("frame_count_mismatch")
        with mock.patch.object(prores, "repair_frame_count") as repair:
            with self.assertRaisesRegex(ValueError, "wrong codec"):
                self.main_fixture(entry, directory, preset_dir, journal,
                                  verify_error=ValueError("wrong codec or color"))
        self.assertFalse(repair.called)
        self.assertEqual(self.output.read_bytes(), b"converted ProRes")
        self.assertTrue(self.source.exists())


class ProResPacketProofTests(unittest.TestCase):
    def manifest(self, packets):
        result = subprocess.CompletedProcess("ffprobe", 0, stdout=json.dumps({"packets": packets}), stderr="")
        with mock.patch.object(prores.subprocess, "run", return_value=result):
            return prores.video_packet_manifest(Path("mocked-packet-source.mpg"))

    def test_payload_change_or_packet_reordering_changes_proof(self):
        packets = [{"size": "100", "data_hash": "SHA256:" + "a" * 64},
                   {"size": "200", "data_hash": "SHA256:" + "b" * 64}]
        original = self.manifest(packets)
        self.assertEqual(original["count"], 2)
        self.assertNotEqual(original, self.manifest(list(reversed(packets))))
        changed = copy.deepcopy(packets)
        changed[-1]["data_hash"] = "SHA256:" + "c" * 64
        self.assertNotEqual(original, self.manifest(changed))

    def test_empty_or_missing_packet_hashes_cannot_prove_preservation(self):
        for packets in [[], [{"size": "100"}], [{"size": "100", "data_hash": "unknown"}]]:
            with self.subTest(packets=packets):
                with self.assertRaisesRegex(ValueError, "packet hashes"):
                    self.manifest(packets)


class ProResBackendRecoveryTests(ProResFixture):
    def backend_fixture(self, count=16, reported=9):
        entries, keys, jobs, outcomes, command = {}, [], [], [], ["Compressor"]
        for n in range(count):
            relative = f"Comp 2/clip-{n:02d}.mpg"
            source = self.root / relative
            source.write_bytes(f"source MPEG2 {n}".encode())
            output = source.with_suffix(".mov")
            if n < count - 1 or count == 1:
                output.write_bytes(f"partial MOV {n}".encode())
            job_id = f"job-{n:02d}"
            entries[relative] = {"source": str(source), "output": str(output), "status": "submitted",
                                 "source_identity": prores.identity(source), "source_sha256": prores.sha256(source)}
            keys.append(relative)
            jobs.append({"jobID": job_id})
            command += ["-jobpath", str(source)]
            if n < reported:
                outcomes.append({"jobStatus": {"jobid": job_id, "batchid": "fixture-batch",
                    "name": source.name, "status": "Failed: 2x job controller down"}})
        batch = {"batch_id": "fixture-batch", "status": "submitted", "entries": keys,
                 "receipt": {"jobs": jobs}, "command": command}
        journal = {"root": str(self.root), "entries": entries, "batches": [batch]}
        snapshot = {"batchid": "fixture-batch", "status": "Failed", "jobs": outcomes}
        directory = self.repo / "state" / "conversion-422"
        directory.mkdir(parents=True)
        unknown = [f"job-{n:02d}" for n in range(reported, count)]
        return journal, batch, snapshot, directory, unknown

    def test_all_sixteen_are_requeued_and_fifteen_partials_preserved(self):
        journal, batch, snapshot, directory, unknown = self.backend_fixture()
        original_snapshot = copy.deepcopy(snapshot)
        result = prores.reconcile_failed_batch(journal, batch, snapshot, directory, lambda: None,
                                               unknown_job_ids=unknown)
        self.assertEqual(result, {"successful": 0, "retry_pending": 16})
        self.assertEqual(batch["status"], "failed")
        self.assertEqual(batch["failure_snapshot"], original_snapshot)
        self.assertEqual(batch["recovery_state"], "reconciled")
        archived = []
        for entry in journal["entries"].values():
            self.assertEqual(entry["status"], "pending")
            self.assertNotEqual(entry.get("compressor_status"), "Successful")
            self.assertTrue(Path(entry["source"]).exists())
            failure = entry["backend_failures"][0]
            archive = Path(failure["archive_path"])
            if failure["output_existed"]:
                self.assertTrue(archive.exists())
                archived.append(archive)
                self.assertFalse(Path(entry["output"]).exists())
        self.assertEqual(len(archived), 15)
        for job_id in unknown:
            outcome = batch["reconciled_job_outcomes"][job_id]
            self.assertFalse(outcome["reported_by_compressor"])
            self.assertTrue(outcome["status"].startswith("Unknown:"))

    def test_missing_children_need_explicit_unknown_ids(self):
        journal, batch, snapshot, directory, _ = self.backend_fixture()
        with self.assertRaisesRegex(ValueError, "incomplete or ambiguous"):
            prores.reconcile_failed_batch(journal, batch, snapshot, directory, lambda: None)
        self.assertFalse(list(directory.rglob("*.mov")))
        self.assertEqual(sum(Path(e["output"]).exists() for e in journal["entries"].values()), 15)

    def test_unknown_children_require_original_submission_order(self):
        journal, batch, snapshot, directory, unknown = self.backend_fixture()
        batch["command"][2], batch["command"][4] = batch["command"][4], batch["command"][2]
        with self.assertRaisesRegex(ValueError, "source order"):
            prores.reconcile_failed_batch(journal, batch, snapshot, directory, lambda: None,
                                          unknown_job_ids=unknown)
        self.assertFalse(list(directory.rglob("*.mov")))

    def test_known_success_stays_converted_and_failed_children_stay_failed(self):
        journal, batch, snapshot, directory, _ = self.backend_fixture(count=3, reported=3)
        snapshot["jobs"][0]["jobStatus"]["status"] = "Successful"
        result = prores.reconcile_failed_batch(journal, batch, snapshot, directory, lambda: None)
        self.assertEqual(result, {"successful": 1, "retry_pending": 2})
        entries = list(journal["entries"].values())
        self.assertEqual(entries[0]["status"], "converted")
        self.assertTrue(Path(entries[0]["output"]).exists())
        self.assertNotIn("output_metadata", entries[0], "Genuine job success still needs full validation")
        self.assertTrue(all(Path(e["source"]).exists() for e in entries))
        self.assertTrue(all(e["compressor_status"].startswith("Failed") for e in entries[1:]))

    def test_active_or_ambiguous_children_do_not_move_outputs(self):
        journal, batch, snapshot, directory, _ = self.backend_fixture(count=1, reported=1)
        snapshot["jobs"][0]["jobStatus"]["status"] = "Processing: job controller down"
        with self.assertRaisesRegex(ValueError, "still be active"):
            prores.reconcile_failed_batch(journal, batch, snapshot, directory, lambda: None)
        self.assertTrue(Path(next(iter(journal["entries"].values()))["output"]).exists())
        snapshot["jobs"].append(copy.deepcopy(snapshot["jobs"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate or ambiguous"):
            prores.reconcile_failed_batch(journal, batch, snapshot, directory, lambda: None)

    def test_source_checksum_change_blocks_any_recovery_mutation(self):
        journal, batch, snapshot, directory, _ = self.backend_fixture(count=1, reported=1)
        entry = next(iter(journal["entries"].values()))
        source = Path(entry["source"])
        original = source.stat()
        source.write_bytes(b"X" * original.st_size)
        os.utime(source, ns=(original.st_atime_ns, original.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, "changed"):
            prores.reconcile_failed_batch(journal, batch, snapshot, directory, lambda: None)
        self.assertEqual(batch["status"], "submitted")
        self.assertTrue(Path(entry["output"]).exists())
        self.assertFalse(list(directory.rglob("*.mov")))

    def test_repeated_failure_limit_is_not_reset_by_reconciliation(self):
        journal, batch, snapshot, directory, _ = self.backend_fixture(count=1, reported=1)
        entry = next(iter(journal["entries"].values()))
        entry["backend_failures"] = [{"job_id": "older-attempt-1"}, {"job_id": "older-attempt-2"}]
        with self.assertRaisesRegex(RuntimeError, "Repeated controller failures"):
            prores.reconcile_failed_batch(journal, batch, snapshot, directory, lambda: None)
        self.assertTrue(Path(entry["output"]).exists())
        self.assertTrue(Path(entry["source"]).exists())

    def test_interrupted_partial_archive_recovers_without_moving_new_files(self):
        journal, batch, snapshot, directory, _ = self.backend_fixture(count=1, reported=1)
        durable = None
        def save():
            nonlocal durable
            histories = [e.get("backend_failures", []) for e in journal["entries"].values()]
            if any(h and h[0]["stage"] == "archived" for h in histories):
                raise RuntimeError("fixture interruption after rename")
            durable = copy.deepcopy(journal)
        with self.assertRaisesRegex(RuntimeError, "fixture interruption"):
            prores.reconcile_failed_batch(journal, batch, snapshot, directory, save)
        restored_batch = durable["batches"][0]
        restored_entry = next(iter(durable["entries"].values()))
        self.assertFalse(Path(restored_entry["output"]).exists())
        self.assertTrue(Path(restored_entry["backend_failures"][0]["archive_path"]).exists())
        result = prores.reconcile_failed_batch(durable, restored_batch, snapshot, directory, lambda: None)
        self.assertEqual(result, {"successful": 0, "retry_pending": 1})
        self.assertEqual(restored_entry["status"], "pending")
        self.assertEqual(len(restored_entry["backend_failures"]), 1)
        self.assertTrue(Path(restored_entry["source"]).exists())

    def test_changed_partial_after_snapshot_is_not_archived(self):
        journal, batch, snapshot, directory, _ = self.backend_fixture(count=1, reported=1)
        durable = None
        def save():
            nonlocal durable
            durable = copy.deepcopy(journal)
            if next(iter(journal["entries"].values())).get("backend_failures"):
                raise RuntimeError("fixture interruption before rename")
        with self.assertRaisesRegex(RuntimeError, "fixture interruption"):
            prores.reconcile_failed_batch(journal, batch, snapshot, directory, save)
        restored_entry = next(iter(durable["entries"].values()))
        output = Path(restored_entry["output"])
        original = output.stat()
        output.write_bytes(b"X" * original.st_size)
        os.utime(output, ns=(original.st_atime_ns, original.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, "changed before"):
            prores.reconcile_failed_batch(durable, durable["batches"][0], snapshot, directory, lambda: None)
        self.assertTrue(output.exists())
        self.assertTrue(Path(restored_entry["source"]).exists())


if __name__ == "__main__":
    unittest.main()
