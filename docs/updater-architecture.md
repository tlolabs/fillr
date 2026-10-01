# Automatic desktop updates

Status on October 1, 2026: FILLR audit fixes and local verification only. **No application/platform is end-to-end qualified by this work.** Production trust is intentionally unconfigured and release promotion is blocked. Local results are recorded in [updater-validation.json](updater-validation.json). No release, key, certificate, or sibling application repository was changed.

## Architecture decision

Use the existing standalone TLO updater snapshot already shared by ATIV and EnCAP, without an AVID Core dependency. FILLR vendors it in `updater/` for independently reproducible checkouts. `UPSTREAM.json` identifies the imported bytes; `SNAPSHOT.json` pins the resulting implementation. This is source reuse, not a claim that a standalone shared repository/package has been published. A future extraction should replace these snapshots with one immutable Git dependency after all consumers pass migration tests.

Common signature verification, semantic versions, GitHub transport, downloads, scheduling and AppImage replacement now come from that component. FILLR's `crates/fillr-update-policy` adds typed verified/staged results, metadata expiry, a key selector, and native publisher policy. `crates/fillr-update` embeds the application's trust and version and provides a small JSON CLI. Native SwiftUI and the shared Avalonia presentation layer own consent and work coordination.

Extensions to the common snapshot are backward-compatible: universal macOS ZIP and Windows MSIX target names, a bounded raw metadata API for authenticated extension fields, and zero-timestamp scheduling. ATIV/EnCAP legacy targets remain supported. These extensions have not been propagated into other active repositories; they require a coordinated reviewed snapshot update. EWAF and YACHT currently contain other updater variants and are not yet consolidated.

## Repository audit and migration

The audit inspected local source and release workflows, excluding generated/build/vendor directories. It is not a claim that every application owned by TLO Labs exists in these checkouts.

| Application/component | Existing implementation and distribution | Result here |
| --- | --- | --- |
| FILLR | No updater; local Developer ID/notarized universal Mac ZIP, unsigned Windows self-contained ZIPs, unsigned Linux AppImages; one build/publish workflow | Integrated shared client, Sparkle, signed-MSIX production path, Avalonia AppImage path; replaced unsigned automatic publication with signed candidate and promotion workflows |
| ATIV | Application Rust helper, Sparkle, portable Windows helper, AppImage adapter; existing signed feeds/keys; application-release and platform signing workflows; new `updater/` snapshot | Reused its shared snapshot; left deployed feeds/keys and in-progress migration untouched |
| EnCAP | Sparkle bridge, release signer, existing update key files, Windows/Linux adapters and identical `updater/` snapshot | Preserved existing identity, keys and migration work; private key contents were not read |
| EWAF | `crates/tlo-updater` plus `ewaf-update`, separate manifest/trust design, native platform layers | Audited structural differences; adoption and native qualification remain outstanding |
| YACHT | `updater/` plus `yacht-update`, separate manifest/trust design and native adapters | Audited structural differences; adoption and native qualification remain outstanding |
| EternalDJ | JUCE/CMake application; bundled JUCE updater code belongs to third-party tooling | No TLO production update integration established by this audit; not migrated |
| Lincoln Sounds | Flutter desktop project with Windows runner | No update dependency identified in pubspec; not migrated |
| Text2QTI GUI | Python/Tk desktop project | No production updater identified in project metadata; not migrated |
| Radio Schedule Tool | Python project | Distribution/desktop ownership needs confirmation before migration |
| AVID Core | Shared engine/runtime library and source/runtime release workflows | Deliberately not made updater owner |
| CSVRIC / Assignment Check / other web/game projects | No matching TLO native desktop release contract established | Outside this FILLR implementation; no migration claimed |

The existing signed FILLR bundle reports Team ID `VR64M92P2M`. ATIV's release documentation records Linux fingerprint `F7E74ED98DB485D03F2565B96B68B73FE752FD16`; the FILLR production Linux signing gate pins that identity. A read-only GitHub audit found no FILLR repository secrets, variables, or environments. The local Keychain does contain a valid Developer ID Application identity for that team; local certificate availability does not configure FILLR CI. No private keys were exported.

Existing FILLR 0.1.0 has no updater. It cannot discover a bridge release automatically: users must install one signed updater-enabled build manually. Retain bundle/application ID `edu.chabot.news.backgrounder`. Windows needs a manual transition from portable ZIP to `TLOLabs.FILLR` MSIX; validate existing LocalAppData preferences and watched-folder access under package identity. Do not delete old feeds or old portable installations until migration is tested. Other apps' obsolete updater code must remain until their replacement is proven.

## GitHub release contract

