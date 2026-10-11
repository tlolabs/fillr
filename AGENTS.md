# Repository development policy

`main` is the authoritative development branch. Direct commits and pushes are
permitted. Pull requests, reviews, status checks, DCO enforcement, and commit
signing are not required. Contributors should still use `git commit -s` for a
voluntary DCO sign-off.

Run relevant tests and builds, and investigate failures. CI reports failures
without blocking unrelated development. Do not publish an artifact whose own
build or functional verification failed. Release each verified platform
independently. Signing and notarization remain optional until credentials and
trust are configured; unsigned builds are identified as prereleases and are
not eligible for automatic updates. Keep runtime update signature checks and
other application security controls intact.

Keep unresolved CI failures visible in the consolidated GitHub issue. Fix
regressions when practical, and record unrelated failures without creating a
new development gate. Never force-push or rewrite published history during
branch reconciliation.
