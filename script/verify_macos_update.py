#!/usr/bin/env python3
"""Validate the final extracted, stapled ZIP and record native signing evidence."""
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
from version import ROOT, version
from release_updates import digest, trust


def verify_bundle_metadata(info, release_version, configured_trust):
    expected = {
        'CFBundleIdentifier': configured_trust['app_id'],
        'CFBundleVersion': release_version,
        'CFBundleShortVersionString': release_version,
        'CFBundleExecutable': 'FILLR',
        'SUFeedURL': 'https://github.com/' + configured_trust['repository'] + '/releases/latest/download/appcast.xml',
        'SURequireSignedFeed': True,
        'SUSignedFeedFailureExpirationInterval': 0,
        'SUVerifyUpdateBeforeExtraction': True,
        'SUAutomaticallyUpdate': False,
        'SUAllowsAutomaticUpdates': False,
        'SUEnableSystemProfiling': False,
    }
    keys = list(configured_trust['keys'].values())
    if len(keys) != 1:
        raise ValueError('Exactly one production Sparkle key is required')
    expected['SUPublicEDKey'] = keys[0]
    for key, value in expected.items():
        if key not in info or type(info[key]) is not type(value) or info[key] != value:
            raise ValueError('Bundle production metadata mismatch: ' + key)


def main():
    v = version()
    t = trust()
    security = json.loads((ROOT / 'updates/platform-security.json').read_text())
    source = ROOT / 'dist/FILLR-universal-signed.zip'
    output = ROOT / f'dist/FILLR-{v}-macos-universal.zip'
    shutil.copy2(source, output)
    with tempfile.TemporaryDirectory() as temp:
        subprocess.run(['ditto', '-x', '-k', str(output), temp], check=True)
        app = pathlib.Path(temp) / 'FILLR.app'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
        subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)], check=True)
        framework = app / 'Contents/Frameworks/Sparkle.framework/Versions/B'
        components = [app / 'Contents/MacOS/FILLR', app / 'Contents/Frameworks/libfillr_core.dylib',
                      app / 'Contents/Resources/ffprobe', framework / 'Sparkle', framework / 'Autoupdate',
                      framework / 'Updater.app/Contents/MacOS/Updater',
                      framework / 'XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
                      framework / 'XPCServices/Installer.xpc/Contents/MacOS/Installer']
        for component in components:
            subprocess.run(['lipo', str(component), '-verify_arch', 'arm64', 'x86_64'], check=True)
            subprocess.run(['codesign', '--verify', '--strict', str(component)], check=True)
            detail = subprocess.run(['codesign', '-dv', '--verbose=4', str(component)],
                                    capture_output=True, text=True, check=True).stderr
            if ('TeamIdentifier=' + security['macos_team_id'] not in detail
                    or 'Authority=Developer ID Application:' not in detail or 'runtime' not in detail):
                raise ValueError('Developer ID identity/hardened runtime mismatch: ' + str(component))
        with (app / 'Contents/Info.plist').open('rb') as f:
            verify_bundle_metadata(plistlib.load(f), v, t)
    evidence = dict(schema=1, platform='macos', architecture='universal', version=v,
                    filename=output.name, sha256=digest(output), identity=t['identities']['macos'],
                    signature_verified=True, installed_upgrade_verified=False)
    output.with_name(output.name + '.verified.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()
