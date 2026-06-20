# AppleScript Limitations

Apple Notes is automated through its AppleScript dictionary. A few features that
exist in the Notes UI are simply **not exposed to AppleScript**, so this MCP
server cannot read or write them no matter how the script is written. This page
documents what was investigated, how it was verified, and the conclusion, so the
limitation isn't re-investigated every release.

The full set of properties Notes exposes on a `note` is:

```
container, class, password protected, modification date, creation date,
shared, body, id, name, plaintext
```

(obtained with `properties of note 1 of account "iCloud"`).

## Pinned notes (#28)

**Status: not feasible via AppleScript.** The Notes UI lets you pin a note to
the top of a folder, but the `note` class has no `pinned` property. Asking for
it raises error `-1700`:

```applescript
tell application "Notes"
    set p to pinned of note 1 of account "iCloud"
    -- error -1700: Can't make pinned of note id "x-coredata://…" into type specifier.
end tell
```

There is no alternative property, element, or command (`pin`, `pinned`,
`favorite`, …) in the dictionary. Pinned state lives only in Notes' private
Core Data store (`NoteStore.sqlite`), which is not part of the scriptable
surface. Reading it would require parsing the SQLite store directly — brittle
across macOS releases and outside what an AppleScript-based server should do —
and there is no supported way to *set* it at all.

**Conclusion:** pinned read/write is not supported and will not be added while
Notes lacks a scriptable property. If a future macOS exposes one, revisit by
re-running the probe above.

## Note-to-note links (#30)

**Status: not supported as data; navigation-only.** Apple Notes lets you insert
a link from one note to another in the UI, but AppleScript exposes no property
or element for it:

- A `note` has no `URL`, `url`, or `link` property — each raises error `-2753`
  (undefined). There is no element that enumerates outgoing/incoming links.
- There is no readable or constructable `applenotes://` / `notes://` deep link.
  The note's `id` (`x-coredata://…/ICNote/p123`) is the only stable handle, and
  it is a Core Data URI, not a shareable or clickable link.

The one related capability that *does* work is the `show` command, which reveals
a note in the Notes UI by id:

```applescript
tell application "Notes" to show note id "x-coredata://…/ICNote/p123"
```

This is deliberately **not** wrapped as a tool: it pops the GUI (unhelpful for a
headless server), and an agent already has the note's content via
`get-note-content` / `get-note-markdown`. Link relationships between notes
cannot be read at all, so a "list links in this note" feature is not possible.

**Conclusion:** note-to-note link data is not exposed and cannot be surfaced.
The `id` field already returned by every read tool is the canonical reference;
use that to address a specific note.

## Tags / hashtags (#29)

**Status: parsed from the body, not first-class.** Apple Notes "tags" are inline
`#hashtag` tokens you type into a note's text. They are **not** a scriptable
property — the `note` class exposes no `tags` element, and the tag relationship
lives only in Notes' private Core Data store. So the only way to surface a
note's tags via AppleScript is to read them back out of the body text.

This server does that: `get-note-content` parses the body and returns the tags
as `hashtags` in its `structuredContent` (see `src/utils/hashtags.ts`). The
rules match Notes' own behaviour — a token is `#` followed by letters/digits/
underscores containing **at least one letter**, so `#123` is not a tag; tokens
are de-duplicated case-insensitively.

Two related caveats:

- The `tags` parameter on `create-note` is an application-level pass-through. It
  is stored on the returned object but Notes does **not** persist it, and it does
  **not** create real `#hashtags` in the body. To make a real tag, put `#tag`
  in the note content.
- **Smart folders are not scriptable.** Notes' tag-driven Smart Folders cannot be
  created, read, or enumerated via AppleScript; there is no `smart folder` class
  in the dictionary. Only regular folders are scriptable.
