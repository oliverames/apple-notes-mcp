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

# Feature write checks go here, each against the copy only. Each note a
# feature writes to in the copy is recorded with watch_live first, and step 5
# proves its live revision did not change.
WATCHED="$WORK/watched-live"
: >"$WATCHED"
watch_live() { printf '%s %s\n' "$1" "$(field "$(run "$(read_request "$1")")" revision)" >>"$WATCHED"; }

# Upstream's read-only paragraph reader (src/utils/noteParagraphs.ts),
# bundled once and pointed at the copy, so every paragraph write is checked by
# the same code list-note-paragraphs runs. Prints one JSON object per call.
READER="$WORK/paragraph-reader.mjs"
cat >"$WORK/paragraph-reader.ts" <<'TS'
import { readNoteParagraphs } from "@/utils/noteParagraphs.js";
const [id, dbPath] = process.argv.slice(2);
try {
  process.stdout.write(JSON.stringify(readNoteParagraphs({ id }, { dbPath })));
} catch (error) {
  process.stdout.write(JSON.stringify({ error: String(error) }));
}
TS
(cd "$REPO" && node_modules/.bin/esbuild "$WORK/paragraph-reader.ts" --bundle --platform=node \
  --format=esm --log-level=error --tsconfig="$REPO/tsconfig.json" \
  "--banner:js=import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" \
  --outfile="$READER")
object_uri() { field "$(copy_run "$(read_request "$1")")" objectURI; }
paragraphs_on_copy() { node "$READER" "$(object_uri "$1")" "$COPY"; }
# JSON-encode one string field (plutil cannot emit a bare JSON string).
json_string() {
  printf '%s' "$1" | node -e '
    let s = "";
    process.stdin.on("data", (c) => (s += c)).on("end", () => {
      let v = JSON.parse(s);
      for (const k of process.argv[1].split(".")) v = v[k];
      process.stdout.write(JSON.stringify(v));
    });' "$2"
}

writable() {
  local state
  state="$(copy_run "$(read_request "$1")" || true)"
  [ "$(field "$state" editable)" = "true" ] && [ "$(field "$state" sharedViaICloud)" = "false" ] &&
    [ "$(field "$state" deletedOrInTrash)" = "false" ]
}
recent_notes() {
  /usr/bin/sqlite3 "$COPY" "SELECT n.ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT n
    JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
    WHERE n.ZIDENTIFIER IS NOT NULL AND n.ZFOLDER IS NOT NULL
      AND IFNULL(n.ZISPASSWORDPROTECTED,0)=0 AND IFNULL(n.ZMARKEDFORDELETION,0)=0
    ORDER BY n.ZMODIFICATIONDATE1 DESC LIMIT $1;"
}

# 6. Paragraph identifiers: mint one for a block whose ID is shared (a
#    recent writable note that has one, else the append note), or re-assign a
#    unique one, which must be a no-op.
PNOTE="$NOTE"
for CANDIDATE in $(recent_notes 80); do
  writable "$CANDIDATE" || continue
  if [ "$(field "$(paragraphs_on_copy "$CANDIDATE")" counts.shared)" -gt 0 ] 2>/dev/null; then
    PNOTE="$CANDIDATE"
    break
  fi
done
watch_live "$PNOTE"
PARAS="$(paragraphs_on_copy "$PNOTE")"
[ -z "$(field "$PARAS" error)" ] || fail "paragraph reader: $(field "$PARAS" error)"
PCOUNT="$(printf '%s' "$PARAS" | /usr/bin/plutil -extract paragraphs raw -o - - 2>/dev/null || echo 0)"
PI=""
for WANT in shared missing; do
  I=0
  while [ -z "$PI" ] && [ "$I" -lt "${PCOUNT:-0}" ]; do
    [ "$(field "$PARAS" "paragraphs.$I.paragraphIdStatus")" = "$WANT" ] && PI="$I"
    I=$((I + 1))
  done
done
EXPECT_UNCHANGED=""
if [ -z "$PI" ]; then
  PI=0
  EXPECT_UNCHANGED=1
fi
BLOCK="$(field "$PARAS" "paragraphs.$PI.blockIndex")"
echo "paragraphs: $PCOUNT (unique $(field "$PARAS" counts.unique), shared $(field "$PARAS" counts.shared), missing $(field "$PARAS" counts.missing)); target block $BLOCK status $(field "$PARAS" "paragraphs.$PI.paragraphIdStatus")"
REV="$(field "$(copy_run "$(read_request "$PNOTE")")" revision)"
set_paragraph_request() { # expectedText-json revision
  printf '{"protocol":1,"action":"set_paragraph_id","identifier":"%s","blockIndex":%s,"expectedText":%s,"ifRevision":"%s"}' \
    "$PNOTE" "$BLOCK" "$1" "$2"
}
OUT="$(copy_run "$(set_paragraph_request '"not the paragraph text"' "$REV")" || true)"
[ "$(field "$OUT" code)" = "paragraph_changed" ] && [ "$(field "$OUT" committed)" = "false" ] ||
  fail "wrong expectedText not refused: $(field "$OUT" code)"
echo "ok: wrong expectedText refused, committed=false"
SETP="$(set_paragraph_request "$(json_string "$PARAS" "paragraphs.$PI.text")" "$REV")"
OUT="$(copy_run "$SETP" || true)"
STATUS="$(field "$OUT" status)"
if [ -n "$EXPECT_UNCHANGED" ]; then
  [ "$STATUS" = "unchanged" ] || fail "unique paragraph re-assigned: $STATUS $(field "$OUT" code)"
  echo "ok: every paragraph already unique; set_paragraph_id was a no-op"
else
  [ "$STATUS" = "updated" ] && [ "$(field "$OUT" verified)" = "true" ] ||
    fail "set_paragraph_id: $(field "$OUT" code) $(field "$OUT" message)"
  PID="$(field "$OUT" paragraphId)"
  AFTERP="$(paragraphs_on_copy "$PNOTE")"
  [ "$(field "$AFTERP" "paragraphs.$PI.paragraphId")" = "$PID" ] || fail "reader does not see the new identifier"
  [ "$(field "$AFTERP" "paragraphs.$PI.paragraphIdStatus")" = "unique" ] || fail "reader does not see it as unique"
  [ "$(field "$AFTERP" "paragraphs.$PI.url")" = "$(field "$OUT" url)" ] || fail "reader url differs from the writer's"
  echo "ok: paragraph identifier minted and verified; list-note-paragraphs reader agrees (unique $(field "$AFTERP" counts.unique))"
  OUT="$(copy_run "$SETP" || true)"
  [ "$(field "$OUT" code)" = "revision_conflict" ] || fail "replayed set_paragraph_id not refused: $(field "$OUT" code)"
  echo "ok: replayed set_paragraph_id refused"
fi

# 5. The live note is untouched.
LIVE_AFTER="$(field "$(run "$READ")" revision)"
[ "$LIVE_BEFORE" = "$LIVE_AFTER" ] || fail "live note revision changed during the copy test"
echo "ok: live note revision unchanged"
while read -r WNOTE WREV; do
  [ "$WREV" = "$(field "$(run "$(read_request "$WNOTE")")" revision)" ] ||
    fail "a live note used by a feature check changed during the copy test"
done <"$WATCHED"
echo "ok: $(wc -l <"$WATCHED" | tr -d ' ') feature-check live note revision(s) unchanged"
echo "PASS"
