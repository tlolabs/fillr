# Contributing to FILLR

`main` accepts direct commits and pushes. Pull requests, reviews, passing
status checks, DCO enforcement, and cryptographic commit signing are not
required. Please use `git commit -s` to add a voluntary DCO sign-off.

Run the checks relevant to your change. The baseline is `cargo test --workspace
--locked`, `cargo fmt --all -- --check`, `cargo clippy --workspace
--all-targets --locked -- -D warnings`, and the Python update tests in
`script/`. Platform builds and native UI tests run in GitHub Actions. A failing
job stays visible and is tracked in the consolidated CI issue on `main`; it
does not prevent unrelated commits or pushes.

Keep packages with failed builds, corrupt artifacts, or confirmed unusable
behavior out of releases. Pushing a matching
`vVERSION` tag publishes each independently verified unsigned package to a
GitHub prerelease for manual download. Build jobs are read-only; dedicated
publisher jobs alone can write release assets, and existing assets are never
overwritten. Signing and notarization are optional for these downloads.
The signed automatic-update workflow is a separate opt-in path; installed
update signature verification remains mandatory.

Linux x64 and ARM64 AppImages publish independently once compilation,
packaging, and artifact integrity pass. CI runs available automated tests and
smoke checks; missing display/session infrastructure skips the AppImage launch
check and is noted in the release. Optional test failures are reported without
blocking publication. Local, student, and community runtime testing is not an
acceptance gate. Community feedback after publication may become GitHub Issues.
See the Linux classification policy in [AGENTS.md](AGENTS.md).
