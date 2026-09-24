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

# 6. Smart folders on the copy: create inside an ordinary folder, idempotent
#    retry, title conflict, a smart folder refused as a parent, an
#    unrepresentable query refused, guarded update, then dry-run and guarded
#    delete. The live smart-folder rows are fingerprinted read-only before and
#    after.
live_smart_rows() {
  /usr/bin/sqlite3 -readonly "$LIVE" "SELECT ZIDENTIFIER, ZTITLE2, ZSMARTFOLDERQUERYJSON,
    ZMARKEDFORDELETION FROM ZICCLOUDSYNCINGOBJECT WHERE ZFOLDERTYPE = 2 ORDER BY ZIDENTIFIER;" |
    /usr/bin/shasum -a 256
}
smart_create() { # title queryJSON [extra fields]
  printf '{"protocol":1,"action":"create_smart_folder","title":"%s","queryJSON":"%s"%s}' "$1" "$2" "${3:-}"
}
smart_read() { printf '{"protocol":1,"action":"read_smart_folder","identifier":"%s"}' "$1"; }
smart_update() { # identifier queryJSON ifRevision
  printf '{"protocol":1,"action":"update_smart_folder","identifier":"%s","queryJSON":"%s","ifRevision":"%s"}' "$1" "$2" "$3"
}
smart_delete() { # identifier dryRun [ifRevision]
  if [ "$2" = "true" ]; then
    printf '{"protocol":1,"action":"delete_smart_folder","identifier":"%s","dryRun":true}' "$1"
  else
    printf '{"protocol":1,"action":"delete_smart_folder","identifier":"%s","dryRun":false,"ifRevision":"%s"}' "$1" "$3"
  fi
}
ZERO_FOLDER="f1:${ZERO#r1:}"

