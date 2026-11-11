#!/usr/bin/env python3
"""Embed public trust and version in generated native build metadata; never create keys."""
import argparse, base64, json, pathlib, plistlib
from version import ROOT, version

def configure_plist(path, production, local_only=False):
    if production and local_only:
        raise ValueError("Production and local-only update modes are mutually exclusive")
    trust = json.loads((ROOT / 'updates/trust.json').read_text())
    with path.open('rb') as f: data = plistlib.load(f)
    identity = trust['identities']['macos']
    if trust['app_id'] != identity or data.get('CFBundleIdentifier') != identity:
        raise ValueError('macOS bundle identifier does not match FILLR update trust')
    data['CFBundleShortVersionString'] = data['CFBundleVersion'] = version()
    if local_only:
        # A notarized local build is not an authenticated updater release. Never
        # retain stale feed/key metadata when reusing a generated plist.
        for key in ('SUPublicEDKey', 'SUFeedURL', 'SURequireSignedFeed',
                    'SUSignedFeedFailureExpirationInterval', 'SUVerifyUpdateBeforeExtraction',
                    'SUScheduledCheckInterval'):
            data.pop(key, None)
        data.update(SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                    SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False)
        with path.open('wb') as f: plistlib.dump(data, f)
        return
    keys = trust['keys']
    if production and not keys: raise ValueError('Configure a FILLR public update key before producing an update-enabled release')
    if keys:
        if len(keys) != 1: raise ValueError('Sparkle key rotation requires an explicit bridge release')
        key = next(iter(keys.values()))
        if len(base64.b64decode(key, validate=True)) != 32: raise ValueError('Invalid public update key')
        data.update(SUPublicEDKey=key, SUFeedURL='https://github.com/' + trust['repository'] + '/releases/latest/download/appcast.xml',
                    SURequireSignedFeed=True, SUSignedFeedFailureExpirationInterval=0, SUVerifyUpdateBeforeExtraction=True,
                    SUEnableAutomaticChecks=True, SUScheduledCheckInterval=86400,
                    SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False)
    with path.open('wb') as f: plistlib.dump(data, f)
if __name__ == '__main__':
    p=argparse.ArgumentParser(); p.add_argument('plist',type=pathlib.Path)
    mode=p.add_mutually_exclusive_group()
    mode.add_argument('--production',action='store_true')
    mode.add_argument('--local-only',action='store_true')
    a=p.parse_args()
    configure_plist(a.plist,a.production,a.local_only)
