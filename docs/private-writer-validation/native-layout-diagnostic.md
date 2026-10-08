# Fixed public native layout diagnostic

This branch adds a separate read-only diagnostic, not a writer adapter. The
unchanged production `content-preservation.h` accepts explicit synthetic
layouts only. No preservation key, native-layout pin, release registry, writer
feature switch, installed client, preference or live store is changed.

The retained generated ordinary-body fixture's compose plan/apply responses
(`writer-135.json` and `writer-138.json` in private fixture `CFD6bW`) both refuse
with `unsupported_note`, `committed: false`, and `Unsupported attributed-text
key`. This is the first observed blocker. It does not establish which native
layout mismatch would appear after that key is handled. The attribute-free c2
fixture proves request/receipt refusals on a narrower body; it does not solve
styled-body compatibility.

`node scripts/test-private-native-layout-synthetic.mjs` accepts no input. Run
only after reviewing its source and the fixed public seed. It creates a new
private scratch directory, uses the identical existing denying sandbox policy
and all six Foundation isolation preflights, keeps `HOME` unchanged, and sets
only `CFFIXED_USER_HOME`/`TMPDIR` inside scratch. It compiles the generic fixture
generator and the separate diagnostic. It never compiles or runs the writer,
never enables authoring gates, and never accepts a store, note, payload or
selector from the caller.

The diagnostic verifies regular single-link files, confinement, the exact
public payload SHA-256 and a generic read-only fixed-note fetch before loading
NotesShared. It then checks ABI and invokes only the existing construction APIs
`managedObjectModel`, `standardStoreOptions`, `mergeableString` and
`attributedString` on the fixed generated note, using a read-only Core Data
store with migration disabled. The entire resulting string must equal the
fixed 184-unit public prose internally. It reports attribute key names and
top-level value classes. Per observed class it reports the superclass chain,
instance size, declared ivar names/type encodings/offsets, declared property
names/attributes/getter ABIs, and declared zero-argument method ABIs. A
zero-argument method is metadata, not an asserted semantic getter.

The diagnostic does not read attribute field values, invoke attribute getters,
traverse nested todo/font/attachment state, describe or archive an attribute,
read object bytes, or emit text/UUID/value/pointer payloads. Runtime metadata C
APIs provide the schema. `supportedKey` means membership in the unchanged key
allowlist; it does not mean its native value can be preserved. The strict
nested report validator rejects extra fields, inconsistent chains, unbounded
metadata and broadened coverage flags. The full scratch tree and raw database
bytes must match after the process returns. Any new journal/cache/preference
file fails this check; only the three exact harness evidence filenames are
excluded.

Raw stdout, stderr, model-dependent stores and failures remain in scratch.
Even successful output requires separate privacy review before sharing. The
harness records all local source dependencies and binary/model/profile hashes.
A failed run is retained and diagnosed from source; do not rerun blindly or
loosen the profile/layout pins to obtain availability.

## Adapter work after metadata review

1. Treat each new native attribute key as a separate representation contract.
   Identify its actual class/schema and semantics using a fixed public fixture;
   do not alias or drop the key merely to let compose proceed.
2. Compare actual ivars, properties, superclass and getter ABI against the
   current synthetic-only pins. Any opaque C++/CRDT state remains unsupported.
   A class name or a set of familiar getters cannot establish complete state.
3. A getter projection needs evidence that all stored fields and nested values
   participate, including immutable-versus-mutable behavior and identity/state
   preservation. An archive or private serializer needs its own audited API,
   complete deterministic representation contract and round-trip/collision
   fixtures. This diagnostic provides neither.
4. Before changing acceptance pins, add separate reviewed public fixtures for
   todo state, attachment glyphs/media and native table CRDT. This seed has no
   todo, body attachment glyph, media or table. Its hidden inline row does not
   supply those types of evidence. Surviving empty table cells remain held
   until latent paragraph/todo state can be completely observed.
5. Two-note source/target flows need independent complete body, row, file and
   context preservation with refusal-before-mutation checks. Metadata on this
   one-note seed cannot validate their cross-process scope/save behavior.

Dirty-editor merging, replica/preference-reset behavior, independent-device
upload, and the maintainer's writer hold remain separate acceptance work.
