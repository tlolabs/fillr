# FILLR

A local desktop utility for collecting CNN MPG footage and preparing the 14 Chabot News background Comps. Comps 1 and 6 are reserved; the app fills Comps 2–16 except 6 with at least **10:05** of whole clips each.

## Workflow

1. Open the app and choose the folder receiving CNN downloads. Only top-level, settled files that match the media preferences count. Temporary `#work_file#` and `#chkpt_file#` objects, recently changing files, and nested exports are ignored.
2. The main window and optional floating panel count down from **141:10** by default. The app shows **Ready** only after it has found a valid assignment of unique clips to every configured folder. It sends one desktop notification on the transition to Ready.
3. Click **Build Comp Folders**. The app rechecks every source file, then creates a dated `Chabot News Comps ...` directory inside the chosen folder. Selected clips move into `Comp 2` through `Comp 16` (skipping 6) with random eight-digit filenames. Stable unused clips, including unreadable MPGs, move into `Unused`. Active downloads remain at the top level.
4. Import the Comp folders into Premiere Pro. `manifest.csv` records every move, including original CNN filenames when an existing `rename-map-*.csv` supplies them.

Exact byte-for-byte duplicate files are removed automatically after hash and byte comparison. The app keeps a dated `.backgrounder-duplicates.log` in the watched folder. Similar footage with different bytes is not identified yet. The app does not split or transcode clips.

The macOS **Window → Layout** menu offers **Compact Panel**, **Horizontal Console**, and **Mini Monitor**, with a checkmark beside the current layout. Choosing any preset applies its layout and window size, including choosing the current preset again after manually resizing the window. In full screen, the size change waits until the window exits full screen. FILLR remembers the selected layout for the next launch, preserves restored or manually resized window dimensions until another preset selection, and keeps the same monitoring session running. All layouts follow the system's light or dark appearance. Expand **Downloads** for per-file speed estimates, **Folder preview** for the verified folder assignment, and **File notes** for exclusions and deletion logs. Mini Monitor groups these under **Details**; expand the window or scroll to inspect longer lists. The separate floating progress overlay remains available from the overlapping-window button.

On macOS, hold **⌘Q for 1.25 seconds** to quit; releasing early keeps FILLR open. Open Settings drafts can be deliberately discarded, and active folder builds finish their file moves before quitting. The compact Settings window separates General and Media preferences and provides labelled Hours, Minutes, and Seconds fields. General includes thumbnail choices for **DMC-12**, **Gradient**, and **6 Colors**. The default accent is Apple green, and progress bars follow the selected icon's palette.

The main window shows each download's **average download speed (estimated)** from observed file-size growth, including Signiant `#work_file#` transfers and media files with `.part` or `.crdownload` suffixes. The average counts only bytes added after FILLR first observes the file and includes pauses while the transfer remains active. The last completed average stays visible until another transfer begins or a different folder is opened. Existing files and transfers without enough observed growth show no rate. Disk buffering and preallocated files can make this differ from network throughput; it does not affect when footage becomes eligible for sorting.

## Media preferences

Open **Settings…** from the app menu on macOS or **Edit → Settings…** on Windows (**Edit → Preferences…** on Linux). Sorting defaults to 14 folders named `Comp` with the existing Comp numbering and a total of **2:21:10**; all three values can be changed. Other folder counts use numbers starting at 1. Media Preferences are in the same window. The enabled default accepts MPEG-2 video in an MPEG container at 1920×1080, 29.97 fps, interlaced, horizontal 16:9, with an `.mpg` extension. Extension, container, codec, resolution, frame rate, NTSC/PAL, scan type, orientation, and display aspect ratio can each be changed or set to any. The default also deletes rejected downloads once they have a final filename, no matching Signiant work/checkpoint companion, and at least ten seconds of unchanged observation. Turn off **Delete rejected completed downloads** to exclude them from FILLR without deleting them, or turn off **Filter media** to disable the profile checks.

FILLR never deletes a `#work_file#` or `#chkpt_file#`. A failed or incomplete media probe cannot authorize deletion. On macOS, FILLR also waits until `lsof` reports that no process has the file open; if that check fails, deletion is deferred. Deleted media and its rejection reasons are recorded in `.fillr-rejections.log` in the watched folder. A read-only preview of a folder is available with `cargo run -p fillr-core --bin fillr-media-check -- "FOLDER"` after building FILLR's probe.

