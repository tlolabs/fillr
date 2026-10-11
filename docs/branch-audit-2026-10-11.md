# Branch audit, October 11, 2026

The pre-audit local and remote branch tips, and copies of the 49 existing
uncommitted working files, are saved under `.git/audit-backup-2026-10-11/`.
The original `main` and `origin/main` were both
`58bcc9d221ca90ada0b907e9c0e3de21067d22f3` after fetching all remotes.

| Branch | Original tip | Decision |
| --- | --- | --- |
| `codex/qt-migration-audit` | `7649f6810de60a3ae5bfe40997cb185ec06caaa7` | Ancestor of main; no unique changes. |
| `codex/avalonia-migration` | `c5fb1738f6dcadde8c20e1d1438dc91d9dc31204` | Historical ancestor of main. |
| `codex/updater-qualification` | `616bccd55d45a9a7b4fd29fb566e35a0542fffdb` | Historical ancestor of main. |
| `codex/avalonia-final-snapshot` | `eb92939ecde2b2782fe00a5ee044bdf07ea73040` | Preserved historical snapshot. Current main already contains its configurable Rust sorting/export work; its Avalonia UI was replaced by Qt. A direct merge would restore retired UI files. |
| `codex/app-progress-indicator` | `b6e4f55c77c5ef830da08180b2da59c49d782603` | Preserved as `backup/pre-qt-progress-indicator-20261011`. Its Windows/Linux code targets retired native front ends. Current main has a macOS Dock gauge and Qt progress displays; the old branch requires a fresh Qt-specific port before any remaining taskbar behavior can be incorporated. |

The two additional worktrees were clean at audit time. The `Sparkle` checkout
inside the ignored Swift build directory is a dependency checkout, not another
project repository. No branch tip was deleted or rewritten.

GitHub reported no branch protection or repository rulesets. No Copilot-authored
policy commit was found in the fetched main history. The repository still has
an optional signed-update promotion path that requires all platforms and native
upgrade evidence. Independent signed publication remains unresolved; removing
verification would weaken runtime update security, and automatic approval review
rejected broad release write permissions and tag publication in this audit.
