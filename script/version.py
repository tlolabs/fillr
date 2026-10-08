#!/usr/bin/env python3
"""Cargo workspace.package.version is the sole authoritative FILLR version."""
import argparse, pathlib, re
ROOT = pathlib.Path(__file__).resolve().parents[1]
def version():
    text = (ROOT / "Cargo.toml").read_text()
    section = text.split("[workspace.package]", 1)[1].split("[", 1)[0]
    value = re.search(r'^version\s*=\s*"([^"]+)"', section, re.M).group(1)
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise ValueError("Stable version must be canonical X.Y.Z")
    # MSIX and CFBundleVersion constraints are intentionally part of the app contract.
    if any(int(p) > 65535 for p in value.split('.')):
        raise ValueError("Version exceeds native packaging limits")
    return value
if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--tag'); parser.add_argument('--sync',action='store_true'); parser.add_argument('--check',action='store_true'); args = parser.parse_args()
    value = version()
    if args.tag and args.tag != 'v' + value:
        raise SystemExit('Release tag must exactly match v' + value)
    # Qt reads this authoritative value during CMake configure; macOS release
    # scripts use the same command when writing bundle metadata.
    print(value)
