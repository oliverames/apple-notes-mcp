# Worklog

## 2026-09-23 - Upstream parity push; paused for machine downtime

**What changed**: About 30 of our PRs merged upstream today (#182-#233 range, plus #204 as read-only). This session also opened #241, then closed it because sweetrb fixed #236 himself in #240. It synced #234, #235 and #238 with main and pushed them (2211, 2222 and 2165 tests passing), and replied to and resolved the CodeQL thread on #235.

**Decisions made**: Private writes stay fork-only. When the rebuild is done, open one draft upstream PR for the writes foundation. NotesCTL is never named publicly. Never run the full `test:integration`, because it writes live notes.

**Left off at**: (issues are disabled on this fork, so the tracking list lives here)

Tracking the unfinished work from the 2026-09-23 upstream parity session. Upstream main was `1462604` (v2.9.10) when work paused. All branches below are on this fork.

## 2026-09-24 (Mac session) - macOS verification, upstream posts, private-writes rebuild

(Placed here, below the lines fork PR #2 adds, so #2 still merges cleanly.)

**What changed**:
- Verified all six upstream branches on macOS 27.2: every test passes with none skipped, and the bundles match. Upstream CI (macos-latest) was green on #234/#235/#238.
- Live checks, test folder only:
  - #238's general pasteboard path works. JXA's `respondsToSelector("accessBehavior")` accepts a plain string, and `pb.accessBehavior` returns the string "2" (alwaysAllow for this host). `Number()` handles that.
  - A PNG copy, a single Finder file copy with `allowPasteAlert`, and the refusal of two copied files all worked.
  - The large-attachment fix read and deleted a note with a 42 MB image; main failed with a false "timed out after 30 seconds".
  - The smart-folder guard refused smart-folder destinations while ordinary same-name folders still worked.
  - search-notes and query-notes `matchedIn`/`wordCount` checked out.
- Posted the review replies on #234, #235 and #238, and opened #244, #245 and #246 with texts updated to the macOS results.
- Upstream merged, in order: #246 (2.9.12), #245 (2.9.13), #244 (2.9.14), #234 (2.9.15) and #235 (2.9.16). sweetrb pushed his own merge-and-release commits to #245 and #234 before merging them. #238 is resynced at 2.9.17 (`951a210`) and still carries his old CHANGES_REQUESTED review.
- Filed upstream issues:
  - #243: add-attachment reports files of 25-64 MiB as unverified because it verifies through the 25 MiB fetch cap.
  - #247: folderStore.ts comment; `folders of account` does list smart folders on 27.2.
  - #248: the Background Operations v5 Shortcut's "Find Notes" action fails on this Mac, so create-table, create-checklist-items and append-native insert nothing. create-table hides the Shortcut error and reports "uncertain".
- Incidental finding 2 confirmed: on main, moving a Recently Deleted note into a smart folder marks it for deletion (it leaves Recently Deleted). #245 refuses that move; recorded in its PR body.
- Private writes:
  - The foundation smoke test passed live.
  - The foundation merged upstream 2.9.11 (`3418163`). Fix `269637a`: `waitedSeconds` now reports elapsed time.
  - Seven agents ported the 13 branches as `-v2` off `3418163`. `markdown-native-import` needed no port (upstream #199), so there are 12 branches.
  - Every `-v2` branch passed its live plan in the test folder and is pushed: edit, compose, compose-2, checklist-toggle, highlight, link-card, paragraph-links, section-chips, table-rows, smart-folders, sync-push, paper-authoring.
  - Step 5.4: `feat/native-edit-attachment-selector` (`43126ea`) and `feat/native-edit-trim-breaks` (`e36c287`) were built and live-tested.
  - Live testing found a real verification bug on native-edit-v2. `AttachmentGlyphs()` merged adjacent glyphs of one attachment into one run, and Notes stores AppleScript-added images as two adjacent glyphs. Fixed in `4382d84` and merged into both follow-ups.
  - Opened ONE draft upstream PR, sweetrb/apple-notes-mcp#250, from `feat/native-writes-upstream` (`6a7c7bc`, 2.9.18). It carries neutral wording, the upload-lag evidence and the branch list. `feat/native-writes-foundation` stays the fork base.

**Decisions made**:
- Merge commits only on pushed branches. Where sweetrb pushed his own resync, I adopted his and dropped my unpushed local resync. The source was identical.
- The upstream draft PR comes from a separate branch, so the fork foundation keeps its fork wording as the `-v2` base.
- The `isolation: "remote"` Agent option silently ran locally. Don't count on it as "cloud" until that is confirmed working.

**Left off at**:
- [ ] Whole-note highlight (step 5.4): agent building `feat/native-highlight-whole-note` off `feat/native-highlight-v2`; live-test and push it.
- [x] #238 merged (2.9.17).
- [ ] #250 (draft): awaiting sweetrb's view on the two open concerns (concurrent saves, CRDT replica identity).
- [ ] The `-v2` branches are based on `3418163`; merge the foundation fix `269637a` into them when next touched. `native-sync-push-v2` also edits `privateSyncNudge.ts`, so expect a small conflict there.
- [ ] Check whether Notes shows an AppleScript-added image twice (two body glyphs per image on 27.2; the 42 MB note's HTML also had two `<img>`). If it does, file it upstream.
- [ ] Orphan attachment row: removing an attachment through native-edit leaves its row in the note, unmarked (observed 2026-09-24). Document or clean up.
- [x] README-credit email to Rob Sweet (rob@superiortech.io, from his README) sent from Oliver's Gmail on 2026-09-24 after Oliver approved the draft; no reply yet.
- [x] Skill PR sweetrb/apple-notes-mcp#252 (formatting rules + tool-table fixes) merged as 2.9.20. Two observation-based rules verified live first.
- [x] Whole-note highlight: `feat/native-highlight-whole-note` (`a2cf2ae`) built, live-tested, pushed.
- [x] Comprehensive bug review (2026-09-23/24 contributions), fixes shipped as #256 (2.9.24), #257 (2.9.25) and #258 (open, below): audit going to ~/Documents/apple-notes-mcp-bug-review-2026-09-24.md. Oliver's instruction: fix every issue found. Plan: foundation writer first (pre-save refusals report committed:false, NSException after save keeps committed:true, Cc-only control set, probe the read properties), merge into all -v2 branches, then branch fixes, then focused upstream PRs (analyze-svg OOM first). Treat the contentPath read scope as sweetrb's design call.
- [ ] Then sweetrb's open issues.
- [x] Gap analysis against the reference tool in ~/Downloads (private; never name it publicly): ~/Documents/apple-notes-mcp-gap-analysis-2026-09-24.md.
- [x] README coverage + SEO PR #254 merged (2.9.22); GitHub topics/description go in the PR body as suggestions for sweetrb.
- #250 resynced to 2.9.21 over main 2.9.20 (`b8d94a1`).
- [ ] **Gap parity (Oliver, 2026-09-24): build ALL gaps from ~/Documents/apple-notes-mcp-gap-analysis-2026-09-24.md, including infra #34 editor, #35 tailnet editor, #39 permissions dashboard, #40 signed broker, #85 resolver; ship as ONE upstream DRAFT PR (Oliver chose upstream over the fork-only rule for this).** Plan/resume point:
  - A. `feat/writer-suite` from `feat/native-writes-upstream` (78d40d8, upstream wording + foundation fix 3474030): merge every -v2 branch + edit-attachment-selector, edit-trim-breaks, highlight-whole-note; keep upstream wording; gate. Apply the bug-audit fixes for writer code HERE, once.
  - B (parallel, from upstream/main): `gap/query-facets-svg-export` (#13, #32), `gap/template-editor` (#34, #35), `gap/permissions-dashboard` (#39), `gap/permission-broker` (#40), `gap/paragraph-anchors` (#84 registry/resolver, #85 service).
  - C (after A): fork-writer gaps #77 rich edit runs, #62 inline link, #70 attachments in compose, #72 frozen attachment proof, #57 scope guards, #58 checklist replace-all, #78 attachment replace, #26 Paper shapes, #52 folder adoption, #89 purge-flag repair, #84 heal step.
  - D. Merge B and C into `feat/writer-suite`, serial live tests in `apple-notes-mcp test`, open one upstream draft PR. Network pieces default off; loopback or tailnet only, token-gated. NotesCTL never named.
  - Agents never write live notes; only this session does, serially.
  - Progress: all four upstream-base gaps built and bundled as `gap/upstream-bundle` (4cbb9c7). `feat/writer-suite` (5c40b1a) integrates all 15 writer branches (16 write actions, committed-flag bracketing enforced by test). Writer gaps + writer-side audit fixes running as `wgap/edit`, `wgap/compose`, `wgap/guards-sync`, `wgap/objects`. #40 broker blocked by the auto-mode classifier; awaiting Oliver.
  - Oliver (2026-09-24): suggest sweetrb release this as 3.0.0. Put it in the combined draft PR body as a suggestion (he renumbers versions himself); keep a patch version on the branch so CI passes.
  - Progress (end of 2026-09-24): `wgap/edit` e32a627, `wgap/compose` c91ecb7, `wgap/guards-sync` d4f3b53, `wgap/objects` 050ceff all pushed and gated. Final integration `feat/gap-parity` (worktree `.claude/worktrees/agent-ae5d5490ebc2da511`) had all five merges + upstream/main, the #84 heal wiring (32933d0), the harness fixes (d714f5d) and release 2.9.28 (60b4ace) committed at wrap-up; its agent was finishing the gate, handshakes and copy-store runs. Check whether `origin/feat/gap-parity` exists; if not, finish the gate in that worktree and push.
  - RESUME (priority order, weekly credits were low): (1) confirm `feat/gap-parity` gate + copy-store results; (2) serial live tests in `apple-notes-mcp test` only; (3) open the upstream DRAFT PR (neutral wording, 3.0.0 suggestion, breaking-ish: error codes, query negation, `quicknote` bare word), then close #250 pointing at it; (4) sweetrb's open issues. Version must stay above main and #258 (2.9.27).
- [ ] sweetrb/apple-notes-mcp#258 data-correctness fixes: open at 2.9.27 (head 34fbde0), CI green before the last main merge; Autofix watches it. Asks sweetrb about query negation on locked notes and word-count changes.
- [x] Rob replied to the credit email; he added the credit himself in #255 (2.9.23). Thank-you reply sent 2026-09-24.
- [x] Trashed `scratchpad/w/copy` (a NoteStore copy) at wrap-up. The gap-parity agent was asked to trash its own copies.

**Verification**: macOS 27.2 (26B5091g), Node 26.9.0, pnpm 11.9.0. Every branch named above passed lint, typecheck, format check, the full unit suite (no skips) and build with a matching bundle before it was pushed. Every live test used disposable notes, a smart folder and a subfolder inside `apple-notes-mcp test`, and all were deleted afterwards (they are in Recently Deleted; one test note was permanently tombstoned by the Recently Deleted to smart folder reproduction). Writer installs went to scratch directories, never to the plugin's install directory.

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
