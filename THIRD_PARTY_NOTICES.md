# Third-party components in desktop packages

FILLR's own source is GPL-3.0-or-later. Package scripts dynamically deploy the following third-party components. The exact transitive library list depends on the target and Qt build; inspect the produced package and its bundled notices for the release being distributed.

| Component | Shipped targets | License and source information |
| --- | --- | --- |
| Qt 6 Core, Gui, Widgets, Network | Windows, Linux, internal macOS Qt | LGPL-3.0 or GPL-3.0 open-source options; [Qt licensing](https://doc.qt.io/qt-6/licensing.html), [qtbase source](https://code.qt.io/cgit/qt/qtbase.git/) |
| Qt platform and style plugins | Windows `qwindows`, Linux XCB/Wayland, internal macOS Cocoa/macstyle | See `licenses/Qt-NOTICE.txt`, Qt's [third-party code inventory](https://doc.qt.io/qt-6/licenses-used-in-qt.html), and package-specific copyright/SPDX files |
| libnotify and GLib | Linux notifications | Ubuntu package copyright files bundled under `usr/share/licenses/system-libraries` |
| Rust dependencies | All platforms | Generated `Rust-LICENSES.txt` in each package; Cargo.lock and `script/package_rust_licenses.py` identify the exact versions and source |
| FFprobe and pinned FFmpeg source | All platforms | `licenses/FFmpeg-NOTICE.txt`, `docs/ffprobe.md`, and bundled source archive/build patch |
| Sparkle | Production macOS only | Bundled Sparkle license and third-party notices through `script/embed_sparkle.sh` |
| Windows SDK projection and packaging tools | Windows build/deployment | `licenses/Windows-SDK-LICENSE.txt`; tooling is not itself shipped as an app runtime |

The Qt libraries/frameworks are dynamic and remain separate from FILLR's executable. The internal Mac bundle includes a qtbase SPDX SBOM from its Homebrew installation when available. The Linux AppImage copies distribution copyright notices for bundled libraries. The Windows release script copies Qt's license directory or SPDX SBOM when present. Before a public signed release, inspect the exact package to confirm complete notices and source availability for the Qt binaries and plugins actually shipped.
