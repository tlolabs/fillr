#!/usr/bin/env python3
"""Fail closed on unreviewed NuGet licenses; ship notices from the locked graph."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

MIT = '''Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'''

def collect(assets):
    graph = json.loads(assets.read_text())
    roots = [Path(p) for p in graph['packageFolders']]
    result = []
    for name, spec in sorted(graph['libraries'].items()):
        if spec['type'] != 'package':
            continue
        package = next((root / spec['path'] for root in roots if (root / spec['path']).is_dir()), None)
        if package is None:
            raise ValueError('Missing restored package: ' + name)
        metadata = ET.parse(next(package.glob('*.nuspec')))
        license_node = metadata.find('.//{*}license')
        if license_node is None:
            raise ValueError('Missing license declaration: ' + name)
        expression = license_node.text
        if license_node.get('type') == 'expression' and expression != 'MIT':
            raise ValueError('Unreviewed license expression: ' + name + ': ' + str(expression))
        if license_node.get('type') == 'file' and not name.startswith('Avalonia.Angle.Windows.Natives/'):
            raise ValueError('Unreviewed embedded license: ' + name)
        files = [p for p in package.iterdir() if p.is_file() and any(term in p.name.lower() for term in ('license', 'notice', 'copying', 'copyright'))]
        if license_node.get('type') == 'file' and not (package / expression).is_file():
            raise ValueError('Declared license missing: ' + name)
        text = '\n\n'.join(p.name + '\n' + p.read_text(errors='strict') for p in sorted(files))
        if not text:
            copyright_text = metadata.findtext('.//{*}copyright')
            if not copyright_text:
                raise ValueError('Missing copyright notice: ' + name)
            text = copyright_text + '\n\n' + MIT
        result.append(name + '\nLicense: ' + str(expression) + '\n' + text)
    # Self-contained runtime packs are framework references, outside libraries.
    runtime_notices = set()
    for framework in graph['project']['frameworks'].values():
        for dependency in framework.get('downloadDependencies', []):
            if not dependency['name'].lower().startswith('microsoft.netcore.app.runtime.'):
                continue
            if dependency['name'] in runtime_notices:
                continue
            runtime_notices.add(dependency['name'])
            version = dependency['version'].strip('[]').split(',')[0].strip()
            package = next((root / dependency['name'].lower() / version for root in roots if (root / dependency['name'].lower() / version).is_dir()), None)
            if package is None:
                raise ValueError('Missing .NET runtime notices')
            result.append(dependency['name'] + '/' + version + '\n' + (package/'LICENSE.TXT').read_text() + '\n' + (package/'THIRD-PARTY-NOTICES.TXT').read_text())
    return '\n\n' + ('\n\n' + '=' * 80 + '\n\n').join(result)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('assets', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.write_text(collect(args.assets))
