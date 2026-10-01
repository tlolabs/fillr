#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/ffprobe_common.sh"
ARCHIVE="$(ffprobe_source_archive)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/ffprobe-linux-$(uname -m)}"
mkdir -p "$ROOT_DIR/target" "$OUTPUT_DIR"
BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
ffprobe_verify_source
tar -xf "$ARCHIVE" -C "$BUILD_ROOT"
ffprobe_patch_source "$BUILD_ROOT/ffmpeg-$FFMPEG_VERSION"
mkdir "$BUILD_ROOT/build"
cd "$BUILD_ROOT/build"
"$BUILD_ROOT/ffmpeg-$FFMPEG_VERSION/configure" "${FFPROBE_CONFIGURE[@]}"
make -j"$(nproc)" ffprobe
cp ffprobe "$OUTPUT_DIR/ffprobe"
"$OUTPUT_DIR/ffprobe" -L > "$OUTPUT_DIR/FFmpeg-LICENSE.txt"
ffprobe_build_record "$OUTPUT_DIR/ffprobe" "Linux $(uname -m)" "$OUTPUT_DIR/FFmpeg-BUILD.txt"
ffprobe_verify_binary "$OUTPUT_DIR/ffprobe"
cp "$ARCHIVE" "$OUTPUT_DIR/ffmpeg-$FFMPEG_VERSION-source.tar.xz"

ffprobe_copy_source_patch "$OUTPUT_DIR"
