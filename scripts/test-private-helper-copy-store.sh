#!/bin/bash
# Exercise the private helper's write path against a COPY of the Notes store.
#
# The live NoteStore.sqlite is only ever opened read-only: once by sqlite3's
# online backup (to make the copy) and, when APPLE_NOTES_MCP_ENABLE_PRIVATE=1
# is set, by the helper's read-only read_note_state before and after the copy
# write to prove the live note did not change. The append runs with
# APPLE_NOTES_MCP_PRIVATE_STORE pointing at the copy; the helper refuses that
# variable if it resolves to the live store.
#
# Usage: scripts/test-private-helper-copy-store.sh [NOTE_UUID]
#   NOTE_UUID  note to append to in the copy. Default: the most recently
#              modified unlocked note with a folder, chosen from the copy.
#   HELPER=/path/to/binary to reuse a built helper instead of compiling.
#
# Prints states and counts only, never note titles or bodies. Needs Full Disk
# Access for the terminal running it. Removes the copy on exit.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$REPO/native/private-helper/apple-notes-private-helper.m"
LIVE="$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/private-helper-copy.XXXXXX")"
chmod 700 "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
field() { printf '%s' "$1" | /usr/bin/plutil -extract "$2" raw -o - - 2>/dev/null || true; }

[ -r "$LIVE" ] || fail "cannot read the live store (grant Full Disk Access to this terminal)"

if [ -z "${HELPER:-}" ]; then
  HELPER="$WORK/apple-notes-private-helper"
  SHA="$(/usr/bin/shasum -a 256 "$SOURCE" | cut -d' ' -f1)"
  /usr/bin/xcrun clang -fobjc-arc -O2 -Wall -framework Foundation -framework CoreData \
    -framework AppKit -framework PencilKit "-DHELPER_SOURCE_SHA256=\"$SHA\"" -o "$HELPER" "$SOURCE"
  echo "built helper from source sha256 $SHA"
fi

COPY="$WORK/NoteStore.sqlite"
/usr/bin/sqlite3 -readonly "$LIVE" ".backup '$COPY'"
echo "copied store: $(/usr/bin/stat -f %z "$COPY") bytes"

run() { printf '%s' "$1" | "$HELPER" 2>/dev/null; }
copy_run() { printf '%s' "$1" | APPLE_NOTES_MCP_PRIVATE_STORE="$COPY" "$HELPER" 2>/dev/null; }
read_request() { printf '{"protocol":1,"action":"read_note_state","identifier":"%s"}' "$1"; }

NOTE="${1:-}"
if [ -z "$NOTE" ]; then
  # First recent candidate the helper itself reports as appendable.
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
[ -n "$NOTE" ] || fail "no appendable candidate note found in the copy"

READ="$(read_request "$NOTE")"

LIVE_BEFORE=""
if [ "${APPLE_NOTES_MCP_ENABLE_PRIVATE:-}" = "1" ]; then
  LIVE_BEFORE="$(field "$(run "$READ")" revision)"
fi

# 1. The helper must refuse to treat the live store as a copy.
REFUSED="$(printf '%s' "$READ" | APPLE_NOTES_MCP_PRIVATE_STORE="$LIVE" "$HELPER" || true)"
[ "$(field "$REFUSED" code)" = "invalid_request" ] || fail "live store accepted as a copy"
echo "ok: live store refused as a copy"

# 2. Stale revision is refused with nothing committed.
STALE="{\"protocol\":1,\"action\":\"append_plain_text\",\"identifier\":\"$NOTE\",\"text\":\"x\",\"ifRevision\":\"r1:$(printf '0%.0s' $(seq 1 64))\"}"
OUT="$(copy_run "$STALE" || true)"
[ "$(field "$OUT" code)" = "revision_conflict" ] || fail "stale revision not refused: $(field "$OUT" code)"
[ "$(field "$OUT" committed)" = "false" ] || fail "stale revision reported committed"
echo "ok: stale ifRevision refused, committed=false"

# 3. Guarded append on the copy, verified by the helper's fresh read-back.
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

