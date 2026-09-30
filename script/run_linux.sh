#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
PROBE_DIR="$ROOT_DIR/dist/ffprobe-linux-$ARCH"
"$ROOT_DIR/script/build_ffprobe_linux.sh" "$PROBE_DIR"
cargo build --manifest-path "$ROOT_DIR/native/linux/Cargo.toml"
cp "$PROBE_DIR/ffprobe" "$ROOT_DIR/native/linux/target/debug/ffprobe"
exec "$ROOT_DIR/native/linux/target/debug/fillr-linux" "$@"
