#!/bin/bash
# STATUS: NOT YET RUN. Syntax-checked only (bash -n, shellcheck), and
# exercised against a synthetic store with a stub writer. It needs Full Disk
# Access for the terminal that runs it, because the harness backs up the live
# Notes store to build its copy. No result in TECHNICAL_NOTES.md comes from it.
#
# Question it answers (maintainer review of PR #262, question 2): which CRDT
# replica do the private writer's edits carry? Does each writer process mint a
# new replica or reuse one, does deleting the writer's preferences domain
# change that, and how do the writer's replicas compare with the replicas
# Notes.app itself recorded for the same note?
#
# It dumps the note's replica table (the vector timestamp in the note body's
# protobuf, decoded by src/utils/noteReplicaTable.ts) at each step:
#   baseline  the copy as backed up from the live store
#   A         5 appends, 5 separate writer processes (the protocol is one JSON
#             request per process, so a single process cannot take several)
#   B         5 more appends from a SECOND copy of the writer binary at another
#             path, which tells path-derived identity from bundle-id identity
#   C         the writer's preferences domain moved aside (saved first, restored
#             after), then 2 more appends
# and compares every table with the live store's table for the same note, read
# only. Replica UUIDs, clocks and counts are printed; note text never is.
#
# Writes go to the COPY only: APPLE_NOTES_MCP_PRIVATE_STORE points every writer
# run at the copy, and the harness redirects the ICAccount directories. The one
# thing outside the copy that this script touches is the writer's own
# preferences domain (io.github.apple-notes-mcp.private-writer), through
# `defaults` only, with an export taken first and restored on exit.
#
# Usage: APPLE_NOTES_MCP_ENABLE_PRIVATE=1 scripts/test-private-writer-replica-identity-copy-store.sh [NOTE_UUID]
#   NOTE_UUID  note to use. Default: the most recently modified writable note in
#              the copy, which is most likely one edited in Notes.app.
#   HELPER=/path/to/binary reuses a built writer instead of compiling.
set -euo pipefail
# shellcheck source=scripts/private-writer-copy-store-lib.sh
. "$(dirname "$0")/private-writer-copy-store-lib.sh"

DOMAIN="io.github.apple-notes-mcp.private-writer"
PREFS_DIR="$HOME/Library/Caches/apple-notes-mcp-replica-evidence"
PREFS_SAVE="$PREFS_DIR/$DOMAIN.plist"
PREFS_MOVED=0
PREFS_EXISTED=0
PREFS_HASH=""

prefs_present() { defaults read "$DOMAIN" >/dev/null 2>&1; }
prefs_hash() { defaults read "$DOMAIN" 2>/dev/null | /usr/bin/shasum -a 256 | cut -d' ' -f1; }

# Puts the writer's preferences domain back exactly as it was found. Safe to
# call twice; also runs on exit so an interrupted run does not strand it.
restore_prefs() {
  [ "$PREFS_MOVED" = "1" ] || return 0
  PREFS_MOVED=0
  defaults delete "$DOMAIN" >/dev/null 2>&1 || true
  if [ "$PREFS_EXISTED" = "1" ]; then
    defaults import "$DOMAIN" "$PREFS_SAVE" || {
      echo "FAIL: could not restore $DOMAIN; the export is at $PREFS_SAVE" >&2
      return 1
    }
    if [ "$(prefs_hash)" != "$PREFS_HASH" ]; then
      echo "FAIL: restored $DOMAIN differs from the original; the export is at $PREFS_SAVE" >&2
      return 1
    fi
    rm -f "$PREFS_SAVE"
    echo "restored: $DOMAIN matches its original contents"
  else
    echo "restored: $DOMAIN did not exist before the run and does not exist now"
  fi
}
on_exit() {
  restore_prefs || true
  cleanup
}
trap on_exit EXIT
trap 'exit 130' INT TERM

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
echo "note under test: $NOTE (the replica table below carries no note text)"

# Decoder: bundle the TypeScript CLI once so the run needs nothing but node.
DUMP_TOOL="$WORK/note-replica-table.mjs"
"$REPO/node_modules/.bin/esbuild" "$REPO/scripts/note-replica-table.ts" --bundle \
  --platform=node --format=esm --outfile="$DUMP_TOOL" --log-level=error ||
  fail "could not bundle scripts/note-replica-table.ts (run pnpm install)"