# 4. The replayed request is now stale.
OUT="$(copy_run "$APPEND" || true)"
[ "$(field "$OUT" code)" = "revision_conflict" ] || fail "replayed append not refused"
echo "ok: replayed append refused"

# 5. The live note is untouched.
if [ -n "$LIVE_BEFORE" ]; then
  LIVE_AFTER="$(field "$(run "$READ")" revision)"
  [ "$LIVE_BEFORE" = "$LIVE_AFTER" ] || fail "live note revision changed during the copy test"
  echo "ok: live note revision unchanged"
else
  echo "skip: live comparison needs APPLE_NOTES_MCP_ENABLE_PRIVATE=1"
fi

# 6. Paper decode against the copy. The helper looks for the bundle beside the
#    copied store (Accounts/<account>/Paper/Bundles), so copy the first Paper
#    drawing's bundle there. The live bundle is only read (cp), and its file
#    signature must be the same afterwards.
LIVE_DIR="$(dirname "$LIVE")"
PAPER="$(/usr/bin/sqlite3 "$COPY" "SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT
  WHERE ZTYPEUTI = 'com.apple.paper' AND IFNULL(ZMARKEDFORDELETION,0) = 0
    AND IFNULL(ZISPASSWORDPROTECTED,0) = 0 ORDER BY Z_PK LIMIT 1;")"
if [ -n "$PAPER" ]; then
  BUNDLE=""
  for CANDIDATE in "$LIVE_DIR"/Accounts/*/Paper/Bundles/"$PAPER".bundle; do
    [ -d "$CANDIDATE" ] && BUNDLE="$CANDIDATE"
  done
  if [ -n "$BUNDLE" ]; then
    ACCOUNT_DIR="$(basename "$(dirname "$(dirname "$(dirname "$BUNDLE")")")")"
    signature() { find "$BUNDLE" -type f -exec stat -f '%N %z %m' {} + | /usr/bin/shasum; }
    SIG_BEFORE="$(signature)"
    mkdir -p "$WORK/Accounts/$ACCOUNT_DIR/Paper/Bundles"
    cp -R "$BUNDLE" "$WORK/Accounts/$ACCOUNT_DIR/Paper/Bundles/"
    PREQ="{\"protocol\":1,\"action\":\"read_paper\",\"attachmentIdentifier\":\"$PAPER\",\"includePoints\":false}"
    OUT="$(copy_run "$PREQ" || true)"
    [ "$(field "$OUT" status)" = "ok" ] || fail "read_paper on the copy failed: $(field "$OUT" code) $(field "$OUT" message)"
    [ "$(field "$OUT" storeKind)" = "copy" ] || fail "read_paper did not report the copy store"
    echo "ok: read_paper on the copy: $(field "$OUT" strokeCount) strokes, $(field "$OUT" pointCount) points, vectorDecode $(field "$OUT" vectorDecode)"
    if [ "${APPLE_NOTES_MCP_ENABLE_PRIVATE:-}" = "1" ]; then
      LIVE_OUT="$(run "$PREQ" || true)"
      [ "$(field "$LIVE_OUT" strokeCount)" = "$(field "$OUT" strokeCount)" ] &&
        [ "$(field "$LIVE_OUT" pointCount)" = "$(field "$OUT" pointCount)" ] ||
        fail "copy and live decodes disagree"
      echo "ok: live read_paper agrees with the copy"
    fi
    [ "$SIG_BEFORE" = "$(signature)" ] || fail "the live Paper bundle changed during the test"
    echo "ok: live Paper bundle unchanged"
    NOPE="{\"protocol\":1,\"action\":\"read_paper\",\"attachmentIdentifier\":\"$NOTE\"}"
    [ "$(field "$(copy_run "$NOPE" || true)" code)" != "ok" ] || fail "a note UUID decoded as a drawing"
  else
    echo "skip: Paper bundle not downloaded on this Mac"
  fi
else
  echo "skip: no Paper drawing in this library"
fi
echo "PASS"
