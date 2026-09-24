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
#   EDIT_NOTES="UUID ..." notes for the plan_edit / edit_note round trip.
#              Default: up to EDIT_SAMPLE (5) recent editable notes that own
#              attachments, plus up to 3 without. Notes with an attachment in
#              the body also run the attachment selector steps (4c).
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
json_field() { printf '%s' "$1" | /usr/bin/plutil -extract "$2" json -o - - 2>/dev/null || true; }

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

# 4b. plan_edit / edit_note on the copy, checked by an independent decoder
# (scripts/check-edit-preservation.mjs decodes the stored protobuf itself, with
# no writer and no NotesShared). Each note gets a content-free round trip:
# insert styled blocks after the first body paragraph, restyle one of them,
# then delete them all. Every step must keep each character outside the edited
# ranges on its exact serialized attribute run and leave attachment rows and
# every other row byte-identical; the last step must restore the note exactly.
# Every plan must leave the store unchanged.
CHECK="$REPO/scripts/check-edit-preservation.mjs"
edit_request() { # action identifier ifRevision(or empty) operations-json
  if [ -n "$3" ]; then
    printf '{"protocol":1,"action":"%s","identifier":"%s","ifRevision":"%s","operations":%s}' \
      "$1" "$2" "$3" "$4"
  else
    printf '{"protocol":1,"action":"%s","identifier":"%s","operations":%s}' "$1" "$2" "$4"
  fi
}
snap() { node "$CHECK" snapshot "$COPY" "$1" "$WORK/$2.json" >/dev/null; }
edit_step() { # uuid label operations-json
  snap "$1" before
  PLAN="$(copy_run "$(edit_request plan_edit "$1" "" "$3")" || true)"
  [ "$(field "$PLAN" status)" = "planned" ] || fail "$2 plan: $(field "$PLAN" code) $(field "$PLAN" message)"
  snap "$1" planned
  node "$CHECK" same "$WORK/before.json" "$WORK/planned.json" >/dev/null || fail "$2: plan_edit changed the store"
  OUT="$(copy_run "$(edit_request edit_note "$1" "$(field "$PLAN" revisionBefore)" "$3")" || true)"
  [ "$(field "$OUT" status)" = "updated" ] || fail "$2 apply: $(field "$OUT" code) $(field "$OUT" message)"
  [ "$(field "$OUT" verified)" = "true" ] || fail "$2 apply not verified"
  [ "$(field "$OUT" preservation.formattingOutsideEditsVerified)" = "true" ] || fail "$2: no preservation report"
  [ "$(field "$OUT" planDigest)" = "$(field "$PLAN" planDigest)" ] || fail "$2: apply planned differently"
  printf '%s' "$OUT" >"$WORK/response.json"
  snap "$1" after
  node "$CHECK" compare "$WORK/before.json" "$WORK/after.json" "$WORK/response.json" ||
    fail "$2: independent preservation check failed"
  echo "ok: $2 ($(field "$OUT" targetCount) targets, $(field "$OUT" preservation.unchangedUTF16) units kept, $(field "$OUT" preservation.attachmentGlyphs) glyphs; writer verified; independent check passed)"
}

