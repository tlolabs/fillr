#!/bin/bash
# Development command-line renderer; does not package a distributable macOS app.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$repo_dir/.build/background_gpu"
ffmpeg_prefix="$(brew --prefix ffmpeg)"
mkdir -p "$build_dir/modules"
xcrun clang++ -O3 -std=c++17 -fobjc-arc -fmodules \
  -fmodules-cache-path="$build_dir/modules" -Wall -Wextra \
  -I"$ffmpeg_prefix/include" -L"$ffmpeg_prefix/lib" \
  "$repo_dir/script/background_gpu/main.mm" \
  "$repo_dir/script/background_gpu/GPUVideoSource.mm" \
  "$repo_dir/script/background_gpu/GPUProResDecoder.mm" \
  "$repo_dir/script/background_gpu/GPUDeinterlacer.mm" \
  "$repo_dir/script/background_gpu/GPUVideoEncoder.mm" \
  "$repo_dir/script/background_gpu/GPUCanvas.mm" \
  -lavformat -lavcodec -lavfilter -lavutil -lswscale \
  -framework Foundation -framework AVFoundation -framework VideoToolbox \
  -framework CoreVideo -framework CoreMedia -framework Metal -framework MetalKit \
  -framework CoreImage -framework ImageIO -framework CoreGraphics -framework MetalPerformanceShaders \
  -o "$build_dir/fillr-background-gpu"
python3 - "$repo_dir" "$build_dir" <<'PY'
import hashlib, json, pathlib, sys
repo, build = map(pathlib.Path, sys.argv[1:])
sources = sorted((repo / "script/background_gpu").glob("*")) + [
    repo / "script/background_gpu.py", repo / "script/build_background_gpu.sh"]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
manifest = {"source_sha256": {str(p.relative_to(repo)): sha(p) for p in sources if p.is_file()},
            "native_binary_sha256": sha(build / "fillr-background-gpu")}
(build / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
printf '%s\n' "$build_dir/fillr-background-gpu"
