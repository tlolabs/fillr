#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/ffprobe_common.sh"
ARCHIVE="$(ffprobe_source_archive)"
OUTPUT="$ROOT_DIR/dist/ffprobe-universal"
mkdir -p "$ROOT_DIR/target" "$ROOT_DIR/dist"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fillr-ffmpeg.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
SOURCE="$BUILD_ROOT/ffmpeg-$FFMPEG_VERSION"

ffprobe_verify_source
tar -xf "$ARCHIVE" -C "$BUILD_ROOT"
ffprobe_patch_source "$BUILD_ROOT/ffmpeg-$FFMPEG_VERSION"

for pair in "arm64:aarch64" "x86_64:x86_64"; do
  DARWIN_ARCH="${pair%%:*}"
  FFMPEG_ARCH="${pair##*:}"
  BUILD="$BUILD_ROOT/build-$DARWIN_ARCH"
  mkdir -p "$BUILD"
  cd "$BUILD"
  "$SOURCE/configure" \
    --target-os=darwin --arch="$FFMPEG_ARCH" --enable-cross-compile \
    --cc="clang -arch $DARWIN_ARCH" \
    --extra-cflags="-arch $DARWIN_ARCH -mmacosx-version-min=13.0" \
    --extra-ldflags="-arch $DARWIN_ARCH -mmacosx-version-min=13.0" \
    "${FFPROBE_CONFIGURE[@]}"
  make -j4 ffprobe
  cp ffprobe "$ROOT_DIR/dist/ffprobe-$DARWIN_ARCH"
done

lipo -create "$ROOT_DIR/dist/ffprobe-arm64" "$ROOT_DIR/dist/ffprobe-x86_64" -output "$OUTPUT"
chmod +x "$OUTPUT"
"$OUTPUT" -L > "$ROOT_DIR/dist/FFmpeg-LICENSE.txt"
CC=clang ffprobe_build_record "$OUTPUT" 'macOS universal arm64 + x86_64' "$ROOT_DIR/dist/FFmpeg-BUILD.txt"
ffprobe_verify_binary "$OUTPUT"
if [[ -n "${SAMPLE_MPG:-}" ]]; then
  "$OUTPUT" -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 "$SAMPLE_MPG" | grep -Eq '^mpeg2video,[1-9][0-9]*,[1-9][0-9]*'
fi
if [[ -n "${SAMPLE_MP4:-}" ]]; then
  "$OUTPUT" -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 "$SAMPLE_MP4" | grep -Eq '^h264,[1-9][0-9]*,[1-9][0-9]*'
fi
cp "$ARCHIVE" "$ROOT_DIR/dist/ffmpeg-$FFMPEG_VERSION-source.tar.xz"
echo "Built $OUTPUT"

ffprobe_copy_source_patch "$ROOT_DIR/dist"
