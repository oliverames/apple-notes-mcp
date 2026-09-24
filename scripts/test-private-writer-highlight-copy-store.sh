#!/bin/bash
# Exercise the private writer's set_highlight action against a COPY of the
# Notes store. See scripts/private-writer-copy-store-lib.sh for the copy and
# live-store rules.
#
# Usage: APPLE_NOTES_MCP_ENABLE_PRIVATE=1 scripts/test-private-writer-highlight-copy-store.sh [NOTE_UUID]
#   NOTE_UUID  note to use in the copy. Default: the most recent writable note.
#   HELPER=/path/to/binary to reuse a built writer instead of compiling.
set -euo pipefail
# shellcheck source=scripts/private-writer-copy-store-lib.sh
. "$(dirname "$0")/private-writer-copy-store-lib.sh"

NOTE="${1:-}"
if [ -z "$NOTE" ]; then
  for CANDIDATE in $(writable_candidates "1 = 1"); do
    if is_writable "$CANDIDATE"; then
      NOTE="$CANDIDATE"
      break
    fi
  done
fi
[ -n "$NOTE" ] || fail "no writable candidate note found in the copy"
READ="$(read_request "$NOTE")"
LIVE_BEFORE="$(field "$(run "$READ")" revision)"
[ -n "$LIVE_BEFORE" ] || fail "could not read the live note state"

highlight_request() {
  printf '{"protocol":1,"action":"set_highlight","identifier":"%s","match":"%s","color":"%s","expectedCount":%s,"ifRevision":"%s"%s}' \
    "$NOTE" "$1" "$2" "$3" "$4" "${5:-}"
}

# 1. Without the write switch the writer refuses a read-write open of the live store.
OUT="$(run "$(highlight_request "x" mint 1 "$ZERO")" || true)"
[ "$(field "$OUT" code)" = "writes_disabled" ] && [ "$(field "$OUT" committed)" = "false" ] ||
  fail "live read-write open not gated: $(field "$OUT" code)"
echo "ok: live set_highlight refused without APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES"

# 2. Add the fixture text twice so the count guard matters.
MARK="hl-$(date +%s)"
REV="$(field "$(copy_run "$READ")" revision)"
OUT="$(copy_run "{\"protocol\":1,\"action\":\"append_plain_text\",\"identifier\":\"$NOTE\",\"text\":\"$MARK one\\n$MARK two\",\"ifRevision\":\"$REV\"}")"
[ "$(field "$OUT" verified)" = "true" ] || fail "could not add the highlight fixture text"
REV="$(field "$OUT" revisionAfter)"
FLAG_BEFORE="$(field "$(copy_run "$(highlight_request "$MARK" mint 2 "$REV" ',"dryRun":true')")" hasEmphasis)"

# 3. Refusals and the dry run write nothing.
OUT="$(copy_run "$(highlight_request "$MARK" mint 1 "$REV")" || true)"
[ "$(field "$OUT" code)" = "match_count_mismatch" ] && [ "$(field "$OUT" found)" = "2" ] &&
  [ "$(field "$OUT" committed)" = "false" ] || fail "count guard did not refuse: $(field "$OUT" code)"
OUT="$(copy_run "$(highlight_request "$MARK" mint 2 "$ZERO")" || true)"
[ "$(field "$OUT" code)" = "revision_conflict" ] || fail "stale highlight revision not refused"
OUT="$(copy_run "$(highlight_request "$MARK" mint 2 "$REV" ',"scope":"note"')" || true)"
[ "$(field "$OUT" code)" = "invalid_request" ] || fail "unknown scope not refused"
OUT="$(copy_run "$(highlight_request "$MARK" teal 2 "$REV")" || true)"
[ "$(field "$OUT" code)" = "invalid_request" ] || fail "unknown color not refused"
OUT="$(copy_run "$(highlight_request "$MARK" mint 2 "$REV" ',"dryRun":true')" || true)"
[ "$(field "$OUT" status)" = "planned" ] && [ "$(field "$OUT" wouldChange)" = "true" ] &&
  [ "$(field "$OUT" plan.1.changes)" = "true" ] || fail "dry run did not plan: $(field "$OUT" code)"
[ "$(field "$(copy_run "$READ")" revision)" = "$REV" ] || fail "dry run changed the note"
echo "ok: count guard, stale revision, unknown scope and color, and dry run (no write) behave"

# 4. Highlight both matches, repeat (no-op), then remove.
OUT="$(copy_run "$(highlight_request "$MARK" mint 2 "$REV")" || true)"
[ "$(field "$OUT" status)" = "updated" ] && [ "$(field "$OUT" verified)" = "true" ] ||
  fail "highlight failed: $(field "$OUT" code) $(field "$OUT" message)"
[ "$(field "$OUT" ranges.0.storedRuns.0.color)" = "mint" ] &&
  [ "$(field "$OUT" ranges.1.storedRuns.0.color)" = "mint" ] || fail "stored runs are not mint"
[ "$(field "$OUT" storeKind)" = "copy" ] || fail "highlight did not report the copy store"
[ "$(field "$OUT" hasEmphasis)" = "true" ] || fail "hasEmphasis not set after the highlight"
echo "ok: hasEmphasis $FLAG_BEFORE -> true"
echo "copy cloud state: current=$(field "$OUT" cloudSync.currentLocalVersion) synced=$(field "$OUT" cloudSync.latestVersionSyncedToCloud) uploadPending=$(field "$OUT" cloudSync.uploadPending)"
REV="$(field "$OUT" revisionAfter)"
OUT="$(copy_run "$(highlight_request "$MARK" mint 2 "$REV")" || true)"
[ "$(field "$OUT" status)" = "unchanged" ] && [ "$(field "$OUT" committed)" = "false" ] &&
  [ "$(field "$OUT" revisionAfter)" = "$REV" ] || fail "repeat highlight was not a no-op"
OUT="$(copy_run "$(highlight_request "$MARK" purple 2 "$REV")" || true)"
[ "$(field "$OUT" ranges.0.storedRuns.0.color)" = "purple" ] || fail "recolor failed: $(field "$OUT" code)"
REV="$(field "$OUT" revisionAfter)"
OUT="$(copy_run "$(highlight_request "$MARK" none 2 "$REV")" || true)"
[ "$(field "$OUT" status)" = "updated" ] && [ -z "$(field "$OUT" ranges.0.storedRuns.0.color)" ] ||
  fail "highlight removal failed: $(field "$OUT" code)"
[ "$(field "$OUT" hasEmphasis)" = "$FLAG_BEFORE" ] || fail "hasEmphasis did not return to $FLAG_BEFORE"
echo "ok: two matches highlighted mint, repeat was a no-op, recolored purple, removal read back"

# 5. The live note is untouched.
assert_live_unchanged "$NOTE" "$LIVE_BEFORE"
echo "PASS"
