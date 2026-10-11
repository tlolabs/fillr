#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES="$1/Contents/Resources"
mkdir -p "$RESOURCES/DockIcon"
cp "$ROOT_DIR/assets/icons/FILLR.icns" "$RESOURCES/"
# Runtime animation needs the separate raster layers, not the flattened .icns.
for layer in "$ROOT_DIR"/assets/icons/fillr.icon/Assets/[0-9][0-9]-*.png; do
  cp "$layer" "$RESOURCES/DockIcon/"
done
