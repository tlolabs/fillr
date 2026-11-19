#!/usr/bin/env bash
# Build the libraries linked by FILLR's native background engine. No FFmpeg
# executable, external codec library, Homebrew dependency, or runtime download.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/script/ffprobe_common.sh"
OUTPUT="$ROOT_DIR/target/background-ffmpeg"
ARCHIVE="$(ffprobe_source_archive)"
RECIPE="$(cat "$ROOT_DIR/script/build_background_ffmpeg_macos.sh" "$ROOT_DIR/script/ffprobe_common.sh" "$ROOT_DIR/script/patches/FFmpeg-minimal-build.patch" | shasum -a 256 | awk '{print $1}')"
LIBRARIES=(avformat avcodec avutil swscale)
if [[ -f "$OUTPUT/recipe.sha256" && "$(cat "$OUTPUT/recipe.sha256")" == "$RECIPE" ]]; then
  ready=true
  for library in "${LIBRARIES[@]}"; do
    if [[ ! -f "$OUTPUT/lib/lib$library.a" ]] ||
       ! lipo "$OUTPUT/lib/lib$library.a" -verify_arch arm64 >/dev/null 2>&1 ||
       ! lipo "$OUTPUT/lib/lib$library.a" -verify_arch x86_64 >/dev/null 2>&1; then ready=false; fi
  done
  if [[ "$ready" == true && -f "$OUTPUT/include/libavcodec/avcodec.h" ]]; then
    echo "Native FFmpeg libraries are current: $OUTPUT"
    exit 0
  fi
fi

ffprobe_verify_source
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fillr-background-ffmpeg.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
tar -xf "$ARCHIVE" -C "$BUILD_ROOT"
SOURCE="$BUILD_ROOT/ffmpeg-$FFMPEG_VERSION"
ffprobe_patch_source "$SOURCE"
CONFIGURE=(
  --target-os=darwin --enable-cross-compile --disable-autodetect
  --disable-gpl --disable-nonfree --disable-network --disable-doc
  --disable-programs --disable-everything --disable-avdevice --disable-avfilter
  --disable-swresample --disable-shared --enable-static --enable-pic
  --disable-debug --disable-x86asm --enable-videotoolbox
  --enable-protocol=file
  --enable-demuxer=mpegps,mpegvideo,mpegts,mov,mxf,avi,matroska
  --enable-parser=mpegvideo,h264,hevc,mpeg4video,vc1,vp9,av1,mpegaudio,aac,ac3
  --enable-decoder=mpeg2video,h264,hevc,mpeg4,prores,vc1,vp9,av1,dvvideo,mjpeg,mp2,mp3,aac,ac3,eac3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_u8,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_dvd
  --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,mpeg2_videotoolbox
  --enable-encoder=mpeg2video,prores_ks,pcm_s24le --enable-muxer=mpeg2video,mov
)
for pair in arm64:aarch64 x86_64:x86_64; do
  DARWIN_ARCH="${pair%%:*}"
  FFMPEG_ARCH="${pair##*:}"
  BUILD="$BUILD_ROOT/build-$DARWIN_ARCH"
  PREFIX="$BUILD_ROOT/install-$DARWIN_ARCH"
  mkdir -p "$BUILD"
  cd "$BUILD"
  "$SOURCE/configure" "${CONFIGURE[@]}" --arch="$FFMPEG_ARCH" \
    --prefix="$PREFIX" --cc="clang -arch $DARWIN_ARCH" \
    --extra-cflags="-arch $DARWIN_ARCH -mmacosx-version-min=13.0" \
    --extra-ldflags="-arch $DARWIN_ARCH -mmacosx-version-min=13.0"
  make -j"${FILLR_FFMPEG_JOBS:-4}"
  make install-libs install-headers
done

# Stage completely before replacing the last usable build.
STAGE="$BUILD_ROOT/staged"
mkdir -p "$STAGE/lib"
cp -R "$BUILD_ROOT/install-arm64/include" "$STAGE/include"
for library in "${LIBRARIES[@]}"; do
  lipo -create "$BUILD_ROOT/install-arm64/lib/lib$library.a" "$BUILD_ROOT/install-x86_64/lib/lib$library.a" -output "$STAGE/lib/lib$library.a"
  lipo "$STAGE/lib/lib$library.a" -verify_arch arm64
  lipo "$STAGE/lib/lib$library.a" -verify_arch x86_64
done
cp "$SOURCE/COPYING.LGPLv2.1" "$STAGE/FFmpeg-Background-LICENSE.txt"
cp "$ARCHIVE" "$STAGE/ffmpeg-$FFMPEG_VERSION-source.tar.xz"
ffprobe_copy_source_patch "$STAGE"
{
  printf 'FFmpeg native background libraries: %s\nSource: %s\nSHA-256: %s\n' "$FFMPEG_VERSION" "$FFMPEG_SOURCE_URL" "$FFMPEG_SHA256"
  printf 'Target: macOS 13+, universal arm64 + x86_64; static app linkage.\n'
  printf 'Local changes: included FFmpeg-minimal-build.patch; apply with patch -p1.\n'
  printf 'No FFmpeg CLI, runtime download, external codec dependency or network protocols.\n'
  printf 'Configure:'; printf ' %q' "${CONFIGURE[@]}"; printf '\n'
  printf 'Recipe SHA-256: %s\n' "$RECIPE"
} > "$STAGE/FFmpeg-Background-BUILD.txt"
printf '%s\n' "$RECIPE" > "$STAGE/recipe.sha256"
mkdir -p "$ROOT_DIR/target"
rm -rf "$OUTPUT"
mv "$STAGE" "$OUTPUT"
echo "Built native FFmpeg libraries: $OUTPUT"
