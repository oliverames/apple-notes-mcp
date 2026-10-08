# Generated synthetic store validation

`node scripts/test-private-writer-synthetic-store.mjs` builds a fresh, one-note,
one-account SQLite store using the installed Notes Core Data model. It never reads or
copies a personal database and takes no private payload or path as input.

The public baseline is constructed field by field in
`scripts/lib/synthetic-note-payload.mjs`: fixed test prose, fixed test UUIDs,
explicit CRDT character/attribute clocks and child references, fixed timestamps,
and a fresh gzip stream. There is no embedded snapshot or opaque base64 blob.
The generator uses generic `NSManagedObject` instances with the unchanged system
model, without loading NotesShared or invoking its object-insertion hooks.

The dedicated workflow `Private writer synthetic store` runs the pure fixture
and replica-evidence tests, then executes the unmodified production writer
against this store. It checks model compatibility, exact baseline decoding,
feature refusal, native append, compose planning, missing/mismatched digest
refusal, real rich compose, fresh-coordinator verification and final integrity.
The fixed `--scope-fixture` generator mode adds a parent for the note's folder
and two off-chain forbidden folders, for four generated folders in total. The
default generator mode remains the one-folder fixture.

For `p3` edit plans the harness simultaneously requires the exact folder, its
generated ancestor, and both forbidden folders. With the same loaded revision,
operations and supplied plan digest, it refuses omission of each guard, either
shortened forbidden list, an empty list, and removal of every guard. The same
matrix runs for a changing replacement and an identity replacement whose plan
is a no-op. The identical strong-scope no-op succeeds with `committed: false`;
the identical changing request commits and verifies the entire expected body.
Every plan, refusal and accepted no-op compares the raw database SHA-256, stored
body SHA-256, complete SQLite dump SHA-256, entity counts, and exact scratch
file-tree entries. Only exact harness report/response filenames are excluded
from the tree; native media, journals, preferences and temporary files are not.
These checks establish persistent state after each process returns, not an
absence of transient in-process activity.

Missing and mismatched digests also refuse a prospective compose-file request,
after its read-only plan, with identical object and file checks. The file is
constructed from literal public bytes inside scratch, and no matching file
apply is attempted. The fixture contains no existing attachments, so it does
not exercise nonempty attachment preservation or `p3` replacement-file
materialization. Digest validation establishes consistency of the loaded
revision and semantic request; it does not authenticate a prior preview.
An unsupported model, API or sandbox fails the job; it does not count as a pass.
The workflow uses the current hosted macOS model rather than shipping an
OS-specific SQLite database.

Before opening any Notes model, the harness proves its file, preference-service
and network denials with a Foundation-only probe. Child processes can read only
system files and their new private scratch root, can write only that root, and
cannot contact Mach services or the network. `HOME` is unchanged;
`CFFIXED_USER_HOME` and `TMPDIR` point inside scratch. Generator policy checks
also reject direct execution outside this sandbox. These are observed boundary
checks, not a claim that every possible IPC mechanism has been analyzed.
The isolated user starts with empty `Library/Preferences` and `Library/Caches`
directories. A cold file-compose plan was observed to create only the empty
Caches directory, with exact database/body/dump/object state unchanged; that
attempt failed the tree assertion and was retained as incomplete. Precreating
ordinary cache infrastructure avoids testing this initialization as note
materialization. Native files or later directory changes remain fully covered
by the unchanged tree assertions.

The synthetic account is local (`accountType = 0`) and starts with a generated
bundle-ID-to-replica map, avoiding an unrelated lazy account update during a
note-only write. This deliberately configured map is not evidence of a user's
production account state. The fixture does not prove live editor merge behavior,
persistent preferences, replica identity on a real account, or cloud upload.
Feature release flags therefore remain unchanged.

Each run retains a private report, source hashes, native responses and the store
in a fresh `/private/tmp/apple-notes-synthetic-fixture-*` directory. The workflow
does not upload these artifacts. Native serialization can add identifiers or
metadata, so generated outputs still need a separate privacy review before
sharing. Only the deterministic, pre-write baseline is designed as public test
data; no runtime fixture is committed.
