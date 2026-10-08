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

Qt is dynamically linked. Package maintainers must retain notices for the exact deployed Qt modules, plugins and their third-party code. Qt's [license overview](https://doc.qt.io/qt-6/licensing.html) and [third-party code inventory](https://doc.qt.io/qt-6/licenses-used-in-qt.html) describe these obligations. A passing build does not by itself establish distribution compliance.

This file records architecture and verification methods. Actual run results belong in the task report or CI run for the corresponding commit.
