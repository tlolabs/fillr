# FILLR

A local desktop utility for collecting CNN MPG footage and preparing the 14 Chabot News background Comps. Comps 1 and 6 are reserved; the app fills Comps 2–16 except 6 with at least **10:05** of whole clips each.

## Workflow

1. Open the app and choose the folder receiving CNN downloads. Only top-level, settled files that match the media preferences count. Temporary `#work_file#` and `#chkpt_file#` objects, recently changing files, and nested exports are ignored.
2. The main window and optional floating panel count down from **141:10**. The app shows **Ready** only after it has found a valid assignment of unique clips to all 14 Comps. It sends one desktop notification on the transition to Ready.
3. Click **Build Comp Folders**. The app rechecks every source file, then creates a dated `Chabot News Comps ...` directory inside the chosen folder. Selected clips move into `Comp 2` through `Comp 16` (skipping 6) with random eight-digit filenames. Stable unused clips, including unreadable MPGs, move into `Unused`. Active downloads remain at the top level.
4. Import the Comp folders into Premiere Pro. `manifest.csv` records every move, including original CNN filenames when an existing `rename-map-*.csv` supplies them.

Exact byte-for-byte duplicate files are removed automatically after hash and byte comparison. The app keeps a dated `.backgrounder-duplicates.log` in the watched folder. Similar footage with different bytes is not identified yet. The app does not split or transcode clips.

## Media preferences

Open **Media Preferences…** in FILLR to edit the default NTSC 1080i preset. The enabled default accepts MPEG-2 video in an MPEG container at 1920×1080, 29.97 fps, interlaced, horizontal 16:9, with an `.mpg` extension. Extension, container, codec, resolution, frame rate, NTSC/PAL, scan type, orientation, and display aspect ratio can each be changed or set to any. The default also deletes rejected downloads once they have a final filename, no matching Signiant work/checkpoint companion, and at least ten seconds of unchanged observation. Turn off **Delete rejected completed downloads** to exclude them from FILLR without deleting them, or turn off **Filter media** to disable the profile checks.

FILLR never deletes a `#work_file#` or `#chkpt_file#`. A failed or incomplete media probe cannot authorize deletion. On macOS, FILLR also waits until `lsof` reports that no process has the file open; if that check fails, deletion is deferred. Deleted media and its rejection reasons are recorded in `.fillr-rejections.log` in the watched folder. A read-only preview of a folder is available with `cargo run -p fillr-core --bin fillr-media-check -- "FOLDER"` after building FILLR's probe.

## Source layout

- `crates/fillr-core`: Rust watcher, probing, duplicate handling, allocation, recovery journal, and versioned C ABI.
- `native/macos`: SwiftUI app with AppKit floating panel.
- `native/windows`: WinUI 3 app, unpackaged and self-contained.
- `native/linux`: GTK4 app.
- `script`: local run and release helpers.

The engine runs FILLR's own packaged `ffprobe` to read video duration and media profile. The probe is a separate executable; the app does not link FFmpeg into its Rust engine. See [FFprobe dependency and build notes](docs/ffprobe.md) for the pinned source, supported media, packaging, tests, and license materials.

## Development

```sh
cargo test -p fillr-core
./script/build_ffprobe_macos.sh # macOS; use the matching platform script elsewhere
cargo run -p fillr-core --bin fillr-inspect -- "CNN VIdeos"
./script/build_and_run.sh
```

`fillr-inspect` is read-only. It does not delete duplicates or move media. The Mac run script uses full Xcode if installed at `/Applications/Xcode.app`, stages a real `.app` bundle under `dist/`, and launches it.

## Download flight recorder (macOS)

Double-click **Start FILLR Download Monitor.command** in this project folder. Choose the CNN download folder in the Mac picker, then press Enter to start. Press Enter again to stop and save the summary. Logs are saved under `~/Documents/FILLR Monitor Logs` in a new folder for each session. You can also run `python3 script/monitor_downloads.py "/path/to/folder"` in Terminal and stop with Control-C. This diagnostic tool only observes downloads; it does not change FILLR's ingest decisions. See [the monitor guide](script/README-monitor.md) for options, log formats, and a controlled test procedure.

