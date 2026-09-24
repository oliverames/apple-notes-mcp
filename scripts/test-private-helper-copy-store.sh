#!/bin/bash
# Exercise the opt-in private WRITER's write paths against a COPY of the Notes
# store. (The read-only helper has no write path; this script builds the
# separate writer, native/private-helper/apple-notes-private-writer.m.)
#
# The live NoteStore.sqlite is only ever opened read-only: once by sqlite3's
# online backup (to make the copy) and by the writer's read-only
# read_note_state before and after the copy writes, to prove the live note did
# not change. Every write runs with APPLE_NOTES_MCP_PRIVATE_STORE pointing at
# the copy; the writer refuses that variable if it resolves to the live store.
# This script never sets APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES, so the writer
# also refuses any read-write open of the live store (checked in step 1b).
#
# Usage: APPLE_NOTES_MCP_ENABLE_PRIVATE=1 scripts/test-private-helper-copy-store.sh [NOTE_UUID]
#   NOTE_UUID  note to write to in the copy. Default: the most recently
#              modified unlocked note with a folder, chosen from the copy.
#   HELPER=/path/to/binary to reuse a built writer instead of compiling.
#
# Prints states and counts only, never note titles or bodies. Needs Full Disk
# Access for the terminal running it. Removes the copy on exit.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$REPO/native/private-helper/apple-notes-private-writer.m"
LIVE="$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/private-writer-copy.XXXXXX")"
chmod 700 "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
field() { printf '%s' "$1" | /usr/bin/plutil -extract "$2" raw -o - - 2>/dev/null || true; }

[ -r "$LIVE" ] || fail "cannot read the live store (grant Full Disk Access to this terminal)"
[ "${APPLE_NOTES_MCP_ENABLE_PRIVATE:-}" = "1" ] ||
  fail "set APPLE_NOTES_MCP_ENABLE_PRIVATE=1 so the live note can be compared (reads only)"

if [ -z "${HELPER:-}" ]; then
  HELPER="$WORK/apple-notes-private-writer"
  SHA="$(/usr/bin/shasum -a 256 "$SOURCE" | cut -d' ' -f1)"
  /usr/bin/xcrun clang -fobjc-arc -O2 -Wall -framework Foundation -framework CoreData \
    -framework AppKit "-DHELPER_SOURCE_SHA256=\"$SHA\"" -o "$HELPER" "$SOURCE"
  echo "built writer from source sha256 $SHA"
fi

COPY="$WORK/NoteStore.sqlite"
/usr/bin/sqlite3 -readonly "$LIVE" ".backup '$COPY'"
echo "copied store: $(/usr/bin/stat -f %z "$COPY") bytes"

# The write switch is always cleared, so the live store can only be opened
# read-only; copy writes do not need it.
run() { printf '%s' "$1" | env -u APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES "$HELPER" 2>/dev/null; }
copy_run() {
  printf '%s' "$1" | env -u APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES \
    APPLE_NOTES_MCP_PRIVATE_STORE="$COPY" "$HELPER" 2>/dev/null
}
read_request() { printf '{"protocol":1,"action":"read_note_state","identifier":"%s"}' "$1"; }
ZERO="r1:$(printf '0%.0s' $(seq 1 64))"

