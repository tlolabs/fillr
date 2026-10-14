# FILLR Audit Remediation Report

**Date:** October 14, 2026  
**Repository:** `/Users/tlothian/Documents/Projects/FILLR`  
**Author:** Tom Lothian `<153565009+TLothian-CC@users.noreply.github.com>`  
**Starting HEAD:** `ce64cc8fb9b39dbfe4b3b30b8f92bda8b5f68570` ("Optimize directory ingest, probe latency, and allocation solver")  
**Target Branch:** `main` (local only, no remote push or PR)  

---

## Executive Summary & Scope

This remediation addresses all 21 findings identified in `FILLR-Agent-Audit-1.md` across six phases:
- **Phase 1: Filesystem safety, numeric correctness, and destructive operations** (SEC-01, SEC-02, CQ-01, CQ-06, CQ-07, CQ-09)
- **Phase 2: Shared validation, transactional settings, and responsiveness** (CQ-02, CQ-03, CQ-04)
- **Phase 3: Updater state and untrusted text** (CQ-05, SEC-04, SEC-03)
- **Phase 4: Accessibility** (A11Y-01, A11Y-02, A11Y-03, A11Y-04)
- **Phase 5: Dependencies, reproducibility, and packaging** (DEP-01, DEP-02, DEP-03, DEP-04)
- **Phase 6: FFI contracts and architecture** (CQ-08, and other audit observations)

All changes are implemented locally, regression tests added, verified across test suites (`cargo test`, `swift test`, CTest), and committed with DCO sign-offs (`git commit -s`).

---

## Master Remediation Tracking Table

