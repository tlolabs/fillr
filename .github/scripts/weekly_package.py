#!/usr/bin/env python3
"""Stage checked direct downloads and attach them without touching release metadata."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zipfile

ASSETS = {'linux-x64': 'FILLR-linux-x86_64.AppImage', 'linux-arm64': 'FILLR-linux-aarch64.AppImage',
          'windows-x64': 'FILLR-win-x64-unsigned.zip', 'windows-arm64': 'FILLR-win-arm64-unsigned.zip'}


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate(path, target):
    if path.is_symlink() or not path.is_file() or path.stat().st_size < 1024 * 1024:
        raise ValueError('Missing, linked or undersized package')
    if target.startswith('linux'):
        with path.open('rb') as stream:
            header = stream.read(20)
        machine = 183 if target.endswith('arm64') else 62
        if header[:4] != b'\x7fELF' or header[8:11] != b'AI\x02' or int.from_bytes(header[18:20], 'little') != machine:
            raise ValueError('Invalid AppImage architecture/header')
    else:
        with zipfile.ZipFile(path) as archive:
            if archive.testzip() or any(n.startswith(('/', '\\')) or '..' in n.replace('\\', '/').split('/') for n in archive.namelist()):
                raise ValueError('Invalid ZIP')
            for name in ('FILLR.exe', 'fillr_core.dll', 'fillr-update.exe', 'ffprobe.exe'):
                data = archive.read(name)
                offset = struct.unpack_from('<I', data, 0x3c)[0]
                expected = 0xaa64 if target.endswith('arm64') else 0x8664
                if data[:2] != b'MZ' or data[offset:offset+4] != b'PE\0\0' or struct.unpack_from('<H', data, offset+4)[0] != expected:
                    raise ValueError('Incorrect PE architecture: ' + name)


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def context():
    target, tag, commit = (os.environ[k] for k in ('PACKAGE_TARGET', 'PACKAGE_TAG', 'PACKAGE_SHA'))
    if target not in ASSETS or not re.fullmatch(r'v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?', tag) or not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise ValueError('Invalid trusted package context')
    return target, tag, commit


def stage(source, destination):
    import shutil
    target, tag, commit = context()
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    version = subprocess.check_output(['python3', str(source / 'script/version.py')], text=True).strip()
    if actual != commit or tag != 'v' + version:
        raise ValueError('Source tag/version mismatch')
    package = source / 'dist' / ASSETS[target]
    validate(package, target)
    destination.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(package, destination / package.name)
    digest = sha(package)
    (destination / (package.name + '.sha256')).write_text(f'{digest}  {package.name}\n')
    (destination / 'verification.json').write_text(json.dumps({'tag': tag, 'sha': commit, 'target': target,
        'package': package.name, 'sha256': digest, 'runtime': 'passed', 'manual_testing': 'not_performed',
        'distribution': 'direct download; not an authenticated update'}, indent=2) + '\n')


def publish(directory):
    target, tag, commit = context()
    repo = os.environ['GITHUB_REPOSITORY']
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', repo):
        raise ValueError('Invalid repository')
    package = directory / ASSETS[target]
    checksum = directory / (package.name + '.sha256')
    receipt = directory / 'verification.json'
    if set(directory.iterdir()) != {package, checksum, receipt} or any(p.is_symlink() for p in directory.iterdir()):
        raise ValueError('Unexpected artifact contents')
    validate(package, target)
    digest = sha(package)
    evidence = json.loads(receipt.read_text())
    for key, expected in {'tag': tag, 'sha': commit, 'target': target, 'package': package.name, 'sha256': digest, 'runtime': 'passed'}.items():
        if evidence.get(key) != expected:
            raise ValueError('Artifact evidence mismatch: ' + key)
    if checksum.read_text() != f'{digest}  {package.name}\n':
        raise ValueError('Checksum mismatch')
    actual = json.loads(gh('api', f'repos/{repo}/commits/{tag}'))['sha']
    if actual != commit:
        raise ValueError('Remote tag changed')
    release = json.loads(gh('api', f'repos/{repo}/releases/tags/{tag}'))
    if release['draft'] or release['tag_name'] != tag:
        raise ValueError('Requires existing published release for exact tag')
    if target.startswith('windows') and (not release['prerelease'] or release['name'] != f'FILLR {tag[1:]} unsigned downloads'):
        raise ValueError('Unsigned Windows requires existing unsigned-download prerelease channel; production signing required otherwise')
    # Unique target-scoped evidence names; do not edit shared release notes or Latest.
    evidence_file = directory / f'FILLR-{tag}-{target}-verification.json'
    evidence_file.write_bytes(receipt.read_bytes())
    for file in (package, checksum, evidence_file):
        current = json.loads(gh('api', f'repos/{repo}/releases/tags/{tag}'))
        assets = [a for a in current['assets'] if a['name'] == file.name]
        if not assets:
            gh('release', 'upload', tag, str(file), '--repo', repo)
        with tempfile.TemporaryDirectory() as temp:
            gh('release', 'download', tag, '--repo', repo, '--pattern', file.name, '--dir', temp)
            if sha(Path(temp) / file.name) != sha(file):
                raise ValueError('Existing/uploaded bytes differ: ' + file.name)
    print(f'Published verified {target}: {digest}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['stage', 'publish'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    if args.command == 'stage':
        stage(args.source.resolve(), args.directory)
    else:
        publish(args.directory)
