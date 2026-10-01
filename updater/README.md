# tlo-updater shared source snapshot

Application-independent stable GitHub Releases client, reused from the identical ATIV and EnCAP `updater/` snapshots. There is no AVID Core or host application dependency.

`UPSTREAM.json` records the imported file digests and this snapshot's small, backward-compatible extensions. `SNAPSHOT.json` binds the actual local source; `python3 script/check_updater_snapshot.py` detects accidental edits. Publish a reviewed standalone repository/revision before replacing snapshots with Git dependencies. Do not make applications depend on sibling checkout paths.

The shared schema remains version 2 and uses `update-manifest.json`. Added target names are `macos-universal`, `windows-x64-msix`, and `windows-arm64-msix`. Existing ATIV/EnCAP ZIP targets remain accepted. The bounded raw-metadata API allows applications to validate signed policy extensions after the common signature/contract check. FILLR requires expiry, key ID, and native identity extensions in `crates/fillr-update-policy`; it does not replace the common crypto/download/version logic.

Always call `verify` before `select` or `download`. FILLR wraps the result in a sealed verified-update type. Never accept an asset or digest supplied independently by the UI as authorization to install.

`cargo test -p tlo-updater` runs common contract, transport, and recovery tests. `tlo-qualify` checks metadata/downloads; it does not qualify native installation. See `../docs/updater-architecture.md` for adoption, trust, and qualification status.
