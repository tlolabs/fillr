#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
if [[ "$ARCH" != x86_64 && "$ARCH" != aarch64 ]]; then
  echo "Unsupported Linux architecture: $ARCH" >&2
  exit 1
fi
: "${APPIMAGETOOL:?Set APPIMAGETOOL to an appimagetool executable for this architecture}"
VERSION="$(python3 "$ROOT_DIR/script/version.py")"
cargo build --locked --manifest-path "$ROOT_DIR/Cargo.toml" --release -p fillr-core -p fillr-update
PROBE_DIR="$ROOT_DIR/dist/ffprobe-linux-$ARCH"
"$ROOT_DIR/script/build_ffprobe_linux.sh" "$PROBE_DIR"
APPDIR="$ROOT_DIR/dist/FILLR-$ARCH.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share"
cmake -S "$ROOT_DIR/native/qt" -B "$ROOT_DIR/target/qt-linux-$ARCH" -DCMAKE_BUILD_TYPE=Release -DFILLR_CORE_LIBRARY="$ROOT_DIR/target/release/libfillr_core.so"
cmake --build "$ROOT_DIR/target/qt-linux-$ARCH" --parallel
cp "$ROOT_DIR/target/qt-linux-$ARCH/fillr_qt" "$APPDIR/usr/bin/fillr"
cp "$ROOT_DIR/target/release/libfillr_core.so" "$APPDIR/usr/bin/"
cp "$ROOT_DIR/target/release/fillr-update" "$APPDIR/usr/bin/fillr-update"
test "$("$APPDIR/usr/bin/fillr" --version)" = "$VERSION"
test "$("$APPDIR/usr/bin/fillr-update" --version)" = "$VERSION"
cp "$PROBE_DIR/ffprobe" "$APPDIR/usr/bin/"
cmp "$PROBE_DIR/ffprobe" "$APPDIR/usr/bin/ffprobe"
cp "$PROBE_DIR/FFmpeg-minimal-build.patch" "$PROBE_DIR/FFmpeg-LICENSE.txt" "$PROBE_DIR/FFmpeg-BUILD.txt" "$PROBE_DIR/ffmpeg-9.0.2-source.tar.xz" "$APPDIR/usr/share/"
python3 "$ROOT_DIR/script/package_rust_licenses.py" --manifest "$ROOT_DIR/Cargo.toml" --output "$APPDIR/usr/share/Rust-LICENSES.txt"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/licenses/FFmpeg-NOTICE.txt" "$ROOT_DIR/licenses/LGPL-3.0.txt" "$APPDIR/usr/share/"
cp "$ROOT_DIR/licenses/Qt-NOTICE.txt" "$APPDIR/usr/share/"
PLUGIN_DIR="$(qtpaths6 --plugin-dir)"
mkdir -p "$APPDIR/usr/plugins/platforms"
for plugin in "$PLUGIN_DIR/platforms/libqxcb.so" "$PLUGIN_DIR"/platforms/libqwayland*.so; do
  [[ -f "$plugin" ]] || continue
  cp "$plugin" "$APPDIR/usr/plugins/platforms/"
done
test -f "$APPDIR/usr/plugins/platforms/libqxcb.so"
mapfile -d '' QT_PLUGINS < <(find "$APPDIR/usr/plugins" -type f -name '*.so' -print0)
python3 "$ROOT_DIR/script/bundle_linux_deps.py" "$APPDIR" "$APPDIR/usr/bin/fillr" "$APPDIR/usr/bin/ffprobe" "$APPDIR/usr/bin/fillr-update" "$APPDIR/usr/bin/libfillr_core.so" "${QT_PLUGINS[@]}"
cat > "$APPDIR/AppRun" <<'RUN'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export QT_PLUGIN_PATH="$HERE/usr/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/usr/plugins/platforms"
exec "$HERE/usr/bin/fillr" "$@"
RUN
chmod +x "$APPDIR/AppRun"
mkdir -p "$APPDIR/usr/share/applications"
cat > "$APPDIR/usr/share/applications/com.tlolabs.fillr.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=FILLR
Exec=fillr
Icon=com.tlolabs.fillr
Categories=AudioVideo;Video;
DESKTOP
cp "$APPDIR/usr/share/applications/com.tlolabs.fillr.desktop" "$APPDIR/"
for icon in "$ROOT_DIR"/assets/icons/linux/hicolor/*/apps/com.tlolabs.fillr.png; do
  size="$(basename "$(dirname "$(dirname "$icon")")")"
  mkdir -p "$APPDIR/usr/share/icons/hicolor/$size/apps"
  cp "$icon" "$APPDIR/usr/share/icons/hicolor/$size/apps/com.tlolabs.fillr.png"
done
cp "$ROOT_DIR/assets/icons/linux/hicolor/256x256/apps/com.tlolabs.fillr.png" "$APPDIR/com.tlolabs.fillr.png"
ln -s com.tlolabs.fillr.png "$APPDIR/.DirIcon"
OUTPUT="$ROOT_DIR/dist/FILLR-linux-$ARCH.AppImage"
ARCH="$ARCH" "$APPIMAGETOOL" "$APPDIR" "$OUTPUT"
echo "Built $OUTPUT"
