import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('weekly_package', Path(__file__).with_name('weekly_package.py'))
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, PACKAGE_TARGET='linux-x64', PACKAGE_TAG='v1.0.4', PACKAGE_SHA='a'*40, GITHUB_REPOSITORY='tlolabs/fillr')
        self.env.start()
        self.addCleanup(self.env.stop)

    def artifact(self):
        path = self.root / pkg.ASSETS['linux-x64']
        header = bytearray(20)
        header[:4] = b'\x7fELF'
        header[8:11] = b'AI\x02'
        header[18:20] = (62).to_bytes(2, 'little')
        path.write_bytes(header + b'x' * 1024*1024)
        digest = pkg.sha(path)
        (self.root / (path.name + '.sha256')).write_text(f'{digest}  {path.name}\n')
        (self.root / 'verification.json').write_text(json.dumps(dict(tag='v1.0.4', sha='a'*40, target='linux-x64', package=path.name, sha256=digest, runtime='passed')))
        return path

    def test_wrong_architecture_rejected(self):
        path = self.artifact()
        pkg.validate(path, 'linux-x64')
        with self.assertRaises(ValueError):
            pkg.validate(path, 'linux-arm64')

    def test_no_api_call_with_bad_receipt(self):
        self.artifact()
        (self.root/'verification.json').write_text('{}')
        with patch.object(pkg, 'gh') as gh, self.assertRaises(ValueError):
            pkg.publish(self.root)
        gh.assert_not_called()

    def test_moved_tag_rejected(self):
        self.artifact()
        with patch.object(pkg, 'gh', return_value=json.dumps({'sha':'b'*40})) as gh, self.assertRaisesRegex(ValueError, 'tag changed'):
            pkg.publish(self.root)
        self.assertEqual(gh.call_count, 1)

    def test_missing_release_does_not_create(self):
        self.artifact()
        with patch.object(pkg, 'gh', side_effect=[json.dumps({'sha':'a'*40}), RuntimeError('404')]) as gh, self.assertRaises(RuntimeError):
            pkg.publish(self.root)
        self.assertTrue(all(call.args[0] == 'api' for call in gh.call_args_list))

    def test_publishes_only_missing_assets_and_verifies_downloads(self):
        self.artifact()
        def fake(*args):
            if args[0] == 'api':
                if '/commits/' in args[1]: return json.dumps({'sha':'a'*40})
                return json.dumps({'draft':False, 'tag_name':'v1.0.4', 'prerelease':False, 'assets':[]})
            if args[:2] == ('release', 'download'):
                name=args[args.index('--pattern')+1]
                destination=Path(args[args.index('--dir')+1])/name
                destination.write_bytes((self.root/name).read_bytes())
            return ''
        with patch.object(pkg, 'gh', side_effect=fake) as gh:
            pkg.publish(self.root)
        operations=[call.args[:2] for call in gh.call_args_list]
        self.assertEqual(operations.count(('release','upload')), 3)
        self.assertNotIn(('release','edit'), operations)
        self.assertNotIn(('release','create'), operations)
        self.assertFalse(any('--clobber' in call.args for call in gh.call_args_list))

    def test_existing_different_bytes_never_overwritten(self):
        path=self.artifact()
        def fake(*args):
            if args[0]=='api':
                if '/commits/' in args[1]: return json.dumps({'sha':'a'*40})
                return json.dumps({'draft':False, 'tag_name':'v1.0.4', 'prerelease':False,'assets':[{'name':path.name}]})
            if args[:2]==('release','download'):
                (Path(args[args.index('--dir')+1])/path.name).write_bytes(b'different')
            return ''
        with patch.object(pkg, 'gh', side_effect=fake) as gh, self.assertRaisesRegex(ValueError,'bytes differ'):
            pkg.publish(self.root)
        self.assertFalse(any(call.args[:2]==('release','upload') for call in gh.call_args_list))

    def test_unsigned_windows_cannot_enter_stable_release(self):
        path=self.artifact()
        windows_name=pkg.ASSETS['windows-x64']
        path.rename(self.root/windows_name)
        (self.root/(path.name+'.sha256')).rename(self.root/(windows_name+'.sha256'))
        (self.root/(windows_name+'.sha256')).write_text(f'{pkg.sha(self.root/windows_name)}  {windows_name}\n')
        evidence=json.loads((self.root/'verification.json').read_text())
        evidence.update(target='windows-x64', package=windows_name)
        (self.root/'verification.json').write_text(json.dumps(evidence))
        with patch.dict(os.environ, PACKAGE_TARGET='windows-x64'), patch.object(pkg, 'validate'), patch.object(pkg, 'gh', side_effect=[json.dumps({'sha':'a'*40}), json.dumps({'draft':False, 'tag_name':'v1.0.4', 'name':'FILLR 1.0.4', 'prerelease':False, 'assets':[]})]) as gh, self.assertRaisesRegex(ValueError, 'Unsigned Windows'):
            pkg.publish(self.root)
        self.assertEqual(gh.call_count, 2)


if __name__ == '__main__': unittest.main()
