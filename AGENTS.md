# Repository development policy

`main` is the authoritative development branch. Direct commits and pushes are
permitted. Pull requests, reviews, status checks, DCO enforcement, and commit
signing are not required. Contributors should still use `git commit -s` for a
voluntary DCO sign-off.

Run relevant tests and builds, and investigate failures. CI reports failures
without blocking unrelated development. Do not publish an artifact whose own
build, packaging, integrity checks, or available required functional
verification confirmed it is broken or unusable. Release each verified platform
independently. Standard local macOS distributable builds require Developer ID signing,
accepted Apple notarization, stapling, and Gatekeeper verification. Missing
credentials fail clearly; there is no automatic unsigned fallback. Explicit
unsigned/sign-only modes remain development or diagnostic artifacts and must
not be described as notarized. Ordinary debug/test iteration does not require
notarization. Default notarized local packages disable automatic updates and
do not require update-key enrollment. Explicit `release_macos.sh --production`
retains every production update-trust check. Unsigned builds are not eligible
for automatic updates. Keep runtime update
signature checks and other application security controls intact.

Linux x64 and ARM64 direct-download releases are best-effort publications, not
professionally certified distributions. Build each with its supported toolchain,
package an AppImage, run available automated tests and packaging checks, and
verify the artifact is nonempty, has a valid header and architecture, and passes
SHA-256 verification. Run automated smoke tests when the runner supports them.
If runtime infrastructure is unavailable, skip that check, record the reason in
the release notes, and publish after the build, packaging, and basic integrity
checks pass. An optional test failure must be reported but does not alone block
publication. A confirmed broken, corrupt, or unusable artifact must not be
published. Never require a local Linux environment, manual Linux acceptance,
student or external verification, full functional testing without its required
environment, or completion of other platforms before publication.

Use these release classifications: **Build verified** means compilation,
packaging, and artifact integrity passed; **Automated runtime verified** means
automated execution and smoke tests passed; **Community testing pending** means
manual runtime testing has not occurred; **Known failure** means a specific
defect is confirmed. A Linux release may say **Build verified — community
testing pending**; never call that fully tested. Student and community testing
is post-publication quality assurance. Record feedback as GitHub Issues and fix
it in later releases without introducing a new release qualification gate.

Keep unresolved CI failures visible in the consolidated GitHub issue. Fix
regressions when practical, and record unrelated failures without creating a
new development gate. Never force-push or rewrite published history during
branch reconciliation.

## CI scheduling policy (owner update, 2026-11-07)

This section supersedes older instructions for automatic CI coverage and publication.

Hosted native CI runs once weekly on Sunday morning Pacific, and only for newly introduced version tags. Existing tags are baselined. The active workflow builds supported Linux and Windows targets and performs basic startup smoke checks only. It does not run macOS builds, full regression suites, automatic retries, publishing, signing, or release creation. Legacy workflows are retained but disabled. GitHub-managed security services remain separate. Runtime authentication, signature verification, and artifact-integrity safeguards must not be weakened. Local development and release verification requirements still apply before any separately authorized publication.

## Archived legacy automation

The former custom workflows are preserved, inactive, under `.github/workflow-archive/2026-11-08/`, with original paths and hashes recorded in its manifest. This archive supersedes older descriptions of automatic builds, retries, reporting, and release publishing. Do not move them back to `.github/workflows/`, enable, or dispatch them without a new explicit owner instruction. GitHub-managed security services remain separate and enabled.
