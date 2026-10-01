#!/usr/bin/env python3
import hashlib,json,pathlib
root=pathlib.Path(__file__).resolve().parents[1]
expected=json.loads((root/'updater/SNAPSHOT.json').read_text())
actual={str(p.relative_to(root)) for p in (root/'updater').rglob('*') if p.is_file() and p.name not in {'SNAPSHOT.json','.DS_Store'}}
if actual!=set(expected): raise SystemExit('Shared updater snapshot file set changed')
for name,digest in expected.items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Shared updater snapshot drift: '+name)
print('Shared updater snapshot verified')