NOTE="${1:-}"
if [ -z "$NOTE" ]; then
  # First recent candidate the writer itself reports as writable.
  for CANDIDATE in $(/usr/bin/sqlite3 "$COPY" "SELECT n.ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT n
    JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
    WHERE n.ZIDENTIFIER IS NOT NULL AND n.ZFOLDER IS NOT NULL
      AND IFNULL(n.ZISPASSWORDPROTECTED,0)=0 AND IFNULL(n.ZMARKEDFORDELETION,0)=0
    ORDER BY n.ZMODIFICATIONDATE1 DESC LIMIT 25;"); do
    STATE="$(copy_run "$(read_request "$CANDIDATE")" || true)"
    if [ "$(field "$STATE" editable)" = "true" ] && [ "$(field "$STATE" sharedViaICloud)" = "false" ] &&
      [ "$(field "$STATE" deletedOrInTrash)" = "false" ]; then
      NOTE="$CANDIDATE"
      break
    fi
  done
fi
[ -n "$NOTE" ] || fail "no writable candidate note found in the copy"

READ="$(read_request "$NOTE")"
LIVE_BEFORE="$(field "$(run "$READ")" revision)"
[ -n "$LIVE_BEFORE" ] || fail "could not read the live note state"

# 1. The writer must refuse to treat the live store as a copy.
REFUSED="$(printf '%s' "$READ" | APPLE_NOTES_MCP_PRIVATE_STORE="$LIVE" "$HELPER" || true)"
[ "$(field "$REFUSED" code)" = "invalid_request" ] || fail "live store accepted as a copy"
echo "ok: live store refused as a copy"

# 1b. Without the write switch the writer refuses a read-write open of the
# live store. The request also carries a zero revision, so even a broken
# switch could only end in revision_conflict, never in a write.
GATED="$(run "{\"protocol\":1,\"action\":\"append_plain_text\",\"identifier\":\"$NOTE\",\"text\":\"x\",\"ifRevision\":\"$ZERO\"}" || true)"
[ "$(field "$GATED" code)" = "writes_disabled" ] || fail "live read-write open not gated: $(field "$GATED" code)"
[ "$(field "$GATED" committed)" = "false" ] || fail "gated write did not report committed=false"
echo "ok: live read-write open refused without APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES"

# 2. Stale revision is refused with nothing committed.
STALE="{\"protocol\":1,\"action\":\"append_plain_text\",\"identifier\":\"$NOTE\",\"text\":\"x\",\"ifRevision\":\"$ZERO\"}"
OUT="$(copy_run "$STALE" || true)"
[ "$(field "$OUT" code)" = "revision_conflict" ] || fail "stale revision not refused: $(field "$OUT" code)"
[ "$(field "$OUT" committed)" = "false" ] || fail "stale revision reported committed"
echo "ok: stale ifRevision refused, committed=false"

# 3. Guarded append on the copy, verified by the writer's fresh read-back.
BEFORE="$(copy_run "$READ")"
REV="$(field "$BEFORE" revision)"
LEN_BEFORE="$(field "$BEFORE" bodyLengthUTF16)"
[ -n "$REV" ] || fail "no revision from read_note_state: $(field "$BEFORE" code)"
TEXT="copy-store append $(date +%s)"
APPEND="{\"protocol\":1,\"action\":\"append_plain_text\",\"identifier\":\"$NOTE\",\"text\":\"$TEXT\",\"ifRevision\":\"$REV\"}"
OUT="$(copy_run "$APPEND" || true)"
[ "$(field "$OUT" status)" = "updated" ] || fail "append failed: $(field "$OUT" code) $(field "$OUT" message)"
[ "$(field "$OUT" verified)" = "true" ] || fail "append not verified"
[ "$(field "$OUT" storeKind)" = "copy" ] || fail "append did not report the copy store"
echo "ok: append committed and verified on the copy (pushState $(field "$OUT" pushState))"

AFTER="$(copy_run "$READ")"
LEN_AFTER="$(field "$AFTER" bodyLengthUTF16)"
[ "$(field "$AFTER" revision)" != "$REV" ] || fail "revision did not change"
echo "ok: body length $LEN_BEFORE -> $LEN_AFTER UTF-16 units; revision changed"
echo "copy cloud state: current=$(field "$AFTER" cloudSync.currentLocalVersion) synced=$(field "$AFTER" cloudSync.latestVersionSyncedToCloud) uploadPending=$(field "$AFTER" cloudSync.uploadPending)"

# 3b. read_sync_state (the sync nudge's read) sees the same pending upload.
SYNC="$(copy_run "{\"protocol\":1,\"action\":\"read_sync_state\",\"identifiers\":[\"$NOTE\"]}" || true)"
[ "$(field "$SYNC" objects.0.uploadPending)" = "true" ] || fail "read_sync_state did not report the pending upload"
[ "$(field "$SYNC" objects.0.revision)" = "$(field "$AFTER" revision)" ] || fail "read_sync_state revision differs from read_note_state"
[ "$(field "$SYNC" objects.0.kind)" = "note" ] || fail "read_sync_state did not classify the note"
echo "ok: read_sync_state reports the pending upload (library backlog $(field "$SYNC" pendingUploadCount))"

# 4. The replayed request is now stale.
OUT="$(copy_run "$APPEND" || true)"
[ "$(field "$OUT" code)" = "revision_conflict" ] || fail "replayed append not refused"
echo "ok: replayed append refused"

# Feature write checks go here, each against the copy only.

# 4b. Structured compose: plan, guarded apply with verified read-back, replay,
#     prepend below the title, and insertion before an exact heading.
PARAS='[{"style":"heading","runs":[{"text":"Compose check"}]},
{"style":"body","runs":[{"text":"b","bold":true},{"text":"i","italic":true},{"text":"u","underline":true},{"text":"s","strikethrough":true},{"text":"l","link":"https://example.com/"},{"text":"h","highlight":"mint"},{"text":"c","color":"#FF0000"}]},
{"style":"body","blockQuote":true,"runs":[{"text":"quote"}]},
{"style":"monospaced","runs":[{"text":"code"}]},{"style":"monospaced","runs":[]},{"style":"monospaced","runs":[{"text":"\tmore"}]},
{"style":"bulleted","runs":[{"text":"b1"}]},{"style":"bulleted","indent":1,"runs":[{"text":"b1.1"}]},
{"style":"dashed","runs":[{"text":"d"}]},{"style":"numbered","runs":[{"text":"n"}]},
{"style":"checklist","checked":true,"runs":[{"text":"done"}]},{"style":"checklist","checked":false,"indent":1,"runs":[{"text":"open"}]},
{"style":"subheading","runs":[{"text":"end"}]}]'
compose_req() { # mode, extra JSON fields (leading comma)
  printf '{"protocol":1,"action":"compose_note","identifier":"%s","mode":"%s","paragraphs":%s%s}' \
    "$NOTE" "$1" "$PARAS" "$2"
}
GATED="$(run "$(compose_req append ",\"ifRevision\":\"$ZERO\"")" || true)"
[ "$(field "$GATED" code)" = "writes_disabled" ] && [ "$(field "$GATED" committed)" = "false" ] ||
  fail "live compose not gated: $(field "$GATED" code)"
