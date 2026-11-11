#!/usr/bin/env python3
"""Offline tests. Never invoke Apple, Keychain, codesign, or build tools."""
import importlib.util
import json
import base64
import plistlib
import configure_updates
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('notary', ROOT / 'script/notarize_macos.py')
notary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notary)
IDENTITY = 'Developer ID Application: Example (ABCDE12345)'


class NotaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Example.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_text('test')
        (self.app / 'Contents/MacOS/Example').write_bytes(bytes.fromhex('cffaedfe'))
        self.report = Path(self.temp.name) / 'report.json'
        self.calls = []

    def fake(self, *args, **kwargs):
        self.calls.append(args)
        if args[:2] == ('codesign', '-d'):
            return 'Authority=Developer ID Application: Example\nCodeDirectory v=20500 flags=0x10000(runtime)\n'
        if args[:3] == ('xcrun', 'notarytool', 'submit'):
            return json.dumps({'status': 'Accepted', 'id': 'submission-id'})
        if args[:2] == ('security', 'find-identity'):
            return f'1) 1234 "{IDENTITY}"\n'
        return ''

    def test_preflight_checks_identity_and_profile_without_storing(self):
        with patch.object(notary, 'run', side_effect=self.fake):
            notary.preflight(IDENTITY, 'existing-profile')
        self.assertEqual(self.calls[-1][:3], ('xcrun', 'notarytool', 'history'))
        self.assertFalse(any('store-credentials' in call for call in self.calls))

    def test_missing_or_wrong_identity_rejected_before_network(self):
        for value in ['', '-', 'Apple Development: Example']:
            with patch.object(notary, 'run') as runner, self.assertRaises(ValueError):
                notary.preflight(value, 'profile')
            runner.assert_not_called()

    def test_missing_profile_and_identity_rejected(self):
        with patch.object(notary, 'run', side_effect=self.fake), self.assertRaises(ValueError):
            notary.preflight(IDENTITY, '')
        self.assertEqual(len(self.calls), 1)
        with patch.object(notary, 'run', return_value=''), self.assertRaises(ValueError):
            notary.preflight(IDENTITY, 'profile')

    def test_accepted_then_staple_validate_signature_gatekeeper(self):
        with patch.object(notary, 'run', side_effect=self.fake):
            notary.notarize(self.app, 'profile', self.report)
        self.assertEqual(json.loads(self.report.read_text())['status'], 'Accepted')
        names = [call[:3] for call in self.calls]
        submit = names.index(('xcrun', 'notarytool', 'submit'))
        staple = names.index(('xcrun', 'stapler', 'staple'))
        validate = names.index(('xcrun', 'stapler', 'validate'))
        gatekeeper = names.index(('spctl', '--assess', '--type'))
        self.assertLess(submit, staple)
        self.assertLess(staple, validate)
        self.assertLess(validate, gatekeeper)
        self.assertFalse(any('--deep' in call and '--sign' in call for call in self.calls))

    def test_invalid_or_pending_never_staples(self):
        for status in ['Invalid', 'In Progress', None]:
            self.calls.clear()
            def fake(*args, **kwargs):
                if args[:3] == ('xcrun', 'notarytool', 'submit'):
                    return json.dumps({'status': status})
                return self.fake(*args, **kwargs)
            with patch.object(notary, 'run', side_effect=fake), self.assertRaises(ValueError):
                notary.notarize(self.app, 'profile', self.report)
            self.assertFalse(any('stapler' in call for call in self.calls))

    def test_not_developer_id_never_submits(self):
        with patch.object(notary, 'run', return_value='Signature=adhoc'), self.assertRaises(ValueError):
            notary.notarize(self.app, 'profile', self.report)
        self.assertFalse(self.report.exists())

    def test_runtime_word_outside_flags_is_not_hardened_runtime(self):
        details = 'Executable=/tmp/runtime/Example\nAuthority=Developer ID Application: Example\nCodeDirectory v=20500 flags=0x0(none)\n'
        with patch.object(notary, 'run', return_value=details), self.assertRaises(ValueError):
            notary.notarize(self.app, 'profile', self.report)
        self.assertFalse(self.report.exists())

    def test_failed_staple_validation_never_passes_gatekeeper(self):
        def fake(*args, **kwargs):
            if args[:3] == ('xcrun', 'stapler', 'validate'):
                raise subprocess.CalledProcessError(1, args)
            return self.fake(*args, **kwargs)
        with patch.object(notary, 'run', side_effect=fake), self.assertRaises(subprocess.CalledProcessError):
            notary.notarize(self.app, 'profile', self.report)
        self.assertFalse(any(call[0] == 'spctl' for call in self.calls))

    def test_signing_is_inside_out_and_skips_resource_data_and_symlinks(self):
        framework = self.app / 'Contents/Frameworks/Example.framework'
        binary = framework / 'Versions/A/Example'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(bytes.fromhex('cffaedfe'))
        (framework / 'Example').symlink_to('Versions/A/Example')
        (self.app / 'Contents/resource.txt').write_text('not executable')
        with patch.object(notary, 'run', side_effect=self.fake):
            notary.sign_bundle(self.app, IDENTITY)
        signed = [call[-1] for call in self.calls if '--sign' in call]
        self.assertLess(signed.index(binary), signed.index(framework))
        self.assertEqual(signed[-1], self.app)
        self.assertNotIn(framework / 'Example', signed)
        self.assertFalse(any('--deep' in call and '--sign' in call for call in self.calls))

    def test_json_capture_does_not_mix_stderr_progress(self):
        completed = subprocess.CompletedProcess([], 0, '{"status":"Accepted"}', 'progress\n')
        with patch.object(notary.subprocess, 'run', return_value=completed):
            self.assertEqual(json.loads(notary.run('tool', capture=True))['status'], 'Accepted')
            self.assertIn('progress', notary.run('tool', capture=True, combine=True))

    def test_final_archive_validates_extracted_app(self):
        def fake(*args, **kwargs):
            if args[:3] == ('ditto', '-x', '-k'):
                (Path(args[-1]) / 'Delivered.app').mkdir()
            return self.fake(*args, **kwargs)
        with patch.object(notary, 'run', side_effect=fake):
            notary.verify_archive('final.zip')
        extracted = [call[-1] for call in self.calls if call[:3] == ('xcrun', 'stapler', 'validate')][0]
        self.assertEqual(extracted.name, 'Delivered.app')
        self.assertNotEqual(extracted, self.app)
        self.assertTrue(any(call[0] == 'spctl' and call[-1] == extracted for call in self.calls))

    def test_final_archive_without_one_app_is_rejected(self):
        with patch.object(notary, 'run', return_value=''), self.assertRaises(ValueError):
            notary.verify_archive('empty.zip')

    def test_distributable_default_preflight_precedes_build_or_stage(self):
        path = ROOT / 'script/release_macos.sh'
        if path.exists():
            source = path.read_text()
            self.assertIn('MODE="${1:-signed}"', source)
            self.assertLess(source.index('preflight='), source.index('build_ffprobe_macos.sh'))
            self.assertIn('signed-unnotarized.zip', source)
        else:
            source = (ROOT / 'script/package_app.sh').read_text()
            self.assertIn('mode="${2:-signed}"', source)
            self.assertLess(source.index('notarize_macos.py preflight'), source.index('mkdir -p'))
            dev = (ROOT / 'script/build_and_run.sh').read_text()
            self.assertIn('package_app.sh "$app" --development', dev)
            self.assertIn('dist/development/$app_name.app', dev)


class LocalUpdateSeparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'updates').mkdir()
        self.trust = {'app_id': 'com.tlolabs.fillr',
                      'identities': {'macos': 'com.tlolabs.fillr'},
                      'repository': 'tlolabs/fillr', 'keys': {}}
        self.info = self.root / 'Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.tlolabs.fillr',
                                              'SUPublicEDKey': 'stale', 'SUFeedURL': 'stale'}))

    def configure(self, production=False, local_only=False):
        (self.root / 'updates/trust.json').write_text(json.dumps(self.trust))
        with patch.object(configure_updates, 'ROOT', self.root), patch.object(configure_updates, 'version', return_value='1.2.3'):
            configure_updates.configure_plist(self.info, production, local_only)
        return plistlib.loads(self.info.read_bytes())

    def test_local_notarization_needs_no_update_key(self):
        result = self.configure(local_only=True)
        self.assertNotIn('SUPublicEDKey', result)
        self.assertNotIn('SUFeedURL', result)
        self.assertFalse(result['SUEnableAutomaticChecks'])
        self.assertFalse(result['SUAllowsAutomaticUpdates'])

    def test_local_mode_does_not_enable_enrolled_feed(self):
        self.trust['keys'] = {'one': base64.b64encode(bytes(32)).decode()}
        result = self.configure(local_only=True)
        self.assertNotIn('SUPublicEDKey', result)
        self.assertFalse(result['SUEnableAutomaticChecks'])

    def test_production_still_requires_valid_update_key(self):
        with self.assertRaises(ValueError): self.configure(production=True)
        self.trust['keys'] = {'one': 'invalid'}
        with self.assertRaises(ValueError): self.configure(production=True)

    def test_production_retains_signed_feed_and_download_verification(self):
        self.trust['keys'] = {'one': base64.b64encode(bytes(32)).decode()}
        result = self.configure(production=True)
        self.assertTrue(result['SURequireSignedFeed'])
        self.assertTrue(result['SUVerifyUpdateBeforeExtraction'])
        self.assertEqual(result['SUSignedFeedFailureExpirationInterval'], 0)
        self.assertTrue(result['SUEnableAutomaticChecks'])
        self.assertFalse(result['SUAutomaticallyUpdate'])
        self.assertFalse(result['SUAllowsAutomaticUpdates'])

    def test_conflicting_modes_rejected(self):
        with self.assertRaises(ValueError): self.configure(production=True, local_only=True)

    def test_release_routes_local_and_production_explicitly(self):
        source = (ROOT / 'script/release_macos.sh').read_text()
        self.assertIn('UPDATE_MODE=local-only', source)
        self.assertIn('if [[ "$MODE" == --production ]]; then MODE=signed; UPDATE_MODE=production; fi', source)
        self.assertIn('Info.plist" "--$UPDATE_MODE"', source)
        self.assertNotIn('Info.plist" --production', source)
        self.assertIn('FILLR-universal-local-notarized.zip', source)
        self.assertIn('FILLR-universal-signed.zip', source)


if __name__ == '__main__':
    unittest.main()
