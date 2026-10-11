#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="FILLR"
BUNDLE_ID="com.tlolabs.fillr"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(python3 "$ROOT_DIR/script/version.py")"
MAC_DIR="$ROOT_DIR/native/macos"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"

# Honor an explicit toolchain. Prefer full Xcode only when its SDK is usable;
# Command Line Tools also include the SwiftUI/AppKit SDK needed by this app.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]] &&
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --show-sdk-path >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun --find swiftc >/dev/null 2>&1 || ! xcrun --show-sdk-path >/dev/null 2>&1; then
  echo "A usable macOS SDK and Swift compiler are required (Xcode or Command Line Tools)." >&2
  exit 1
fi

if [[ "$MODE" != "--build-only" && "$MODE" != "build-only" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
cd "$ROOT_DIR"
cargo build --release -p fillr-core
export RUST_LIB_DIR="$ROOT_DIR/target/release"
SWIFT_BUILD_ARGS=(--package-path "$MAC_DIR" -c release)
if [[ -n "${FILLR_MACOS_SDK:-}" ]]; then
  SWIFT_BUILD_ARGS+=(--sdk "$FILLR_MACOS_SDK")
else
  TOOLCHAIN_SWIFTC="$(xcrun --find swiftc)"
  MACOS_SDK="$(xcrun --show-sdk-path)"
  # macOS 27's State macro needs a plugin absent from Command Line Tools.
  # Use the installed compatible SDK when building with that toolchain.
  if [[ "$TOOLCHAIN_SWIFTC" == /Library/Developer/CommandLineTools/* &&
        -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]] &&
     grep -q SwiftUIMacros "$MACOS_SDK"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*-apple-macos.swiftinterface; then
    echo "Using the macOS 26.5 SDK (Command Line Tools lack the macOS 27 SwiftUI macro plugin)."
    SWIFT_BUILD_ARGS+=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
  fi
fi
swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_MACOS/$APP_NAME"
cp "$RUST_LIB_DIR/libfillr_core.dylib" "$APP_FRAMEWORKS/"
install_name_tool -id "@rpath/libfillr_core.dylib" "$APP_FRAMEWORKS/libfillr_core.dylib"
RUST_LINK="$(otool -L "$APP_MACOS/$APP_NAME" | sed -n '/libfillr_core[.]dylib/ { s/^[[:space:]]*//; s/ (compatibility.*$//; p; q; }')"
if [[ -z "$RUST_LINK" ]]; then echo "FILLR has no Rust engine link" >&2; exit 1; fi
install_name_tool -change "$RUST_LINK" "@rpath/libfillr_core.dylib" "$APP_MACOS/$APP_NAME"
"$ROOT_DIR/script/build_ffprobe_macos.sh"
cp "$DIST_DIR/ffprobe-universal" "$APP_RESOURCES/ffprobe"
cp "$DIST_DIR/FFmpeg-minimal-build.patch" "$DIST_DIR/FFmpeg-LICENSE.txt" "$APP_RESOURCES/"
cp "$DIST_DIR/FFmpeg-BUILD.txt" "$APP_RESOURCES/"
cp "$DIST_DIR/ffmpeg-9.0.2-source.tar.xz" "$APP_RESOURCES/"
python3 "$ROOT_DIR/script/package_rust_licenses.py" --manifest "$ROOT_DIR/Cargo.toml" --output "$APP_RESOURCES/Rust-LICENSES.txt"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/licenses/FFmpeg-NOTICE.txt" "$APP_RESOURCES/"
bash "$ROOT_DIR/script/package_macos_icons.sh" "$APP_BUNDLE"
chmod +x "$APP_RESOURCES/ffprobe"
cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>FILLR</string>
  <key>CFBundleDisplayName</key><string>FILLR</string>
  <key>CFBundleIconFile</key><string>FILLR</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

bash "$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE"
python3 "$ROOT_DIR/script/configure_updates.py" "$APP_BUNDLE/Contents/Info.plist"

# Relocating the Rust library invalidates its linker-generated signature.
# Sign the local build so Apple Silicon can run the staged bundle.
codesign --force --sign - "$APP_FRAMEWORKS/libfillr_core.dylib"
codesign --force --sign - "$APP_RESOURCES/ffprobe"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  --build-only|build-only) echo "Built $APP_BUNDLE" ;;
  run) open_app ;;
  --preview-icon|preview-icon) /usr/bin/open -n "$APP_BUNDLE" --args --preview-icon ;;
  --debug|debug) lldb -- "$APP_MACOS/$APP_NAME" ;;
  --logs|logs) open_app; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify) open_app; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo "usage: $0 [run|--preview-icon|--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
