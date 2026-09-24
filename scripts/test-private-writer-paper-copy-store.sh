#!/bin/bash
# Exercise the private WRITER's Paper authoring (add_paper) against a COPY of
# the Notes store. Sibling of test-private-helper-copy-store.sh, which covers
# the foundation's append path.
#
# The live NoteStore.sqlite is only ever opened read-only: once by sqlite3's
# online backup (to make the copy) and by the writer's read-only
# read_note_state before and after, to prove the live note did not change.
# Every write runs with APPLE_NOTES_MCP_PRIVATE_STORE pointing at the copy. On
# a copy store the writer redirects every Notes file directory (Paper bundles,
# previews, media) beside the copy, so the script also checks that no file in
# the live Notes container changed. APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES is
# always cleared, so the writer refuses any read-write open of the live store.
#
# Usage: APPLE_NOTES_MCP_ENABLE_PRIVATE=1 scripts/test-private-writer-paper-copy-store.sh [NOTE_UUID]
#   NOTE_UUID  note to draw into in the copy. Default: the most recently
#              modified unlocked note with a folder, chosen from the copy.
#   HELPER=/path/to/binary to reuse a built writer instead of compiling.
#
# Prints states and counts only, never note titles or bodies. Needs Full Disk
# Access for the terminal running it. Removes the copy on exit.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$REPO/native/private-helper/apple-notes-private-writer.m"
LIVE="$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
LIVE_DIR="$(dirname "$LIVE")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/private-writer-paper.XXXXXX")"
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
    -framework AppKit -framework PencilKit "-DHELPER_SOURCE_SHA256=\"$SHA\"" -o "$HELPER" "$SOURCE"
  echo "built writer from source sha256 $SHA"
fi

# The copy lives in its own directory: the writer redirects Notes' file
# directories into Accounts/ beside it.
mkdir -m 700 "$WORK/store"
COPY="$WORK/store/NoteStore.sqlite"
/usr/bin/sqlite3 -readonly "$LIVE" ".backup '$COPY'"
echo "copied store: $(/usr/bin/stat -f %z "$COPY") bytes"

run() { printf '%s' "$1" | env -u APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES "$HELPER" 2>/dev/null; }
copy_run() {
  printf '%s' "$1" | env -u APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES \
    APPLE_NOTES_MCP_PRIVATE_STORE="$COPY" "$HELPER" 2>/dev/null
}
read_request() { printf '{"protocol":1,"action":"read_note_state","identifier":"%s"}' "$1"; }
ZERO="r1:$(printf '0%.0s' $(seq 1 64))"

NOTE="${1:-}"
if [ -z "$NOTE" ]; then
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
touch "$WORK/authoring-start"

# Two strokes, five points: a pen curve and a watercolor line with a
# per-point width.
DRAW='{"strokes":[{"ink":"pen","color":[0,0,0,1],"width":3,"points":[[10,10],[60,40],[110,10]]},{"ink":"watercolor","color":[0.9,0.1,0.1,0.8],"width":5,"points":[[10,60],[110,60,8]]}]}'
add_request() { # identifier revision format [dryRun]
  printf '{"protocol":1,"action":"add_paper","identifier":"%s","ifRevision":"%s","drawing":%s,"format":"%s"%s}' \
    "$1" "$2" "$DRAW" "$3" "${4:+,\"dryRun\":true}"
}

# 1. Without the write switch the writer refuses a read-write open of the live
#    store. The zero revision means even a broken switch ends in a conflict.
GATED="$(run "$(add_request "$NOTE" "$ZERO" auto)" || true)"
[ "$(field "$GATED" code)" = "writes_disabled" ] || fail "live read-write open not gated: $(field "$GATED" code)"
[ "$(field "$GATED" committed)" = "false" ] || fail "gated write did not report committed=false"
echo "ok: live add_paper refused without APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES"

# 2. Refusals on the copy: a stale revision and an ink PencilKit would not keep.
OUT="$(copy_run "$(add_request "$NOTE" "$ZERO" auto)" || true)"
[ "$(field "$OUT" code)" = "revision_conflict" ] || fail "stale revision not refused: $(field "$OUT" code)"
[ "$(field "$OUT" committed)" = "false" ] || fail "stale revision reported committed"
echo "ok: stale ifRevision refused, committed=false"
REV="$(field "$(copy_run "$READ")" revision)"
BAD="{\"protocol\":1,\"action\":\"add_paper\",\"identifier\":\"$NOTE\",\"ifRevision\":\"$REV\",\"drawing\":{\"strokes\":[{\"ink\":\"monoline\",\"color\":[0,0,0,1],\"width\":2,\"points\":[[0,0],[1,1]]}]}}"
OUT="$(copy_run "$BAD" || true)"
[ "$(field "$OUT" code)" = "invalid_request" ] && [ "$(field "$OUT" committed)" = "false" ] ||
  fail "unsupported ink not refused: $(field "$OUT" code)"
