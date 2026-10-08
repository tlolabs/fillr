#!/usr/bin/env python3
"""Copy the linked native/runtime libraries into an AppDir without bundling glibc."""
import re
import shutil
import subprocess
import sys
from pathlib import Path

appdir = Path(sys.argv[1])
queue = [Path(value) for value in sys.argv[2:]]
seen = set()
notice_dir = appdir / "usr/share/licenses/system-libraries"
notice_dir.mkdir(parents=True, exist_ok=True)


def copy_notice(dependency):
    # Production Linux packages use Ubuntu's dpkg-owned native/runtime libraries.
    # Resolve usr-merge aliases before locating the exact distribution notice.
    owners = None
    for candidate in dict.fromkeys([str(dependency), str(dependency.resolve())]):
        result = subprocess.run(["dpkg-query", "--search", candidate], text=True, capture_output=True)
        if result.returncode == 0:
            owners = result.stdout.splitlines()
            break
    if not owners:
        raise RuntimeError(f"No distribution license owner for {dependency}")
    for owner in owners:
        package = owner.split(": ", 1)[0]
        notice = Path("/usr/share/doc") / package.split(":", 1)[0] / "copyright"
        if not notice.is_file():
            raise RuntimeError(f"Missing license notice for {package}: {dependency}")
        shutil.copy2(notice, notice_dir / (package + ".copyright"))

# Initial system libraries may have been explicitly copied for dlopen. Record
# their licenses even if no executable links them directly.
for initial in queue:
    if str(initial).startswith('/usr/lib/'):
        copy_notice(initial)
        shutil.copy2(initial, appdir / 'usr/lib' / initial.name)

excluded = re.compile(r"^(?:ld-linux|libc\.|libm\.|libdl\.|libpthread\.|librt\.|libresolv\.|libnss_|libutil\.)")
while queue:
    binary = queue.pop()
    if binary in seen:
        continue
    seen.add(binary)
    result = subprocess.run(["ldd", str(binary)], text=True, capture_output=True, check=True)
    for line in result.stdout.splitlines():
        if "=> not found" in line:
            raise RuntimeError(f"Unresolved library for {binary}: {line.strip()}")
        match = re.search(r"=>\s+(/\S+)", line)
        if not match:
            continue
        dependency = Path(match.group(1))
        if excluded.match(dependency.name):
            continue
        # Rust and Qt package libraries carry their own collected notices.
        # Follow their imports in place; they are not Ubuntu-owned system files.
        if dependency.resolve().is_relative_to(appdir.resolve()):
            queue.append(dependency)
            continue
        destination = appdir / "usr/lib" / dependency.name
        if not destination.exists():
            copy_notice(dependency)
            shutil.copy2(dependency, destination)
            queue.append(destination)
