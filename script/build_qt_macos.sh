#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Internal Qt reference requires Apple Silicon macOS.' >&2; exit 1; }
cd "$ROOT_DIR"
VERSION="$(python3 script/version.py)"
cargo build --locked --release -p fillr-core --target aarch64-apple-darwin
./script/build_ffprobe_macos.sh
CORE="$ROOT_DIR/target/aarch64-apple-darwin/release/libfillr_core.dylib"
cmake -S native/qt -B target/qt-release -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DFILLR_CORE_LIBRARY="$CORE"
cmake --build target/qt-release --parallel
APP="$ROOT_DIR/dist/FILLR-Qt-Internal.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp target/qt-release/fillr_qt "$APP/Contents/MacOS/FILLR"
cp "$CORE" "$APP/Contents/Frameworks/libfillr_core.dylib"
install_name_tool -change "$CORE" '@executable_path/../Frameworks/libfillr_core.dylib' "$APP/Contents/MacOS/FILLR"
cp dist/ffprobe-universal "$APP/Contents/Resources/ffprobe"
cp dist/FFmpeg* dist/ffmpeg-9.0.2-source.tar.xz "$APP/Contents/Resources/"
cp LICENSE licenses/FFmpeg-NOTICE.txt licenses/LGPL-3.0.txt "$APP/Contents/Resources/"
cp licenses/Qt-NOTICE.txt "$APP/Contents/Resources/"
cp assets/icons/FILLR.icns "$APP/Contents/Resources/FILLR.icns"
python3 script/package_rust_licenses.py --manifest Cargo.toml --target aarch64-apple-darwin --output "$APP/Contents/Resources/Rust-LICENSES.txt"
python3 - "$APP" "$VERSION" <<'PY'
import pathlib, plistlib, sys
app=pathlib.Path(sys.argv[1]);version=sys.argv[2]
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier='com.tlolabs.fillr.qt.internal',
    CFBundleName='FILLR Qt Internal',
    CFBundleDisplayName='FILLR — Internal Qt Reference',
    CFBundleExecutable='FILLR',
    CFBundleIconFile='FILLR.icns',
    CFBundlePackageType='APPL',
    CFBundleShortVersionString=version,
    CFBundleVersion=version,
    LSMinimumSystemVersion='15.0',
    NSHighResolutionCapable=True,
    FILLRInternalReference=True)))
PY
macdeployqt "$APP" -always-overwrite -no-plugins -no-codesign
PLUGIN_DIR="$(qtpaths6 --plugin-dir)"
QT_PREFIX="$(qtpaths6 --query QT_INSTALL_PREFIX)"
if [[ -f "$QT_PREFIX/Cellar/qtbase/$(pkg-config --modversion Qt6Core)/sbom.spdx.json" ]]; then
  cp "$QT_PREFIX/Cellar/qtbase/$(pkg-config --modversion Qt6Core)/sbom.spdx.json" "$APP/Contents/Resources/Qt-SBOM.spdx.json"
fi
for kind in platforms styles; do mkdir -p "$APP/Contents/PlugIns/$kind"; done
cp "$PLUGIN_DIR/platforms/libqcocoa.dylib" "$APP/Contents/PlugIns/platforms/"
cp "$PLUGIN_DIR/styles/libqmacstyle.dylib" "$APP/Contents/PlugIns/styles/"
for plugin in "$APP/Contents/PlugIns/platforms/libqcocoa.dylib" "$APP/Contents/PlugIns/styles/libqmacstyle.dylib"; do
  for framework in QtCore QtGui QtWidgets; do
    install_name_tool -change "@rpath/$framework.framework/Versions/A/$framework" "@executable_path/../Frameworks/$framework.framework/Versions/A/$framework" "$plugin"
  done
done
test ! -e "$APP/Contents/MacOS/fillr-update"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$ROOT_DIR/dist/FILLR-qt-INTERNAL-osx-arm64.zip"
echo "Internal Qt reference: $APP"
