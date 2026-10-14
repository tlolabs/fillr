# Qt desktop migration and verification

The production macOS 13+ application remains the SwiftUI/AppKit implementation in `native/macos`. Windows and Linux use the Qt Widgets application in `native/qt`, which calls the existing Rust `fillr-core` C ABI. The Apple Silicon Qt bundle targets macOS 15+ as an internal reference with a separate bundle identity and settings path; it has no production updater.

## Functional mapping

| Function | Implementation |
| --- | --- |
| Folder selection, saved folder, drag and drop | `MainWindow`, `SettingsStore` |
| Media policy, sorting, appearance | `SettingsDialog`, `SettingsStore`, Rust engine settings ABI |
| Refresh, progress, preview, build, open export | `MainWindow`, `EngineWorker`, Rust engine ABI |
| Ready notification and floating progress | Qt system tray on Windows, libnotify on Linux, Qt tool window |
| Windows signed MSIX and Linux AppImage updates | `UpdateService`, `WindowsInstaller`, bundled `fillr-update` helper |
| Single instance activation | Qt local server/socket |

Qt work runs on a worker thread and the Rust core retains scan, allocation, export, recovery, and media probe logic. The update helper retains manifest verification and publisher policy. The internal Mac app excludes update controls and helpers.

## Accessibility and appearance

Controls use Qt Widgets with accessible names for status, progress, preview and settings fields. Keyboard alternatives exist for folder selection, refresh, build, settings and overlay. The window uses a scroll area at constrained sizes. System, Light and Dark preferences persist; System is the default. Functional CTest cases and separate best-effort accessibility checks are wired into CI. This is not a WCAG certification or a claim of VoiceOver, UI Automation or AT-SPI testing on every target.

## Verification scope

Development CI builds x64 and ARM64 Windows, x86-64 and ARM64 Linux, the native universal Mac app, and the internal Apple Silicon Qt app. The Windows and Linux package jobs run the Qt settings tests and packaged FFprobe smoke checks. Accessibility tests run as nonblocking checks. Signed candidate jobs retain the existing trust and upgrade gates. Actual installed-upgrade qualification remains governed by `updater-architecture.md`.

## Deployed Qt versions and dependency maintenance (DEP-01)

Qt versions deployed across platforms:
- **Windows (x64 and ARM64):** Official Qt 6.8.3 LTS MSVC 2022 binaries (`win64_msvc2022_64` and `win64_msvc2022_arm64`) installed via `jurplel/install-qt-action`.
- **Linux (x86_64 and aarch64):** Canonical distribution-packaged Qt 6 (`qt6-base-dev`, `qt6-wayland`, `qt6-qpa-plugins`) on Ubuntu LTS runners, receiving upstream security backports through `apt`.
- **macOS (Developer reference only):** Current Homebrew Qt 6 (6.11.2). Production macOS releases use the native SwiftUI/AppKit application.

### Security advisory review and architecture containment

Advisories cited in the source audit were evaluated against authoritative upstream sources (The Qt Company Security Advisories, NVD, and distribution security trackers):
- **CVE-2023-51714 / CVE-2024-39936 (HTTP/2 / HPack state handling):** Affects `QtNetwork`. FILLR Qt desktop does not link `QtNetwork` or execute network protocols via Qt; all update operations are delegated to the isolated Rust update helper (`fillr-update`).
- **CVE-2024-36048 (QProcess command injection on Windows):** Resolved in Qt 6.8+ LTS. Furthermore, FILLR strictly invokes helper executables using structured argument vectors (`QProcess::start(QString, QStringList)`) without invoking a command shell.
- **Image/Format Parsers:** FILLR Qt does not load or parse untrusted video files or image metadata directly through Qt; probing is isolated in FFprobe with bounded stdout/stderr pipes and strict timeout enforcement.

## Linux Wayland packaging and verification limitations (DEP-03)

The Linux AppImage packaging script (`script/release_linux.sh`) packages both X11 and Wayland display integrations:
- Platform plugins: `platforms/libqxcb.so` and `platforms/libqwayland*.so`.
- QtWayland client integration plugins: `wayland-shell-integration`, `wayland-graphics-integration-client`, and `wayland-decoration-client`.
- Linked shared libraries and their corresponding Debian/Ubuntu copyright notices are gathered by `script/bundle_linux_deps.py`.

### Verification limitations:
- Automated CI testing runs under `Xvfb` (X11 virtual framebuffer). This verifies binary initialization, dynamic loader resolution, and functional logic under X11, but does not exercise native Wayland compositor integration.
- Native Wayland runtime testing is recorded as *Build verified — community testing pending* in accordance with repository release policy.

Qt is dynamically linked. Package maintainers must retain notices for the exact deployed Qt modules, plugins and their third-party code. Qt's [license overview](https://doc.qt.io/qt-6/licensing.html) and [third-party code inventory](https://doc.qt.io/qt-6/licenses-used-in-qt.html) describe these obligations. A passing build does not by itself establish distribution compliance.

This file records architecture and verification methods. Actual run results belong in the task report or CI run for the corresponding commit.
