#!/usr/bin/env python3
"""Release promotion: no replacement of an existing public release or mutable tag."""
import json, os, pathlib, re, subprocess, sys
from release_updates import ROOT, preflight, qualification

def gh(*args): return subprocess.check_output(['gh',*args],text=True)
def run(*args): subprocess.run(args,check=True)
def check_remote_tag(tag):
    local=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    remote=json.loads(gh('api','repos/tlolabs/fillr/commits/'+tag))['sha']
    if remote!=local: raise ValueError('Remote release tag moved away from the qualified source')

def prepare():
    tag=os.environ['RELEASE_TAG'];preflight(tag);check_remote_tag(tag)
    sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    repo='tlolabs/fillr'
    for variable,artifact,directory in [('CANDIDATE_RUN','authenticated-update-candidate','release'),('EVIDENCE_RUN','installed-upgrade-evidence','upgrade-evidence')]:
        run_id=os.environ[variable]
        if not re.fullmatch(r'[1-9][0-9]*',run_id): raise ValueError('Invalid Actions run ID')
        info=json.loads(gh('api',f'repos/{repo}/actions/runs/{run_id}'))
        if info['conclusion']!='success' or info['head_sha']!=sha or info['repository']['full_name']!=repo:
            raise ValueError('Qualification/candidate run must be successful and bound to the exact tagged source')
        if variable=='CANDIDATE_RUN' and info['path']!='.github/workflows/release-updates.yml': raise ValueError('Unexpected candidate workflow')
        run('gh','run','download',run_id,'--repo',repo,'--name',artifact,'--dir',directory)
    qualification(pathlib.Path('release'),pathlib.Path('upgrade-evidence/qualification.json'))
    run('cargo','run','--locked','-p','fillr-update-policy','--bin','tlo-update-release','--','verify','release/update-manifest.json','release','updates/trust.json')
    for image in pathlib.Path('release').glob('*.AppImage'):
        run('gh','attestation','verify',str(image),'--repo',repo,'--signer-workflow',repo+'/.github/workflows/release-updates.yml','--source-ref','refs/tags/'+tag)

def publish():
    # Re-run local byte/signature/qualification validation immediately before mutation.
    tag=os.environ['RELEASE_TAG'];preflight(tag);check_remote_tag(tag)
    qualification(pathlib.Path('release'),pathlib.Path('upgrade-evidence/qualification.json'))
    run('cargo','run','--locked','-p','fillr-update-policy','--bin','tlo-update-release','--','verify','release/update-manifest.json','release','updates/trust.json')
    # gh release create rejects existing releases; never --clobber.
    assets=[str(p) for p in sorted(pathlib.Path('release').iterdir()) if p.name!='manifest.json' and p.is_file()]
    run('gh','release','create',tag,*assets,'--repo','tlolabs/fillr','--verify-tag','--draft','--title',tag,'--generate-notes')
    downloaded=pathlib.Path('published-verification/draft');downloaded.mkdir(parents=True)
    run('gh','release','download',tag,'--repo','tlolabs/fillr','--dir',str(downloaded))
    run('cargo','run','--locked','-p','fillr-update-policy','--bin','tlo-update-release','--','verify',str(downloaded/'update-manifest.json'),str(downloaded),'updates/trust.json')
    run('gh','release','edit',tag,'--repo','tlolabs/fillr','--draft=false','--prerelease=false','--latest')
if __name__=='__main__':
    if sys.argv[1]=='prepare':prepare()
    elif sys.argv[1]=='publish':publish()
    else:raise SystemExit('Unknown promotion operation')
