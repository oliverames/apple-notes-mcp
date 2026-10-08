# Observed native attribute representation

This dependent local patch represents all reviewed stored fields of the five
native attribute classes on this Mac. It adds no writer action or permission,
does not resolve the maintainer hold, and leaves all 13 release records null.

The layout input is the exact saved public-fixture diagnostic JSON, SHA256
`a5abc6b1588edb5cc70da3371e3d6cc71eb56506a7483b469c082f4c8486eb53`.
Its privacy-reviewed immutable subset is checked in as
`test/fixtures/native-attribute-layouts-public.json`. Layouts are explicit;
the comparator never learns or broadens a schema from an input object.

| Class | Direct storage | Direct properties | Representation |
| --- | --- | --- | --- |
| ICTTParagraphStyle | 11 fields, size 80 | 26 | All scalar bytes, cleanup flags, UUID and todo |
| ICTTMutableParagraphStyle | No new fields, size 80 | 11 | Separate dynamic-property contract plus full superclass contract |
| ICTTTodo | done B at 8, UUID at 16; size 24 | 2 | Exact stored flag plus required UUID |
| ICTTFont | hints I at 8, name at 16, size d at 24, nativeFont at 32; size 40 | 4 | All four fields; nested nil or supported public font |
| ICTTAttachment | identifier at 8, UTI at 16; size 24 | 6 | Both required strings plus the complete runtime property contract |

Every declared field encoding and offset, instance size, superclass, property
attribute string, and inherited getter ABI must match. Stored scalar values use
`["stored-scalar", encoding, immutable bytes]`; they do not rely on NSNumber
boxing to preserve signedness or BOOL representation. The paragraph snapshot
remains `["paragraph", fields]`, including the existing UUID/todo tags. Unknown
keys, classes, references or additional state refuse before mutation.

The observed nested nativeFont reference was nil. Metadata did not read scalar
field values or invoke attribute getters. Availability of the class layout is
separate from complete archive semantics and from native writer persistence.
No native operation in this patch verifies a populated nativeFont, todo or glyph.
Pure counterfeit fixtures use the actual reviewed ABI to verify those paths.

## Public font contract

Core Text publicly bridges its font and descriptor types to NSFont and
NSFontDescriptor. Its normalized descriptor is documented to contain enough
information to recreate the font; the descriptor attribute dictionary fully
specifies the descriptor. Creation can return the best match, so successful
construction alone does not prove preservation. See
[CTFontCopyFontDescriptor](https://developer.apple.com/documentation/coretext/ctfontcopyfontdescriptor(_:)),
[CTFontDescriptorCopyAttributes](https://developer.apple.com/documentation/coretext/ctfontdescriptorcopyattributes(_:)), and
[CTFontCreateWithFontDescriptor](https://developer.apple.com/documentation/coretext/ctfontcreatewithfontdescriptor(_:_:_:)).
The [Apple TrueType format specification](https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6.html) defines a font as a sequence of tables, including the required outline, metric, naming and post tables. The [OpenType format specification](https://learn.microsoft.com/en-us/typography/opentype/spec/otff) likewise defines selected-face data through its table directory and additionally requires OS/2. Inference from these format contracts and Core Text table enumeration/copy supports the complete tag/data witness for this narrow TrueType outline domain.

These contracts were checked against the selected Xcode 27.1 SDK headers. The
Xcode documentation service was disabled and its settings were left unchanged.

The supported immutable witness contains the entire original and normalized
attribute graphs, font name and exact size, all six matrix and text-transform
components, vertical state, explicit rendering mode, observed variation and
feature settings, and every available selected-face font table. The complete selected-face TrueType SFNT
table data differentiates resource collisions that name or URL alone cannot.
Absence remains distinct from an empty dictionary/array. Numeric variation keys
are typed; feature and cascade arrays retain order and duplicates. See
[fontAttributes](https://developer.apple.com/documentation/appkit/nsfontdescriptor/fontattributes),
[CTFontCopyVariation](https://developer.apple.com/documentation/coretext/ctfontcopyvariation(_:)),
[CTFontCopyFeatureSettings](https://developer.apple.com/documentation/coretext/ctfontcopyfeaturesettings(_:)), and
[table access](https://developer.apple.com/documentation/coretext/ctfontcopyavailabletables(_:_:)).

Two public descriptor factories cover the documented size and transform
precedence rules. At least one reconstructed font must re-freeze identically
in every witness field, including resource tables. No field is dropped to make
a round trip pass. Unknown descriptor values, cycles/budget overflow, nonfinite
numbers, concrete classes differing from fixed public font/descriptor factories, unresolved default rendering,
missing required TrueType outline/metric tables, non-TrueType resource formats, missing table bytes, and substitution refuse. The actual resource format is captured and compared on reconstruction; both TrueType and OpenType TrueType faces are supported. Other legitimate Apple class-cluster implementations may conservatively refuse. Public descriptor graphs support
strings, typed numbers, bytes, URLs, character-set bitmaps, affine transforms,
arrays, numeric/string-keyed dictionaries and nested descriptors.

This is the documented public font semantic contract, not an archive of
undocumented font internals. The pure fixtures establish an ordinary named font
round trip and a materialized transform collision whose old name/size projection
is equal. They separately check numeric variation-key retention, feature order,
mutable input detachment, cycles and unsupported descriptor values. They do not
claim materialized variable-font, feature, cascade or same-name resource coverage.

## Evidence

Pure attributed-content assertions and the four adversarial process modes pass.
The native writer passes clang syntax checking, and transitive source integrity
includes `native-attribute-layouts.h` and `public-font-preservation.h`.

Both new extended diagnostic harness attempts remain failures:

- `llxymN`: the outer sandbox prevented the isolation preflight from completing;
  no generator, private framework or diagnostic executed.
- `htEErd`: all six preflights and the fixed generic public seed passed. Exact
  store bytes and the entire non-evidence scratch tree remained identical.
  The diagnostic emitted metadata, but the original strict validator rejected
  Objective-C's numeric 0/1 boxing of two metadata comparison flags.

The exact saved second stdout was separately validated offline after limiting
those two flag fields to boolean or exact 0/1; unexpected fields and payloads
still refuse. The original executed hashes remain recorded. This is offline
metadata evidence, not a repaired harness pass. No third execution occurred.

The next native prerequisite is a source-reviewed fresh generated fixture that
captures these adapters before and after actual writer normalization, with
rich todos/glyphs and a populated nested public font where safely constructible.
Complete cell/table CRDT state is owned by the table adapter, and complete
attachment/file isolation and both-note preservation by their respective
patches. This implementation does not infer those guarantees from styled text.