| Finding ID | Category | Severity / Priority | Description | Affected Locations | Planned Correction & Tests | Final Disposition |
|---|---|---|---|---|---|---|
| **SEC-01** | Security | Medium | Unsafe action-log writes in watched folder with unrestricted create/append | `crates/fillr-core/src/scan.rs` | Race-resistant opening (`O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK`), descriptor validation via `fstat`, regular file check, link count <= 1, ownership verification, control character escaping (`\n`, `\r`, `\t`). Regression tests for symlinks, hardlinks, FIFOs, and newlines. | Remediated |
| **SEC-02** | Security / Correctness | Medium | Duration conversion & unchecked arithmetic | `crates/fillr-core/src/probe.rs`, `allocation.rs`, `scan.rs` | Documented duration limits (`MAX_CLIP_DURATION_MS` = 7 days), checked arithmetic with explicit errors throughout totals, allocation, scoring, group totals, and public APIs. Boundary & overflow tests. | Remediated |
| **SEC-03** | Security | Medium | Spreadsheet formula injection in exported filenames | `crates/fillr-core/src/export.rs` | Formula neutralization (prefixing leading `=`, `+`, `-`, `@`, `\t`, `\r` with single quote `'`) for human reports/manifests while preserving raw filenames in machine-readable interchange (`journal.json`). Unit test `manifest_neutralizes_spreadsheet_formula_prefixes`. | Remediated |
| **SEC-04** | Security | Low | Qt rich-text interpretation of untrusted filenames/paths | `native/qt/MainWindow.cpp`, `SettingsDialog.cpp` | Set `Qt::PlainText` on labels displaying filenames, paths, errors, diagnostics. Added `errorLabelIsPlainTextAndResistsHtmlInjection` test in `accessibility_tests.cpp`. | Remediated |
| **CQ-01** | Code Quality | Medium | Unverified file completion before deletion | `crates/fillr-core/src/scan.rs` | Replace non-macOS constant closed (`Ok(false)`) with truthful three-state semantics (`FileOpenStatus::Open`, `Closed`, `Unknown`). Check completion markers (`#work_file#`, `#chkpt_file#`) for both candidate and keeper, platform-specific sharing/descriptor checks where available, re-verify keeper/target stamps immediately prior to deletion, and defer deletion if unknown or held. Tests for marker transitions and open handles. | Remediated |
| **CQ-02** | Code Quality | Medium | Inconsistent validation between native interfaces | `crates/fillr-core/src/media.rs`, `settings.rs`, `ffi.rs`, `native/macos`, `native/qt` | Rust authoritative validation boundary exposed via C ABI (`fillr_validate_media_policy`, `fillr_validate_sort_settings`). Documented canonical grammar for frame rate & aspect ratio with `parse_ratio_or_number`. Shared fixture table tests. Native interfaces delegate validation to Rust FFI. | Remediated |
| **CQ-03** | Code Quality | Medium | Partially applied or persisted settings | `crates/fillr-core/src/settings.rs`, `ffi.rs`, `native/macos`, `native/qt` | Transactional combined configuration setter (`fillr_set_configuration`) applying policy and sort under a single synchronization boundary. Atomic file replacement with rollback on persistence failure. Native stores rollback in-memory state on persistence failure. Preserved `sortSettings` across migration. | Remediated |
| **CQ-04** | Responsiveness | Medium | Blocking macOS engine operations on `@MainActor` | `native/macos/Sources/FILLR/Services/FillrStore.swift`, `EngineBridge.swift` | Moved blocking FFI calls, engine creation/teardown off `@MainActor` to a serialized background queue (`engineQueue`) with epoch tracking (`engineEpoch`) to prevent stale engine updates. UI state updates safely dispatched back to `@MainActor`. | Remediated |
| **CQ-05** | Reliability | Medium | Updater launch failure leaves interface busy | `native/qt/UpdateService.cpp`, `MainWindow.cpp` | Idempotent terminal-completion path for updater helper commands (`FailedToStart`, `Crashed`, JSON parse error). Resets command and busy state, emits actionable error to UI. | Remediated |
| **CQ-06** | Resource Management | Low | Unbounded action histories | `crates/fillr-core/src/scan.rs` | Cap underlying in-memory collections (`context.duplicate_log`, `context.rejection_log`) to 100 entries via `push_action_log`. Unit test `push_action_log_bounds_memory_to_100_entries`. | Remediated |
| **CQ-07** | Test Integrity | Low | Misleading rollback coverage | `crates/fillr-core/src/export.rs` | Renamed misleading preflight test to `change_during_preflight_aborts_without_moving_files`. Added deterministic fault injection hooks for mid-move identity changes, mid-move rename failures, and final publication failures. Asserted files are restored and recovery material preserved on failure. | Remediated |
| **CQ-08** | Documentation | Low | Public C ABI documentation | `crates/fillr-core/src/ffi.rs`, `native/macos/Sources/CFillr/include/fillr.h` | Documented pointer validity, UTF-8/NUL termination, returned-string ownership, matching free functions (`fillr_free_string` / `fillr_string_free`), handle lifetimes, thread safety, and panic containment. | Remediated |
| **CQ-09** | Reliability | Medium | Silently discarded filesystem errors | `crates/fillr-core/src/scan.rs`, `export.rs` | Replaced `.flatten()` in `scan.rs` with explicit entry error capture, setting `scan_incomplete = true`, reporting errors in `snapshot.excluded`, and pausing destructive deletions. In `export.rs`, propagated `original_names` I/O and CSV errors. | Remediated |
| **A11Y-01** | Accessibility | High | Progress names and values | `native/macos/Sources/FILLR/Views/ContentView.swift`, `OverlayController.swift`, `native/qt/MainWindow.cpp` | Meaningful accessible names and collected/required progress values on progress indicators. Hide decorative images from accessibility hierarchy. | Remediated |
| **A11Y-02** | Accessibility | Medium | Settings layout fixed geometry | `native/macos/Sources/FILLR/Views/MediaPreferencesView.swift`, `native/qt/SettingsDialog.cpp` | Replaced fixed dialog frames with flexible minimum and ideal sizing and scroll views; ensure Save/Cancel buttons remain reachable at large text scale. | Remediated |
| **A11Y-03** | Accessibility | Medium | Errors and meaningful status announcements | `native/macos`, `native/qt` | Associated validation errors with input fields via accessible descriptions; set focus transitions to invalid fields on validation failure; set `Qt::PlainText` on error and status labels. | Remediated |
| **A11Y-04** | Test Coverage | Medium | Accessibility verification coverage | `native/qt/accessibility_tests.cpp`, `native/macos/Tests` | Added Qt accessibility test suite `accessibility_tests.cpp` covering control names, PlainText resistance to injection, validation failure focus transition, and error association. Verified migration tests in macOS. | Remediated |
| **DEP-01** | Dependencies | Medium | Qt maintenance & advisories | `docs/qt-migration.md`, `licenses/Qt-NOTICE.txt` | Verify Qt advisory claims against upstream sources. Document exact Qt version (6.11.2), patches, and platform verification limitations. | Planned |
| **DEP-02** | Build Reproducibility | Medium | Pin GitHub Actions to verified full commit SHAs | `.github/workflows/*.yml` | Pin all third-party GitHub Actions to verified commit SHAs with version comments. | Planned |
| **DEP-03** | Packaging | Medium | Linux Wayland packaging | `script/release_linux.sh`, `bundle_linux_deps.py` | Package required QtWayland shell integration plugins (`wayland-shell-integration`, `wayland-graphics-integration-client`, etc.) rather than only `platforms/libqwayland*.so`. | Planned |
| **DEP-04** | Compliance / Provenance | Medium | Package notices and provenance | `script/package_rust_licenses.py`, `release_macos.sh` | Union Rust notice graphs across both architectures (`aarch64` and `x86_64`) for universal macOS builds; accurate third-party notice inventories. | Planned |

---

## Baseline Status

- **Baseline Tests Passing:**
  - `cargo test`: 81 tests passing (core, update, update-policy, updater)
  - `swift test`: 7 tests passing (UpdatePolicyTests & AppPreferencesTests)
  - `ctest`: 2 tests passing (`fillr_qt_settings` and `fillr_qt_accessibility`)