Use a stable tag exactly `vMAJOR.MINOR.PATCH` matching `[workspace.package].version` in root Cargo.toml. Prereleases, build metadata, leading zeroes, mismatched tags, drafts and development channels cannot qualify. Numeric SemVer comparison is owned by `tlo-updater`.

GitHub Releases is canonical. Clients request `https://github.com/tlolabs/fillr/releases/latest/download/update-manifest.json`; Sparkle requests `appcast.xml` at that same release. This avoids unauthenticated API limits. Routine clients have no GitHub token, cookies, identifiers, system profile, analytics or custom telemetry. HTTPS and normal transport headers/IP addresses are unavoidable. CI uses the authenticated Releases API to verify actual release status.

A release contains:

- `FILLR-VERSION-macos-universal.zip` and signed `appcast.xml`.
- `FILLR-VERSION-windows-x64.msix` and `...-arm64.msix`.
- `FILLR-VERSION-linux-x86_64.AppImage` and `...-aarch64.AppImage`, each with a GPG `.asc` signature and GitHub provenance attestation.
- `update-manifest.json`, a signed envelope, plus native verification reports.

The envelope contains `key_id`, base64 `payload`, and base64 Ed25519 `signature`. Sign **the exact decoded payload bytes**, not a reserialized object. Never trust a public key embedded in a downloaded manifest. The installed build pins public keys in `updates/trust.json`; private keys never belong in source.

The payload uses the shared schema 2: application_id, repository, version, tag, stable channel, draft/prerelease flags, release date, release notes URL, restart requirement, migration, and a map of platform targets. Each artifact declares platform, architecture, minimum OS/glibc, format, filename, exact versioned GitHub URL, byte size and SHA-256. FILLR additionally requires `expires_at` and per-artifact `identity`. Its JSON schemas live in `updates/`; the base schema lives in `updater/`.

FILLR target keys are `macos-universal`, `windows-x64-msix`, `windows-arm64-msix`, `linux-x64-appimage`, and `linux-arm64-appimage`. The signed Windows identity is the exact expected certificate/package publisher. Mac/Linux application IDs are also fixed. The native signing identities are separately pinned in `updates/platform-security.json`. Linux's compatibility floor is glibc 2.39; `minimum_os=0.0.0` means no separate kernel floor is asserted. Published assets are immutable; promotion never uses `--clobber`.

## Trust and failure behavior

Installed public key → authenticated manifest/app identity/version/target → signed SHA-256 and size → complete staged artifact → native signature/identity gate → coordinated installation. A checksum alone is never authority. The generic component verifies all asset URLs against the pinned repository and exact stable tag. The client admits only HTTPS redirects to GitHub's known release CDN hosts, bounds metadata to 1 MiB, and imposes connection/request timeouts.

The Rust Windows/Linux helper rejects expired or future-dated metadata, replay below the highest authenticated offered version, unknown keys, wrong publishers, unsupported migrations, or missing trust. Downloads remain temporary/non-executable until verified. Corruption, truncation and interruptions remove incomplete staged downloads. The production helper cannot accept a runtime key or endpoint override. Local mock endpoints exist only in tests.

The Rust helper checks daily, with hourly failure retry and periodic native timers; Sparkle owns macOS scheduling. Automatic network checks do not block starting media builds. The last successful check, last attempt, highest version and disable preference persist per user. Manual checks bypass timing. Errors do not stop the media engine. Native interfaces block build operations during installation coordination and never force termination to update.

AppImage replacement uses the existing common adapter: same-filesystem staging, full re-verification, durable previous-image backup and atomic rename. It rejects links, special files and privileged modes. The FILLR helper additionally checks the complete ELF64 little-endian machine header, type-2 AppImage magic, and that it is running inside APPDIR. Kernel and glibc compatibility are evaluated independently. AppImageUpdate was evaluated: its delta transport would still require this pinned authentication boundary and extra packaged tooling. The existing small, tested full-download adapter was reused; no new binary patch algorithm or archive extractor was added. Power-loss behavior on unusual/network filesystems and a real native installation remain unqualified.

On Windows, signed MSIX replaces portable ZIP as the production update format. After signed-manifest verification, the adapter checks the downloaded digest and MSIX application name, publisher, version and processor architecture. Windows deployment verifies package trust while staging. After consent, it rechecks the bytes while denying concurrent file writers and asks Windows to defer registration until the application is no longer in use. No forced shutdown or custom DLL replacement occurs. Users close and reopen FILLR from Start. Portable ZIPs remain development artifacts only. Velopack was considered; native MSIX already supplies transactional deployment without adding another bootstrapper or paid service.

