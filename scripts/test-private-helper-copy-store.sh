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

# 6. Native tables: row delete (two-phase), row insert, cell edit, and orphan
#    prune, all on the copy. Candidate: the first editable note with a table
#    that is visible exactly once and has at least two rows.
tables_request() { printf '{"protocol":1,"action":"read_tables","identifier":"%s"}' "$1"; }
delete_request() { # dryRun [ifRevision ifTableDigest]
  if [ "$1" = "true" ]; then
    printf '{"protocol":1,"action":"delete_table_row","identifier":"%s","tableIdentifier":"%s","rowIdentifier":"%s","dryRun":true}' \
      "$TNOTE" "$TID" "$ROW1"
  else
    printf '{"protocol":1,"action":"delete_table_row","identifier":"%s","tableIdentifier":"%s","rowIdentifier":"%s","dryRun":false,"ifRevision":"%s","ifTableDigest":"%s"}' \
      "$TNOTE" "$TID" "$ROW1" "$2" "$3"
  fi
}
prune_request() { # tableIdentifier dryRun [ifRevision ifTableDigest]
  if [ "$2" = "true" ]; then
    printf '{"protocol":1,"action":"prune_orphan_table","identifier":"%s","tableIdentifier":"%s","dryRun":true}' "$TNOTE" "$1"
  else
    printf '{"protocol":1,"action":"prune_orphan_table","identifier":"%s","tableIdentifier":"%s","dryRun":false,"ifRevision":"%s","ifTableDigest":"%s"}' \
      "$TNOTE" "$1" "$3" "$4"
  fi
}
ZERO_DIGEST="t1:${ZERO#r1:}"

