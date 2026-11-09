#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$1/Contents/Resources"
mkdir -p "$RESOURCES"
cp "$ROOT_DIR/assets/icons/FILLR.icns" "$ROOT_DIR/assets/icons/FILLR-Classic.icns" \
    "$ROOT_DIR/assets/icons/FILLR-MacOS.icns" "$RESOURCES/"
# build_platform_icons.py bakes the visible facets and saved Composer layout.
# Package those images together with their official Affinity axle geometry.
for variant in DockIcon DockIconClassic DockIconMacOS; do
    mkdir -p "$RESOURCES/$variant"
    cp "$ROOT_DIR/assets/icons/$variant/"*.png "$RESOURCES/$variant/"
    cp "$ROOT_DIR/assets/icons/$variant/artwork.json" "$RESOURCES/$variant/"
done
