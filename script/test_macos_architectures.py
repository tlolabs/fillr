import pathlib
import subprocess
import unittest
from unittest.mock import call, patch

from verify_macos_update import verify_universal_architectures


class MacArchitectureTests(unittest.TestCase):
    def test_verifier_checks_both_architectures_separately(self):
        with patch('verify_macos_update.subprocess.run') as run:
            verify_universal_architectures('/tmp/test binary')
        self.assertEqual(run.call_args_list, [
            call(['lipo', '/tmp/test binary', '-verify_arch', arch], check=True)
            for arch in ('arm64', 'x86_64')])

    def test_verifier_rejects_either_missing_architecture(self):
        for missing in ('arm64', 'x86_64'):
            def lipo(args, **kwargs):
                if args[-1] == missing:
                    raise subprocess.CalledProcessError(1, args)
            with self.subTest(missing=missing), patch('verify_macos_update.subprocess.run', side_effect=lipo):
                with self.assertRaises(subprocess.CalledProcessError):
                    verify_universal_architectures('/tmp/test binary')

    def release_check(self, missing=''):
        source = pathlib.Path(__file__).with_name('release_macos.sh').read_text()
        # Exercise the production architecture loop, not build/sign/publish commands.
        block = source.split('for binary in ', 1)[1].split('\n\n', 1)[0]
        script = '''set -euo pipefail
CONTENTS='/tmp/synthetic bundle/Contents'
APP_NAME=FILLR
missing="$1"
lipo() {
  [[ "$#" == 3 && "$2" == -verify_arch ]] || return 98
  printf '%s\\n' "$3"
  [[ "$3" != "$missing" ]]
}
''' + 'for binary in ' + block
        return subprocess.run(['bash', '-c', script, 'test', missing], capture_output=True, text=True)

    def test_release_checks_both_architectures_for_all_binaries(self):
        result = self.release_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['arm64', 'x86_64'] * 3)

    def test_release_rejects_either_missing_architecture(self):
        for missing in ('arm64', 'x86_64'):
            with self.subTest(missing=missing):
                self.assertNotEqual(self.release_check(missing).returncode, 0)
