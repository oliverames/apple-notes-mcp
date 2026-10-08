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
Raw stdout and stderr remain private pending a separate privacy review.
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

No retry has occurred. A future source candidate must distinguish fixed payload
match booleans from bounded in-memory change flags and retain exact read-only
store/tree checks. Each new execution requires exact-source root approval.
