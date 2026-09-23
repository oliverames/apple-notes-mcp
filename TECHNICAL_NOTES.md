# Apple Notes Technical Documentation

This document contains research findings on Apple Notes internals, programmatic access methods, and known limitations. It serves as a reference for improving the apple-notes-mcp project.

## Table of Contents

- [Data Storage Architecture](#data-storage-architecture)
- [AppleScript API](#applescript-api)
- [Direct Database Access](#direct-database-access)
- [Protobuf Data Format](#protobuf-data-format)
- [Alternative Approaches](#alternative-approaches)
- [Private helper (NotesShared)](#private-helper-notesshared)
- [Known Issues & Limitations](#known-issues--limitations)
- [Related Tools & Projects](#related-tools--projects)
- [Sources](#sources)

---

## Data Storage Architecture

### Database Location

Notes are stored in a SQLite database at:
```
~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite
```

The database consists of three files:
- `NoteStore.sqlite` - Main database
- `NoteStore.sqlite-shm` - Shared memory file
- `NoteStore.sqlite-wal` - Write-ahead log (active changes)

**Important**: The WAL file contains uncommitted changes while Notes.app is running. Always copy the database files before reading directly.

### Key Tables

| Table | Purpose |
|-------|---------|
| `ZICCLOUDSYNCINGOBJECT` | Sync state for notes, attachments, folders (209 columns as of iOS 18) |
| `ZICNOTEDATA` | Note content (gzipped protobuf in `ZDATA` column) |

### Identifiers

- **CoreData IDs**: Format `x-coredata://DEVICE-UUID/ICNote/pXXXX`
- **UUID Identifiers**: Stored in `ZIDENTIFIER` column
- **Z_PK**: Primary key linking tables

### Attachments

Media files are stored separately at:
```
~/Library/Group Containers/group.com.apple.notes/Media/<UUID>/
```

---

## AppleScript API

### Capabilities

The Notes.app scripting dictionary exposes:
- Creating, reading, updating, deleting notes
- Folder management
- Account enumeration
- Note properties (name, body, id, creation date, modification date, shared, password protected)

### Limitations

1. **Attachment Positioning**: Cannot determine where attachments appear within note body
2. **Image Embedding**: Adding images via AppleScript is unreliable; images may appear in attachments browser but not inline
3. **Rich Text Formatting**: Limited control over formatting; markdown is inserted as plain text
4. **Password-Protected Notes**: Cannot read content of locked notes
5. **No Undo**: Operations are immediate and cannot be reverted programmatically
6. **Maintenance Mode**: Apple has disbanded the AppleScript team; no new features expected

### ID-Based Operations

Notes can be accessed by CoreData ID at the application level (not account-scoped):
```applescript
tell application "Notes"
  set n to note id "x-coredata://UUID/ICNote/p123"
  get body of n
  delete note id "x-coredata://UUID/ICNote/p123"
end tell
```

This is more reliable than title-based lookups when duplicate titles exist.

### HTML Body Format

Notes stores content as HTML internally:
```html
<div>Title</div>
<div>First paragraph</div>
<div><br></div>
<div>Second paragraph</div>
```

The first `<div>` becomes the note title. Attachments use a proprietary object tag format.

---

## Direct Database Access

### Reading the Database

```python
import sqlite3
import gzip

db_path = "~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
conn = sqlite3.connect(db_path)

# Get note data
cursor = conn.execute('''
    SELECT n.Z_PK, n.ZDATA, o.ZTITLE1
    FROM ZICNOTEDATA n
    JOIN ZICCLOUDSYNCINGOBJECT o ON n.ZNOTE = o.Z_PK
''')

for pk, data, title in cursor:
    if data:
        decompressed = gzip.decompress(data)
        # Parse protobuf...
```

### Safety Considerations

- **Read-Only**: Never write to the live database
- **Copy First**: Make a copy of all three files before reading
- **Quit Notes**: For consistent reads, quit Notes.app first
- **Full Disk Access**: Required to access the Group Containers path

### Read-Only Metadata Columns (verified macOS 27 / Notes 4.13)

Most useful note metadata lives as plain scalar columns on `ZICCLOUDSYNCINGOBJECT`, so
it can be read with an ordinary `SELECT` and needs no protobuf decoding, unlike the
`ZICNOTEDATA.ZDATA` body blob. The columns below were confirmed against a live store on
macOS 27.0 (Notes 4.13). Column names and availability shift between OS releases, so
treat them as version-specific and feature-detect with `PRAGMA table_info` before use.

| Column | Exposes | Why it matters |
|--------|---------|----------------|
| `ZISPINNED` | Pinned state (boolean) | AppleScript has no `pinned` property, so this is the only read path for pin state |
| `ZHASCHECKLIST`, `ZHASCHECKLISTINPROGRESS` | Whether a note has a checklist, and whether any item is still unchecked | Cheap flags without decoding the body |
| `ZISRECOVERINGFROMTRASH` | Trash / recovery state | Distinguishes a recently deleted note |
| `ZSMARTFOLDERQUERYJSON` | Smart Folder query as JSON | Smart Folders are otherwise not scriptable |
| `ZSNIPPET`, `ZWIDGETSNIPPET` | Preview snippet text | Fast preview without reading the full body |
| `ZISPASSWORDPROTECTED`, `ZLOCKEDNOTESMODE`, `ZPASSWORDHINT` | Lock state and hint | Richer than AppleScript's single `password protected` boolean |
| `ZFOLDERTYPE`, `ZCROPPINGQUAD*` | Folder kind; document-scan crop geometry | Smart vs regular folder; scan bounds |

Reading these is safe under the existing rules: copy the three database files first, open
the copy read-only, and never touch the live store. Writing any of these values directly
is unsafe. It bypasses CloudKit's sync bookkeeping and can corrupt notes or desync iCloud.
To *change* pin state or tags, use the Shortcuts bridge (below), not a SQL `UPDATE`.

---

## Protobuf Data Format

### Document Structure

The `ZDATA` blob contains gzipped protobuf data:

```protobuf
message Document {
  repeated Version version = 2;
}

message Version {
  optional bytes data = 3;  // Format-specific content
}
```

### Note Content

```protobuf
message String {
  string string = 2;                    // Plain text content
  repeated AttributeRun attributeRun = 5;
}

message AttributeRun {
  uint32 length = 1;
  ParagraphStyle paragraphStyle = 2;
  Font font = 3;
  uint32 fontHints = 5;     // 1:bold, 2:italic, 3:bold+italic
  uint32 underline = 6;
  uint32 strikethrough = 7;
  int32 superscript = 8;
  string link = 9;
  Color color = 10;
  AttachmentInfo attachmentInfo = 12;
}

message ParagraphStyle {
  uint32 style = 1;     // 0:title, 1:heading, 4:monospace, 100-103:lists
  uint32 alignment = 2; // 0:left, 1:center, 2:right, 3:justified
  int32 indent = 4;
  Todo todo = 5;
}
```

### Embedded Objects

The Unicode replacement character `￼` (U+FFFC) marks attachment positions. Each has a corresponding `AttachmentInfo` in the AttributeRun with type and UUID.

### CRDT Implementation

Tables and collaborative editing use Conflict-Free Replicated Data Types (CRDTs). Apple uses "topotext" for synchronization with first-write-wins conflict resolution via iCloud.

---

## Alternative Approaches

### JavaScript for Automation (JXA)

JXA provides similar capabilities to AppleScript but with JavaScript syntax:

```javascript
#!/usr/bin/env osascript -l JavaScript

const Notes = Application('Notes');
const note = Notes.notes.byId('x-coredata://...');
console.log(note.body());
```

**Status**: Abandoned by Apple (like AppleScript), has rough edges.

### ScriptingBridge (Swift/Objective-C)

Enables programmatic access via Objective-C messages:

```swift
import ScriptingBridge

if let notes = SBApplication(bundleIdentifier: "com.apple.Notes") {
    // Access notes via generated protocols
}
```

**Limitations**:
- Cannot be used in Mac App Store apps
- Some operations (like adding attachments) don't work
- Considered "incompetent" by many developers

### Shortcuts.app

Can export notes to HTML/Markdown using built-in actions, but limited programmatic control.

---

## App Intents and the Shortcuts Bridge

Apple Notes ships App Intents (the `Metadata.appintents` bundle is present inside
`Notes.app` on macOS 27), which raises an obvious question: can the server call them to
do the things AppleScript cannot, such as pinning, tagging, or appending a checklist item?
This was researched in June 2026 and verified against the live `shortcuts` CLI on macOS 27
and Apple's developer documentation.

### There is no cross-app App Intent invocation

App Intents are a one-way, app-to-system contract. An app *exposes* its actions through an
`AppIntent`'s `perform()` method, and the **system** (Siri, Spotlight, Shortcuts, Apple
Intelligence) is the only caller. There is no public API to enumerate, reference, or
`perform()` another app's intents from your own process. A native Swift helper therefore
cannot invoke Notes' App Intents directly; it could only drive Notes through the same
AppleScript the server already uses, with a worse permissions story. This is consistent
with Apple's `AppIntent` documentation and the SiriKit donation model, where
`INInteraction.donate()` only informs Siri and does not execute anything.

### The only route is `shortcuts run` against a user-installed Shortcut

The `shortcuts` CLI runs a *named, already-installed* Shortcut
(`shortcuts run "<name>" -i <input> -o <output>`). It cannot run a `.shortcut` from a file
path, and it cannot invoke an App Intent directly, so each capability has to be wrapped in
a Shortcut the user installs once. There is no headless import: adding a `.shortcut` always
needs a GUI confirmation click (`shortcuts sign` only changes which prompt appears).

The constraints that make this a BETA, opt-in path rather than a default:

- **Needs an active GUI login session.** `shortcuts run` drives the Shortcuts app and is
  not documented to work at the login window, over plain SSH, or from a `launchd`
  background agent. Only `shortcuts list` is fully GUI-free.
- **One-time manual install** of each wrapper Shortcut, plus one foreground run in
  Shortcuts.app after install or upgrade to answer its first-run consent prompt with
  Always Allow. A background run cannot display that prompt, so it stalls until the
  transport timeout instead, and the CLI exposes no consent state to check first (#172).
- **Plain text only.** Notes actions take rich text or attachments only through their
  interactive compose sheet, which defeats automation.
- **Coarse results.** Exit code 0 or 1 with output on stdout; no structured error surface.

### What a Shortcuts bridge can and cannot add

| Reachable through a wrapper Shortcut | Not exposed as a Shortcuts action |
|--------------------------------------|--------------------------------------|
| Pin / unpin a note | Prepend to a body ¹ |
| Add / remove / create / delete tags | Toggle a checklist item done/undone |
| Move to folder; create / delete folder | Insert a table or import CSV |
| Append a checklist item | Insert a note-to-note link |
| Append plain text to a body | Rich text / Markdown body writes |
| Attach a file | Attach a URL / link |
| Find notes (plain-text result) | Get a note's full contents |

The right-hand column is scoped to the **Shortcuts** inventory — Notes ships no
action for these. It does not mean the capability is unreachable altogether.

¹ Prepend needs no bridge: `append-to-note` (2.6.0) does it over plain
AppleScript with `position: "before"`, by reading the body, splicing the new
block in after the title `<div>`, and writing the whole body back.

### macOS version gating

Apple's "What's new in Shortcuts" pages omit Notes actions, so per-version attributions
come from secondary sources and should be feature-detected at runtime rather than gated on
`sw_vers`:

- **Long-standing (macOS 13 and earlier):** Create Note, Append to Note, Find Notes, Show
  Note / Folder, Rename Folder.
- **Sequoia 15:** Pin Notes, Delete Notes, Move to Folder, Create / Delete Folder, and the
  tag actions (Add / Remove / Create / Delete Tag).
- **Tahoe 26:** Add File, Append Checklist Item (secondary-sourced; verify at runtime).

### Packaging note

If a native helper is ever shipped for the AppleScript path, the packaging is light:
`npm install` does not set the quarantine xattr, ad-hoc signing is enough to run (and is
mandatory on Apple Silicon), and notarization is optional for an npm-delivered CLI. But
TCC attributes the Automation prompt to the host app (the MCP client), not the helper, so a
compiled helper is no better than the in-process AppleScript on permissions and is not
worth the complexity.

### Verdict

Keep AppleScript as the primary engine. If write coverage for pin and tags is wanted, add
a BETA, opt-in Shortcuts bridge scoped to the reachable actions above, with the
GUI-session constraint documented loudly and runtime feature detection instead of version
gating. Do not invest in a Swift App Intents helper; it cannot do the cross-app thing that
would justify it. Markdown-interpreted body writes, checklist toggling, tables, and
*inserting* note-to-note links stay GUI-only under every known approach.

**Update (2026-07, apple-notes-mcp 2.6.0).** Two items on that GUI-only list turned out
not to need a bridge at all, and the verdict above is narrowed accordingly:

- **Prepend** ships as `append-to-note` with `position: "before"`, over plain AppleScript.
  It reads the existing HTML body, splices the new block in after the title `<div>`, and
  writes the body back — a full-body rewrite, not an in-place edit, so the
  attachment caveat still applies. Rich HTML *is* preserved on that round trip, so
  "rich-body manipulation" was too broad; what remains unavailable is having Notes
  interpret Markdown on write.
- **Reading a note-to-note link** ships as `get-note-link`, which returns the
  `notes://showNote?identifier=<uuid>` deep link (primary path: `ZIDENTIFIER` read
  read-only from `NoteStore.sqlite`, needs Full Disk Access; AppleScript `note link`
  fallback on macOS 12–15). Inserting a link into a body, and enumerating the links
  already in one, remain unavailable.

---

## Private helper (NotesShared)

An opt-in native helper (`native/private-helper/apple-notes-private-helper.m`)
edits notes through Notes' own Core Data model. It exists because several
Notes features (checklist state, highlights, structured edits, Smart Folders)
have no AppleScript or Shortcuts interface. It is **unsupported Apple API**.
The findings below were verified on macOS 27.2 (build 26B5091g) with Notes 4.13
(3195.41.8.101.1) on 2026-09-23, by runtime introspection
(`objc_copyClassNamesForImage`, `class_copyMethodList`,
`class_copyPropertyList`) and by running the helper.

### Why Objective-C, and how it loads the framework

The helper is one Objective-C file compiled on the user's Mac with
`xcrun clang` from the Command Line Tools and ad-hoc signed. Objective-C needs
no Swift runtime or package manifest and calls private classes by name
naturally. Linking `-framework NotesShared` is refused for ordinary clients
("not an allowed client"), so the helper links only Foundation, CoreData, and
AppKit, `dlopen`s
`/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared`, and
resolves everything with `objc_getClass` / `objc_msgSend`. Selectors are
compile-time constants; no request field ever becomes a selector.

### Opening the store the way Notes does

`ICNoteContext` (the object Notes.app uses) does not build its store in a
headless process and has no way to point at another file. The helper instead:

1. takes the model from `+[ICPersistentContainer managedObjectModel]` and the
   options from `+[ICPersistentContainer standardStoreOptions]` (on 27.2:
   automatic migration, inferred mapping, persistent history tracking, and
   remote-change notifications);
2. turns migration **off** (a model/store mismatch means the helper is out of
   date, never a reason to migrate the user's library) and adds
   `NSReadOnlyPersistentStoreOption` for every read;
3. attaches `NoteStore.sqlite` to its own `NSPersistentStoreCoordinator` and
   uses a context with `NSErrorMergePolicy` and transaction author
   `apple-notes-mcp-private-helper`;
4. fetches real `ICNote` objects by `identifier`.

Persistent history tracking is what lets a running Notes.app notice the
helper's save. Opening a store that is not the live one needs only a different
file URL, which is how the copy-store test works
(`APPLE_NOTES_MCP_PRIVATE_STORE`; the helper refuses any path that resolves to
the live store, including symlinks and hard links).

### API surface used

| Kind | Name | Used for |
|------|------|----------|
| class methods | `+[ICPersistentContainer managedObjectModel]`, `+standardStoreOptions` | model and store options |
| model properties | `ICNote.identifier/title/modificationDate/creationDate/folder/account/noteData/cloudState/isPasswordProtected/markedForDeletion/needsInitialFetchFromCloud`, `ICNoteData.data`, `ICCloudState.currentLocalVersion/latestVersionSyncedToCloud`, `ICFolder.identifier` | reads, guards, revision token |
| instance methods | `-[ICNote mergeableString]`, `-isDeletedOrInTrash`, `-isSharedViaICloud`, `-isEditable` | body and guards |
| instance methods | `-[ICTTMergeableString attributedString]`, `-beginEditing`, `-endEditing`, `-insertAttributedString:atIndex:` | CRDT edit |
| instance methods | `-[ICNote edited:range:changeInLength:]`, `-regenerateTitle:snippet:`, `-saveNoteData`, `-updateChangeCountWithReason:` | derived fields, serialization, upload eligibility |

Core Data attributes are `@dynamic`, so `respondsToSelector:` is false for
them until Core Data generates accessors. The probe therefore checks model
properties against the entity descriptions and real methods with
`instancesRespondToSelector:`. On 27.2 the mergeable string is an
`ICTTMergeableAttributedString` whose `-string` returns an attributed string;
the helper reads text from `-attributedString`. Paragraph style lives in the
`TTStyle` attribute (`ICTTParagraphStyle`) and rides on each paragraph's
terminating newline. The helper copies only that style onto the separator it
inserts, so the previous last paragraph keeps its style; appended text carries
no attributes and becomes body text.

Fetching an `ICNote` logs a `+[ICNoteContext sharedContext]` backtrace from
`ICAuthenticationState` because no shared context exists in the helper. It is
a log line, not a failure; reads and writes proceed.

### Protocol

One JSON object on stdin (1 MiB cap), one on stdout, exit 0 on success and 1
on error with `{status:"error", code, message}`. Every request carries
`protocol: 1`; a mismatch is `protocol_mismatch`. Unknown actions and unknown
request fields are refused. Actions: `hello` (context-free handshake,
reports the source SHA-256 compiled in), `probe`, `read_note_state`,
`append_plain_text`. Error codes: `input_too_large`, `invalid_json`,
`protocol_mismatch`, `unknown_action`, `invalid_request`, `disabled`,
`store_unavailable`, `private_api_unavailable`, `not_found`,
`unsupported_note`, `revision_conflict`, `save_failed`,
`verification_failed`, `internal_error`. Adding an action is a handler plus
one row in `kActions` and, when it needs new selectors, one requirement table
the probe reports per feature.

### Safety contract

- **Off by default.** Both the server and the helper refuse to open the live
  store unless `APPLE_NOTES_MCP_ENABLE_PRIVATE=1`.
- **Fail closed on install drift.** Setup records the source and binary
  SHA-256 in `manifest.json`; the server re-checks both, and the protocol,
  before every call.
- **Compare-and-swap.** `append_plain_text` requires `ifRevision`. The
  revision (`r1:` + SHA-256) covers the note identifier, folder identifier,
  deletion and lock flags, modification date, and a digest of the serialized
  body (`ICNoteData.data`), so any persisted edit to text, style, or
  attachments changes it. It does not see unsaved typing in an open Notes
  editor.
- **One optimistic save.** `NSErrorMergePolicy` turns a concurrent save by
  Notes into `revision_conflict` with nothing written.
- **Refusals before writing:** locked, shared (collaborative), trashed or
  marked-for-deletion, folderless, not editable, and not-yet-downloaded notes;
  text with control characters other than tab and newline, `\r`, U+FFFC, or
  U+2028/U+2029; more than 50,000 UTF-16 units.
- **Fresh read-back.** After saving, the helper opens a new coordinator
  read-only and requires the persisted text to equal the old text plus the
  insertion. A mismatch is `verification_failed` with `committed: true`.
- **Timeouts are indeterminate** (`committed: "unknown"`). Read state before
  retrying.
- **Never SQL, never a shell, never a caller-chosen selector.**

### Build, distribution, and TCC

`apple-notes-mcp setup --native-helper` compiles the packaged source
(`native/` ships in the npm package; no binary is committed or published),
signs it ad hoc, runs `hello` against the staged binary, and installs it with
its manifest under `~/Library/Application Support/apple-notes-mcp/private-helper`
(`APPLE_NOTES_MCP_PRIVATE_HELPER_DIR` overrides). Upgrading apple-notes-mcp
with a changed helper source makes the installed helper `helper_stale` until
setup runs again.

The helper opens `NoteStore.sqlite` itself, so it needs Full Disk Access.
macOS attributes a command-line child process to the app responsible for it
(Claude Desktop, Terminal), so in practice the helper uses the same grant as
the server's existing `sqlite3` reads. That was observed here only in the
positive case (a host with Full Disk Access; the helper opened the store); a
host without it gets `store_unavailable`. Because the helper is ad-hoc
signed and rebuilt on upgrade, it should not be added to Full Disk Access by
itself.

### Sync behaviour observed

The live test appended one line to a note created for the test in an iCloud
folder, with Notes.app running:

- Notes.app showed the new line immediately through AppleScript (the helper's
  save reached Notes.app's context through persistent history).
- `updateChangeCountWithReason:` and the edit raised
  `ICCloudState.currentLocalVersion` from 1 to 4 while
  `latestVersionSyncedToCloud` stayed 1, so Notes' own upload-eligibility test
  was true.
- Polling read-only every 15 seconds for 5 minutes, and once more 13 minutes
  after the write, `latestVersionSyncedToCloud` never advanced, even after the
  AppleScript read had Notes.app load the note. For comparison, the same note's creation through AppleScript was
  recorded as uploaded (both counters at 1) within the minute before the
  append. So with Notes.app running, the helper's change was visible locally
  but not uploaded in that window. Relaunching Notes.app was not tried,
  because it would interrupt the user; upload on the next launch is the
  expected path but is unverified here.

The helper cannot upload: CloudKit access for Notes needs Notes.app's
private entitlements, and scheduling an upload is in-memory state inside
Notes.app. Responses therefore always report `pushScheduled: false`, with
`pushState: "awaiting_notes_app"` when Notes is running and
`"queued_for_next_launch"` when it is not. `native-note-state` exposes the two
version counters so a caller can see when Notes records the upload.

### Risks

- Any macOS update can rename or remove a class, selector, or model property.
  The probe then reports `private_api_unavailable` with the missing names; a
  changed model without migration makes the store fail to open
  (`store_unavailable`) rather than migrate.
- A write made outside Notes.app may not upload until Notes.app schedules it
  (see above). Verify on another device when sync matters.
- The helper edits the CRDT as its own replica, like a new device would. How
  NotesShared assigns that replica identity in a process with no bundle
  identifier was not inspected; repeated appends may add replica entries to
  the note.

---

## Known Issues & Limitations

### macOS Sequoia/Sonoma (2024)

- Notes.app crashes after OS updates (especially on M1 Macs)
- Sync issues between devices
- Database corruption reported by some users

**Workarounds**:
- Delete `com.apple.Notes.plist` and restart
- Toggle iCloud Notes sync off/on
- Change to gallery view, restart, change back to list view

### AppleScript-Specific Issues

| Issue | Impact | Workaround |
|-------|--------|------------|
| Duplicate titles | Wrong note affected | Use CoreData IDs |
| Special characters | Escaping failures | HTML-encode backslashes |
| Timeout on large operations | Script hangs | Break into smaller batches |
| Attachment positioning unknown | Can't recreate note layout | Accept limitation |
| Password-protected notes | Cannot read | Skip or warn user |

### Note Creation: Body-Only Approach

When creating notes via AppleScript, setting both the `name` property and the `body` causes title duplication — the title appears twice in the rendered note. The fix is to set only the `body`, with the title prepended as an `<h1>` tag. Apple Notes derives the note's display title from the first element in the body HTML. This approach works for both plaintext (converted to HTML) and HTML format content.

### Database Access Issues

- Launch agents cannot access Group Containers even with Full Disk Access
- WAL file may contain uncommitted changes
- Schema changes with each iOS/macOS version (209 columns in iOS 18)

---

## Related Tools & Projects

### Forensic/Parsing Tools

| Tool | Language | Features |
|------|----------|----------|
| [apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser) | Ruby | Full forensic parser, protobuf decoding, iOS 9-18 support |
| [dunhamsteve/notesutils](https://github.com/dunhamsteve/notesutils) | Python | Lightweight export to HTML/Bear format |
| [akx/notorious](https://github.com/akx/notorious) | Python | Database parser |

### Export Tools

| Tool | Language | Features |
|------|----------|----------|
| [storizzi/notes-exporter](https://github.com/storizzi/notes-exporter) | Python | Export to HTML, Markdown, PDF, DOCX |
| [Kylmakalle/apple-notes-exporter](https://github.com/Kylmakalle/apple-notes-exporter) | Python | Shortcuts + Python for HTML/Markdown |

### Other MCP Implementations

| Project | Approach | Notes |
|---------|----------|-------|
| [RafalWilinski/mcp-apple-notes](https://github.com/RafalWilinski/mcp-apple-notes) | RAG/Semantic search | Uses embeddings for search |
| [sirmews/apple-notes-mcp](https://github.com/sirmews/apple-notes-mcp) | Direct SQLite | Requires Full Disk Access |
| [harperreed/notes-mcp](https://github.com/harperreed/notes-mcp) | Go + AppleScript | CLI tool included |

---

## Sources

### Official Documentation
- [AppleScript Language Guide](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/introduction/ASLR_intro.html)
- [ScriptingBridge Documentation](https://developer.apple.com/documentation/scriptingbridge)
- [SBApplication Documentation](https://developer.apple.com/documentation/scriptingbridge/sbapplication)

### Technical Analysis
- [Ciofeca Forensics - Apple Notes Series](https://www.ciofecaforensics.com/2020/01/10/apple-notes-revisited/)
- [Yogesh Khatri - Reading Notes Database](http://www.swiftforensics.com/2018/02/reading-notes-database-on-macos.html)
- [Simon Willison - Notes on Notes.app](https://simonwillison.net/2021/Dec/9/notes-on-notesapp/)
- [dunhamsteve/notesutils - Format Documentation](https://github.com/dunhamsteve/notesutils/blob/master/notes.md)

### Community Resources
- [macosxautomation.com - Notes AppleScript](http://www.macosxautomation.com/applescript/notes/index.html)
- [JXA Cookbook](https://github.com/JXA-Cookbook/JXA-Cookbook)
- [bru6.de - JXA Notes Examples](https://bru6.de/jxa/automating-applications/notes/)

### Issue Discussions
- [Apple Community - AppleScript with Notes.app](https://discussions.apple.com/thread/7390030)
- [Late Night Software - Exporting Notes Attachments](https://forum.latenightsw.com/t/exporting-apple-notes-attachments/766)
- [Clutterstack - Getting Notes Out of Apple Notes](https://clutterstack.com/posts/2024-09-27-applenotes)

### App Intents & Shortcuts Bridge (2026 research)
- Apple Developer - [AppIntent](https://developer.apple.com/documentation/appintents/appintent) and [App Intents overview](https://developer.apple.com/documentation/appintents): `perform()` is system-invoked; no cross-app call path.
- Apple Support - [Run shortcuts from the command line](https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac), cross-checked against the live `shortcuts --help` on macOS 27: `run` takes a named shortcut, not a file path or an intent.
- Shortcuts action catalogs - [matthewcassinelli.com action library](https://matthewcassinelli.com/actions/) and MacStories Shortcuts coverage for the per-action Notes capability list and macOS-version debuts (secondary; feature-detect at runtime).

---

*Last updated: 2026-06-23 (added App Intents bridge feasibility and live-verified read-only SQLite metadata columns)*
