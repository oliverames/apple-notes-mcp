# Worklog

## 2026-09-25 - Upstream submission, live tests, fork and clone sync (Mac) - START HERE

**What changed**:
- `feat/gap-parity` rebuilt on `origin/feat/gap-parity` (`da9dff0`): cherry-picked the #84 heal wiring (`edd4a63`, was `32933d0`) and the writer harness fixes (`81f808a`, was `d714f5d`), carried their README/TECHNICAL_NOTES/CHANGELOG text (`2f57069`), and dropped `60b4ace` (2.9.28 release). `c6d3497` was already on origin. Later merged upstream 2.9.30 and renumbered to **2.9.31** (`3e4ef92`), then fixed two CodeQL `js/file-system-race` findings in `anchorRegistry.test.ts` (`65029da`, `686e714`). No force-push.
- Upstream: opened **sweetrb/apple-notes-mcp#262** (combined writer + #181 roadmap, not draft, Testing section rewritten to what ran). Closed #250 pointing at it. Posted on #248 (rerun result), #220 (npx-chain suggestion) and #181 (status).
- #248 root cause found: the bridge's Find Notes step matches `scopeText` against Body, which leaves out the title line. Fix **#261** (`textBelowTitle` pre-check) merged by sweetrb with a follow-up making it `validation_error`; shipped 2.9.30. sweetrb closed #248. sweetrb also shipped #263 (2.9.30 CI timing fix; 2.9.29 never published).
- Fork: merged PR #3; closed #4 and #5 (carried by #262); merged upstream/main twice (2.9.28, then 2.9.30) into fork main with merge commits. Kept the fork-only publish guard and the removal of the two marketplace manifests. **Restored upstream's CLAUDE.md** (Oliver, 2026-09-25) because upstream's docs tests read it. Publish workflow skipped on every run.
- Local clone: `main` tracks `origin/main` and contains `upstream/main` (`a1ff4a9`). Removed 66 worktrees (all clean). Deleted 105 remote and 167 local branches that were merged, merged upstream, inside gap-parity, or v1 writer branches replaced by -v2 ports (Oliver approved the list).

**Live tests (macOS 27.2, 26B5091g, serial, `apple-notes-mcp test`, disposable notes deleted afterwards; writer built into the session scratchpad)**:
- Passed: compose create with file + link-card blocks, compose append with PDF + card (stale refusal, frozen attachments proven), writer scope guards (all three refusal reasons, `scope_folder_not_found`, passing pair), native-edit `append_to_paragraph`, `replace_checklist`, attachment replace with a file (SHA-256 verified), file-policy refusals of `~/.zshrc` in compose and edit, `native-read-paper` on a writer-authored drawing (strokes only; revision unchanged), `native-repair-purge-flag` scan/plan/apply-refusal (dry run only; no flagged note exists), `setup --permissions`, `templates edit` (token 401, Host 421, Origin refusals, preview, create-only save 0600, forced replace).
- Not run live: typed-shape decode (needs a Notes-drawn shape), purge-flag apply, `--tailnet`, `remint` through the writer, `anchors serve`, `setup --permissions-window`, HTML drawing export, `query-notes` additions.

