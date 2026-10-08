# Fixed public native comparator control

This source-reviewed control imports the production `content-preservation.h`
without importing or executing the writer. It accepts no personal input and
opens only a freshly generated fixed public store under the established denying
sandbox. Its native objects, UUIDs, text, link and glyph UTI are public constants.
The production six-file source closure is
`4cc975742d74f769076327315f21339b3760526fd7e51b957b025553f5cb5b10`.

The first approved attempt, `/private/tmp/apple-notes-synthetic-fixture-Xl7WEa`,
is **FAILED**. Its original reviewed source hashes were:

- control: `345d25ccf5dc18641de4a5a5a093d733ef65af8c3044070fa178d2c1d3d0f92d`
- harness: `27ed631d6cb883e8dbf9491617c9a82a16a63833f59a6871479da45eee79b3d8`
- strict validator: `222542cc494d375bcf40b36a6e9156842fffb9fe03a158d875140ccce915ff9a`

The original strict validator accepts the retained bounded failure envelope.
Raw stdout SHA256 is
`c5516b7cd50787cd90b1776345b64f22294b7e57d5dcd023423435b0d01afbab`.
The bounded raw stdout envelope was separately privacy reviewed for export;
raw stderr, store bytes and native body values remain private.
The completed ordered checks are:

1. `native-fixed-seed-accepted`
2. `native-fixed-seed-repeated-projection-stable`
3. `native-fixed-seed-independent-context-stable`

These establish that the actual production comparator accepts the fixed native
seed and that repeated and independent read-only projections compare equal.
They do not establish durable writer behavior or complete archives.

The failure stage `read-only-public-body-ledgers` covers both the fixed payload
hash recheck and `!first.hasChanges && !second.hasChanges`. Its existing envelope
cannot distinguish those two conditions. In-memory lazy initialization is a
possible explanation, not an observed result. The fresh mutable/todo/glyph/copy
and mutation controls were not reached, so they remain unproven on actual
native objects.

All six isolation preflights passed before generation/model/framework access.
The generic generator created only one public note, one account, four folders
and one hidden inline attachment without loading NotesShared. No writer or
store save was invoked. The raw before/after ledgers are exactly equal:

- SQLite store SHA256: `0914ca7c22972edf052c896e5825f28f9ff02d83f4a1fd0460998dcce086f7c0`
- entire non-evidence tree SHA256: `e325aab255e46afb555b50361e33271c1e8decbf4c651f025e190bb15aedeaa0`
- tree: six files, six directories, 542129 bytes

This failed source was not rerun. The separately approved amended source below
distinguishes payload matches from bounded in-memory change flags and retains
the exact read-only store/tree checks. Each execution requires exact-source
root approval.


## Separately approved amended control

A separately reviewed schema2 control was executed exactly once in fresh root
`/private/tmp/apple-notes-synthetic-fixture-qZeFi9`. It completed successfully
at these reviewed source hashes:

- control: `c340b2f32d1f44d2cd81d6ae449ce991e8f6832a0fb233eca7f79a1afabec554`
- harness: `204f5b678ea5f03c3326df6798ae13de4ec2f2cee40a62d5c2f4bc540e53f691`
- strict validator: `1e3f1ef959d029740b1f98b34d4d6351e537dd35f6214432469dc73a2d49573e`
- raw bounded stdout: `42109c9f652a7ff278ea1079223b16473af7f02b52f99a166c96dfcb82e7f7c3`

The amended source runs independent fresh in-memory controls before opening
native read-only store contexts. Its exact ordered checks all passed:

1. `native-mutable-todo-glyph-accepted`
2. `independent-native-memory-values-stable`
3. `native-mutable-to-immutable-copy-preserves-stored-state`
4. `native-stored-field-todo-glyph-mutation-detected`
5. `native-fixed-seed-accepted`
6. `native-fixed-seed-repeated-projection-stable`
7. `native-fixed-seed-independent-context-stable`
8. `native-fixed-seed-public-body-ledgers-unchanged`

The in-memory controls use only source-established, type-checked constructors
and setters on newly allocated native objects. Todo UUID/done and attachment
identifier/UTI expected witnesses come independently from fixed public
constants. Independently reconstructed native rich objects compare equal.
Actual mutable paragraph `copy` yields an immutable paragraph and preserves
all stored fields. Indent, todo done and glyph identifier mutations each break
comparison; exact restoration recovers it. The control does not allocate a
populated private nativeFont reference, execute an archive or claim completeness
for unknown classes or states.

All four before/after payload-match flags were true. Both contexts' bounded
hasChanges observations were true before and after projection. These describe
in-memory state; no cause or harmlessness is inferred. They do not establish
which combined condition failed in the original attempt. The exact read-only
persistent store/tree invariant is the durable boundary and remained mandatory.

All six isolation preflights again passed before generation/model/framework
access. The production closure stayed `4cc975742d74f769076327315f21339b3760526fd7e51b957b025553f5cb5b10`.
The two raw state ledgers are equal:

- SQLite store SHA256: `5806a92d63c34955b62b1054ec73acb65c6a9f6eec424f5965e419e4bdee6153`
- entire non-evidence tree SHA256: `86e97319ac2c9e6955bbfc86deb9bbce03cfec21fc92418470a00aa90dbb4fb6`
- tree: six files, six directories, 542129 bytes

Independent fixed public literal and observed native body ledgers also matched.
Neither this comparator positive control nor its immutable-copy behavior proves
an independently committed/reopened writer operation. Native persistence,
media/two-note writer fixtures, opaque table CRDT completeness and all release
validation rows remain separate prerequisites. The original FAILED attempt
and all earlier failed metadata diagnostics are retained without reclassification.

The exact bounded success stdout and selected evidence were separately privacy
reviewed for export. No raw stderr, store bytes or native body values are
included in the exported evidence. Preparation checks pass: six pure strict
validator/source/sandbox tests, JavaScript syntax, clang syntax and diff checks.
