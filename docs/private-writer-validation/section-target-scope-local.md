# Section-link target scope: local contract evidence

2026-10-08. This is a dependent local review patch atop `f5e377f` and the
closed, unmerged private-writer candidate. It is not independently landable
on stable upstream and does not resolve the maintainer's writer hold.

Native writer source SHA-256:
`2d48d100529db1be3408c658a0b2981ab2226e55209bd6248c58e0513c6415bd`.

The service, tool and `add_section_link` protocol now accept an explicit
`targetScope` object with `ifFolderId`, `ifAncestorFolderId` and
`forbiddenAncestorFolderIds` (at most 50 exact folder ids). A nonempty receiver
policy on a cross-note link requires a nonempty target policy. Target-only
policies work, and the target check runs regardless of paragraph-ID minting.
Self-links use one subject: a target-only policy guards it; two explicit
policies must be equivalent or the request refuses. Only known folder-id
spelling and forbidden-list set order are normalized for equivalence; original
folder ids still have to resolve in the writing store.

Both subjects are checked in the writing context before paragraph-ID minting
or chip creation and again before the shared save. Folder ancestors, guard-id
existence/deletion state, and an unchanged target's direct folder are fetched
from persisted values. This catches cached ancestry drift even when the
target's `r1:` has not changed. Persisted deleted ancestors now fail closed.

Validation executed:

- Seven focused Vitest suites, `--maxWorkers=2`: 100 tests passed. Suites:
  `privateWriterSectionScopeNative`, `privateWriterSectionLinks`,
  `privateWriterParagraphTools`, `privateWriterScope`, `privateWriterSource`,
  `privateWriterScopeInputs`, and `privateWriterSafety`.
- `tsc --noEmit`, focused ESLint, Prettier checks, and `git diff --check` passed.
- The native section-scope fixture compiled with test-only `-O0` and reported
  `frameworkLoaded: false`. Its 13 cases cover equivalent/conflicting self-link
  policy, explicit target-policy requirements, target-only exact-folder
  guards, source-pass/target-fail checks, unique and unminted targets, cached
  ancestor/direct-folder drift, missing/deleted/cyclic ancestors, deleted
  forbidden ids, and a permitted independent-policy save. Refusals verify
  fresh persisted bodies/bytes, target paragraph ID and inline-row count, and
  no pending context changes or attempted save. Reparenting fixtures also
  compare the actual production `RevisionToken` before and after ancestry
  drift using fresh peer contexts.

The fixture constructs an original generic in-memory Core Data model and
includes the production scope/save functions with `dlopen` forbidden. It never
opens a Notes store or installed Notes model and does not call NotesShared
section-chip creation. Initial compiler/transport attempts did not produce
runtime evidence; the successful fresh run and final focused suite did.

No generated production-model store, live Notes operation, replica preference
script, permission/configuration change, installed helper, version/build
artifact, release-evidence record or publishing action was performed. All 13
release records remain null; feature opt-ins, running-Notes refusal, source
hash handshake, early-save detection and post-commit uncertainty remain.

The folder rereads do not lock ancestor rows, or an unchanged target row,
against changes during the final read-to-save window. Actual NotesShared
two-note materialization and rollback still need separately authorized,
isolated generated-store coverage. Dirty-editor and replica evidence remain
held and unverified for release.