**Decisions made**:
- #261 claimed 2.9.29 and merged first, so #262 moved to 2.9.31 above main's 2.9.30.
- Kept 9 remote branches whose upstream PRs closed unmerged (#70, #72-74, #86, #95, #102, #241, fork #2) and `feat/paper-vector-decode` (no PR, not in gap-parity, content unverified).
- PR descriptions carry no Claude Code footer (harness rule); comments do.

**Left off at**:
- [ ] #262: every check green on `686e714` (CodeQL included), both CodeQL threads replied to and resolved. sweetrb (2026-09-25 11:35) is holding it for Rob's decision on the three write questions, flag defaults and 3.0.0. Auto-fix monitor is on. Nothing to do until review.
- [ ] #220: sweetrb replied (2026-09-25) that the disclaimer breaks the TCC chain at the first child, so npx likely doesn't matter; a direct-node test is optional data. Left open. No action needed unless Oliver wants to run that test.
- [ ] Unverified: `list-attachments` reported `contentType` as a `cid:` string for writer-added attachments on the compose test note. Check whether AppleScript-added attachments do the same before filing upstream.
- [ ] Fork Dependabot security-update runs for js-yaml and qs failed on `434c2bd` (not investigated).
- [ ] A detached worktree from another session remains at `/private/tmp/claude-501/-Users-oliverames/b7151a52-.../scratchpad/sync-wt/feat-markdown-templates` with 14 uncommitted changes. Not ours to discard.
- [ ] Live-test the items listed as not run live when a flagged note or Notes-drawn shape is available.
- Tracking: issues are disabled on the fork, so this list is the tracker. The `list-attachments` item stays unfiled upstream until it is reproduced with an AppleScript-added attachment.

**Verification**: gap-parity: lint, typecheck, format check, `test:coverage` 3219 passed with none skipped, bundle matches; fork CI green on `2f57069`; upstream CI on #262 fully green on `686e714`. #261: 2531 tests, live refusal confirmed. Fork main: 2531 tests pass, CI and CodeQL green on the final merge, npm publish skipped. Clean `pnpm install --frozen-lockfile` plus build leaves `git status` clean.

## 2026-09-25 - Integration pushed; Mac handoff (cloud session)

**What changed**:
- `origin/feat/gap-parity` (`da9dff0`, 2.9.29) was rebuilt in the cloud from pushed branches. It contains `upstream/main` `7bcb131` (2.9.28), `feat/writer-suite`, every `wgap/*` branch (through `wgap/file-read-policy` and `wgap/edit-file-policy`), `gap/upstream-bundle` (all four `gap/*` branches) and #250's `feat/native-writes-upstream`.
- Conflicts were resolved by keeping both sides. In three places upstream #258 was folded into refactored code: `exportAssets.ts` `write()` keeps the directory-failure handling, the HTML export receipt keeps both truncation and vector drawings, and the query-notes text keeps both.
- The CHANGELOG has one consolidated 2.9.29 section. Everything from 2.9.28 down is byte-identical to upstream's file. There are no NotesCTL or reference-tool mentions.
- macOS CI passed on `feat/gap-parity` (fork run 36078775859), fork PR #4 and fork PR #5. Fork PR #3 is green.
- Fork PRs: #3, #4 and #5 are out of draft. #2 was closed as superseded by #3.
- Upstream post drafts (combined PR body, #250 close, #248, #220, #181) are in a comment on fork PR #3.

**Not in the cloud build**: the Mac-only commits in the old `feat/gap-parity` worktree (`.claude/worktrees/agent-ae5d5490ebc2da511`): #84 heal wiring `32933d0`, harness fixes `d714f5d`, and release `60b4ace` (2.9.28, which now collides with upstream). The #40 permission broker was never built.

**Left off at** (all on the Mac):
- [ ] Reconcile the local worktree with `origin/feat/gap-parity`. Take the origin branch as the base, cherry-pick `32933d0` and `d714f5d` (resolve against the new code), and drop `60b4ace`. Do not force-push over origin.
- [ ] Run the serial live tests in `apple-notes-mcp test` for the features never run live (listed in the draft PR body). Update the PR's Testing section to match.
- [ ] Open the combined upstream PR, not as a draft. Close #250 pointing at it, post on #248 (after the rerun), #220 and #181, and check every upstream thread.
- [ ] #248 rerun: see the 2026-09-25 entry below.
- [ ] Sync fork `main` with upstream (Oliver, 2026-09-25): merge `upstream/main`, keep the fork-only publish guard, merge PR #3 first. Note that `main` currently tracks `origin/main` (2026-07-24 entry).
- [ ] Close fork PRs #4 and #5 unmerged, noting that `feat/gap-parity` carries them. Then sync the Mac's local clone: fast-forward local `main` to `origin/main` (tracking `origin`), remove superseded worktrees, and ask Oliver before deleting remote branches. The full prompt is in the session's final handoff.

## 2026-09-24 (evening) - Upstream review from a cloud session

**What changed**: Nothing in code. Read-only review of upstream state from a Linux cloud session, which cannot run live Notes tests.

- Upstream merged #256 (2.9.24), #257 (2.9.25) and #258 (2.9.27). sweetrb commented on each and agreed with every judgement call; he added a Mobile Documents/CloudStorage carve-out to #256 and a `committed:true` fix to #257 (bbc7811).
- sweetrb then shipped #259 (2.9.26) and #260 (2.9.28): a shared `readAllowedFile()` in `src/utils/attachmentFs.ts` now scopes add-attachment, create-note-with-attachment, analyze-svg and templateFile reads (roots, hidden/`~/Library` rule, realpath re-check, O_NONBLOCK, dev/ino match).
- Upstream main is `7bcb131` (2.9.28). Open upstream items: draft #250 (no maintainer comment yet), issues #181 (our roadmap), #220 (FDA under Claude Desktop), #248 (ours).
- #248: #251 fixed the reporting half (refusal now `committed:false`, message suggests search lag). The root cause (Find Notes returning nothing on 27.2) is still unconfirmed and needs a Mac.
- #220: #227 changed the advice to grant the Node binary, but the reporter had already tried that with `npx -y`. Untested hypothesis: the `npx` wrapper or a shell in the launch chain becomes the responsible process. A cheap test is `command` = absolute node path, `args` = absolute `build/index.js`, then grant that node.

**Findings that block the gap-parity PR**:
- `origin/feat/gap-parity` does not exist. It lives only in the Mac worktree named in the 2026-09-24 entry, so resume step (1) must run on the Mac.
- Its release number 2.9.28 now collides with upstream #260. Merge upstream main and renumber to 2.9.29 or higher.
- `wgap/compose` `composeFileSize()` (`src/services/privateCompose.ts`) accepts any absolute path with only O_NOFOLLOW, and the writer then reads that file into the note. That is the #195 class sweetrb just closed in #259; it also lacks O_NONBLOCK, so a FIFO can block. Route compose attachments and paper `svgPath` (`assertReadableInRoots` in `privatePaperWriterTools.ts`) through `readAllowedFile()` or its policy check after the merge.
- Fork PR oliverames/apple-notes-mcp#2 is obsolete once fork main syncs with upstream (its CI fix is a port of upstream #152). Fork `main` is still at 2.7.1.

## 2026-09-25 - File-read policy fixes for the writer branches (cloud session)

**What changed**:
- `wgap/file-read-policy` = `wgap/compose` + upstream main `7bcb131`, as 2.9.29. The merge commit `9386722` adapts the paper writer to #260: `analyzeSvgFile` is gone, and `svgPath` now reads through `readAllowedFile`. It also keeps writer timeouts as `timeout_indeterminate`, because #257 made the read-only helper map a timeout to `operation_failed` and the writer fell through to that mapping. Fix `307102a` routes `compose-note` file blocks through a new `assertAllowedFile()` in `attachmentFs.ts`, which shares `readAllowedFile()`'s checks without reading the file.
- `wgap/edit-file-policy` = `wgap/edit` + the same upstream merge (`10c06ca`) with byte-identical shared files. Fix `dbeaa63` routes `native-edit-note` replacement files (#78) through `assertAllowedFile()` as well.
- Not changed: the #84 anchor registry and #39 permissions window in `gap/upstream-bundle` read server-owned paths, not caller paths. The paper `svgPath` copies on `wgap/objects` and `wgap/guards-sync` are the same shared code that the two merges fix.

**Decisions made**:
- One fix branch per writer branch, with no compose/edit merge here. Their conflicts (`apple-notes-private-writer.m`, `privateWriter.ts`) were already resolved in the Mac-only `feat/gap-parity`, and a second, different resolution would only conflict again.
- The per-file-block check stays a check. The writer still opens the path itself, so a local process that swaps the file between the check and the writer's open is not covered. That threat is outside the prompt-injection case #259 closed.

**Left off at**:
- [ ] On the Mac, in the `feat/gap-parity` worktree, merge `wgap/file-read-policy` and `wgap/edit-file-policy`. The top of CHANGELOG will conflict. Renumber the release to 2.9.29 or higher (upstream has 2.9.28), then run the gate and push `feat/gap-parity`.
- [ ] #248 test on the Mac: the bridge Shortcut filters Find Notes by `Name contains title AND Body contains scopeText` (`scripts/build-native-operations-shortcut.py`, `select()`). The 2026-09-24 repro used the title as `scopeText` on a note whose body was "x". If the Shortcuts "Body" property leaves out the title line, the filter can never match, which fits three identical refusals better than search lag. Repeat the repro with a `scopeText` of 12 or more characters taken from below the title. If that works, the server pre-check (`mutateBackground`, `before.rich.text.includes(scopeText)`) should refuse a `scopeText` found only in the title line, and the #251 refusal message should say so. Report the result on #248.
- [ ] #220 suggestion for the reporter (untested): launch without `npx`, using `command` = absolute Node path and `args` = the absolute `build/index.js`, then grant that Node binary. That tells us whether the `npx` launch chain is what defeats the Node grant. This session's GitHub access cannot comment on sweetrb/apple-notes-mcp.

**Verification**: Linux cloud session, so no live Notes tests. On both branches: `tsc --noEmit`, eslint and the prettier check pass, the rebuilt bundle matches the committed one, and the full vitest run has no failures beyond the 44 that fail on unmodified upstream main in this Linux container (osascript, `/private/tmp`, case-insensitive paths). The new refusal tests (hidden directory, FIFO) run and pass here.

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
