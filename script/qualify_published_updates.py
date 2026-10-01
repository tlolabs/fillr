#!/usr/bin/env python3
"""Read real GitHub Release metadata, then exercise the shipped transport/verification code."""
import json,os,pathlib,subprocess
from release_updates import ROOT, TARGETS, trust
from version import version
v=version();t=trust()
release=json.loads(subprocess.check_output(['gh','api',f"repos/{t['repository']}/releases/tags/v{v}"],text=True))
if release['draft'] or release['prerelease'] or release['tag_name']!='v'+v:raise ValueError('Published release is not stable')
evidence=json.loads(pathlib.Path('upgrade-evidence/qualification.json').read_text())
root=pathlib.Path('published-verification');root.mkdir(exist_ok=True)
for platform,arch,_,os_version in TARGETS:
    for tested_arch in (['x86_64','aarch64'] if arch=='universal' else [arch]):
        target=platform+'-'+tested_arch
        old=evidence['targets'][target]['from_version']
        config=dict(application_id=t['app_id'],repository=t['repository'],version=old,platform=platform,
                    architecture={'arm64':'aarch64','x64':'x86_64'}.get(tested_arch,tested_arch),os_version=('999.999.999' if platform=='linux' else os_version),glibc_version=(os_version if platform=='linux' else None),keys=t['keys'],identity=t['identities'][platform])
        path=root/(target+'.json');path.write_text(json.dumps(config))
        directory=root/target
        subprocess.run(['cargo','run','--locked','-p','fillr-update-policy','--bin','tlo-update-release','--','fetch',str(path),str(directory),'updates/trust.json'],check=True)
(root/'result.json').write_text(json.dumps(dict(discovery_authentication_download=True,installed_upgrade=False,note='Native installed-upgrade evidence is separate.'),indent=2))
