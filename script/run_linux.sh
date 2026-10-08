#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
PROBE_DIR="$ROOT_DIR/dist/ffprobe-linux-$ARCH"
"$ROOT_DIR/script/build_ffprobe_linux.sh" "$PROBE_DIR"
cargo build --locked --manifest-path "$ROOT_DIR/Cargo.toml" -p fillr-core -p fillr-update
cmake -S "$ROOT_DIR/native/qt" -B "$ROOT_DIR/target/qt-linux-debug" -DCMAKE_BUILD_TYPE=Debug -DFILLR_CORE_LIBRARY="$ROOT_DIR/target/debug/libfillr_core.so"
cmake --build "$ROOT_DIR/target/qt-linux-debug" --parallel
mkdir -p "$ROOT_DIR/dist/linux-development"
cp "$ROOT_DIR/target/qt-linux-debug/fillr_qt" "$ROOT_DIR/dist/linux-development/fillr"
cp "$PROBE_DIR/ffprobe" "$ROOT_DIR/target/debug/libfillr_core.so" "$ROOT_DIR/target/debug/fillr-update" "$ROOT_DIR/dist/linux-development/"
exec "$ROOT_DIR/dist/linux-development/fillr" "$@"
