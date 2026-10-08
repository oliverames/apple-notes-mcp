# Untouched content preservation draft

This is a dependent local safety patch for the held private writer. It does not
resolve PR #262's maintainer hold or populate any of the 13 null release-evidence
records. It does not add a writer action, enable a gate, change a permission,
dispatch a Notes action, or validate real Notes persistence.

`content-preservation.h` provides a standalone Foundation/AppKit comparator.
Snapshots use immutable typed values and normalized attribute runs. Numeric,
date, font-size, and color components retain their precision; canonicalization
does not use object descriptions, rounded plain summaries, or string delimiters.
Checklist UUID and checked state, paragraph UUID and every supported paragraph
field are preserved. Unknown attribute keys or value classes refuse.

The native adapters accept only explicit synthetic-supported layouts for
`ICTTParagraphStyle`, `ICTTMutableParagraphStyle`, `ICTTTodo`, `ICTTFont`, and
`ICTTAttachment`. Every declared ivar and property across the superclass chain
must fit the pinned layout, and every getter ABI must match. The snapshot reads
all pinned stored fields rather than trusting a getter projection. Extra/opaque
state, extra properties, different superclasses, or getter ABI changes refuse.
These pins are not an assertion that a real NotesShared release has these
layouts. Real native compatibility remains unvalidated and may refuse even a
known class name. Ordinary `NSFont`, pattern/dynamic colors, decimal numbers,
string-only table cell accessors, and unrecognized attributes are availability
limitations. This is not a claim of full native rich-text parity.
The native cell accessor's exposure of stored semantics is also unvalidated.
An empty attributed string cannot expose latent cell paragraph/todo state, so
existing empty surviving cells conservatively refuse before mutation. Empty
cells only in the exact replaced cell or deleted row are intended deltas; new
intentionally plain inserted/replaced cells remain permitted.

Compose compares every original UTF-16 range before save and through fresh
readback. Offsets before the insertion remain unchanged; offsets at or after it
shift by its complete UTF-16 length. The inserted range includes the intended
prefix and trailing newline separators and their new styles. No old character,
paragraph style, or checklist identity is exempted.

Table edits retain the body's supported attributes and every surviving cell's
supported attributes, stable row identities, and stable column identities. Only
the selected replacement cell and newly inserted rows receive a new attribute
allowance, with planned text still checked. Row deletion preserves every other
row and its cells, without assuming any fixed row or column count.

The table preview receipt covers all existing attachments, including the
selected table, before loading its table model. Apply recaptures that receipt in
the writing context and a fresh context. Within-call and fresh pre-save checks
exclude exactly the intentionally changed table; unrelated attachment rows,
media, files, inline objects, hidden/orphan objects, and glyph order use the
shared attachment-evidence implementation. Fresh readback repeats preservation.
The pre-save `RequireExpectedChanges` filters remain. Prune independently checks
that its intended row still exists as a tombstone; a missing row is a failure.
Any caught mismatch or readback exception after save is committed and
indeterminate.

## Synthetic evidence and integration limits

`test/native/content-preservation.m` imports only the comparator and standard
Foundation/AppKit/Objective-C runtime APIs. It contains fabricated style/font/
todo/attachment classes and no private framework import, dynamic loader,
writer/action dispatch, database, or store access. Its reported assertion count
is the test result; source inspection, rather than a printed boolean, establishes
the harness's limited execution surface.

The harness checks loss of bold/italic, links, highlights, underline,
strikethrough, font and timestamps; paragraph alignment, writing direction,
indent, quote level, list start, style and hints; paragraph/todo UUIDs and done
state; sub-rounding color/font/date changes; unknown keys and classes;
independently allocated equal objects; frozen mutable values; explicit UTF-16
maps for append, prepend, title-only and heading placements, including missing
final newlines and emoji; and table cell replacement, row insertion/deletion,
surviving styles, and stable identities. Separate process modes reject a hidden
ivar, extra property, incompatible getter ABI, and unsupported subclass.

`contentPreservation.test.ts` compiles that pure harness and checks its results.
Its separate source assertions check compose/table/prune integration locations,
the expected-change filters, fresh checks, and post-save uncertainty fields.
They are not store-based behavior evidence. The native writer depends on the
attachment owner's `attachment-evidence.h`, `ANMAttachmentSnapshotToken`,
`ANMAttachmentEvidencePolicy`, `FrozenAttachments`, `FrozenDrift`, and
`FreshFrozenAttachments`. Its source closure must bind both evidence headers.
Writer compilation and generated table/prune/compose persistence coverage must
be run on the integrated branch before treating this draft as a verified writer
implementation. No live or copied Notes store was used for this patch.
