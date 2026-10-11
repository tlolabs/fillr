#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$1/Contents/Resources"
mkdir -p "$RESOURCES/DockIcon"
cp "$ROOT_DIR/assets/icons/FILLR.icns" "$RESOURCES/"
# build_platform_icons.py bakes the visible facets and saved Composer layout.
# Package those images together with their official Affinity axle geometry.
cp "$ROOT_DIR"/assets/icons/DockIcon/*.png "$RESOURCES/DockIcon/"
cp "$ROOT_DIR/assets/icons/DockIcon/artwork.json" "$RESOURCES/DockIcon/"
