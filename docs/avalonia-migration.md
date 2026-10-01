# Shared desktop presentation migration

The migration replaces WinUI 3 and GTK4 with one Avalonia 12.1.3 presentation implementation under `native/desktop`. Production macOS remains the existing SwiftUI/AppKit application. The ARM64 Mac Avalonia app is an internal reference, with identical AXAML, controls, view models and themes to Windows/Linux.

## Architecture and dependencies

The Rust C ABI remains the application boundary. No allocation, file-watching, media-filtering, duplicate, export or recovery logic is rewritten. `EngineHost` owns the Rust engine. `MainViewModel` coordinates state and commands through engine, settings, interaction and update interfaces. Views handle window/dialog interactions. Platform installers retain the authenticated Rust updater, Windows MSIX service and atomic AppImage replacement. Work guards serialize engine ownership, builds, preferences, dialogs and updates.

The application uses .NET 10 LTS, Avalonia Desktop and Fluent 12.1.3. Transitive dependencies include SkiaSharp 3.119.4, HarfBuzzSharp 8.3.1.3, MicroCom.Runtime 0.11.6, Tmds.DBus.Protocol 0.94.1, Avalonia native/AT-SPI libraries and ANGLE. The new Avalonia managed packages declare MIT; ANGLE carries upstream BSD and third-party notices. BuildServices 11.3.2 is an MIT build-only dependency; repository scripts disable its telemetry. No paid framework or service is required. The retained Windows installer/notification adapter also uses the Microsoft Windows SDK .NET projection, as the previous WinUI application did. This is governed by [Microsoft's separate SDK terms](https://aka.ms/WinSDKLicenseURL), not Avalonia's MIT license; the exact downloaded terms are included in Windows packages. Its redistribution and GPL system-library treatment require maintainer review before public production distribution; this migration does not claim legal clearance for that pre-existing dependency. Test dependencies are xUnit v3, Microsoft.NET.Test.Sdk and Avalonia.Headless.XUnit.

`package_nuget_licenses.py` checks the restored graph against reviewed license forms and embeds upstream notices, including native graphics notices and .NET runtime notices. Cargo and FFmpeg notices remain required. NuGet restore auditing runs with warnings as errors. Lock files record exact package versions and hashes.

## Parity ledger

Source baseline: `616bccd55d45a9a7b4fd29fb566e35a0542fffdb`, `native/windows/MainWindow.xaml.cs`, `OverlayWindow.xaml.cs`, `UpdateClient.cs`, and `native/linux/src/{main,updates}.rs`.

| Capability | Shared replacement | Evidence / remaining verification |
|---|---|---|
| Folder picker and remembered folder | StorageProvider and SettingsStore | Legacy Windows/Unix paths retained; persistence tests |
| All media policy fields and Any constraints | Shared PolicyWindow/PolicyEditor | Round-trip, invalid dimensions/ratios, cancellation tests |
| Rejected media/duplicate deletion and logs | Existing Rust engine | Existing core tests; no business-logic change |
| Countdown, progress, ready state, Comp preview, file counts | MainViewModel and shared AXAML | View-model and headless binding tests |
| Ready notification once per transition | Shared transition logic; native notification adapter | Transition tests; OS notification delivery needs manual verification |
| Always-on-top floating panel | Shared OverlayWindow, Topmost | Headless state test; window-manager behavior needs native checks |
| Build Comps, recovery and Open Last Export | Existing C ABI; background build; shell open adapter | Work/close guards tested; packaged media smoke and native UI checks required |
| Preferences persistence and errors | Atomic file replacement; rollback on save failure | Persistence, malformed data and rollback tests |
| Update consent, manual/automatic discovery | Shared commands; existing Rust helper | Mocked consent/failure tests; production A→B remains unqualified |
| Windows MSIX validation/install | WindowsPackageInstaller | Same identity, digest, publisher and deployment checks; native installation pending |
| Linux AppImage install/restart/recovery copy | Existing Rust helper; restart after lifetime and lock release | Deferred-update loop test; native installation pending |
| Quit during build/update/unsaved editor | Shared lifecycle guard | Automated tests |
| Keyboard and accessibility | Standard controls, focus, labels, live status, Ctrl+O/F5/Ctrl+comma | Headless input test; screen-reader/high-DPI/manual platform checks pending |
| Light/dark appearance | Fluent theme follows system | Native visual inspection pending |
| Menus, drag/drop, build cancellation | Neither retired UI implemented these | No existing workflow removed; export remains noncancellable and journaled |
| Command-line version | Shared `--version` | Packaging checks |
| Linux single-instance behavior | Settings-root lock | Prevents concurrent engines; second launch activates the existing window over a same-user pipe |

The native Mac app's richer platform-specific behavior remains unchanged. The internal reference app uses separate preferences and does not auto-load native Mac watched folders.

## Build and release boundaries

- Windows: self-contained x64/ARM64 packages through `release_windows.ps1`; production MSIX signing and qualification gates unchanged.
- Linux: self-contained x64/ARM64 AppImages through `release_linux.sh`; native runtime dependencies and notices are bundled. X11/XWayland is required; native Wayland compositor behavior is not asserted.
- Internal Mac: `script/build_avalonia_macos.sh`, ARM64 only, `FILLR-Avalonia-Internal.app`, ID `org.tlolabs.fillr.avalonia.internal`, settings under `FILLR-Avalonia-Internal`. Local ad-hoc signing only. No Sparkle, production helper, update feed, Developer ID requirement or notarization claim.
- Production Mac: existing native universal build and release scripts.

The desktop publish target refuses macOS unless `InternalReference=true` and refuses unsupported RIDs. Runtime macOS updater calls fail before launching helpers or network requests. CI uploads the internal ZIP under `INTERNAL-ONLY-FILLR-Avalonia-osx-arm64`; signed release jobs do not build or collect it. Release assembly rejects internal/Avalonia artifact names and still enforces the native Mac bundle identity, Sparkle configuration, signed evidence and exact production artifact whitelist. Isolation tests cover these boundaries.

## Validation status

Migration validation is in progress. A successful cross-compile is not native qualification. The preceding updater-only commit passed all eight jobs in [run 36835110410](https://github.com/tlolabs/fillr/actions/runs/36835110410); those results are baseline evidence, not evidence for this migration.

No production tag or release is authorized by this migration. Production updater trust/signing setup and real installed older-to-newer tests remain blocked as recorded in the updater guide.

Local manual reference test (2026-10-01): launched the packaged Apple Silicon app, verified its internal version identity and absent updater controls, rejected width=0 while retaining the editor, saved non-destructive fixture preferences, selected an isolated folder, observed 14 pending→14 ready clips and all Comp assignments, inspected the Topmost overlay, built the export through the UI, and opened it in Finder. Filesystem checks found 14 Comp folders, 14 media files, 14 manifest rows and no leftover `.building-*` directory. Normal quit/relaunch restored the fixture folder. Production media/settings were not used. This is reference-app evidence, not a Windows/Linux or updater qualification claim.

Local automated gates: 133 passing tests (78 Rust, 5 Swift, 20 release-tool Python, 30 Avalonia including headless tests); zero local skips. Full Rust workspace tests/Clippy/rustfmt, C# formatting, actionlint, ShellCheck, Python compilation, version and shared snapshot checks passed. RustSec found no vulnerabilities among 208 dependencies; NuGet reported no vulnerable direct/transitive packages. The four production UI RIDs cross-published with locked dependencies and warnings denied. Native production macOS universal and internal ARM64 packaging completed; both passed bundled MPG/MP4 smoke checks with PATH hidden. The internal bundle passed strict ad-hoc signature verification and isolation checks. Production signing and installed upgrade qualification are not claimed. Native Windows/Linux package results will be recorded after CI.