echo "ok: unsupported ink refused, committed=false"

# 3. Each format: dry run leaves the note alone, then a verified write whose
#    read-back decodes 2 strokes and 5 points, then the replay is refused.
for FORMAT in paper drawing; do
  REV="$(field "$(copy_run "$READ")" revision)"
  DRY="$(copy_run "$(add_request "$NOTE" "$REV" "$FORMAT" dry)" || true)"
  [ "$(field "$DRY" status)" = "planned" ] || fail "$FORMAT dry run failed: $(field "$DRY" code) $(field "$DRY" message)"
  [ "$(field "$DRY" committed)" = "false" ] || fail "$FORMAT dry run reported committed"
  [ "$(field "$(copy_run "$READ")" revision)" = "$REV" ] || fail "the $FORMAT dry run changed the note"
  ADD="$(add_request "$NOTE" "$REV" "$FORMAT")"
  OUT="$(copy_run "$ADD" || true)"
  [ "$(field "$OUT" status)" = "created" ] || fail "add_paper ($FORMAT) failed: $(field "$OUT" code) $(field "$OUT" message)"
  [ "$(field "$OUT" verified)" = "true" ] || fail "add_paper ($FORMAT) not verified"
  [ "$(field "$OUT" storeKind)" = "copy" ] || fail "add_paper ($FORMAT) did not report the copy store"
  [ "$(field "$OUT" decodedStrokeCount)" = "2" ] && [ "$(field "$OUT" decodedPointCount)" = "5" ] ||
    fail "add_paper ($FORMAT) read-back decoded $(field "$OUT" decodedStrokeCount)/$(field "$OUT" decodedPointCount)"
  ATTS="${ATTS:-} $(field "$OUT" attachmentIdentifier)"
  [ "$FORMAT" = "paper" ] && PAPER_ATT="$(field "$OUT" attachmentIdentifier)"
  echo "ok: add_paper $FORMAT: $(field "$OUT" typeUTI), decoded $(field "$OUT" decodedStrokeCount) strokes / $(field "$OUT" decodedPointCount) points, glyphInserted=$(field "$OUT" glyphInserted) previewUpdated=$(field "$OUT" previewUpdated) pushState=$(field "$OUT" pushState)"
  AFTER="$(copy_run "$READ")"
  [ "$(field "$AFTER" revision)" = "$(field "$OUT" revisionAfter)" ] || fail "revisionAfter differs from read_note_state"
  echo "copy cloud state: current=$(field "$AFTER" cloudSync.currentLocalVersion) synced=$(field "$AFTER" cloudSync.latestVersionSyncedToCloud) uploadPending=$(field "$AFTER" cloudSync.uploadPending)"
  [ "$(field "$(copy_run "$ADD" || true)" code)" = "revision_conflict" ] || fail "replayed add_paper ($FORMAT) not refused"
  echo "ok: replayed add_paper ($FORMAT) refused"
done
BUNDLES="$(find "$WORK/store/Accounts" -mindepth 4 -maxdepth 4 -path "*/Paper/Bundles/$PAPER_ATT.bundle" -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$BUNDLES" = "1" ] || fail "expected the new Paper bundle beside the copy, found $BUNDLES"
echo "ok: the Paper bundle was written beside the copy"

# 4. The live container and the live note are untouched.
for ATT in $ATTS; do
  LEAKED="$(find "$LIVE_DIR" -name "*$ATT*" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$LEAKED" = "0" ] || fail "$LEAKED live Notes files are named after a copy-store attachment"
done
echo "ok: no file for the new attachments in the live Notes container"
# Notes.app itself may touch account files while it runs, so this count is
# reported, not asserted; the check above is the one tied to this test.
NEW_LIVE="$(find "$LIVE_DIR/Accounts" -newer "$WORK/authoring-start" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "info: $NEW_LIVE live Notes account files changed during the test (Notes.app running: $(pgrep -xq Notes && echo yes || echo no))"
LIVE_AFTER="$(field "$(run "$READ")" revision)"
[ "$LIVE_BEFORE" = "$LIVE_AFTER" ] || fail "live note revision changed during the copy test"
echo "ok: live note revision unchanged"
echo "PASS"
