#!/usr/bin/env python3
"""Verify that a packaged reference app cannot impersonate production macOS."""
import pathlib
import plistlib
import sys

def verify(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'org.tlolabs.fillr.avalonia.internal' or info.get('FILLRInternalReference') is not True:
        raise ValueError('Incorrect reference identity')
    if any(key.startswith('SU') for key in info):
        raise ValueError('Reference build contains production update configuration')
    if any('sparkle' in path.name.lower() or path.name.startswith('fillr-update') for path in app.rglob('*')):
        raise ValueError('Reference build contains a production updater')
    if not (app / 'Contents/MacOS/libfillr_core.dylib').is_file():
        raise ValueError('Reference build has no shared core')

if __name__ == '__main__':
    verify(pathlib.Path(sys.argv[1]))
