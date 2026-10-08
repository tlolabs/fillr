#!/usr/bin/env python3
"""Verify the internal Qt bundle cannot impersonate production macOS."""
import pathlib
import plistlib
import sys


def verify(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.tlolabs.fillr.qt.internal' or info.get('FILLRInternalReference') is not True:
        raise ValueError('Incorrect internal Qt identity')
    if any(key.startswith('SU') for key in info):
        raise ValueError('Internal Qt bundle contains production update configuration')
    if any('sparkle' in path.name.lower() or path.name.startswith('fillr-update') for path in app.rglob('*')):
        raise ValueError('Internal Qt bundle contains a production updater')
    for path in ('Contents/MacOS/FILLR', 'Contents/Frameworks/libfillr_core.dylib',
                 'Contents/Resources/ffprobe', 'Contents/PlugIns/platforms/libqcocoa.dylib'):
        if not (app / path).is_file():
            raise ValueError('Internal Qt bundle is missing ' + path)


if __name__ == '__main__':
    verify(pathlib.Path(sys.argv[1]))
