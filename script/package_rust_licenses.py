#!/usr/bin/env python3
"""Collect notices from the exact locked, target-selected Cargo source graph."""
import argparse
import json
import pathlib
import subprocess

PREFIXES = ('LICENSE', 'LICENCE', 'COPYING', 'COPYRIGHT', 'NOTICE')


def collect(manifests, target):
    packages = {}
    for manifest in manifests:
        metadata = json.loads(subprocess.check_output([
            'cargo', 'metadata', '--locked', '--format-version', '1',
            '--manifest-path', str(manifest), '--filter-platform', target]))
        by_id = {p['id']: p for p in metadata['packages']}
        nodes = {n['id']: n for n in metadata['resolve']['nodes']}
        pending = list(metadata['workspace_members'])
        seen = set()
        while pending:
            item = pending.pop()
            if item in seen:
                continue
            seen.add(item)
            package = by_id[item]
            if package['source']:
                packages[item] = package
            pending.extend(d['pkg'] for d in nodes[item]['deps']
                           if any(k['kind'] != 'dev' for k in d['dep_kinds']))
    sections = ['FILLR Rust dependency notices\nTarget: ' + target + '\n'
                'Generated from the locked normal/build dependency graph; may include build tools.\n']
    for package in sorted(packages.values(), key=lambda p: (p['name'], p['version'])):
        root = pathlib.Path(package['manifest_path']).parent
        notices = sorted(p for p in root.rglob('*') if p.is_file()
                         and p.name.upper().startswith(PREFIXES))
        if package.get('license_file'):
            license_file = root / package['license_file']
            if license_file not in notices:
                notices.append(license_file)
        if not notices or not package.get('license') and not package.get('license_file'):
            raise ValueError('Missing license declaration/text: ' + package['name'])
        sections.append('\n' + '=' * 72 + '\n' + package['name'] + ' ' + package['version']
                        + '\nLicense expression: ' + (package['license'] or 'See license file')
                        + '\nSource: ' + (package.get('repository') or package['source']) + '\n')
        for notice in notices:
            sections.append('\n--- ' + str(notice.relative_to(root)) + ' ---\n'
                            + notice.read_text(encoding='utf-8'))
    return '\n'.join(sections)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', type=pathlib.Path, action='append', required=True)
    parser.add_argument('--target')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    target = args.target or next(line.removeprefix('host: ') for line in
                                subprocess.check_output(['rustc', '-vV'], text=True).splitlines()
                                if line.startswith('host: '))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(collect(args.manifest, target), encoding='utf-8')

    sysroot = pathlib.Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip())
    runtime_notice = sysroot / 'share/doc/rust/COPYRIGHT-library.html'
    if not runtime_notice.is_file():
        runtime_notice = sysroot / 'share/doc/rust/COPYRIGHT.html'
    if not runtime_notice.is_file():
        raise ValueError('Rust toolchain is missing its runtime copyright/license notice')
    args.output.with_name('Rust-runtime-COPYRIGHT.html').write_bytes(runtime_notice.read_bytes())