EDIT_NOTES="${EDIT_NOTES:-}"
if [ -z "$EDIT_NOTES" ]; then
  editable() {
    local state
    state="$(copy_run "$(read_request "$1")" || true)"
    [ "$(field "$state" editable)" = "true" ] && [ "$(field "$state" sharedViaICloud)" = "false" ] &&
      [ "$(field "$state" deletedOrInTrash)" = "false" ] && [ "$(field "$state" passwordProtected)" = "false" ]
  }
  pick() { # "" or "NOT" (owns attachments or not), how many
    local found=0 candidate
    for candidate in $(/usr/bin/sqlite3 -readonly "$COPY" "SELECT n.ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT n
      JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
      WHERE n.ZIDENTIFIER IS NOT NULL AND n.ZFOLDER IS NOT NULL
        AND IFNULL(n.ZISPASSWORDPROTECTED,0)=0 AND IFNULL(n.ZMARKEDFORDELETION,0)=0
        AND $1 EXISTS (SELECT 1 FROM ZICCLOUDSYNCINGOBJECT a WHERE a.ZNOTE = n.Z_PK)
      ORDER BY n.ZMODIFICATIONDATE1 DESC LIMIT 60;"); do
      [ "$found" -lt "$2" ] || break
      if editable "$candidate"; then
        EDIT_NOTES="$EDIT_NOTES $candidate"
        found=$((found + 1))
      fi
    done
  }
  pick "" "${EDIT_SAMPLE:-5}"
  pick "NOT" 3
fi
[ -n "$EDIT_NOTES" ] || fail "no editable candidate notes for edit_note"

MARK_OPS='[{"op":"insert_after","anchor":{"kind":"style","style":"body","occurrence":1},"expectedCount":COUNT,"blocks":[{"type":"heading","text":"copy-store edit marker"},{"type":"checklist","text":"copy-store checklist","checked":true},{"type":"body","runs":[{"text":"copy-store "},{"text":"bold","bold":true}]}]}]'
RESTYLE_OPS='[{"op":"replace","selector":{"kind":"text","text":"copy-store edit marker","match":"equals"},"replacement":{"runs":[{"text":"copy-store edit marker 2","italic":true}]}}]'
DELETE_OPS='[{"op":"delete_paragraph","selector":{"kind":"text","text":"copy-store edit marker 2"}},{"op":"delete_paragraph","selector":{"kind":"text","text":"copy-store checklist"}},{"op":"delete_paragraph","selector":{"kind":"text","text":"copy-store bold"}}]'
CAPTION_OPS='[{"op":"replace","selector":{"kind":"attachment","ordinal":1,"position":"after"},"replacement":{"text":" copy-store attachment caption"}}]'
UNCAPTION_OPS='[{"op":"replace","selector":{"kind":"text","text":" copy-store attachment caption","scope":"all"},"replacement":{"text":""}}]'
ATTACHMENT_ANCHOR_OPS='[{"op":"insert_after","anchor":{"kind":"attachment","ordinal":1},"blocks":[{"type":"body","text":"copy-store attachment anchor"}]}]'
ATTACHMENT_ANCHOR_UNDO_OPS='[{"op":"delete_paragraph","selector":{"kind":"text","text":"copy-store attachment anchor"}}]'
REMOVE_ATTACHMENT_OPS='[{"op":"replace","selector":{"kind":"attachment","ordinal":1},"replacement":{"text":""}}]'
ATTACHMENT_EDITED=0
TRIM_MARK_OPS='[{"op":"insert_after","anchor":{"kind":"style","style":"body","occurrence":1},"expectedCount":COUNT,"blocks":[{"type":"body","text":"copy-store trim start"},{"type":"body","text":""},{"type":"body","text":" "},{"type":"body","text":""},{"type":"body","text":"copy-store trim end"}]}]'
TRIM_AROUND_OPS='[{"op":"trim_blank_lines","mode":"around","anchor":{"kind":"text","text":"copy-store trim start"},"side":"after","expectedCount":3}]'
TRIM_UNMARK_OPS='[{"op":"delete_paragraph","selector":{"kind":"text","text":"copy-store trim start"}},{"op":"delete_paragraph","selector":{"kind":"text","text":"copy-store trim end"}}]'
TRIM_RUNS_OPS='[{"op":"trim_blank_lines","mode":"runs"}]'
TRIMMED=0
EDITED=0
REFUSED_NOTES=0
EDIT_LIVE_BEFORE=""
for EDIT_NOTE in $EDIT_NOTES; do
  EDIT_LIVE_BEFORE="$EDIT_LIVE_BEFORE $EDIT_NOTE=$(field "$(run "$(read_request "$EDIT_NOTE")")" revision)"
  # Guard rails: the live store is gated, a missing ifRevision is refused, a
  # stale one is a conflict, and none of them commit.
  OUT="$(run "$(edit_request edit_note "$EDIT_NOTE" "$ZERO" "$RESTYLE_OPS")" || true)"
  [ "$(field "$OUT" code)" = "writes_disabled" ] || fail "live edit_note not gated: $(field "$OUT" code)"
  OUT="$(copy_run "$(edit_request edit_note "$EDIT_NOTE" "" "$RESTYLE_OPS")" || true)"
  [ "$(field "$OUT" code)" = "invalid_request" ] || fail "edit_note without ifRevision was not refused"
  OUT="$(copy_run "$(edit_request edit_note "$EDIT_NOTE" "$ZERO" "$RESTYLE_OPS")" || true)"
  if [ "$(field "$OUT" code)" != "revision_conflict" ] || [ "$(field "$OUT" committed)" != "false" ]; then
    fail "stale edit ifRevision not refused: $(field "$OUT" code)"
  fi
  # How many body paragraphs the style anchor sees (a count mismatch reports it).
  PROBE="$(copy_run "$(edit_request plan_edit "$EDIT_NOTE" "" "${MARK_OPS/COUNT/1000}")" || true)"
  COUNT="$(field "$PROBE" matchedCount)"
  [ "$(field "$PROBE" status)" = "planned" ] && COUNT=1000
  if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then
    echo "skip: a candidate has no body paragraph to anchor on ($(field "$PROBE" code))"
    continue
  fi
  # A note whose edit would dirty another object (for example Notes
  # re-deriving the title from an attachment) must be refused at the plan.
  PROBE="$(copy_run "$(edit_request plan_edit "$EDIT_NOTE" "" "${MARK_OPS/COUNT/$COUNT}")" || true)"
  if [ "$(field "$PROBE" code)" = "unexpected_side_effect" ]; then
    REFUSED_NOTES=$((REFUSED_NOTES + 1))
    echo "ok: plan refused a note whose edit would change another object"
    continue
  fi
  snap "$EDIT_NOTE" original
  edit_step "$EDIT_NOTE" "insert blocks" "${MARK_OPS/COUNT/$COUNT}"
  edit_step "$EDIT_NOTE" "restyle inserted text" "$RESTYLE_OPS"
  edit_step "$EDIT_NOTE" "delete inserted paragraphs" "$DELETE_OPS"
  snap "$EDIT_NOTE" final
  node "$CHECK" same "$WORK/original.json" "$WORK/final.json" >/dev/null ||
    fail "the round trip did not restore the original text and runs"
  EDITED=$((EDITED + 1))

  # 4c. trim_blank_lines: insert a marker, three empty body paragraphs (one
  # holding a space), and a second marker; trim the blank run after
  # the first marker (exactly 3 removed); delete the markers. The note must
  # be restored exactly. Then trim the note's own runs of blank lines on the
  # copy (not undoable, so it runs last); the plan must list each removed
  # paragraph, and the independent check proves nothing else changed.
  snap "$EDIT_NOTE" original
  edit_step "$EDIT_NOTE" "insert blank lines between markers" "${TRIM_MARK_OPS/COUNT/$COUNT}"
  edit_step "$EDIT_NOTE" "trim the blank lines after a marker" "$TRIM_AROUND_OPS"
  [ "$(field "$OUT" operations.0.matchedCount)" = "3" ] || fail "trim around removed $(field "$OUT" operations.0.matchedCount), not 3"
  [ "$(field "$OUT" operations.0.targets.1.blankUTF16)" = "1" ] || fail "trim did not report the whitespace paragraph"
  edit_step "$EDIT_NOTE" "delete the trim markers" "$TRIM_UNMARK_OPS"
  snap "$EDIT_NOTE" final
  node "$CHECK" same "$WORK/original.json" "$WORK/final.json" >/dev/null ||
    fail "the trim round trip did not restore the original text and runs"
  PLAN="$(copy_run "$(edit_request plan_edit "$EDIT_NOTE" "" "$TRIM_RUNS_OPS")" || true)"
  [ "$(field "$PLAN" status)" = "planned" ] || fail "trim runs plan: $(field "$PLAN" code) $(field "$PLAN" message)"
  if [ "$(field "$PLAN" targetCount)" != "0" ]; then
    edit_step "$EDIT_NOTE" "trim the note's own blank runs" "$TRIM_RUNS_OPS"
    [ "$(field "$OUT" targetCount)" = "$(field "$PLAN" targetCount)" ] || fail "trim runs removed a different number than planned"
  else
    echo "ok: no redundant blank lines to trim in this note"
  fi
  TRIMMED=$((TRIMMED + 1))

  # 4d. Attachment selectors on notes whose body holds an attachment: add a
  # caption inline after the first attachment and remove it, insert and
  # delete a paragraph anchored on it (both must restore the note exactly),
  # then remove the attachment from the body. The removal cannot be undone,
  # so it runs last, on the copy only; the independent check proves every
  # other attachment row and every other row unchanged.
  PROBE="$(copy_run "$(edit_request plan_edit "$EDIT_NOTE" "" "$CAPTION_OPS")" || true)"
  if [ "$(field "$PROBE" code)" = "match_count_mismatch" ]; then
    continue
  elif [ "$(field "$PROBE" code)" = "unexpected_side_effect" ]; then
    echo "ok: plan refused an attachment edit that would change another object"
    continue
  fi
  [ "$(field "$PROBE" status)" = "planned" ] || fail "attachment plan: $(field "$PROBE" code) $(field "$PROBE" message)"
  snap "$EDIT_NOTE" original
  edit_step "$EDIT_NOTE" "caption beside an attachment" "$CAPTION_OPS"
  edit_step "$EDIT_NOTE" "remove the caption" "$UNCAPTION_OPS"
  edit_step "$EDIT_NOTE" "insert after an attachment's paragraph" "$ATTACHMENT_ANCHOR_OPS"
  edit_step "$EDIT_NOTE" "delete the inserted paragraph" "$ATTACHMENT_ANCHOR_UNDO_OPS"
  snap "$EDIT_NOTE" final
  node "$CHECK" same "$WORK/original.json" "$WORK/final.json" >/dev/null ||
    fail "the attachment round trip did not restore the original text and runs"
  edit_step "$EDIT_NOTE" "remove an attachment from the body" "$REMOVE_ATTACHMENT_OPS"
  [ "$(field "$OUT" removedAttachments.0)" != "" ] || fail "attachment removal reported no removed attachment"
  [ "$(field "$OUT" preservation.removedAttachments.0.identifier)" = "$(field "$OUT" removedAttachments.0)" ] ||
    fail "attachment removal did not report the removed row's state"
  echo "   removed attachment row: stillInNote=$(field "$OUT" preservation.removedAttachments.0.rowStillInNote) markedForDeletion=$(field "$OUT" preservation.removedAttachments.0.markedForDeletion) changedBeforeSave=$(json_field "$OUT" removedAttachmentRowChanges)"
  ATTACHMENT_EDITED=$((ATTACHMENT_EDITED + 1))
done
[ "$EDITED" -gt 0 ] || fail "the edit_note round trip ran on no note"
echo "ok: edit_note round trip restored $EDITED note(s) exactly; $REFUSED_NOTES refused at plan"
[ "$ATTACHMENT_EDITED" -gt 0 ] || fail "the attachment selector steps ran on no note (EDIT_NOTES needs a note with an attachment in its body)"
echo "ok: attachment selector steps passed on $ATTACHMENT_EDITED note(s)"
echo "ok: trim_blank_lines steps passed on $TRIMMED note(s)"

# 5. The live notes are untouched.
LIVE_AFTER="$(field "$(run "$READ")" revision)"
[ "$LIVE_BEFORE" = "$LIVE_AFTER" ] || fail "live note revision changed during the copy test (a concurrent edit in Notes also causes this; rerun)"
for PAIR in $EDIT_LIVE_BEFORE; do
  [ "$(field "$(run "$(read_request "${PAIR%%=*}")")" revision)" = "${PAIR#*=}" ] ||
    fail "a live edit-note revision changed during the copy test (a concurrent edit in Notes also causes this; rerun)"
done
echo "ok: live note revisions unchanged"
echo "PASS"
