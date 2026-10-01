#!/usr/bin/env python3
"""Provision ephemeral runner credentials without printing or persisting exported keys."""
import base64,json,os,pathlib,secrets,subprocess
from version import ROOT
security=json.loads((ROOT/'updates/platform-security.json').read_text())
keychain=pathlib.Path(os.environ['RUNNER_TEMP'])/'fillr-signing.keychain-db'
p12=keychain.with_suffix('.p12'); password=secrets.token_urlsafe(32)
def run(*args):
    # Never include a credential-bearing argv in an exception/CI log.
    if subprocess.run(args,stdout=subprocess.DEVNULL).returncode:
        raise SystemExit('Credential provisioning failed: '+args[0])
try:
    p12.write_bytes(base64.b64decode(os.environ['MACOS_CERTIFICATE_P12_B64'],validate=True));p12.chmod(0o600)
    run('security','create-keychain','-p',password,str(keychain))
    run('security','set-keychain-settings','-lut','21600',str(keychain))
    run('security','unlock-keychain','-p',password,str(keychain))
    run('security','import',str(p12),'-k',str(keychain),'-P',os.environ['MACOS_CERTIFICATE_PASSWORD'],'-T','/usr/bin/codesign','-T','/usr/bin/security')
    run('security','set-key-partition-list','-S','apple-tool:,apple:,codesign:','-s','-k',password,str(keychain))
    run('security','list-keychains','-d','user','-s',str(keychain))
    run('security','default-keychain','-d','user','-s',str(keychain))
    run('xcrun','notarytool','store-credentials','FILLR-CI','--keychain',str(keychain),'--apple-id',os.environ['APPLE_ID'],'--team-id',security['macos_team_id'],'--password',os.environ['APPLE_APP_PASSWORD'])
finally: p12.unlink(missing_ok=True)
