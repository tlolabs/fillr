#!/usr/bin/env bash
# Run inside the matching MSYS2 UCRT64 or CLANGARM64 shell.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/ffprobe_common.sh"
ARCHIVE="$(ffprobe_source_archive)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/ffprobe-windows}"
mkdir -p "$ROOT_DIR/target" "$OUTPUT_DIR"
BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
ffprobe_verify_source
tar -xf "$ARCHIVE" -C "$BUILD_ROOT"
ffprobe_patch_source "$BUILD_ROOT/ffmpeg-$FFMPEG_VERSION"
mkdir "$BUILD_ROOT/build"
cd "$BUILD_ROOT/build"
if [[ "${MSYSTEM:-}" == CLANGARM64 ]]; then
  ARCH=aarch64
  COMPILER=clang
else
  ARCH=x86_64
  COMPILER=gcc
fi
"$BUILD_ROOT/ffmpeg-$FFMPEG_VERSION/configure" \
  --target-os=mingw32 --arch="$ARCH" --cc="$COMPILER" --extra-ldflags=-static \
  "${FFPROBE_CONFIGURE[@]}"
make -j4 ffprobe.exe
cp ffprobe.exe "$OUTPUT_DIR/ffprobe.exe"
"$OUTPUT_DIR/ffprobe.exe" -L > "$OUTPUT_DIR/FFmpeg-LICENSE.txt"
CC="$COMPILER" ffprobe_build_record "$OUTPUT_DIR/ffprobe.exe" "Windows $ARCH ($MSYSTEM)" "$OUTPUT_DIR/FFmpeg-BUILD.txt"
ffprobe_verify_binary "$OUTPUT_DIR/ffprobe.exe"
cp "$ARCHIVE" "$OUTPUT_DIR/ffmpeg-$FFMPEG_VERSION-source.tar.xz"

ffprobe_copy_source_patch "$OUTPUT_DIR"
