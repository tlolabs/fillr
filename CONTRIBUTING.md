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

Keep failing or unverified packages out of releases. Development artifacts
are separate from signed automatic updates. Signing and notarization are
optional until configured, while installed update signature verification
remains mandatory. The signed update workflow is manually dispatched on a
version tag. Its release checks protect published update bytes and identity;
they are not development branch requirements.
