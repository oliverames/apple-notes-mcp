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

# Feature write checks go here, each against the copy only. Each note a
# feature writes to in the copy is recorded with watch_live first, and step 5
# proves its live revision did not change.
WATCHED="$WORK/watched-live"
: >"$WATCHED"
watch_live() { printf '%s %s\n' "$1" "$(field "$(run "$(read_request "$1")")" revision)" >>"$WATCHED"; }

# Upstream's read-only readers (src/utils/noteParagraphs.ts and
# noteLinkInventory.ts), bundled once and pointed at the copy, so every
# paragraph or link write is checked by the same code list-note-paragraphs and
# list-note-links run. Prints one JSON object per call.
READER="$WORK/paragraph-reader.mjs"
cat >"$WORK/paragraph-reader.ts" <<'TS'
import { readNoteParagraphs } from "@/utils/noteParagraphs.js";
import { listNoteLinks } from "@/utils/noteLinkInventory.js";
const [mode, id, dbPath] = process.argv.slice(2);
try {
  const result =
    mode === "links"
      ? listNoteLinks({ id, kinds: ["section"], dbPath })
      : readNoteParagraphs({ id }, { dbPath });
  process.stdout.write(JSON.stringify(result));
} catch (error) {
  process.stdout.write(JSON.stringify({ error: String(error) }));
}
TS
(cd "$REPO" && node_modules/.bin/esbuild "$WORK/paragraph-reader.ts" --bundle --platform=node \
  --format=esm --log-level=error --tsconfig="$REPO/tsconfig.json" \
  "--banner:js=import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" \
  --outfile="$READER")
object_uri() { field "$(copy_run "$(read_request "$1")")" objectURI; }
paragraphs_on_copy() { node "$READER" paragraphs "$(object_uri "$1")" "$COPY"; }
section_links_on_copy() { node "$READER" links "$(object_uri "$1")" "$COPY"; }
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

# 4a. Paragraph identifiers: mint one for a block whose ID is shared (a
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

# 4a2. Section-link chips (macOS 27). A chip within a note that has a heading,
#    a replacement below the title that clears it, and a chip from the append
#    note into that heading. Each is checked with upstream's list-note-links
#    reader on the copy: one `section` link whose attachment, target note and
#    paragraph match the writer's result.
# The section link with this attachment identifier, as JSON ({} if none), and
# how many section links the reader lists.
section_link() {
  printf '%s' "$1" | node -e '
    let s = "";
    process.stdin.on("data", (c) => (s += c)).on("end", () => {
      const links = JSON.parse(s).links || [];
      const hit = links.find((l) => (l.attachmentIdentifier || "").toUpperCase() === process.argv[1].toUpperCase());
      process.stdout.write(JSON.stringify(hit || {}));
    });' "$2"
}
section_count() { printf '%s' "$1" | /usr/bin/plutil -extract links raw -o - - 2>/dev/null || echo 0; }
check_chip() { # writer-output source-note
  local out="$1" links hit
  links="$(section_links_on_copy "$2")"
  hit="$(section_link "$links" "$(field "$out" inlineAttachmentIdentifier)")"
  [ "$(field "$hit" kind)" = "section" ] || fail "list-note-links does not list the chip as a section link"
  [ "$(field "$hit" inBody)" = "true" ] || fail "the chip's glyph is not in the body"
  [ "$(field "$hit" targetNote)" = "$(field "$out" target)" ] || fail "the chip targets another note"
  [ "$(field "$hit" paragraphId)" = "$(field "$out" paragraphId)" ] || fail "the chip targets another paragraph"
  [ "$(field "$hit" url)" = "$(field "$out" token)" ] || fail "the stored URL differs from the writer's token"
  TPARAS="$(paragraphs_on_copy "$(field "$out" target)")"
  grep -qF "\"url\":\"$(field "$out" url)\"" <<<"$TPARAS" ||
    fail "list-note-paragraphs does not link the target paragraph"
  LAST_SECTION_COUNT="$(section_count "$links")"
}
if [ "$(field "$(copy_run '{"protocol":1,"action":"probe"}')" features.addSectionLink.available)" != "true" ]; then
  echo "skip: section-link chips unavailable here (need macOS 27)"
