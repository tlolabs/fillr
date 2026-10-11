"""Checks for the write-scoped direct-download publisher."""

import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import publish_direct
import report_ci_failures


class PackageChecks(unittest.TestCase):
    def test_accepts_one_valid_zip_and_rejects_extra_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            package = directory / publish_direct.ASSETS["macos"]
            with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("FILLR.app/Contents/MacOS/FILLR", b"x" * (1024 * 1024))
            self.assertEqual(publish_direct.validate_package("macos", directory), package)
            (directory / "unexpected").write_text("extra")
            with self.assertRaises(ValueError):
                publish_direct.validate_package("macos", directory)

    def test_rejects_non_elf_appimage(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / publish_direct.ASSETS["linux-x64"]).write_bytes(b"x" * (1024 * 1024))
            with self.assertRaises(ValueError):
                publish_direct.validate_package("linux-x64", directory)


class PublicationChecks(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {
            "GITHUB_REF_NAME": "v0.2.0",
            "GITHUB_REF": "refs/tags/v0.2.0",
            "GITHUB_REPOSITORY": "tlolabs/fillr",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.package = Path(self.directory.name) / publish_direct.ASSETS["windows-x64"]
        self.package.write_bytes(b"package")

    @patch("publish_direct.version", return_value="0.2.0")
    @patch("publish_direct.validate_package")
    @patch("publish_direct.digest", return_value="expected")
    @patch("publish_direct.verify_uploaded")
    @patch("publish_direct.release")
    @patch("publish_direct.gh")
    def test_uploads_only_to_prerelease_and_verifies_bytes(
            self, command, release, verify, digest, validate, version):
        validate.return_value = self.package
        release.side_effect = [None, {"tag_name": "v0.2.0", "name": "FILLR 0.2.0 unsigned downloads",
                                    "draft": True, "prerelease": True, "assets": []},
                               {"tag_name": "v0.2.0", "name": "FILLR 0.2.0 unsigned downloads",
                                "draft": True, "prerelease": True,
                                "assets": [{"name": self.package.name, "size": self.package.stat().st_size}]}]
        publish_direct.publish("windows-x64", Path(self.directory.name))
        self.assertEqual(command.call_count, 3)
        self.assertEqual(command.call_args_list[1].args[:3], ("release", "upload", "v0.2.0"))
        self.assertEqual(command.call_args.args[:3], ("release", "edit", "v0.2.0"))
        verify.assert_called_once_with("tlolabs/fillr", "v0.2.0", self.package, "expected")

    @patch("publish_direct.version", return_value="0.2.0")
    @patch("publish_direct.validate_package")
    @patch("publish_direct.digest", return_value="expected")
    @patch("publish_direct.verify_uploaded")
    @patch("publish_direct.release")
    @patch("publish_direct.gh")
    def test_existing_matching_asset_is_idempotent(
            self, command, release, verify, digest, validate, version):
        validate.return_value = self.package
        release.return_value = {"tag_name": "v0.2.0", "name": "FILLR 0.2.0 unsigned downloads",
                                "draft": False, "prerelease": True,
                                "assets": [{"name": self.package.name, "size": self.package.stat().st_size}]}
        publish_direct.publish("windows-x64", Path(self.directory.name))
        command.assert_not_called()
        verify.assert_called_once()

    @patch("publish_direct.version", return_value="0.2.0")
    @patch("publish_direct.validate_package")
    @patch("publish_direct.digest", return_value="expected")
    @patch("publish_direct.release", return_value={"tag_name": "v0.2.0", "name": "FILLR 0.2.0 unsigned downloads",
                                                      "draft": False, "prerelease": False, "assets": []})
    @patch("publish_direct.gh")
    def test_refuses_stable_release(self, command, release, digest, validate, version):
        validate.return_value = self.package
        with self.assertRaises(ValueError):
            publish_direct.publish("windows-x64", Path(self.directory.name))
        command.assert_not_called()


class FailureIssueChecks(unittest.TestCase):
    def test_tracks_main_and_tag_failures_separately(self):
        state = {"main": {"run_url": "https://example/main", "failed_jobs": ["security-audit"]},
                 "v0.2.0": {"run_url": "https://example/tag", "failed_jobs": ["windows-arm64"]}}
        self.assertEqual(report_ci_failures.read_state(report_ci_failures.render(state)), state)
        self.assertEqual(report_ci_failures.read_state("Latest run: https://example/main\n\nFailed jobs:\n- `macos`\n"),
                         {"main": {"run_url": "https://example/main", "failed_jobs": ["macos"]}})
        self.assertEqual(report_ci_failures.failed_jobs({"macos": {"result": "success"},
                                                        "linux": {"result": "failure"},
                                                        "publisher": {"result": "skipped"}}),
                         ["linux"])


if __name__ == "__main__":
    unittest.main()
