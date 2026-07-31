# Worklog

## 2026-07-31 - Upstream PR #114: disclose title-only scope on empty search-notes results

**What changed**: Shipped a code handoff from another session as upstream PR
sweetrb/apple-notes-mcp#114, on branch `fix/search-notes-title-only-hint` cut
from `upstream/main` at d0204a8 (not from local `main`). `search-notes` returned
a bare `{"notes":[],"count":0}` when a title-only search matched nothing, with no
indication that bodies were never searched. New helper
`src/utils/searchScope.ts` (plus `searchScope.test.ts`) appends a hint to the
empty result only; `src/index.ts` calls it in the `notes.length === 0` branch.
`searchContent` still defaults to `false` and no search semantics changed.
Bumped 2.6.10 to 2.6.11, added a CHANGELOG entry under `[Unreleased]`, synced the
six plugin manifests, and committed the rebuilt `build/index.js` bundle, all of
which CONTRIBUTING requires and the original handoff did not mention.

**Decisions made**: Deferred the real fix, a `"title" | "body" | "both"` mode, to
the maintainer rather than implementing it. `searchNotes` builds the AppleScript
`whose` clause as either `name contains` or `body contains` and never both, so
`searchContent: true` searches bodies *instead of* titles and there is no way to
get title-or-body matches in one call. A `both` clause has unmeasured cost on a
large library and #100/#101 already documented a tight 30s AppleScript budget, so
PR #114 raises it as a scope question instead. Also left the mirror-image case
silent on purpose: `searchContent: true` with zero results means titles were never
searched, and making the hint symmetric would have widened a disclosure PR.
Put the CHANGELOG entry under `[Unreleased]` rather than opening a `## [2.6.11]`
section, matching what #104 did when it bumped to 2.6.10.

**Left off at**: PR #114 open, out of draft, marked ready for review, mergeable,
all ten CI checks green (`test (22)`, `test (24)`, `integration`,
`bundle-boots (standalone, Node 20)`, `require-version-bump`, `CodeQL`,
`Analyze (javascript-typescript)`; the three Dependabot jobs correctly skip).
Awaiting Rob Sweet's review. Any follow-up goes on the existing branch, not a new
PR.

**Open questions**: NEW - upstream `CLAUDE.md` line 133 says "Set
`searchContent: true` to search note body, not just titles", which reads as
additive and is wrong for the same reason PR #114 exists. Not included in #114,
because the PR was already marked ready; it is a one-line follow-up if wanted.
NEW - local `main` is now 7 commits behind `upstream/main` (#108 through #113),
so the 2026-07-24 entry's "fork is fully synced with upstream" no longer holds.

**Verification**: `pnpm run lint`, `pnpm run typecheck`, `pnpm run format:check`,
`pnpm test` (518 tests, 20 files, 3 new), and `pnpm run build` all pass. Confirmed
the committed bundle matches source via a rebuild plus `git diff --quiet build/`,
and manifest parity via `node scripts/sync-plugin-version.mjs` leaving a clean
tree. Live-checked the built server over MCP stdio against the real iCloud
library, not just mocks: a title-only miss now carries the hint, the same query
with `searchContent: true` does not, and a title-matching search is unchanged.
That run also quantified the bug: the term "because" matches 0 titles and 62
bodies. `corepack` is not installed on this Mac, so the documented
`corepack enable && pnpm install --frozen-lockfile` needed plain `pnpm`
(11.9.0 on PATH) instead.

---

## 2026-07-24 - Fix fork tracking branch for kitchensync commit-push-all

**What changed**: Kitchensync's `commit-push-all` step failed because the
local `main` branch was tracking `upstream/main` (the sweetrb repo) instead
of `origin/main` (Oliver's fork). The rebase on `@{u}` tried to replay
fork-specific merge commits onto upstream/main, hitting version-number
conflicts in every plugin manifest. Fixed with
`git branch --set-upstream-to=origin/main main`. The rebase is now a no-op
since `origin/main` is an ancestor of local `main`.

**Decisions made**: The fork should track `origin/main` for the rebase-sync,
not `upstream/main`. Upstream merges are pulled in explicitly and merged,
not via the automatic rebase path.

**Left off at**: `commit-push-all` re-run green ("All repos clean"). Fork
is fully synced with upstream: `upstream/main` is an ancestor of local
`main`; zero upstream commits are missing.

**Verification**: `git merge-base --is-ancestor upstream/main main` returns
true. `git rebase --autostash '@{u}'` succeeds cleanly.

---

## 2026-07-22 - Refresh the contributor fork

**What changed**: Merged the current upstream `main` branch into Oliver's contributor fork while preserving the fork-only publish guard and prior contribution commits.

**Decisions made**: Kept this repository as an upstream-contribution fork, not an independently maintained product or release line.

**Left off at**: The sync merge is pushed to `origin/main`; local branch comparison reports zero commits behind upstream and five fork-specific commits ahead.

**Open questions**: GitHub's security-alert display had not yet reconciled with the new lockfile; recheck it later rather than changing the dependency graph again.

**Verification**: The pre-push hook passed TypeScript compilation and the complete local test suite. The current lockfile resolves the intended patched dependency revisions.

---