## Source layout

- `crates/fillr-core`: Rust watcher, probing, duplicate handling, allocation, recovery journal, and versioned C ABI.
- `native/macos`: SwiftUI app with AppKit floating panel.
- `native/qt`: Qt Widgets UI for Windows/Linux and the internal Apple Silicon reference build.
- `script`: local run and release helpers.

The engine runs FILLR's own packaged `ffprobe` to read video duration and media profile. The probe is a separate executable; the app does not link FFmpeg into its Rust engine. See [FFprobe dependency and build notes](docs/ffprobe.md) for the pinned source, supported media, packaging, tests, and license materials.

Desktop dependency and source information is in [Third-party notices](THIRD_PARTY_NOTICES.md).

## Development

```sh
cargo test -p fillr-core
./script/build_ffprobe_macos.sh # macOS; use the matching platform script elsewhere
cargo run -p fillr-core --bin fillr-inspect -- "CNN VIdeos"
./script/build_and_run.sh
```

`fillr-inspect` is read-only. It does not delete duplicates or move media. The Mac run script uses full Xcode when its SDK is usable, otherwise the selected Command Line Tools, stages a real `.app` bundle under `dist/`, and launches it. With Command Line Tools that lack the macOS 27 SwiftUI macro plugin, it uses an installed macOS 26.5 SDK; `FILLR_MACOS_SDK` can select an explicit SDK.

### Git commits

Use `git commit -s` for a voluntary Developer Certificate of Origin sign-off. Direct pushes to `main` do not require a pull request, review, passing status checks, or cryptographic commit signing. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development and CI policy.

## Download flight recorder (macOS)

Double-click **Start FILLR Download Monitor.command** in this project folder. Choose the CNN download folder in the Mac picker, then press Enter to start. Press Enter again to stop and save the summary. Logs are saved under `~/Documents/FILLR Monitor Logs` in a new folder for each session. You can also run `python3 script/monitor_downloads.py "/path/to/folder"` in Terminal and stop with Control-C. This diagnostic tool only observes downloads; it does not change FILLR's ingest decisions. See [the monitor guide](script/README-monitor.md) for options, log formats, and a controlled test procedure.

## Upgrade compatibility

FILLR uses `com.tlolabs.fillr` as its macOS bundle identifier, Linux desktop identity, and signed update application ID. The previous macOS bundle identifier was `edu.chabot.news.backgrounder`. On first launch, FILLR copies the saved download folder, media policy, and automatic update choice from that preferences domain when each new-domain value is absent. It leaves the old preferences intact, so running the migration again does not overwrite later choices. Linux continues using its existing `fillr` settings directory; only its launcher and icon identity change.

The new macOS identifier is a distinct application identity. Install `FILLR.app` manually over the existing app; the old 0.1.0 build cannot discover this transition through automatic updates. The first distributable with the new identity must have a version newer than the published `v0.1.0`. macOS may ask for notification permission again. Future signed builds must keep the existing Developer ID team and use `com.tlolabs.fillr`; the updater rejects manifests signed for the previous application ID. Production update credentials and installed-upgrade qualification remain pending as described in [the updater architecture](docs/updater-architecture.md).

FILLR saves the selected folder under its new name on Windows and Linux. On first launch after an update, it reads the previous `ChabotBackgrounder` or `chabot-backgrounder` settings path when the new one does not exist, then saves to the new path. The existing `.backgrounder-duplicates.log` filename remains in watched folders so new duplicate entries append to the same audit file. The previous probe path overrides are no longer used; FILLR resolves only its packaged FFprobe. The Rust library and its exported C symbols have new FILLR names; any external consumers of the prior development ABI must rebuild against `fillr.h` and `libfillr_core`.

For Windows/Linux development, install Qt 6.4 or newer, CMake, and the existing Rust/native build tools. Build `fillr-core`, then configure `native/qt` with `-DFILLR_CORE_LIBRARY` set to the built native library. Run `ctest --test-dir` on the CMake build directory for presentation tests. On Linux install X11, fontconfig, libnotify development files and Qt platform plugins, then run `./script/run_linux.sh`. Windows packages use the release script below.

