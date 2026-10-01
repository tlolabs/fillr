#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
RID=linux-x64
[[ "$ARCH" == aarch64 ]] && RID=linux-arm64
PROBE_DIR="$ROOT_DIR/dist/ffprobe-linux-$ARCH"
"$ROOT_DIR/script/build_ffprobe_linux.sh" "$PROBE_DIR"
cargo build --locked --manifest-path "$ROOT_DIR/Cargo.toml" -p fillr-core -p fillr-update
export AVALONIA_TELEMETRY_OPTOUT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
dotnet publish "$ROOT_DIR/native/desktop/FILLR.Desktop.csproj" -c Debug -f net10.0 -r "$RID" --self-contained true -p:RestoreLockedMode=true -o "$ROOT_DIR/dist/linux-development"
cp "$PROBE_DIR/ffprobe" "$ROOT_DIR/target/debug/libfillr_core.so" "$ROOT_DIR/target/debug/fillr-update" "$ROOT_DIR/dist/linux-development/"
exec "$ROOT_DIR/dist/linux-development/FILLR" "$@"
