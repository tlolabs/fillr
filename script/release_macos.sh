#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-signed}"
if [[ "$MODE" != signed && "$MODE" != --sign-only && "$MODE" != --unsigned ]]; then
  echo "usage: $0 [signed|--sign-only|--unsigned]" >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(python3 "$ROOT_DIR/script/version.py")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_NAME=FILLR
BUNDLE_ID=com.tlolabs.fillr
UNIVERSAL_DIR="$ROOT_DIR/dist/universal-libs"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

"$ROOT_DIR/script/build_ffprobe_macos.sh"
mkdir -p "$UNIVERSAL_DIR"
cd "$ROOT_DIR"
cargo build --release -p fillr-core --target aarch64-apple-darwin
cargo build --release -p fillr-core --target x86_64-apple-darwin
lipo -create \
  "$ROOT_DIR/target/aarch64-apple-darwin/release/libfillr_core.dylib" \
  "$ROOT_DIR/target/x86_64-apple-darwin/release/libfillr_core.dylib" \
  -output "$UNIVERSAL_DIR/libfillr_core.dylib"
install_name_tool -id "@rpath/libfillr_core.dylib" "$UNIVERSAL_DIR/libfillr_core.dylib"
export RUST_LIB_DIR="$UNIVERSAL_DIR"
swift build --package-path "$ROOT_DIR/native/macos" -c release --arch arm64 --arch x86_64
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR/native/macos" -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"
cp "$BUILD_BINARY" "$CONTENTS/MacOS/$APP_NAME"
cp "$UNIVERSAL_DIR/libfillr_core.dylib" "$CONTENTS/Frameworks/"
RUST_LINK="$(otool -L "$CONTENTS/MacOS/$APP_NAME" | sed -n '/libfillr_core[.]dylib/ { s/^[[:space:]]*//; s/ (compatibility.*$//; p; q; }')"
if [[ -z "$RUST_LINK" ]]; then echo "FILLR has no Rust engine link" >&2; exit 1; fi
install_name_tool -change "$RUST_LINK" "@rpath/libfillr_core.dylib" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT_DIR/dist/ffprobe-universal" "$CONTENTS/Resources/ffprobe"
cp "$ROOT_DIR/dist/FFmpeg-minimal-build.patch" "$ROOT_DIR/dist/FFmpeg-LICENSE.txt" "$ROOT_DIR/dist/FFmpeg-BUILD.txt" "$ROOT_DIR/dist/ffmpeg-9.0.2-source.tar.xz" "$CONTENTS/Resources/"
python3 "$ROOT_DIR/script/package_rust_licenses.py" --manifest "$ROOT_DIR/Cargo.toml" --target aarch64-apple-darwin --output "$CONTENTS/Resources/Rust-LICENSES.txt"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/licenses/FFmpeg-NOTICE.txt" "$CONTENTS/Resources/"
cp "$ROOT_DIR/assets/icons/FILLR.icns" "$CONTENTS/Resources/"
chmod +x "$CONTENTS/MacOS/$APP_NAME" "$CONTENTS/Resources/ffprobe"
cmp "$ROOT_DIR/dist/ffprobe-universal" "$CONTENTS/Resources/ffprobe"
cat >"$CONTENTS/Info.plist" <<PLIST
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

for binary in "$CONTENTS/MacOS/$APP_NAME" "$CONTENTS/Frameworks/libfillr_core.dylib" "$CONTENTS/Resources/ffprobe"; do
  lipo "$binary" -verify_arch arm64 x86_64
done

if [[ "$MODE" == signed || "$MODE" == --sign-only ]]; then
  : "${APPLE_DEVELOPER_ID:?Set APPLE_DEVELOPER_ID to your Developer ID Application certificate name}"
  if [[ "$MODE" == signed ]]; then : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a stored notarytool keychain profile}"; fi
  python3 "$ROOT_DIR/script/configure_updates.py" "$CONTENTS/Info.plist" --production
  FRAMEWORK="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
  for component in "$FRAMEWORK/XPCServices/Downloader.xpc" "$FRAMEWORK/XPCServices/Installer.xpc" "$FRAMEWORK/Autoupdate" "$FRAMEWORK/Updater.app" "$CONTENTS/Frameworks/Sparkle.framework"; do
    codesign --force --timestamp --options runtime --preserve-metadata=entitlements --sign "$APPLE_DEVELOPER_ID" "$component"
  done
  codesign --force --timestamp --options runtime --sign "$APPLE_DEVELOPER_ID" "$CONTENTS/Frameworks/libfillr_core.dylib"
  codesign --force --timestamp --options runtime --sign "$APPLE_DEVELOPER_ID" "$CONTENTS/Resources/ffprobe"
  codesign --force --timestamp --options runtime --sign "$APPLE_DEVELOPER_ID" "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

if [[ "$MODE" == signed || "$MODE" == --sign-only ]]; then
  ZIP="$ROOT_DIR/dist/FILLR-universal-signed.zip"
else
  ZIP="$ROOT_DIR/dist/FILLR-universal-unsigned.zip"
fi
rm -f "$ZIP"
if [[ "$MODE" == signed ]]; then
  SUBMISSION_ZIP="$ROOT_DIR/dist/FILLR-universal-notary-submission.zip"
  rm -f "$SUBMISSION_ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$SUBMISSION_ZIP"
  xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"
  rm -f "$SUBMISSION_ZIP"
else
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"
fi
unzip -tq "$ZIP"
echo "Built $ZIP"
