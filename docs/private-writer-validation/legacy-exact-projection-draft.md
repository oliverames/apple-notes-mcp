# Legacy edit exact getter projection — dependent draft

This preparatory branch extends `fix/private-safety-contracts` at
`23fc9acc77bb32457b0a075595abbcb187004795`. It changes no action, request key,
feature gate, release-validation record, package version or installed helper.
It is not a release candidate or accepted writer validation.

The legacy edit path previously rounded timestamps to six decimal places,
font sizes to four, and colors to hexadecimal components. It also combined
attribute fields with separators. Those representations could compare changed
values as equal. The new shared projection retains scalar type and bytes,
exact component colors and color-space information, and length-framed values
with literal UTF-16 dictionary ordering. Unknown representations refuse.
Private getters are called only after checking their return ABI, implicit
argument ABI and argument count.

An attributed-string copy retains its mutable attribute objects. The plan
now captures immutable getter projections before planning and mutation,
freezes replacement projections and planned glyph identities, and compares
fresh read-back against those values. Untouched ranges include timestamps;
the existing timestamp allowance remains limited to intended replacements
and no-op determination. Slice offsets and lengths remain UTF-16 units.

This is still the existing supported **getter projection**. It does not prove
that native font, paragraph, checklist or attachment objects have no opaque
fields. The strict stored-layout compose/table adapters remain separate and
continue to refuse unsupported keys, layouts and cell representations.

`legacy-attribute-projection.h` joins the writer's recursive source closure.
Any eventual deployment requires a rebuild and its new integrity manifest;
the old helper checksum cannot validate this source. The `p4` plan schema,
mandatory `ifAttachmentSnapshot` receipt and all per-feature gates are
unchanged. Old generated proofs retain their original source and hashes;
they are not claimed as execution evidence for this new writer.

Validation uses public Foundation/AppKit objects and synthetic getter fixtures. The standalone
fixture checks single-ULP numeric/font/date changes, exact alpha/color space,
separator/NUL/Unicode key handling, checklist identities, range slicing,
mutable values and incorrect getter ABI. Six regression checks call the
actual production `VerifyAgainstPlan` against shallow copies with shared
mutable attributes; dynamic framework loading is forbidden and no context
or store is opened. Type, lint, source-closure and syntax checks supplement
those assertions. No live Notes, private framework, Shortcut, preference
reset or device-sync experiment is performed by these tests.
