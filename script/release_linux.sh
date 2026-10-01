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
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --release -p fillr-update
PROBE_DIR="$ROOT_DIR/dist/ffprobe-linux-$ARCH"
"$ROOT_DIR/script/build_ffprobe_linux.sh" "$PROBE_DIR"
cargo build --manifest-path "$ROOT_DIR/native/linux/Cargo.toml" --release
APPDIR="$ROOT_DIR/dist/FILLR-$ARCH.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/glib-2.0/schemas"
cp "$ROOT_DIR/native/linux/target/release/fillr-linux" "$APPDIR/usr/bin/fillr"
cp "$ROOT_DIR/target/release/fillr-update" "$APPDIR/usr/bin/fillr-update"
test "$("$APPDIR/usr/bin/fillr" --version)" = "$VERSION"
test "$("$APPDIR/usr/bin/fillr-update" --version)" = "$VERSION"
cp "$PROBE_DIR/ffprobe" "$APPDIR/usr/bin/"
cmp "$PROBE_DIR/ffprobe" "$APPDIR/usr/bin/ffprobe"
cp "$PROBE_DIR/FFmpeg-minimal-build.patch" "$PROBE_DIR/FFmpeg-LICENSE.txt" "$PROBE_DIR/FFmpeg-BUILD.txt" "$PROBE_DIR/ffmpeg-9.0.2-source.tar.xz" "$APPDIR/usr/share/"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/licenses/FFmpeg-NOTICE.txt" "$APPDIR/usr/share/"
cp /usr/share/glib-2.0/schemas/gschemas.compiled "$APPDIR/usr/share/glib-2.0/schemas/"
python3 "$ROOT_DIR/script/bundle_linux_deps.py" "$APPDIR" "$APPDIR/usr/bin/fillr" "$APPDIR/usr/bin/ffprobe" "$APPDIR/usr/bin/fillr-update"
cat > "$APPDIR/AppRun" <<'RUN'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$HERE/usr/bin/fillr" "$@"
RUN
chmod +x "$APPDIR/AppRun"
mkdir -p "$APPDIR/usr/share/applications"
cat > "$APPDIR/usr/share/applications/edu.chabot.news.backgrounder.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=FILLR
Exec=fillr
Icon=edu.chabot.news.backgrounder
Categories=AudioVideo;Video;
DESKTOP
cp "$APPDIR/usr/share/applications/edu.chabot.news.backgrounder.desktop" "$APPDIR/"
for icon in "$ROOT_DIR"/assets/icons/linux/hicolor/*/apps/edu.chabot.news.backgrounder.png; do
  size="$(basename "$(dirname "$(dirname "$icon")")")"
  mkdir -p "$APPDIR/usr/share/icons/hicolor/$size/apps"
  cp "$icon" "$APPDIR/usr/share/icons/hicolor/$size/apps/edu.chabot.news.backgrounder.png"
done
cp "$ROOT_DIR/assets/icons/linux/hicolor/256x256/apps/edu.chabot.news.backgrounder.png" "$APPDIR/edu.chabot.news.backgrounder.png"
ln -s edu.chabot.news.backgrounder.png "$APPDIR/.DirIcon"
OUTPUT="$ROOT_DIR/dist/FILLR-linux-$ARCH.AppImage"
ARCH="$ARCH" "$APPIMAGETOOL" "$APPDIR" "$OUTPUT"
echo "Built $OUTPUT"