On macOS, Sparkle 2.10.0 owns update UI, scheduling, archive authentication, installation and relaunch. Signed feeds and verification before extraction are required; signed-feed fallback is disabled. System profiling and unattended automatic installation are disabled. The delegate defers restart during Comp building, and the application refuses termination while moving files or editing unsaved media preferences. Nested Sparkle code is signed inside-out, then the app is Developer ID signed, notarized, stapled, re-zipped, extracted and verified. Sparkle performs its own signature checks rather than consuming the common JSON manifest at runtime; the release pipeline binds both feeds to the same final ZIP and the signed JSON payload authenticates the exact appcast SHA-256. macOS does not consume the Rust manifest expiry/high-water state. Sparkle accepts an EdDSA-authorized change of Apple signing identity; same-team Developer ID, notarization and Gatekeeper enforcement are additionally required by the production artifact verifier. Do not describe those release checks as a separate same-team check inside the installed Sparkle client.

## Key ownership and recovery

TLO Labs' release maintainer owns each application's Ed25519 private key, Developer ID identity, Windows Authenticode identity and Linux signing key. Use the existing keys for applications with deployed clients. Do not copy EnCAP's private key merely because it is available locally. FILLR's `keys` map is empty until the maintainer selects/provisions its production key and commits only the public half.

Store private material in a protected signing environment or local Keychain/hardware-backed signing setup. Keep a separate encrypted recovery backup under maintainer control. `TLO_UPDATE_PRIVATE_KEY` is a base64 32-byte Ed25519 seed passed through environment/stdin, never command-line literals or logs; `TLO_UPDATE_KEY_ID` selects the pinned public key. Release tools reject mismatched public/private pairs. Windows production signing requires an existing trusted certificate; self-signed CI certificates are not a substitute.

For Windows/Linux rotation, issue and qualify a bridge build trusted by the old key that includes the next public key, then switch signing after adoption. Keep old feeds reachable during migration. FILLR's all-platform packaging currently requires an explicit Mac rotation procedure: Sparkle's verification-before-extraction ZIP policy means EdDSA recovery may require a Developer ID signed DMG bridge or a manual notarized reinstall. That bridge is not implemented or qualified here. Never silently replace a pinned key or disable verification to recover. If both trust roots are lost/compromised, stop automated publication and distribute a separately authenticated manual recovery build.

## Release and qualification procedure

1. Change only root Cargo workspace version, run `python3 script/version.py --sync`, and commit the generated native version files. CI checks that they agree. Mac bundle versions, Rust helper/engine versions, Windows assembly/MSIX versions and Linux reported version derive from that authority.
2. Configure public trust and platform identities. Protected CI environments `production-signing` and `production-release` should restrict who can sign/promote. Supply existing certificate/notary/GPG secrets listed in `.github/workflows/release-updates.yml`; no new service is required.
3. Tag the exact source `vVERSION`. Normal `build.yml` artifacts cannot enter the update channel. `release-updates.yml` runs tests, builds native targets, signs/notarizes, verifies actual packages, attests AppImages, generates Sparkle's signed appcast with Sparkle's own tools, and signs the common manifest. The candidate is only an Actions artifact, never a production update.
4. **Currently blocked:** the following original candidate-first procedure has no native evidence producer and cannot exercise an ordinary production build against the unpublished GitHub release. A proposed publication-then-native-qualification sequence needs explicit approval after automatic review rejected removing the existing pre-publication gate. No gate has been removed. On disposable native hosts, install an actual older updater-enabled build; discover/authenticate/download/install the new signed candidate through a controlled qualification build/endpoint, then relaunch and verify version, app identity and existing user settings/media. Interrupt downloads and installation, test unwritable destinations, and verify recovery. Do not point ordinary users at a test feed or publish bogus production releases. Production builds intentionally have no test endpoint override; a dedicated qualification build must be separately constructed and must retain native signing requirements.
5. Record each native result in `qualification.json` with target, from_version, to_version, final artifact SHA-256, evidence URL and true results for discovered/authenticated/downloaded/installed/relaunched/user_data_preserved. Required targets include **both** `macos-x86_64` and `macos-aarch64`, `windows-x64`, `windows-arm64`, `linux-x86_64`, `linux-aarch64`. Upload this as `installed-upgrade-evidence` from a successful Actions run on the exact tagged commit. A native installed-upgrade harness/evidence producer is still outstanding; no dummy passing evidence is supplied.
6. Run `publish-updates.yml` with tag, candidate run ID and evidence run ID. Promotion verifies source bindings, all package bytes/signatures, provenance and native qualification. It creates a draft, downloads and verifies the uploaded bytes, then makes the release stable/latest. Existing releases are never overwritten.
7. Post-publication verification checks GitHub's actual draft/prerelease status and uses the client transport/verifier to discover/download the released assets from older-version configurations. This proves published metadata/download behavior, not a second native installation test. A failure fails qualification and requires investigation; it does not rewrite a release silently.