# dump LABEL STORE writes $WORK/LABEL.dump and the sorted replica UUIDs to
# $WORK/LABEL.uuids, and fails if the decoder could not read the note.
dump() {
  node "$DUMP_TOOL" "$2" "$NOTE" >"$WORK/$1.dump" || fail "could not decode the replica table ($1)"
  awk '$1 == "replica" { print $3 }' "$WORK/$1.dump" | LC_ALL=C sort >"$WORK/$1.uuids"
  grep -q '^layout lengthsMatchText=true' "$WORK/$1.dump" ||
    echo "WARN: $1 layout self-check failed; see warnings below" >&2
  grep '^warning ' "$WORK/$1.dump" | sed "s/^/  [$1] /" >&2 || true
}
count() { wc -l <"$WORK/$1.uuids" | tr -d ' '; }
new_since() { LC_ALL=C comm -13 "$WORK/$1.uuids" "$WORK/$2.uuids"; }
in_live() { LC_ALL=C comm -12 "$WORK/$1.uuids" "$WORK/live.uuids" | wc -l | tr -d ' '; }
short() {
  local out=""
  while read -r u; do out="$out${u%%-*} "; done
  printf '%s' "${out:--}"
}

copy_run_bin() {
  printf '%s' "$2" | env -u APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES \
    APPLE_NOTES_MCP_PRIVATE_STORE="$COPY" "$1" 2>/dev/null
}

REV=""
# append_from BINARY TAG sends one native append in a fresh writer process.
append_from() {
  local out
  [ -n "$REV" ] || REV="$(field "$(copy_run_bin "$1" "$READ")" revision)"
  out="$(copy_run_bin "$1" "{\"protocol\":1,\"action\":\"append_plain_text\",\"identifier\":\"$NOTE\",\"text\":\"replica-probe $2\",\"ifRevision\":\"$REV\"}")"
  [ "$(field "$out" verified)" = "true" ] || fail "append $2 failed: $(field "$out" code) $(field "$out" message)"
  [ "$(field "$out" storeKind)" = "copy" ] || fail "append $2 did not report the copy store"
  REV="$(field "$out" revisionAfter)"
}

SECOND="$WORK/second-writer"
mkdir -p "$SECOND"
cp "$HELPER" "$SECOND/apple-notes-private-writer"

echo
echo "preferences domain $DOMAIN before the run:"
if prefs_present; then
  PREFS_EXISTED=1
  PREFS_HASH="$(prefs_hash)"
  mkdir -p "$PREFS_DIR"
  chmod 700 "$PREFS_DIR"
  defaults export "$DOMAIN" "$PREFS_SAVE"
  /usr/bin/plutil -p "$PREFS_SAVE" | sed 's/^/  /'
else
  echo "  (absent)"
fi

# Live table first, read-only: the replicas Notes.app and other devices wrote.
dump live "$LIVE"
dump base "$COPY"
[ "$(cat "$WORK/live.uuids")" = "$(cat "$WORK/base.uuids")" ] ||
  echo "note: live and baseline tables differ (the note changed after the backup)"

for i in 1 2 3 4 5; do append_from "$HELPER" "A$i"; done
dump A "$COPY"
PREFS_AFTER_A="$(prefs_present && echo present || echo absent)"

for i in 1 2 3 4 5; do append_from "$SECOND/apple-notes-private-writer" "B$i"; done
dump B "$COPY"
PREFS_AFTER_B="$(prefs_present && echo present || echo absent)"

# Move the writer's preferences domain aside, then write again.
PREFS_MOVED=1
defaults delete "$DOMAIN" >/dev/null 2>&1 || true
for i in 1 2; do append_from "$HELPER" "C$i"; done
dump C "$COPY"
PREFS_AFTER_C="$(prefs_present && echo present || echo absent)"
restore_prefs

echo
echo "replica identity for note $NOTE (copy store; live store read only)"
printf '%-34s %8s  %-26s %s\n' "step" "replicas" "new replicas (first 8 hex)" "in live table"
row() { printf '%-34s %8s  %-26s %s\n' "$1" "$(count "$2")" "$3" "$(in_live "$2")/$(count "$2")"; }
row "live note (Notes.app, read only)" live "-"
row "baseline (copy at backup)" base "-"
row "A: 5 appends, 5 processes" A "$(new_since base A | short)"
row "B: +5, second binary path" B "$(new_since A B | short)"
row "C: +2, prefs domain removed" C "$(new_since B C | short)"
echo
echo "writer replicas added in A:  $(new_since base A | wc -l | tr -d ' ') for 5 processes"
echo "second binary added in B:    $(new_since A B | wc -l | tr -d ' ') (0 means A's replica was reused across processes and paths)"
echo "after prefs removal in C:    $(new_since B C | wc -l | tr -d ' ') (0 means the identity does not come from the prefs domain)"
echo "prefs domain after A / B / C: $PREFS_AFTER_A / $PREFS_AFTER_B / $PREFS_AFTER_C (present or absent)"
echo "replicas shared with live note: $(in_live C) of $(count C)"
echo
echo "replica lines, as: index uuid clock chars live-chars substrings"
for step in live base C; do
  echo "[$step]"
  grep '^replica ' "$WORK/$step.dump" | sed 's/^replica /  /'
done

assert_live_unchanged "$NOTE" "$LIVE_BEFORE"
echo "done"
