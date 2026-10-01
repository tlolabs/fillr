# FILLR's FFprobe dependency

FILLR uses FFprobe to inspect video duration, container, codec, resolution, aspect ratio, field order, and frame rate before it counts or accepts downloaded clips. The Rust engine runs FFprobe as a separate process. The macOS, Windows, and Linux applications all use `owned_ffprobe_path` in `crates/fillr-core/src/probe_path.rs`: macOS loads `Contents/Resources/ffprobe`, while Windows and Linux load `ffprobe` beside the application executable. A missing or non-executable package probe produces an error. FILLR never searches `PATH` or uses the old `FILLR_FFPROBE`/`BACKGROUNDER_FFPROBE` overrides. The read-only inspection tools use a staged FILLR build artifact.

## Source and build

`script/ffprobe_common.sh` pins FFmpeg **9.0.2** to `https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz`, SHA-256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`. Each platform build script obtains or reuses this archive and checks its hash before extraction. The archive is cached in `target/`; no source or executable is downloaded at runtime. The build scripts produce only the `ffprobe` CLI and the FFmpeg libraries it needs internally. They do not build or ship the `ffmpeg` CLI. `--disable-autodetect`, `--disable-gpl`, `--disable-nonfree`, and `--disable-network` prevent accidental external library and nonfree additions. The full shared configure arguments are in `script/ffprobe_common.sh`; platform toolchain flags stay in their respective scripts.

Enabled demuxers are MPEG-PS, raw MPEG video, MPEG-TS, MOV/MP4, MXF, AVI, Matroska, WAV, AIFF, and MP3. Selected parsers and decoders cover MPEG-2, H.264, HEVC, MPEG-4, ProRes, VC-1, VP9, AV1, DV, MJPEG, AAC, and MP3 metadata. FILLR's default acceptance policy still accepts only MPEG-2 in MPG; editable policies may allow the other recognized video containers. A codec outside this list may not yield complete metadata, in which case FILLR excludes it safely. Widen the feature list only when a real media example requires it, and add a representative fixture or test at the same time.

Run the matching build command:

| Platform | Command | Staged probe |
| --- | --- | --- |
| macOS universal arm64 and x86-64 | `./script/build_ffprobe_macos.sh` | `dist/ffprobe-universal` |
| Linux native x86-64 or ARM64 | `./script/build_ffprobe_linux.sh` | `dist/ffprobe-linux-$(uname -m)/ffprobe` |
| Windows x64 or ARM64, in matching MSYS2 shell | `./script/build_ffprobe_windows.sh` | `dist/ffprobe-windows/ffprobe.exe` |

macOS development packages the staged probe via `script/build_and_run.sh`. Linux development uses `script/run_linux.sh`, which stages it beside the debug executable. Windows release packaging uses `script/release_windows.ps1` after the matching MSYS2 build. Release scripts package the architecture-matched binary, `FFmpeg-LICENSE.txt`, `FFmpeg-BUILD.txt`, and the exact verified source archive. `FFmpeg-BUILD.txt` records the version, source URL, hash, target, compiler, build host, configure arguments, and `ffprobe -version` output. The executable itself reports its FFmpeg version, compiler, and configure arguments with `-version`.

To update FFmpeg, change the version and verified checksum in `script/ffprobe_common.sh`, and the source archive filenames in the release scripts and CI. Obtain the new hash independently from the upstream release and verify it against the downloaded archive. Rebuild on all supported targets, confirm `ffprobe -version`, run the probe smoke test and Rust tests, and inspect each package. Do not claim a target is verified until its own CI job passes.

## Tests and licensing

CI compiles FFprobe from the verified source on macOS universal, Windows x64/ARM64, and Linux x86-64/ARM64. It verifies the packaged source hash, version and architecture, then runs `fillr-probe-smoke` against tiny synthetic MPG and MP4 fixtures with `PATH` hidden. That command uses the same package locator and `VideoProbe::media_info` code as the applications, so a system probe cannot satisfy the test. `cargo test -p fillr-core` also checks that a missing packaged probe has no system fallback.

The selected build reports **LGPL 2.1 or later** for FFprobe and no external libraries. FILLR is intended to be **GPL 3.0 or later**; this separate executable configuration is compatible with that intent. Do not enable FFmpeg's `nonfree` components. FFmpeg's source archive includes its LGPL and other component notices; distributed packages include the matching archive and `FFmpeg-LICENSE.txt`. The FFmpeg project also publishes a [distribution checklist](https://ffmpeg.org/legal.html). Recheck enabled modules, their licenses, and the distribution materials whenever the FFmpeg pin or feature set changes.

## Local source correction (October 1, 2026)

All builds apply `script/patches/FFmpeg-minimal-build.patch` to the verified source. It rejects AAC/AC3 parser branches when the respective parser is disabled, preventing an uninitialized bitrate read, and guards a WMV2-only label and data-demuxer-only function with their existing feature macros. No warning flags or enabled media features change. Packages include the pristine archive and this exact patch so the corresponding modified source can be reconstructed with `patch -p1`.
