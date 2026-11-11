#!/usr/bin/env python3
"""Developer ID preflight, inside-out signing, and verified Apple notarization.

Uses existing Keychain identities/profiles only. It never enrolls credentials,
changes security settings, launches applications, or publishes releases.
"""
import argparse
import json
import re
from pathlib import Path
import subprocess
import tempfile

MACHO_MAGIC = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def run(*args, capture=False, combine=False):
    result = subprocess.run([str(arg) for arg in args], check=True, text=True,
                            capture_output=capture)
    return (result.stdout + (result.stderr if combine else '')) if capture else ''


def preflight(identity, profile=None):
    if not identity or not identity.startswith('Developer ID Application: '):
        raise ValueError('Set a Developer ID Application signing identity; ad-hoc/Development identities are not distributable.')
    if f'"{identity}"' not in run('security', 'find-identity', '-v', '-p', 'codesigning', capture=True):
        raise ValueError('The requested Developer ID Application identity is not available in Keychain.')
    if profile is not None:
        if not profile:
            raise ValueError('Set NOTARY_PROFILE to an existing notarytool Keychain profile; no unsigned fallback is permitted.')
        # Read-only authentication check before expensive compilation or staging.
        run('xcrun', 'notarytool', 'history', '--keychain-profile', profile,
            '--output-format', 'json', capture=True)


def sign_bundle(bundle, identity):
    bundle = Path(bundle)
    if bundle.suffix != '.app' or not (bundle / 'Contents/Info.plist').is_file():
        raise ValueError('Expected a staged macOS .app bundle.')
    targets = []
    for path in bundle.rglob('*'):
        if path.is_symlink():
            continue
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO_MAGIC:
                    targets.append(path)
        elif path.is_dir() and path.suffix in {'.app', '.framework', '.xpc', '.plugin', '.bundle'}:
            targets.append(path)
    # Children before containers; never use --deep to perform signing.
    for path in sorted(targets, key=lambda item: (-len(item.parts), str(item))) + [bundle]:
        run('codesign', '--force', '--timestamp', '--options', 'runtime',
            '--preserve-metadata=entitlements', '--sign', identity, path)
    run('codesign', '--verify', '--deep', '--strict', bundle)


def notarize(bundle, profile, report):
    bundle = Path(bundle)
    if not profile:
        raise ValueError('An existing notarytool Keychain profile is required.')
    if bundle.suffix != '.app' or not (bundle / 'Contents/Info.plist').is_file():
        raise ValueError('Expected a signed macOS .app bundle.')
    run('codesign', '--verify', '--deep', '--strict', bundle)
    details = run('codesign', '-d', '--verbose=4', bundle, capture=True, combine=True)
    if not re.search(r'^Authority=Developer ID Application:', details, re.M) or not re.search(
            r'^CodeDirectory\b[^\n]*flags=0x[0-9a-fA-F]+\([^\n)]*\bruntime\b', details, re.M):
        raise ValueError('Developer ID signing and hardened runtime are required before notarization.')
    with tempfile.TemporaryDirectory(prefix='macos-notary-') as temporary:
        archive = Path(temporary) / 'submission.zip'
        run('ditto', '-c', '-k', '--keepParent', bundle, archive)
        response = run('xcrun', 'notarytool', 'submit', archive, '--keychain-profile', profile,
                       '--wait', '--output-format', 'json', capture=True)
        Path(report).write_text(response)
        result = json.loads(response)
        if result.get('status') != 'Accepted':
            raise ValueError(f'Apple notarization was not Accepted; inspect {report}.')
    run('xcrun', 'stapler', 'staple', bundle)
    run('xcrun', 'stapler', 'validate', bundle)
    run('codesign', '--verify', '--deep', '--strict', bundle)
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', bundle)


def verify_archive(archive):
    """Validate the app actually delivered in the final ZIP, not just staging."""
    with tempfile.TemporaryDirectory(prefix='macos-final-archive-') as temporary:
        destination = Path(temporary)
        run('ditto', '-x', '-k', archive, destination)
        bundles = [path for path in destination.iterdir() if path.is_dir() and path.suffix == '.app']
        if len(bundles) != 1:
            raise ValueError('Final archive must contain exactly one top-level macOS app.')
        bundle = bundles[0]
        run('codesign', '--verify', '--deep', '--strict', bundle)
        details = run('codesign', '-d', '--verbose=4', bundle, capture=True, combine=True)
        if not re.search(r'^Authority=Developer ID Application:', details, re.M) or not re.search(
                r'^CodeDirectory\b[^\n]*flags=0x[0-9a-fA-F]+\([^\n)]*\bruntime\b', details, re.M):
            raise ValueError('Final archive lacks Developer ID signing or hardened runtime.')
        run('xcrun', 'stapler', 'validate', bundle)
        run('spctl', '--assess', '--type', 'execute', '--verbose=2', bundle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('preflight')
    check.add_argument('--identity', required=True)
    check.add_argument('--profile')
    sign = commands.add_parser('sign')
    sign.add_argument('bundle')
    sign.add_argument('--identity', required=True)
    notary = commands.add_parser('notarize')
    notary.add_argument('bundle')
    notary.add_argument('--profile', required=True)
    notary.add_argument('--report', required=True)
    verify = commands.add_parser('verify-archive')
    verify.add_argument('archive')
    args = parser.parse_args()
    try:
        if args.command == 'preflight': preflight(args.identity, args.profile)
        elif args.command == 'sign': sign_bundle(args.bundle, args.identity)
        elif args.command == 'notarize': notarize(args.bundle, args.profile, args.report)
        else: verify_archive(args.archive)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Notarization failed: {error}\n')


if __name__ == '__main__':
    main()