else
  SNOTE=""
  for CANDIDATE in $(recent_notes 80); do
    [ "$CANDIDATE" != "$NOTE" ] || continue
    writable "$CANDIDATE" || continue
    if grep -Eq '"style":"(heading|subheading)"' <<<"$(paragraphs_on_copy "$CANDIDATE")"; then
      SNOTE="$CANDIDATE"
      break
    fi
  done
  # Without a heading in any recent note, link a paragraph of the step 6
  # note by blockIndex instead of the default first heading.
  SELECTOR=""
  if [ -z "$SNOTE" ] && [ "$PNOTE" != "$NOTE" ]; then
    SNOTE="$PNOTE"
    SPARAS="$(paragraphs_on_copy "$SNOTE")"
    # Prefer a paragraph whose identifier is shared, so the chip must mint one.
    SPI=0
    I=0
    while [ -n "$(field "$SPARAS" "paragraphs.$I.blockIndex")" ]; do
      if [ "$(field "$SPARAS" "paragraphs.$I.paragraphIdStatus")" = "shared" ]; then
        SPI="$I"
        break
      fi
      I=$((I + 1))
    done
    SELECTOR=",\"blockIndex\":$(field "$SPARAS" "paragraphs.$SPI.blockIndex"),\"expectedText\":$(json_string "$SPARAS" "paragraphs.$SPI.text")"
    echo "no heading in recent notes; linking block $(field "$SPARAS" "paragraphs.$SPI.blockIndex") of the step 6 note"
  fi
  if [ -z "$SNOTE" ]; then
    echo "skip: no second writable note for section-link chips in the copy"
  else
    watch_live "$SNOTE"
    chip_request() { # revision position clear
      printf '{"protocol":1,"action":"add_section_link","identifier":"%s","ifRevision":"%s","position":"%s","clearExistingSectionLinks":%s%s}' \
        "$SNOTE" "$1" "$2" "$3" "$SELECTOR"
    }
    SREV="$(field "$(copy_run "$(read_request "$SNOTE")")" revision)"
    OUT="$(copy_run "$(chip_request "$SREV" end false)" || true)"
    [ "$(field "$OUT" status)" = "updated" ] && [ "$(field "$OUT" verified)" = "true" ] ||
      fail "add_section_link: $(field "$OUT" code) $(field "$OUT" message)"
    check_chip "$OUT" "$SNOTE"
    echo "ok: chip within a note added and verified (minted=$(field "$OUT" paragraphIdMinted), previous status $(field "$OUT" previousParagraphIdStatus)); reader lists $LAST_SECTION_COUNT section link(s)"
    OUT2="$(copy_run "$(chip_request "$(field "$OUT" revisionAfter)" belowTitle true)" || true)"
    [ "$(field "$OUT2" status)" = "updated" ] || fail "clear and re-add: $(field "$OUT2" code) $(field "$OUT2" message)"
    [ "$(field "$OUT2" clearedSectionLinks)" -ge 1 ] || fail "clearExistingSectionLinks cleared nothing"
    [ "$(field "$OUT2" paragraphIdMinted)" = "false" ] || fail "second chip minted again"
    check_chip "$OUT2" "$SNOTE"
    [ "$LAST_SECTION_COUNT" = "1" ] || fail "cleared section links are still listed ($LAST_SECTION_COUNT)"
    echo "ok: $(field "$OUT2" clearedSectionLinks) chip(s) cleared and one re-added below the title"
    OUT3="$(copy_run "$(chip_request "$SREV" end false)" || true)"
    [ "$(field "$OUT3" code)" = "revision_conflict" ] && [ "$(field "$OUT3" committed)" = "false" ] ||
      fail "stale add_section_link not refused: $(field "$OUT3" code)"
    echo "ok: stale add_section_link refused, committed=false"

    # A chip in the append note that opens the same heading in SNOTE.
    NREV="$(field "$(copy_run "$READ")" revision)"
    TREV="$(field "$(copy_run "$(read_request "$SNOTE")")" revision)"
    CROSS="{\"protocol\":1,\"action\":\"add_section_link\",\"identifier\":\"$NOTE\",\"target\":\"$SNOTE\",\"ifRevision\":\"$NREV\""
    OUT4="$(copy_run "$CROSS}" || true)"
    [ "$(field "$OUT4" code)" = "invalid_request" ] || fail "cross-note chip without ifTargetRevision not refused"
    OUT4="$(copy_run "$CROSS,\"paragraphId\":\"$(field "$OUT2" paragraphId)\",\"ifTargetRevision\":\"$TREV\"}" || true)"
    [ "$(field "$OUT4" status)" = "updated" ] && [ "$(field "$OUT4" selfLink)" = "false" ] ||
      fail "cross-note chip: $(field "$OUT4" code) $(field "$OUT4" message)"
    [ "$(field "$OUT4" targetRevisionAfter)" = "$TREV" ] || fail "an unminted target note changed"
    check_chip "$OUT4" "$NOTE"
    echo "ok: chip into another note added by paragraphId, target note unchanged"

    # A chip into another note's paragraph whose identifier is shared, so
    # the writer mints it in the target note within the same save.
    XPARAS="$(paragraphs_on_copy "$SNOTE")"
    XI=""
    I=0
    while [ -z "$XI" ] && [ -n "$(field "$XPARAS" "paragraphs.$I.blockIndex")" ]; do
      [ "$(field "$XPARAS" "paragraphs.$I.paragraphIdStatus")" = "shared" ] && XI="$I"
      I=$((I + 1))
    done
    if [ -z "$XI" ]; then
      echo "skip: no shared paragraph left for a minting cross-note chip"
    else
      NREV="$(field "$OUT4" revisionAfter)"
      TREV="$(field "$(copy_run "$(read_request "$SNOTE")")" revision)"
      OUT5="$(copy_run "{\"protocol\":1,\"action\":\"add_section_link\",\"identifier\":\"$NOTE\",\"target\":\"$SNOTE\",\"ifRevision\":\"$NREV\",\"ifTargetRevision\":\"$TREV\",\"blockIndex\":$(field "$XPARAS" "paragraphs.$XI.blockIndex"),\"expectedText\":$(json_string "$XPARAS" "paragraphs.$XI.text")}" || true)"
      [ "$(field "$OUT5" status)" = "updated" ] && [ "$(field "$OUT5" paragraphIdMinted)" = "true" ] ||
        fail "minting cross-note chip: $(field "$OUT5" code) $(field "$OUT5" message)"
      [ "$(field "$OUT5" targetRevisionAfter)" != "$TREV" ] || fail "the minted target note did not change"
      check_chip "$OUT5" "$NOTE"
      echo "ok: chip into another note minted the target paragraph's identifier ($LAST_SECTION_COUNT section links in the source)"
    fi
  fi
fi

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

# 4e. Structured compose: plan, guarded apply with verified read-back, replay,
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

# 4f. Native tables: row delete (two-phase), row insert, cell edit, and orphan
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

# 5. The live notes are untouched.
LIVE_AFTER="$(field "$(run "$READ")" revision)"
[ "$LIVE_BEFORE" = "$LIVE_AFTER" ] || fail "live note revision changed during the copy test (a concurrent edit in Notes also causes this; rerun)"
for PAIR in $EDIT_LIVE_BEFORE; do
  [ "$(field "$(run "$(read_request "${PAIR%%=*}")")" revision)" = "${PAIR#*=}" ] ||
    fail "a live edit-note revision changed during the copy test (a concurrent edit in Notes also causes this; rerun)"
done
echo "ok: live note revisions unchanged"
while read -r WNOTE WREV; do
  [ "$WREV" = "$(field "$(run "$(read_request "$WNOTE")")" revision)" ] ||
    fail "a live note used by a feature check changed during the copy test"
done <"$WATCHED"
echo "ok: $(wc -l <"$WATCHED" | tr -d ' ') feature-check live note revision(s) unchanged"
echo "PASS"
