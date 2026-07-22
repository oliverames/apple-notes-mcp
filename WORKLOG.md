# Worklog

## 2026-07-22 - Refresh the contributor fork

**What changed**: Merged the current upstream `main` branch into Oliver's contributor fork while preserving the fork-only publish guard and prior contribution commits.

**Decisions made**: Kept this repository as an upstream-contribution fork, not an independently maintained product or release line.

**Left off at**: The sync merge is pushed to `origin/main`; local branch comparison reports zero commits behind upstream and five fork-specific commits ahead.

**Open questions**: GitHub's security-alert display had not yet reconciled with the new lockfile; recheck it later rather than changing the dependency graph again.

**Verification**: The pre-push hook passed TypeScript compilation and the complete local test suite. The current lockfile resolves the intended patched dependency revisions.

---