## Upgrade compatibility

FILLR retains the macOS bundle identifier `edu.chabot.news.backgrounder` to keep its preferences, notification identity, and signing continuity. Linux retains the same application ID for the same reason. These identifiers are historical compatibility values, not the product name. Changing them later would require an explicit data and update migration. Because the macOS bundle filename changes to `FILLR.app`, a drag-and-drop update may leave the previous app alongside it; remove the previous bundle after installing FILLR to avoid two apps with the same bundle identifier.

FILLR saves the selected folder under its new name on Windows and Linux. On first launch after an update, it reads the previous `ChabotBackgrounder` or `chabot-backgrounder` settings path when the new one does not exist, then saves to the new path. The existing `.backgrounder-duplicates.log` filename remains in watched folders so new duplicate entries append to the same audit file. The previous probe path overrides are no longer used; FILLR resolves only its packaged FFprobe. The Rust library and its exported C symbols have new FILLR names; any external consumers of the prior development ABI must rebuild against `fillr.h` and `libfillr_core`.

On Linux, install GTK4 development libraries and run `./script/run_linux.sh`. On Windows, build in Visual Studio with the .NET 8 SDK, then run the Windows release script described below.

## Release targets

| System | Architectures | Initial package |
| --- | --- | --- |
| macOS 13+ | x86-64 + ARM64 | Universal signed and notarized ZIP |
| Windows 10/11 | x64, ARM64 | Separate unsigned self-contained ZIPs |
| Linux | x86-64, ARM64 | Separate AppImages |

Windows signing can be added to CI when a publicly trusted signing service or certificate is available. The Linux overlay requests topmost placement on X11. Wayland may not keep it above all other applications; the window remains movable, and the main window and notification remain available.

## Packaging

The workflow in `.github/workflows/build.yml` prepares unsigned macOS and Windows ZIPs plus Linux AppImages on native x86-64 and ARM64 runners. It runs on pushes to `main` and version tags, and a successful tag build publishes the Windows ZIPs and Linux AppImages to a GitHub Release. It runs the Rust tests on each system, builds a matching LGPL-only `ffprobe` from the pinned FFmpeg 9.0.2 source, and includes its license, build details, and source archive. Windows downloads are ZIPs containing the WinUI 3 and .NET runtimes; users extract the full ZIP before launching the app. The Linux AppImage uses GTK4 from the build environment and includes its linked libraries, so it targets distributions compatible with Ubuntu 24.04 or newer.

For a local Mac release, set `APPLE_DEVELOPER_ID` to the Developer ID Application identity and `NOTARY_PROFILE` to the saved `notarytool` keychain profile name (`EnCAP` on the maintainer's Mac), then run `./script/release_macos.sh signed`. The script verifies both slices of the app, engine, and probe, signs the app, submits a ZIP to Apple, staples the returned ticket to `FILLR.app`, then creates the distributable ZIP. Users can unzip it and move `FILLR.app` to Applications. `./script/release_macos.sh --sign-only` stops before notarization, and `--unsigned` produces a development ZIP.

The Windows CI step runs `build_ffprobe_windows.sh` in the matching MSYS2 UCRT64 or CLANGARM64 shell, then `release_windows.ps1 -Architecture x64` or `arm64`. The Linux step runs `release_linux.sh` with `APPIMAGETOOL` pointing to an architecture-matched appimagetool. The `ffprobe` source archive and build record are included for license compliance. Windows code signing requires a later, trusted signing identity; a CI certificate made solely for the workflow would not establish publisher trust.

## Recovery

Build moves are recorded in `journal.json` before any source clip is moved. An interrupted build leaves a `.building-*` directory. The next app launch restores moved clips to the download folder and removes that staging directory. If recovery cannot safely restore a file, the app stops and reports the staging directory path for manual review.