table_checks() {
  local CANDIDATE STATE COUNT I TREAD TLIVE_BEFORE ROWS_BEFORE ROW0 COL0 PLAN PREV PDIG OUT
  local REV_AFTER DIG_AFTER INSERT NEWROW SETCELL ORPHAN
  TNOTE=""
  TABLE=""
  TSTATE=""
  for CANDIDATE in $(/usr/bin/sqlite3 "$COPY" "SELECT n.ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT a
    JOIN ZICCLOUDSYNCINGOBJECT n ON a.ZNOTE = n.Z_PK
    WHERE a.ZTYPEUTI = 'com.apple.notes.table' AND IFNULL(a.ZMARKEDFORDELETION,0)=0
      AND n.ZFOLDER IS NOT NULL AND IFNULL(n.ZISPASSWORDPROTECTED,0)=0
      AND IFNULL(n.ZMARKEDFORDELETION,0)=0
    GROUP BY n.Z_PK ORDER BY MAX(n.ZMODIFICATIONDATE1) DESC LIMIT 40;"); do
    STATE="$(copy_run "$(read_request "$CANDIDATE")" || true)"
    if [ "$(field "$STATE" editable)" != "true" ] || [ "$(field "$STATE" sharedViaICloud)" != "false" ] ||
      [ "$(field "$STATE" deletedOrInTrash)" != "false" ]; then
      continue
    fi
    TSTATE="$(copy_run "$(tables_request "$CANDIDATE")" || true)"
    COUNT="$(field "$TSTATE" tableCount)"
    I=0
    while [ "$I" -lt "${COUNT:-0}" ]; do
      if [ "$(field "$TSTATE" "tables.$I.glyphCount")" = "1" ] &&
        [ "$(field "$TSTATE" "tables.$I.readable")" = "true" ] &&
        [ "$(field "$TSTATE" "tables.$I.rowCount")" -ge 2 ]; then
        TNOTE="$CANDIDATE"
        TABLE="$I"
        break 2
      fi
      I=$((I + 1))
    done
  done
  if [ -z "$TNOTE" ]; then
    echo "skip: no editable note with a visible multi-row table in the copy"
    return 0
  fi
  TREAD="$(tables_request "$TNOTE")"
  TLIVE_BEFORE="$(field "$(run "$TREAD")" "tables.$TABLE.digest")"
  [ -n "$TLIVE_BEFORE" ] || fail "could not read the live table state"
  TID="$(field "$TSTATE" "tables.$TABLE.identifier")"
  ROWS_BEFORE="$(field "$TSTATE" "tables.$TABLE.rowCount")"
  ROW0="$(field "$TSTATE" "tables.$TABLE.rows.0.identifier")"
  ROW1="$(field "$TSTATE" "tables.$TABLE.rows.1.identifier")"
  COL0="$(field "$TSTATE" "tables.$TABLE.columnIdentifiers.0")"

  # Without the write switch an apply against the live store is refused
  # before any read-write open (and carries zero tokens besides).
  OUT="$(run "$(delete_request false "$ZERO" "$ZERO_DIGEST")" || true)"
  [ "$(field "$OUT" code)" = "writes_disabled" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "live table apply not gated: $(field "$OUT" code)"
  echo "ok: live table apply refused without APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES"

  PLAN="$(copy_run "$(delete_request true)" || true)"
  [ "$(field "$PLAN" status)" = "planned" ] || fail "delete dry run: $(field "$PLAN" code) $(field "$PLAN" message)"
  [ "$(field "$PLAN" committed)" = "false" ] || fail "dry run reported committed"
  PREV="$(field "$PLAN" revision)"
  PDIG="$(field "$PLAN" tableDigest)"
  echo "ok: delete-row dry run planned row $(field "$PLAN" rowIndex) of $ROWS_BEFORE"
  OUT="$(copy_run "$(delete_request false "$PREV" "$ZERO_DIGEST")" || true)"
  [ "$(field "$OUT" code)" = "attachment_conflict" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "stale table digest not refused: $(field "$OUT" code)"
  echo "ok: stale ifTableDigest refused, committed=false"
  OUT="$(copy_run "$(delete_request false "$ZERO" "$PDIG")" || true)"
  [ "$(field "$OUT" code)" = "revision_conflict" ] && [ "$(field "$OUT" committed)" = "false" ] ||
    fail "stale ifRevision not refused: $(field "$OUT" code)"
  echo "ok: stale ifRevision refused, committed=false"
  OUT="$(copy_run "$(delete_request false "$PREV" "$PDIG")" || true)"
  [ "$(field "$OUT" status)" = "updated" ] && [ "$(field "$OUT" verified)" = "true" ] ||
    fail "delete apply: $(field "$OUT" code) $(field "$OUT" message)"
  [ "$(field "$OUT" rowCount)" = "$((ROWS_BEFORE - 1))" ] || fail "row count did not drop by one"
  [ "$(field "$OUT" storeKind)" = "copy" ] || fail "delete did not report the copy store"
  [ "$(field "$OUT" pushScheduled)" = "false" ] || fail "delete claimed a push"
  REV_AFTER="$(field "$OUT" revisionAfter)"
  DIG_AFTER="$(field "$OUT" tableDigestAfter)"
  echo "ok: row deleted and verified ($ROWS_BEFORE -> $(field "$OUT" rowCount) rows, uploadPending $(field "$OUT" cloudSync.uploadPending))"
  OUT="$(copy_run "$(delete_request false "$PREV" "$PDIG")" || true)"
  [ "$(field "$OUT" code)" = "revision_conflict" ] || fail "replayed delete not refused: $(field "$OUT" code)"
  echo "ok: replayed delete refused"

  INSERT="$(printf '{"protocol":1,"action":"insert_table_row","identifier":"%s","tableIdentifier":"%s","afterRowIdentifier":"%s","cells":["copy-store row"],"ifRevision":"%s","ifTableDigest":"%s"}' \
    "$TNOTE" "$TID" "$ROW0" "$REV_AFTER" "$DIG_AFTER")"
  OUT="$(copy_run "$INSERT" || true)"
  [ "$(field "$OUT" status)" = "updated" ] && [ "$(field "$OUT" verified)" = "true" ] ||
    fail "insert: $(field "$OUT" code) $(field "$OUT" message)"
  NEWROW="$(field "$OUT" rowIdentifier)"
  echo "ok: row inserted at index $(field "$OUT" rowIndex) and verified"
  SETCELL="$(printf '{"protocol":1,"action":"set_table_cell","identifier":"%s","tableIdentifier":"%s","rowIdentifier":"%s","columnIdentifier":"%s","text":"copy-store edit","ifRevision":"%s","ifTableDigest":"%s"}' \
    "$TNOTE" "$TID" "$NEWROW" "$COL0" "$(field "$OUT" revisionAfter)" "$(field "$OUT" tableDigestAfter)")"
  OUT="$(copy_run "$SETCELL" || true)"
  [ "$(field "$OUT" status)" = "updated" ] && [ "$(field "$OUT" verified)" = "true" ] ||
    fail "set cell: $(field "$OUT" code) $(field "$OUT" message)"
  [ "$(field "$OUT" previousText)" = "copy-store row" ] || fail "set cell saw the wrong previous text"
  echo "ok: cell edited and verified"
  OUT="$(copy_run "$SETCELL" || true)"
  [ "$(field "$OUT" code)" = "revision_conflict" ] || fail "replayed cell edit not refused: $(field "$OUT" code)"
  echo "ok: replayed cell edit refused"

  # 7. Orphan prune. COPY-ONLY fixture: reassign another note's table
  #    attachment to this note with SQL on the copy, so the note owns an
  #    active table that no body glyph shows. The writer itself never runs SQL.
  /usr/bin/sqlite3 "$COPY" "UPDATE ZICCLOUDSYNCINGOBJECT
    SET ZNOTE = (SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER = '$TNOTE')
    WHERE Z_PK = (SELECT a.Z_PK FROM ZICCLOUDSYNCINGOBJECT a
      WHERE a.ZTYPEUTI = 'com.apple.notes.table' AND IFNULL(a.ZMARKEDFORDELETION,0)=0
        AND a.ZNOTE != (SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER = '$TNOTE')
      ORDER BY a.Z_PK LIMIT 1);"
  TSTATE="$(copy_run "$TREAD" || true)"
  ORPHAN=""
  I=0
  while [ "$I" -lt "$(field "$TSTATE" tableCount)" ]; do
    if [ "$(field "$TSTATE" "tables.$I.orphan")" = "true" ]; then
      ORPHAN="$(field "$TSTATE" "tables.$I.identifier")"
    fi
    I=$((I + 1))
  done
  if [ -z "$ORPHAN" ]; then
    echo "skip: the copy has no second table to turn into an orphan"
  else
    OUT="$(copy_run "$(prune_request "$TID" true)" || true)"
    [ "$(field "$OUT" code)" = "unsupported_attachment" ] || fail "visible table accepted as an orphan"
    echo "ok: visible table refused by prune"
    PLAN="$(copy_run "$(prune_request "$ORPHAN" true)" || true)"
    [ "$(field "$PLAN" status)" = "planned" ] || fail "prune dry run: $(field "$PLAN" code) $(field "$PLAN" message)"
    OUT="$(copy_run "$(prune_request "$ORPHAN" false "$(field "$PLAN" revision)" "$(field "$PLAN" tableDigest)")" || true)"
    [ "$(field "$OUT" status)" = "updated" ] && [ "$(field "$OUT" verified)" = "true" ] ||
      fail "prune apply: $(field "$OUT" code) $(field "$OUT" message)"
    echo "ok: orphan pruned and verified (active tables $(field "$OUT" activeTableCountBefore) -> $(field "$OUT" activeTableCountAfter))"
    OUT="$(copy_run "$(prune_request "$ORPHAN" true)" || true)"
    [ "$(field "$OUT" code)" = "unsupported_attachment" ] || fail "pruned table still prunable"
    echo "ok: pruned table no longer offered"
  fi

  [ "$TLIVE_BEFORE" = "$(field "$(run "$TREAD")" "tables.$TABLE.digest")" ] ||
    fail "live table changed during the copy test"
  echo "ok: live table digest unchanged"
}
table_checks


# 5. The live note is untouched.
LIVE_AFTER="$(field "$(run "$READ")" revision)"
[ "$LIVE_BEFORE" = "$LIVE_AFTER" ] || fail "live note revision changed during the copy test"
echo "ok: live note revision unchanged"
echo "PASS"
