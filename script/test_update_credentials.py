"""Credential-file lifecycle tests use dummy bytes and never invoke Keychain tools."""
import base64
import os
import pathlib
import runpy
import stat
import tempfile
import types
import unittest
from unittest.mock import patch
from version import ROOT


class CredentialStagingTests(unittest.TestCase):
    def environment(self, directory):
        return dict(RUNNER_TEMP=directory, MACOS_CERTIFICATE_P12_B64=base64.b64encode(b'fixture').decode(),
                    MACOS_CERTIFICATE_PASSWORD='test-only', APPLE_ID='test@example.test',
                    APPLE_APP_PASSWORD='test-only')

    def test_certificate_is_private_before_any_command_and_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'fillr-signing.p12'
            def command(*args, **kwargs):
                self.assertEqual(path.read_bytes(), b'fixture')
                if os.name == 'posix':
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                return types.SimpleNamespace(returncode=0)
            with patch.dict(os.environ, self.environment(directory)), patch('subprocess.run', side_effect=command) as runner:
                runpy.run_path(str(ROOT / 'script/ci_macos_credentials.py'))
                self.assertGreater(runner.call_count, 0)
            self.assertFalse(path.exists())

    def test_preexisting_path_is_neither_overwritten_nor_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'fillr-signing.p12'
            path.write_bytes(b'preexisting')
            with patch.dict(os.environ, self.environment(directory)), patch('subprocess.run') as runner:
                with self.assertRaises(FileExistsError):
                    runpy.run_path(str(ROOT / 'script/ci_macos_credentials.py'))
                runner.assert_not_called()
            self.assertEqual(path.read_bytes(), b'preexisting')
