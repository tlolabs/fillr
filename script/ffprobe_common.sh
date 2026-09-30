#!/usr/bin/env bash
# Shared, pinned FFprobe source and feature set for all release targets.
FFMPEG_VERSION=9.0.2
FFMPEG_SOURCE_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
FFPROBE_CONFIGURE=(
  --disable-shared --enable-static --disable-asm --disable-autodetect
  --disable-gpl --disable-nonfree --disable-network --disable-doc
  --disable-programs --enable-ffprobe --disable-everything
  --enable-demuxer=mpegps,mpegvideo,mpegts,mov,mxf,avi,matroska,wav,aiff,mp3
  --enable-parser=mpegvideo,h264,hevc,mpeg4video,vc1,vp9,av1,aac,mpegaudio
  --enable-decoder=mpeg2video,h264,hevc,mpeg4,prores,vc1,vp9,av1,dvvideo,mjpeg,aac,mp3
  --enable-protocol=file
)

ffprobe_source_archive() {
  printf '%s/target/ffmpeg-%s.tar.xz' "$ROOT_DIR" "$FFMPEG_VERSION"
}

ffprobe_verify_source() {
  local archive actual
  archive="$(ffprobe_source_archive)"
  mkdir -p "$ROOT_DIR/target"
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --silent --show-error "$FFMPEG_SOURCE_URL" --output "$archive"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  fi
  if [[ "$actual" != "$FFMPEG_SHA256" ]]; then
    echo "FFmpeg $FFMPEG_VERSION source checksum mismatch: expected $FFMPEG_SHA256, got $actual" >&2
    return 1
  fi
}

ffprobe_build_record() {
  local executable="$1" target="$2" record="$3"
  local compiler_version
  compiler_version="$("${CC:-cc}" --version)"
  {
    printf 'FFmpeg version: %s\nSource: %s\nSHA-256: %s\nTarget: %s\n' \
      "$FFMPEG_VERSION" "$FFMPEG_SOURCE_URL" "$FFMPEG_SHA256" "$target"
    printf 'Build host: '; uname -a
    printf 'Compiler: %s\n' "${compiler_version%%$'\n'*}"
    printf 'Shared configure arguments:'; printf ' %q' "${FFPROBE_CONFIGURE[@]}"; printf '\n'
    "$executable" -version
  } > "$record"
}

ffprobe_verify_binary() {
  local executable="$1" version
  version="$("$executable" -version 2>&1)"
  [[ "$version" == "ffprobe version $FFMPEG_VERSION "* ]] || {
    echo "Built FFprobe version does not match $FFMPEG_VERSION" >&2; return 1;
  }
  [[ "$version" == *'--disable-gpl'* && "$version" == *'--disable-nonfree'* ]] || {
    echo 'Built FFprobe has unexpected license configuration' >&2; return 1;
  }
  if "$executable" -L | grep -q 'GNU General Public License'; then
    echo 'Expected an LGPL-only FFprobe build' >&2; return 1;
  fi
  "$executable" -demuxers | grep -Eq '^ D +mpeg +MPEG-PS' || {
    echo 'Built FFprobe is missing MPEG-PS demuxer' >&2; return 1;
  }
  "$executable" -demuxers | grep -Eq '^ D +mov,mp4,m4a,3gp,3g2,mj2 ' || {
    echo 'Built FFprobe is missing MP4/MOV demuxer' >&2; return 1;
  }
}
