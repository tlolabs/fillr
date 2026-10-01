#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
FRAMEWORK="$ROOT_DIR/native/macos/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$FRAMEWORK"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

# Sparkle and its bundled third-party notices must accompany binary distributions.
cp "$ROOT_DIR/native/macos/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