echo "ok: live compose refused without APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES"
PLAN="$(copy_run "$(compose_req append ',"dryRun":true')" || true)"
[ "$(field "$PLAN" status)" = "planned" ] || fail "compose plan failed: $(field "$PLAN" code) $(field "$PLAN" message)"
[ "$(field "$PLAN" committed)" = "false" ] || fail "compose plan reported committed"
CREV="$(field "$PLAN" revisionBefore)"
[ "$CREV" = "$(field "$(copy_run "$READ")" revision)" ] || fail "plan revision differs from note state"
echo "ok: compose dry run planned $(field "$PLAN" paragraphs) paragraphs, nothing written"
OUT="$(copy_run "$(compose_req append ",\"ifRevision\":\"$ZERO\"")" || true)"
[ "$(field "$OUT" code)" = "revision_conflict" ] && [ "$(field "$OUT" committed)" = "false" ] ||
  fail "stale compose revision not refused"
OUT="$(copy_run "$(compose_req append ",\"ifRevision\":\"$CREV\"")" || true)"
[ "$(field "$OUT" status)" = "updated" ] || fail "compose failed: $(field "$OUT" code) $(field "$OUT" message)"
[ "$(field "$OUT" verified)" = "true" ] || fail "compose not verified"
[ "$(field "$OUT" storeKind)" = "copy" ] || fail "compose did not report the copy store"
[ "$(field "$OUT" readBack)" = "13" ] || fail "compose read back $(field "$OUT" readBack) paragraphs, expected 13"
[ "$(field "$OUT" readBack.10.checked)" = "true" ] && [ "$(field "$OUT" readBack.11.checked)" = "false" ] ||
  fail "checklist state did not persist"
[ "$(field "$OUT" readBack.1.runs.6.attributes.color)" = "#FF0000" ] || fail "run color did not persist"
[ "$(field "$OUT" unitStart)" = "$(field "$PLAN" unitStart)" ] || fail "unitStart differs between plan and apply"
[ -n "$(field "$OUT" objectURI)" ] || fail "compose did not report objectURI"
[ "$(field "$OUT" pushScheduled)" = "false" ] || fail "compose reported a scheduled push"
echo "ok: compose applied; 13 paragraphs verified (styles, indent, quote, checklist state, runs); unitStart $(field "$OUT" unitStart)"
OUT="$(copy_run "$(compose_req append ",\"ifRevision\":\"$CREV\"")" || true)"
[ "$(field "$OUT" code)" = "revision_conflict" ] && [ "$(field "$OUT" committed)" = "false" ] ||
  fail "replayed compose not refused"
