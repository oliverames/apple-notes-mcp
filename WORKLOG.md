# Worklog

## 2026-09-23 - Upstream parity push; paused for machine downtime

**What changed**: About 30 of our PRs merged upstream today (#182-#233 range, plus #204 as read-only). This session also opened #241, then closed it because sweetrb fixed #236 himself in #240. It synced #234, #235 and #238 with main and pushed them (2211, 2222 and 2165 tests passing), and replied to and resolved the CodeQL thread on #235.

**Decisions made**: Private writes stay fork-only. When the rebuild is done, open one draft upstream PR for the writes foundation. NotesCTL is never named publicly. Never run the full `test:integration`, because it writes live notes.

**Left off at**: (issues are disabled on this fork, so the tracking list lives here)

Tracking the unfinished work from the 2026-09-23 upstream parity session. Upstream main was `1462604` (v2.9.10) when work paused. All branches below are on this fork.

## Ready, not yet opened upstream
- [ ] `feat/search-match-details` (`fbb60a0`, base 8c90ea7): `matchedIn` + opt-in `wordCount` on `search-notes` / `query-notes`. 2179 tests pass; live read-only check done. Merge current upstream/main, set version to 2.10.x above main, open PR "Part of sweetrb/apple-notes-mcp#181".
- [ ] `feat/smart-folder-destination-guard` (`2867a1e`, base 8c90ea7): refuses smart folders as create/move destinations. Main today moves such notes into Recently Deleted or creates them inside the smart folder while reporting an error. 2163 tests pass; live-verified on test notes. Fails open without Full Disk Access. Merge main (CHANGELOG conflict), renumber, open PR.
- [ ] `fix/large-attachment-read` (`be1dfa2`, base 8c90ea7): real fix for sweetrb/apple-notes-mcp#237 (reads >64 MB hit maxBuffer; deletes >5 MB blocked by the inline expected-body limit). Upstream #242 only explains the error. Rebase on main, make `classifyBodyReadError` recognise the new overflow error, renumber, then offer as a follow-up to #242.

## sweetrb change requests to address first on resume (posted ~21Z, 2026-09-23)
Read the full reviews with `gh api repos/sweetrb/apple-notes-mcp/pulls/<n>/reviews/<id>`.
- [ ] **#234** (review 5296113654; head d6220bf, which someone else pushed, so check it first). He asked for four things:
  - merge main;
  - escape list bodies in `blockLine`, with fixture cases for `## Notes`, `1. x` and `---`. The keeper's fix may already cover part of this;
  - stop echoing file contents in template errors, from `parseTemplate`/`readTemplateFile` via the JSON.parse snippet and echoed values;
  - a version bump and rebuilt bundle.
- [ ] **#235** (review 5296113924): wait for #234, then:
  - add a test that `validate-markdown-template` on a file that isn't a template returns none of its contents;
  - the CodeQL fix is already pushed as 9630336;
  - bump the version.
- [ ] **#238** (review 5296114130):
  - merge main and bump the version;
  - avoid the macOS 26+ "Allow Paste" prompt on the general pasteboard. The live runs used a named pasteboard, so the real path is untested;
  - freeze the pasteboard only after the note and revision checks pass;
  - handle multiple copied file URLs;
  - use `callTimeoutMs()` and make the unsupported-types output clearer.
- [ ] **#231**: his review is still open on his head 3de370a, which is mergeable. Wait for his re-review.

## Open upstream PRs to keep mergeable
- sweetrb/apple-notes-mcp#231: all review points addressed and replied (9e3a7f4); sweetrb pushed 3de370a (2.9.11), awaiting his re-review. #234, #235, #238 synced. Every upstream merge re-conflicts version/CHANGELOG/manifests/build.

## Private writes (fork only; upstream hold)
- [ ] `feat/native-writes-foundation` (`671c539`): separate opt-in writer binary on top of upstream's read-only helper; copy-store test passes. Needs live smoke test in the `apple-notes-mcp test` folder.
- [ ] Port the 13 branches as `-v2` onto it (see resume notes in the foundation commit / TECHNICAL_NOTES.md).
- [ ] Then open ONE draft upstream PR for the foundation with the sync-lag evidence, listing the feature branches (decision 2026-09-23).
- [ ] Build on the foundation: whole-note highlight, attachment selector in edits, line-break trimming.

## Incidental findings (unverified beyond one run)
- `src/utils/folderStore.ts` comment says `folders of account` omits smart folders; a live probe showed it returns them.
- Moving a note that is already in Recently Deleted into a smart folder appeared to tombstone it.

---

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
