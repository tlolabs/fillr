#!/usr/bin/env python3
"""Use Sparkle's maintained generator and signature verifier, not custom XML signatures."""
import base64, json, os, pathlib, shutil, subprocess, tempfile
from version import ROOT, version
from release_updates import trust
v=version();t=trust(); seed=base64.b64decode(os.environ['TLO_UPDATE_PRIVATE_KEY'],validate=True)
if len(seed)!=32: raise ValueError('Expected a 32-byte Ed25519 seed')
# Sparkle accepts the same base64 32-byte seed via stdin; never put keys in argv/files/logs.
tools=ROOT/'native/macos/.build/artifacts/sparkle/Sparkle/bin'
with tempfile.TemporaryDirectory() as temp:
    directory=pathlib.Path(temp)
    shutil.copy2(ROOT/f'dist/FILLR-{v}-macos-universal.zip', directory)
    subprocess.run([str(tools/'generate_appcast'),'--ed-key-file','-','--maximum-deltas','0','--maximum-versions','1',
                    '--download-url-prefix',f"https://github.com/{t['repository']}/releases/download/v{v}/",str(directory)],
                    input=base64.b64encode(seed)+b'\n',check=True)
    feed=directory/'appcast.xml'
    subprocess.run([str(tools/'sign_update'),'--verify','--ed-key-file','-',str(feed)],input=base64.b64encode(seed)+b'\n',check=True)
    shutil.copy2(feed,ROOT/'dist/appcast.xml')