On Apple Silicon, `./script/build_qt_macos.sh` creates **FILLR-Qt-Internal.app** with separate preferences and no production updater. The production macOS application remains SwiftUI/AppKit. See [Qt migration and validation](docs/qt-migration.md).

## Release targets and automatic updates

FILLR now has native update controls backed by Sparkle on macOS and the shared TLO updater on Windows/Linux. Production update trust is not yet configured, so development builds fail closed. **No platform has completed an older-to-newer installed upgrade qualification.** See [the updater architecture, migration and release guide](docs/updater-architecture.md) for exact implementation status and blockers.

| System | Architectures | Production update package |
| --- | --- | --- |
| macOS 13+ | x86-64 + ARM64 | Universal Developer ID signed, notarized, stapled ZIP; signed Sparkle feed |
| Windows 10 build 19041+ | x64, ARM64 | Signed MSIX with pinned publisher and native Windows deployment |
| Linux, glibc 2.39+ | x86-64, ARM64 | Signed/attested AppImage with verified atomic replacement and backup |

Hosted native CI runs once weekly on Sunday morning Pacific for newly introduced version tags. It builds supported Linux and Windows targets and performs basic startup smoke checks. It does not build macOS, run full regression suites, retry jobs automatically, publish packages, sign artifacts, or create releases. Legacy workflows are inactive under `.github/workflow-archive/2026-11-08/`; GitHub-managed security services remain separate.

Releases are built, verified, and published separately under an owner instruction. Each platform can be released independently after its build, packaging, integrity, and available required functional checks pass. Unsigned downloads are prereleases and are not eligible for automatic updates. A Developer ID signature on a manual Mac download does not configure Sparkle trust or establish installed-upgrade qualification.

Linux x64 and ARM64 direct downloads are best-effort publications. Each AppImage needs a valid type and architecture, a verified SHA-256 checksum, and available automated tests. Run automated launch smoke checks when the infrastructure supports them; otherwise record the reason for skipping them in release notes. Optional accessibility failures are reported without blocking publication; a confirmed broken or unusable AppImage is withheld. Release notes distinguish **Build verified — community testing pending** from **Automated runtime verified — community testing pending**. Community testing occurs after publication and may generate GitHub Issues. See [AGENTS.md](AGENTS.md) for the permanent policy.

The archived automatic-update workflows remain inactive. Future authenticated updates require configured production trust, signing, and installed-upgrade evidence; runtime signature verification remains mandatory. Do not re-enable or dispatch archived workflows without a new explicit owner instruction.

The authoritative application version is `[workspace.package].version` in root Cargo.toml. Keep workspace package entries in Cargo.lock consistent when changing it, and verify the intended tag with `python3 script/version.py --tag vVERSION`.

For a standard local Mac distributable, set `APPLE_DEVELOPER_ID` to an existing Developer ID Application identity and `NOTARY_PROFILE` to an existing notarytool Keychain profile, and run `./script/release_macos.sh` (defaults to `signed`). Credentials are checked before compilation. Default/`signed` builds disable automatic updates and produce `FILLR-universal-local-notarized.zip`; no public update-key enrollment is required. Explicit `--production` retains the configured public-key requirement, all authenticated-update checks, and the updater-compatible `FILLR-universal-signed.zip` name. Existing release automation that needs that signed update artifact must select `--production`. The app must receive Apple's Accepted response, be stapled, and pass signature, staple and Gatekeeper checks before the final ZIP is made. `--unsigned` and `--sign-only` are explicit development/diagnostic alternatives, not standard notarized distributables; sign-only ZIPs are labeled `signed-unnotarized`. Ordinary `build_and_run.sh` iteration remains local development. No credentials are created or stored by these commands. Windows ZIPs require no signing credentials; `-Production` builds a signed MSIX only with a configured trusted Authenticode identity. Linux direct downloads use unsigned AppImages.

Existing FILLR installations have no updater and require one manual signed bridge installation. Windows portable users must transition to MSIX; that settings/data migration still needs native qualification.

## Recovery

Build moves are recorded in `journal.json` before any source clip is moved. An interrupted build leaves a `.building-*` directory. The next app launch restores moved clips to the download folder and removes that staging directory. If recovery cannot safely restore a file, the app stops and reports the staging directory path for manual review.
