#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Internal reference requires Apple Silicon macOS.' >&2; exit 1; }
export AVALONIA_TELEMETRY_OPTOUT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
cd "$ROOT_DIR"
python3 script/version.py --check
cargo build --locked --release -p fillr-core --target aarch64-apple-darwin
./script/build_ffprobe_macos.sh
APP="$ROOT_DIR/dist/FILLR-Avalonia-Internal.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
dotnet publish native/desktop/FILLR.Desktop.csproj -c Release -f net10.0 -r osx-arm64 --self-contained true -p:RestoreLockedMode=true -p:InternalReference=true -warnaserror -o "$APP/Contents/MacOS"
cp target/aarch64-apple-darwin/release/libfillr_core.dylib "$APP/Contents/MacOS/"
cp dist/ffprobe-universal "$APP/Contents/Resources/ffprobe"
cp dist/FFmpeg* dist/ffmpeg-9.0.2-source.tar.xz "$APP/Contents/Resources/"
cp LICENSE licenses/FFmpeg-NOTICE.txt "$APP/Contents/Resources/"
python3 script/package_rust_licenses.py --manifest Cargo.toml --target aarch64-apple-darwin --output "$APP/Contents/Resources/Rust-LICENSES.txt"
python3 script/package_nuget_licenses.py native/desktop/obj/project.assets.json "$APP/Contents/Resources/NuGet-LICENSES.txt"
python3 - "$APP" "$(python3 script/version.py)" <<'PY'
import pathlib, plistlib, sys
app=pathlib.Path(sys.argv[1]);version=sys.argv[2]
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.tlolabs.fillr.avalonia.internal',CFBundleName='FILLR Avalonia Internal',CFBundleDisplayName='FILLR — Internal Avalonia Reference',CFBundleExecutable='FILLR',CFBundlePackageType='APPL',CFBundleShortVersionString=version,CFBundleVersion=version,NSHighResolutionCapable=True,LSMinimumSystemVersion='15.0',FILLRInternalReference=True)))
assert not (app/'Contents/MacOS/fillr-update').exists()
PY
# Local ARM64 executable pages require ad-hoc signatures; this is not Developer ID signing.
codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" dist/FILLR-avalonia-INTERNAL-osx-arm64.zip
echo "Internal reference only: $APP"
