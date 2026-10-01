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

### Git commits and tags

Use unsigned Git commits and tags for this repository. No PGP/GPG key is required. Run these commands once in each clone to override any global signing defaults:

```sh
git config --local commit.gpgsign false
git config --local tag.gpgsign false
```

Use ordinary `git commit` and `git tag` commands without `-S` or `-s`. To override signing for an individual commit, use `git -c commit.gpgsign=false commit`. These settings apply to linked worktrees unless a worktree has its own signing override; they are local Git configuration and are not copied by cloning.

The September 30, 2026 audit found all 10 historical commits and the `v0.1.0` tag already unsigned, with local and remote history matching. Existing commit messages and hashes were preserved; no history rewrite was needed. This policy concerns Git signatures. macOS application signing and notarization remain part of the release process below.

## Download flight recorder (macOS)

Double-click **Start FILLR Download Monitor.command** in this project folder. Choose the CNN download folder in the Mac picker, then press Enter to start. Press Enter again to stop and save the summary. Logs are saved under `~/Documents/FILLR Monitor Logs` in a new folder for each session. You can also run `python3 script/monitor_downloads.py "/path/to/folder"` in Terminal and stop with Control-C. This diagnostic tool only observes downloads; it does not change FILLR's ingest decisions. See [the monitor guide](script/README-monitor.md) for options, log formats, and a controlled test procedure.

## Upgrade compatibility

FILLR retains the macOS bundle identifier `edu.chabot.news.backgrounder` to keep its preferences, notification identity, and signing continuity. Linux retains the same application ID for the same reason. These identifiers are historical compatibility values, not the product name. Changing them later would require an explicit data and update migration. Because the macOS bundle filename changes to `FILLR.app`, a drag-and-drop update may leave the previous app alongside it; remove the previous bundle after installing FILLR to avoid two apps with the same bundle identifier.

FILLR saves the selected folder under its new name on Windows and Linux. On first launch after an update, it reads the previous `ChabotBackgrounder` or `chabot-backgrounder` settings path when the new one does not exist, then saves to the new path. The existing `.backgrounder-duplicates.log` filename remains in watched folders so new duplicate entries append to the same audit file. The previous probe path overrides are no longer used; FILLR resolves only its packaged FFprobe. The Rust library and its exported C symbols have new FILLR names; any external consumers of the prior development ABI must rebuild against `fillr.h` and `libfillr_core`.

On Linux, install GTK4 development libraries and run `./script/run_linux.sh`. On Windows, build in Visual Studio with the .NET 8 SDK, then run the Windows release script described below.

## Release targets and automatic updates

FILLR now has native update controls backed by Sparkle on macOS and the shared TLO updater on Windows/Linux. Production update trust is not yet configured, so development builds fail closed. **No platform has completed an older-to-newer installed upgrade qualification.** See [the updater architecture, migration and release guide](docs/updater-architecture.md) for exact implementation status and blockers.

| System | Architectures | Production update package |
| --- | --- | --- |
| macOS 13+ | x86-64 + ARM64 | Universal Developer ID signed, notarized, stapled ZIP; signed Sparkle feed |
| Windows 10 build 19041+ | x64, ARM64 | Signed MSIX with pinned publisher and native Windows deployment |
| Linux, glibc 2.39+ | x86-64, ARM64 | Signed/attested AppImage with verified atomic replacement and backup |

`build.yml` produces development artifacts only, including unsigned Windows ZIPs. It no longer publishes unsigned tag builds as stable releases. `release-updates.yml` produces authenticated candidates after tests and platform signing; `publish-updates.yml` requires real native upgrade evidence before promotion and verifies the published GitHub assets afterward.

The authoritative application version is `[workspace.package].version` in root Cargo.toml. After changing it, run `python3 script/version.py --sync`; CI checks generated native copies and rejects a mismatching tag.

For a signed local Mac release, configure FILLR's public update trust, set `APPLE_DEVELOPER_ID` and `NOTARY_PROFILE`, and run `./script/release_macos.sh signed`. `--unsigned` remains available for development. Windows release packaging accepts `-Production` only with a configured trusted Authenticode identity; no self-signed fallback is provided. Linux keeps the AppImage distribution and shared signing identity.

Existing FILLR installations have no updater and require one manual signed bridge installation. Windows portable users must transition to MSIX; that settings/data migration still needs native qualification.

## Recovery

Build moves are recorded in `journal.json` before any source clip is moved. An interrupted build leaves a `.building-*` directory. The next app launch restores moved clips to the download folder and removes that staging directory. If recovery cannot safely restore a file, the app stops and reports the staging directory path for manual review.