Current blockers: FILLR public update key and Windows publisher/certificate are unconfigured; FILLR has no repository signing secrets/variables or protected signing environments configured; native Windows signing/MSIX tests and six native installed-upgrade runs are outstanding. Local compilation and Avalonia/native package CI are not installed-update qualification. The committed ledger is deliberately empty.

## Tests and troubleshooting

Run `cargo test --locked -p tlo-updater -p fillr-update-policy -p fillr-update -p fillr-core`, `python3 -m unittest discover -s script -p 'test_update*.py'`, `python3 script/version.py --check`, and `python3 script/check_updater_snapshot.py`. Common and FILLR tests cover newer/same/older versions, malformed/prerelease/draft metadata, wrong identity/platform/architecture, signatures, hash/size failures, interruptions, network outage, local HTTP discovery/download, release signing and artifact mismatch, scheduling, replay and AppImage pre-commit recovery. Native UI/install tests remain distinct.

- “No trusted public key”: expected for current development builds. Configure the public trust, rebuild and sign; never accept a key from a remote manifest.
- Network/rate-limit errors: app stays usable; check proxy/firewall and GitHub status. Do not replace the endpoint with an arbitrary download URL.
- Metadata expiry/replay/signature error: investigate release signing and system clock. Do not clear security state to force a downgrade.
- Another update running: wait for the helper; OS locks release automatically after a crash.
- AppImage permission error: keep the original, download a verified release to a writable location, and install manually. Recovery backups named `tlo-previous-*.AppImage` can be restored while the app is closed after checking their identity/version.
- MSIX installation failure: review Windows deployment logs and publisher trust. Do not disable signature checks or force-close media work.
- Sparkle error: inspect Console and the bundle's public key/feed settings, verify appcast and archive signatures, then check Developer ID/notarization. Missing credentials are not evidence that an unsigned update is safe.

## Adopting the component elsewhere

Import one reviewed complete `updater/` snapshot, preserving its license and source ledger, or pin the future standalone repository revision. Add an application-only adapter with embedded app ID/repository/version/trust. Preserve old manifest/feed routes through a bridge release. Use common verification/select/download/state logic, native UI/installation, and the shared tests. Add schema extensions only after common signature verification; unknown mandatory policy must fail closed. Coordinate schema changes across consumers and qualify actual older installed builds before deleting legacy adapters. Do not introduce an AVID Core dependency for updating.

References: [Sparkle integration/security](https://sparkle-project.org/documentation/), [AppImageUpdate](https://github.com/AppImageCommunity/AppImageUpdate), [Windows deferred package registration](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.addpackageoptions.deferregistrationwhenpackagesareinuse), [GitHub artifact attestations](https://github.com/actions/attest).

## October 1 qualification audit

The full pending diff and surrounding engine/native/release code were reviewed. Fixes cover recovery-journal path validation and nonrecursive rollback cleanup; bounded concurrent probe pipe draining; independent Linux kernel/glibc checks; ELF architecture validation; GTK preference/update coordination and process replacement; Windows folder/editor/close races and downloaded-file cleanup; numeric stable-version and artifact URL policy in the native Mac delegate; authenticated appcast binding; and verification of every embedded Mac executable. The workspace license now matches the existing GPL-3.0-or-later license. Packages include Sparkle notices, exact locked Rust dependency notices, Rust runtime copyright, Ubuntu library notices, and the exact local FFmpeg source patch.

Pre-migration Apple Silicon results: 100 automated tests passed with no skips (baseline 70); Rust/GTK Clippy with warnings denied, Rust formatting, actionlint, ShellCheck, Python compilation, version/snapshot checks and both RustSec lockfile audits passed. The universal release packaging script completed in unsigned mode and packaged MPG/MP4 probing passed with PATH hidden. This is not a signed production artifact or an installed-upgrade test. SwiftPM may report that it is preserving already-signed Sparkle components instead of stripping them; signing protections are not disabled.

The production key, CI signing setup and installed-upgrade release sequence remain blocked. No new tag or GitHub Release has been created. VERSION A and VERSION B do not yet exist. Production signing, notarization, Gatekeeper, updater installation, relaunch, post-update data preservation and native Windows/Linux upgrade qualification are not claimed. See the machine-readable ledger for exact results.

The Avalonia migration retains the authenticated updater and release gates. Its internal macOS reference build has no production update service; see [the migration ledger](avalonia-migration.md). Baseline commit `616bccd` passed all eight development CI jobs, including Windows/Linux ARM64 and x64 packaging. Those builds do not establish installed-upgrade qualification.