echo "ok: stale and replayed compose refused, committed=false"
PREV="$(field "$(copy_run "$READ")" revision)"
OUT="$(copy_run "$(compose_req prepend ",\"ifRevision\":\"$PREV\"")" || true)"
[ "$(field "$OUT" verified)" = "true" ] || fail "prepend failed: $(field "$OUT" code) $(field "$OUT" message)"
echo "ok: prepend verified at UTF-16 offset $(field "$OUT" insertAt) (below the title line)"
ANCHOR=',"insertBeforeHeading":{"text":"Compose check","occurrence":2,"expectedCount":2}'
HREV="$(field "$(copy_run "$READ")" revision)"
OUT="$(copy_run "$(compose_req append "$ANCHOR,\"ifRevision\":\"$HREV\"")" || true)"
[ "$(field "$OUT" placementVerified)" = "true" ] || fail "insert before heading failed: $(field "$OUT" code) $(field "$OUT" message)"
OUT="$(copy_run "$(compose_req append "$ANCHOR,\"dryRun\":true")" || true)"
[ "$(field "$OUT" code)" = "selector_conflict" ] && [ "$(field "$OUT" committed)" = "false" ] ||
  fail "stale heading count not refused"
echo "ok: insert before heading verified; a stale expectedCount is refused"
OBJECTS='[{"style":"body","runs":[{"text":"objects"}]},{"kind":"divider"},
{"kind":"table","rows":[["A","B"],["1",""]]},{"kind":"divider"},
{"style":"body","runs":[{"text":"link","link":"notes://showNote?identifier='"$NOTE"'"}]}]'
OREQ="$(printf '{"protocol":1,"action":"compose_note","identifier":"%s","mode":"append","paragraphs":%s' "$NOTE" "$OBJECTS")"
OUT="$(copy_run "$OREQ,\"dryRun\":true}" || true)"
[ "$(field "$OUT" status)" = "planned" ] || fail "object plan failed: $(field "$OUT" code) $(field "$OUT" message)"
OBJ_BEFORE="$(/usr/bin/sqlite3 "$COPY" "SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTYPEUTI IN ('com.apple.notes.table','com.apple.notes.inlinetextattachment.dividerline') OR ZTYPEUTI1 IN ('com.apple.notes.table','com.apple.notes.inlinetextattachment.dividerline');" 2>/dev/null || echo "?")"
OREV="$(field "$(copy_run "$READ")" revision)"
OUT="$(copy_run "$OREQ,\"ifRevision\":\"$OREV\"}" || true)"
[ "$(field "$OUT" verified)" = "true" ] || fail "object compose failed: $(field "$OUT" code) $(field "$OUT" message)"
[ "$(field "$OUT" objects)" = "3" ] || fail "expected 3 created objects, got $(field "$OUT" objects)"
[ "$(field "$OUT" objects.1.uti)" = "com.apple.notes.table" ] || fail "table object has UTI $(field "$OUT" objects.1.uti)"
OBJ_AFTER="$(/usr/bin/sqlite3 "$COPY" "SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTYPEUTI IN ('com.apple.notes.table','com.apple.notes.inlinetextattachment.dividerline') OR ZTYPEUTI1 IN ('com.apple.notes.table','com.apple.notes.inlinetextattachment.dividerline');" 2>/dev/null || echo "?")"
echo "ok: 2 dividers and a table created, placed, and verified cell by cell (divider UTI $(field "$OUT" objects.0.uti); object rows $OBJ_BEFORE -> $OBJ_AFTER)"
OUT="$(copy_run "$OREQ,\"ifRevision\":\"$OREV\"}" || true)"
[ "$(field "$OUT" code)" = "revision_conflict" ] && [ "$(field "$OUT" committed)" = "false" ] ||
  fail "replayed object compose not refused"
echo "ok: replayed object compose refused, committed=false"
QUICK="$(/usr/bin/sqlite3 "$COPY" "SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE ZISSYSTEMPAPER=1
  AND IFNULL(ZMARKEDFORDELETION,0)=0 AND ZFOLDER IS NOT NULL LIMIT 1;" 2>/dev/null || true)"
if [ -n "$QUICK" ]; then
  OUT="$(copy_run "$(compose_req append ',"dryRun":true,"requireNonSystemPaper":true' | sed "s/$NOTE/$QUICK/")" || true)"
  [ "$(field "$OUT" code)" = "unsupported_note" ] || fail "Quick Note not refused: $(field "$OUT" code)"
  echo "ok: requireNonSystemPaper refuses a Quick Note"
else
  echo "note: no Quick Note in this store; requireNonSystemPaper refusal not exercised"
fi

# 5. The live note is untouched.
LIVE_AFTER="$(field "$(run "$READ")" revision)"
[ "$LIVE_BEFORE" = "$LIVE_AFTER" ] || fail "live note revision changed during the copy test"
echo "ok: live note revision unchanged"
echo "PASS"
