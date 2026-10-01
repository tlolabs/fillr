#!/usr/bin/env python3
"""FILLR release assembly/qualification. Cryptography is owned by tlo-updater."""
import argparse, base64, datetime as dt, hashlib, json, pathlib, plistlib, subprocess, zipfile
from version import ROOT, version

TARGETS = [('macos','universal','zip','13.0.0'),('windows','x64','msix','10.0.19041'),
           ('windows','arm64','msix','10.0.19041'),('linux','x86_64','AppImage','2.39.0'),('linux','aarch64','AppImage','2.39.0')]
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()
def trust(): return json.loads((ROOT/'updates/trust.json').read_text())
def preflight(tag):
    v=version()
    if tag!='v'+v: raise ValueError('Tag differs from authoritative version')
    t=trust()
    if not t['keys'] or t['identities']['windows']=='UNCONFIGURED':
        raise ValueError('Production requires pinned FILLR Ed25519 keys and the trusted Windows publisher in updates/trust.json')
    for key in t['keys'].values():
        if len(base64.b64decode(key,validate=True))!=32: raise ValueError('Invalid public key')
    return v,t

def assemble(directory,tag):
    v,t=preflight(tag)
    now=dt.datetime.now(dt.timezone.utc)
    manifest=dict(schema=2,application_id=t['app_id'],repository=t['repository'],version=v,tag=tag,channel='stable',draft=False,prerelease=False,
                  published_at=now.isoformat(),expires_at=(now+dt.timedelta(days=365)).isoformat(),release_notes_url=f"https://github.com/{t['repository']}/releases/tag/{tag}",restart_required=True,migration='none',assets={})
    for platform,arch,extension,min_os in TARGETS:
        name=f'FILLR-{v}-{platform}-{arch}.{extension}'
        path=directory/name
        evidence=json.loads((directory/(name+'.verified.json')).read_text())
        if evidence.get('filename')!=name or evidence.get('version')!=v or evidence.get('sha256')!=digest(path) or evidence.get('signature_verified') is not True:
            raise ValueError('Missing or mismatched native verification evidence: '+name)
        if evidence.get('identity') != t['identities'][platform]: raise ValueError('Wrong platform identity: '+name)
        if platform=='macos':
            with zipfile.ZipFile(path) as z:
                info=plistlib.loads(z.read('FILLR.app/Contents/Info.plist'))
                if info['CFBundleIdentifier']!=t['app_id'] or info['CFBundleShortVersionString']!=v or info['CFBundleVersion']!=v:
                    raise ValueError('Mac bundle identity/version mismatch')
                if not info.get('SURequireSignedFeed') or not info.get('SUVerifyUpdateBeforeExtraction') or info.get('SUPublicEDKey') not in t['keys'].values():
                    raise ValueError('Mac bundle trust configuration mismatch')
            if not (directory/'appcast.xml').is_file(): raise ValueError('Signed Sparkle appcast missing')
        target = 'macos-universal' if platform=='macos' else ('windows-'+arch+'-msix' if platform=='windows' else 'linux-'+{'x86_64':'x64','aarch64':'arm64'}[arch]+'-appimage')
        manifest['assets'][target]=dict(platform=platform,architecture={'x64':'x86_64','arm64':'aarch64'}.get(arch,arch),minimum_os=('0.0.0' if platform=='linux' else min_os),minimum_glibc=(min_os if platform=='linux' else None),filename=name,
            url=f"https://github.com/{t['repository']}/releases/download/{tag}/{name}",size=path.stat().st_size,sha256=digest(path),
            format=extension,identity=t['identities'][platform])
    if any(platform=='macos' for platform,_,_,_ in TARGETS):
        manifest['appcast_sha256']=digest(directory/'appcast.xml')
    path=directory/'manifest.json';path.write_text(json.dumps(manifest,indent=2)+'\n')
    return path

def qualification(directory,evidence_path):
    """A passing build or metadata check is not evidence of an installed upgrade."""
    v=version(); ledger=json.loads(evidence_path.read_text())
    for platform,arch,ext,_ in TARGETS:
        name=f'FILLR-{v}-{platform}-{arch}.{ext}'
        architectures=['x86_64','aarch64'] if arch=='universal' else [arch]
        for tested_arch in architectures:
            verify_upgrade_evidence(ledger.get('targets',{}).get(platform+'-'+tested_arch,{}), v, directory/name, platform+'-'+tested_arch)

def verify_upgrade_evidence(evidence,v,artifact,target):
    required=['discovered','authenticated','downloaded','installed','relaunched','user_data_preserved']
    if any(evidence.get(key) is not True for key in required): raise ValueError('Installed upgrade not qualified: '+target)
    if evidence.get('to_version')!=v or evidence.get('artifact_sha256')!=digest(artifact): raise ValueError('Upgrade evidence does not bind to final artifact')
    old=tuple(int(x) for x in evidence['from_version'].split('.'))
    if len(old)!=3 or old>=tuple(int(x) for x in v.split('.')): raise ValueError('Qualification requires an actually older build')
    if not evidence.get('evidence_url','').startswith('https://github.com/tlolabs/fillr/actions/runs/'): raise ValueError('Attach native test evidence from the repository Actions run')
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('command',choices=['preflight','assemble','qualify']);p.add_argument('--tag');p.add_argument('--assets',type=pathlib.Path);p.add_argument('--evidence',type=pathlib.Path)
    a=p.parse_args()
    if a.command=='preflight':preflight(a.tag)
    elif a.command=='assemble':print(assemble(a.assets,a.tag))
    else:qualification(a.assets,a.evidence)
