#!/usr/bin/env python3
"""Use the existing Linux signing identity; never generate a replacement production key."""
import json, os, pathlib, platform, shutil, subprocess
from version import ROOT, version
from release_updates import digest, trust
v=version(); arch=platform.machine(); t=trust()
fingerprint=json.loads((ROOT/'updates/platform-security.json').read_text())['linux_gpg_fingerprint']
source=ROOT/f'dist/FILLR-linux-{arch}.AppImage';output=ROOT/f'dist/FILLR-{v}-linux-{arch}.AppImage'
shutil.copy2(source,output)
# Key import and passphrase handling belong to protected CI secret provisioning.
subprocess.run(['gpg','--batch','--yes','--pinentry-mode','loopback','--passphrase-fd','0','--local-user',fingerprint,'--armor','--detach-sign',str(output)],input=os.environ['LINUX_GPG_PASSPHRASE'].encode(),check=True)
status=subprocess.run(['gpg','--batch','--status-fd','1','--verify',str(output)+'.asc',str(output)],capture_output=True,text=True,check=True).stdout
if not any(line.startswith('[GNUPG:] VALIDSIG ') and (line.split()[2]==fingerprint or line.split()[-1]==fingerprint) for line in status.splitlines()): raise ValueError('Wrong Linux signing identity')
# The package was built here, and is now authenticated before executing its version probe.
env=dict(os.environ,APPIMAGE_EXTRACT_AND_RUN='1')
actual=subprocess.check_output([str(output),'--version'],env=env,text=True).strip()
if actual!=v: raise ValueError('AppImage version mismatch')
evidence=dict(schema=1,platform='linux',architecture=arch,version=v,filename=output.name,sha256=digest(output),identity=t['identities']['linux'],signature_verified=True,gpg_fingerprint=fingerprint,installed_upgrade_verified=False)
output.with_name(output.name+'.verified.json').write_text(json.dumps(evidence,indent=2)+'\n')