smart_folder_checks() {
  local LIVE_SMART_BEFORE PARENT TITLE Q1 Q2 QNOT OUT SMART REVF REVU
  LIVE_SMART_BEFORE="$(live_smart_rows)"
  PARENT="$(/usr/bin/sqlite3 "$COPY" "SELECT f.ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT f
    WHERE f.ZIDENTIFIER IS NOT NULL AND f.ZTITLE2 IS NOT NULL AND IFNULL(f.ZFOLDERTYPE,0)=0
      AND IFNULL(f.ZMARKEDFORDELETION,0)=0 AND f.ZIDENTIFIER NOT LIKE 'TrashFolder%'
      AND f.ZIDENTIFIER NOT LIKE 'DefaultFolder%' AND f.ZOWNER IS NOT NULL AND f.ZSERVERSHAREDATA IS NULL
    ORDER BY f.Z_PK DESC LIMIT 1;" 2>/dev/null || true)"
  if [ -z "$PARENT" ]; then
    echo "skip: no ordinary folder in the copy for the smart-folder test"
    return 0
  fi
  TITLE="copy-store smart folder $(date +%s)"
  Q1='{\"entity\":\"note\",\"type\":{\"checklist\":true}}'
  Q2='{\"entity\":\"note\",\"type\":{\"or\":[{\"pinned\":true},{\"attachment\":true}]}}'
  QNOT='{\"entity\":\"note\",\"type\":{\"not\":{\"pinned\":true}}}'

  # Without the write switch a create against the live store is refused
  # before any read-write open.
  OUT="$(run "$(smart_create "$TITLE" "$Q1" ",\"parentIdentifier\":\"$PARENT\"")" || true)"
  [ "$(field "$OUT" code)" = "writes_disabled" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "live smart-folder create not gated: $(field "$OUT" code)"
  echo "ok: live smart-folder create refused without APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES"

  OUT="$(copy_run "$(smart_create "$TITLE" "$Q1" ",\"parentIdentifier\":\"$PARENT\"")" || true)"
  [ "$(field "$OUT" status)" = "created" ] && [ "$(field "$OUT" verified)" = "true" ] ||
    fail "smart folder create: $(field "$OUT" code) $(field "$OUT" message)"
  [ "$(field "$OUT" folderType)" = "2" ] || fail "created folder is not a smart folder"
  [ "$(field "$OUT" parentDurability)" = "stamped" ] || fail "parent timestamp not stamped"
  [ "$(field "$OUT" titleDurability)" = "stamped" ] || fail "title timestamp not stamped"
  [ "$(field "$OUT" storeKind)" = "copy" ] || fail "create did not report the copy store"
  [ "$(field "$OUT" pushScheduled)" = "false" ] || fail "create claimed a push"
  SMART="$(field "$OUT" identifier)"
  echo "ok: smart folder created and verified on the copy (filters $(field "$OUT" filterCount), uploadPending $(field "$OUT" cloudSync.uploadPending))"
  OUT="$(copy_run "$(smart_create "$TITLE" "$Q1" ",\"parentIdentifier\":\"$PARENT\"")" || true)"
  [ "$(field "$OUT" status)" = "ok" ] && [ "$(field "$OUT" changed)" = "false" ] &&
    [ "$(field "$OUT" committed)" = "false" ] || fail "idempotent retry changed something"
  echo "ok: identical retry is a no-op"
  OUT="$(copy_run "$(smart_create "$TITLE" "$Q2" ",\"parentIdentifier\":\"$PARENT\"")" || true)"
  [ "$(field "$OUT" code)" = "folder_exists" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "different query under the same title not refused: $(field "$OUT" code)"
  echo "ok: a different query under the same title is refused, committed=false"
  OUT="$(copy_run "$(smart_create "$TITLE x" "$Q1" ",\"parentIdentifier\":\"$SMART\"")" || true)"
  [ "$(field "$OUT" code)" = "unsupported_folder" ] && [ "$(field "$OUT" reason)" = "smart_folder_destination" ] &&
    [ "$(field "$OUT" committed)" = "false" ] || fail "smart folder accepted as a parent: $(field "$OUT" code)"
  echo "ok: a smart folder is refused as a parent (smart_folder_destination), committed=false"
  OUT="$(copy_run "$(smart_create "$TITLE y" "$QNOT" ",\"parentIdentifier\":\"$PARENT\"")" || true)"
  [ "$(field "$OUT" code)" = "query_not_representable" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "unrepresentable query not refused: $(field "$OUT" code)"
  echo "ok: a query Notes would change is refused, committed=false"

  REVF="$(field "$(copy_run "$(smart_read "$SMART")")" revision)"
  [ -n "$REVF" ] || fail "read_smart_folder returned no revision"
  OUT="$(copy_run "$(smart_update "$SMART" "$Q2" "$ZERO_FOLDER")" || true)"
  [ "$(field "$OUT" code)" = "revision_conflict" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "stale update revision not refused: $(field "$OUT" code)"
  OUT="$(copy_run "$(smart_update "$SMART" "$Q2" "$REVF")" || true)"
  [ "$(field "$OUT" status)" = "updated" ] && [ "$(field "$OUT" verified)" = "true" ] ||
    fail "guarded update failed: $(field "$OUT" code) $(field "$OUT" message)"
  REVU="$(field "$OUT" revisionAfter)"
  [ "$REVU" != "$REVF" ] || fail "update did not change the folder revision"
  OUT="$(copy_run "$(smart_update "$SMART" "$Q2" "$REVF")" || true)"
  [ "$(field "$OUT" code)" = "revision_conflict" ] || fail "replayed update not refused: $(field "$OUT" code)"
  echo "ok: stale update refused; guarded update verified; replay refused"

  OUT="$(copy_run "$(smart_delete "$SMART" true)" || true)"
  [ "$(field "$OUT" status)" = "planned" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "delete dry run: $(field "$OUT" code) $(field "$OUT" message)"
  [ "$(field "$OUT" revision)" = "$REVU" ] || fail "dry-run revision differs from the update's revisionAfter"
  OUT="$(copy_run "$(smart_delete "$SMART" false "$ZERO_FOLDER")" || true)"
  [ "$(field "$OUT" code)" = "revision_conflict" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "stale delete revision not refused: $(field "$OUT" code)"
  OUT="$(copy_run "$(smart_delete "$SMART" false "$REVU")" || true)"
  [ "$(field "$OUT" status)" = "deleted" ] && [ "$(field "$OUT" verified)" = "true" ] ||
    fail "delete apply: $(field "$OUT" code) $(field "$OUT" message)"
  OUT="$(copy_run "$(smart_delete "$SMART" false "$REVU")" || true)"
  [ "$(field "$OUT" code)" = "unsupported_folder" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "replayed delete not refused: $(field "$OUT" code)"
  echo "ok: delete planned, stale revision refused, tombstone verified, replay refused"
  OUT="$(copy_run "$(smart_delete "$PARENT" true)" || true)"
  [ "$(field "$OUT" code)" = "unsupported_folder" ] || fail "ordinary folder accepted for smart-folder delete"
  echo "ok: ordinary folder refused by the smart-folder delete"

  [ "$LIVE_SMART_BEFORE" = "$(live_smart_rows)" ] || fail "live smart folders changed during the copy test"
  echo "ok: live smart-folder rows unchanged"
}
smart_folder_checks


# 5. The live note is untouched.
LIVE_AFTER="$(field "$(run "$READ")" revision)"
[ "$LIVE_BEFORE" = "$LIVE_AFTER" ] || fail "live note revision changed during the copy test"
echo "ok: live note revision unchanged"
echo "PASS"
