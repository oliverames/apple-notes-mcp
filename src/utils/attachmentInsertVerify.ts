/**
 * Database-backed confirmation that one attachment insertion landed.
 *
 * add-attachment verifies through AppleScript first. On some macOS releases
 * (27.2 for PDFs, #236) Notes creates the attachment but AppleScript never
 * lists it, so that path can only report an uncertain outcome, and a caller
 * that retries creates duplicates. This module confirms the insertion from
 * the NoteStore instead, read-only:
 *
 * 1. Before the write, {@link snapshotStoreAttachments} records the note's
 *    attachment primary keys and the time.
 * 2. After AppleScript lists nothing new, {@link verifyAttachmentInStore}
 *    polls briefly for attachment rows owned by the note that were not in the
 *    snapshot and were created after it.
 * 3. {@link decideStoreVerification} accepts the result only when exactly one
 *    new row exists, its type matches the file, the decoded note body holds
 *    an attachment run for it (when the body decodes), and its media file
 *    under the account's `Media` folder has the source's size and SHA-256.
 *    Anything else stays uncertain.
 *
 * Every query goes through runReadOnlySql (`sqlite3 -readonly`, argument
 * array, bound integer parameters). Nothing here writes to the store or the
 * group container.
 *
 * @module utils/attachmentInsertVerify
 */

import { createHash } from "node:crypto";
import { closeSync, constants, fstatSync, openSync, readFileSync } from "node:fs";
import { extname, sep } from "node:path";
import {
  assetPathsFor,
  classifyAttachmentKind,
  NOTES_CONTAINER_DIR,
  resolveAccountDir,
  type AttachmentRow,
} from "./attachmentAssets.js";
import { decodeCompressedNoteBlocks } from "./noteBlocks.js";
import {
  CORE_DATA_EPOCH_MS,
  col,
  entity,
  NOTES_DB_PATH,
  notTombstonedSql,
  parseJsonLines,
  readColumns,
  runReadOnlySql,
} from "./noteStoreSql.js";

/** Attachment state of one note before the write. */
export interface StoreAttachmentSnapshot {
  notePk: number;
  /** Primary keys of the note's attachment rows at snapshot time. */
  attachmentPks: number[];
  /** Snapshot time as a Core Data timestamp (seconds since 2001-01-01Z). */
  takenAt: number;
}

/** One attachment row owned by the note, with its media location. */
export interface StoreAttachmentCandidate extends AttachmentRow {
  /** ZCREATIONDATE as a Core Data timestamp, or null. */
  created: number | null;
}

/** What one read of the store returned for the note. */
export interface StoreAttachmentRead {
  candidates: StoreAttachmentCandidate[];
  /** Attachment identifiers in the decoded body, or null when the body did not decode. */
  bodyAttachmentIds: string[] | null;
}

/** The file that was attached. */
export interface ExpectedAttachment {
  /** Uniform type identifier the file's extension implies, or null when unknown. */
  uti: string | null;
  size: number;
  sha256: string;
}

/** A media file that matched the expected bytes. */
export interface MediaEvidence {
  path: string;
  size: number;
  sha256: string;
}

/** The outcome of one database verification attempt. */
export type StoreVerification =
  | { status: "verified"; candidate: StoreAttachmentCandidate; media: MediaEvidence }
  | {
      status:
        "absent" | "ambiguous" | "type-mismatch" | "not-in-body" | "media-missing" | "id-mismatch";
      reason: string;
    };

/** Grace for clock granularity between this process and Notes. */
const CREATION_SKEW_SECONDS = 2;
/** Default bound on how long the store is polled after AppleScript lists nothing. */
export const STORE_VERIFY_TIMEOUT_MS = 6000;
const STORE_VERIFY_INTERVAL_MS = 300;

/** Attachment types this module can name from a file extension. */
const UTI_BY_EXTENSION: Record<string, string> = {
  ".pdf": "com.adobe.pdf",
  ".png": "public.png",
  ".jpg": "public.jpeg",
  ".jpeg": "public.jpeg",
  ".heic": "public.heic",
  ".tif": "public.tiff",
  ".tiff": "public.tiff",
  ".gif": "com.compuserve.gif",
  ".txt": "public.plain-text",
};

/** The UTI Notes records for a file with this name, or null when not known here. */
export function expectedUtiForName(name: string): string | null {
  return UTI_BY_EXTENSION[extname(name).toLowerCase()] ?? null;
}

/** Current time as a Core Data timestamp. */
export function coreDataNow(now: number = Date.now()): number {
  return (now - CORE_DATA_EPOCH_MS) / 1000;
}

function notePkOf(noteId: string): number {
  const match = /^x-coredata:\/\/[0-9A-Fa-f-]+\/ICNote\/p(\d{1,15})$/.exec(noteId);
  if (!match) throw new Error("An exact note ID is required");
  return Number(match[1]);
}

/**
 * Build the one-transaction read of a note's live attachment rows plus its
 * body. Column names come only from PRAGMA table_info; the note key is the
 * bound parameter `@note`.
 */
export function buildStoreAttachmentSql(columns: ReadonlySet<string>): string {
  const firstOf = (alias: string, names: string[]) => {
    const present = names.filter((name) => columns.has(name)).map((name) => `${alias}.${name}`);
    if (!present.length) return "NULL";
    return present.length === 1 ? present[0] : `COALESCE(${present.join(", ")})`;
  };
  const accountColumns = [...columns].filter((name) => /^ZACCOUNT\d*$/.test(name)).sort();
  const account = accountColumns.length
    ? `(SELECT acc.ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT acc WHERE acc.Z_ENT = ${entity("ICAccount")} ` +
      `AND acc.Z_PK IN (${[...accountColumns.map((c) => `a.${c}`), ...accountColumns.map((c) => `n.${c}`)].join(", ")}) LIMIT 1)`
    : "NULL";
  const media = columns.has("ZMEDIA")
    ? "LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = a.ZMEDIA"
    : "LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON 0";
  const fields = [
    `'k', 'attachment'`,
    `'pk', a.Z_PK`,
    `'identifier', ${col(columns, "a", "ZIDENTIFIER")}`,
    `'uti', ${col(columns, "a", "ZTYPEUTI")}`,
    `'parentPk', ${col(columns, "a", "ZPARENTATTACHMENT")}`,
    `'filename', ${col(columns, "a", "ZFILENAME")}`,
    `'created', ${firstOf("a", ["ZCREATIONDATE", "ZCREATIONDATE1", "ZCREATIONDATE3"])}`,
    `'mediaIdentifier', ${col(columns, "m", "ZIDENTIFIER")}`,
    `'mediaFilename', ${col(columns, "m", "ZFILENAME")}`,
    `'mediaGeneration', ${firstOf("m", ["ZGENERATION1", "ZGENERATION"])}`,
    `'accountIdentifier', ${account}`,
  ].join(", ");
  return [
    "BEGIN;",
    `SELECT json_object('k', 'note', 'exists', (SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT ` +
      `WHERE Z_PK = @note AND Z_ENT = ${entity("ICNote")}), ` +
      `'data', (SELECT hex(ZDATA) FROM ZICNOTEDATA WHERE ZNOTE = @note LIMIT 1));`,
    `SELECT json_object(${fields}) FROM ZICCLOUDSYNCINGOBJECT a ${media} ` +
      `LEFT JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = a.ZNOTE ` +
      `WHERE a.Z_ENT = ${entity("ICAttachment")} AND a.ZNOTE = @note AND ${notTombstonedSql(columns, "a")} ` +
      `ORDER BY a.Z_PK;`,
    "COMMIT;",
  ].join(" ");
}

const text = (value: unknown) => (typeof value === "string" && value ? value : null);
const integer = (value: unknown) =>
  typeof value === "number" && Number.isSafeInteger(value) ? value : null;

/** Read the note's live attachment rows and decoded body attachment ids. */
export function readStoreAttachments(
  noteId: string,
  dbPath: string = NOTES_DB_PATH
): StoreAttachmentRead {
  const notePk = notePkOf(noteId);
  const columns = readColumns(dbPath);
  if (!columns.has("ZNOTE") || !columns.has("ZIDENTIFIER"))
    throw new Error("This Notes database lacks the attachment columns verification needs");
  const rows = parseJsonLines<Record<string, unknown>>(
    runReadOnlySql(dbPath, buildStoreAttachmentSql(columns), { note: { int: notePk } })
  );
  const note = rows.find((row) => row.k === "note");
  if (!note?.exists) throw new Error("The note is not in the Notes database");
  const candidates: StoreAttachmentCandidate[] = [];
  for (const row of rows) {
    if (row.k !== "attachment") continue;
    const pk = integer(row.pk);
    const identifier = text(row.identifier);
    if (pk === null || identifier === null) continue;
    candidates.push({
      pk,
      identifier,
      uti: text(row.uti),
      parentPk: integer(row.parentPk),
      filename: text(row.filename),
      created: typeof row.created === "number" && Number.isFinite(row.created) ? row.created : null,
      mediaIdentifier: text(row.mediaIdentifier),
      mediaFilename: text(row.mediaFilename),
      mediaGeneration: text(row.mediaGeneration),
      fallbackImageGeneration: null,
      fallbackPdfGeneration: null,
      accountIdentifier: text(row.accountIdentifier),
    });
  }
  let bodyAttachmentIds: string[] | null = null;
  const data = text(note.data);
  if (data && /^[0-9a-f]+$/i.test(data)) {
    try {
      bodyAttachmentIds = decodeCompressedNoteBlocks(Buffer.from(data, "hex")).attachments.map(
        (marker) => marker.id
      );
    } catch {
      bodyAttachmentIds = null;
    }
  }
  return { candidates, bodyAttachmentIds };
}

/**
 * Record the note's attachment rows before a write. Returns null when the
 * store cannot be read (no Full Disk Access, an unfamiliar schema), which
 * leaves the database fallback unavailable rather than failing the write.
 */
export function snapshotStoreAttachments(
  noteId: string,
  dbPath: string = NOTES_DB_PATH,
  now: number = Date.now()
): StoreAttachmentSnapshot | null {
  try {
    const { candidates } = readStoreAttachments(noteId, dbPath);
    return {
      notePk: notePkOf(noteId),
      attachmentPks: candidates.map((candidate) => candidate.pk),
      takenAt: coreDataNow(now),
    };
  } catch {
    return null;
  }
}

/** Size and SHA-256 of a regular file opened without following links, or null. */
export function digestFile(path: string, maxBytes = 64 * 1024 * 1024): MediaEvidence | null {
  let descriptor: number | undefined;
  try {
    descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const stat = fstatSync(descriptor);
    if (!stat.isFile() || stat.size > maxBytes) return null;
    const bytes = readFileSync(descriptor);
    return { path, size: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") };
  } catch {
    return null;
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

/**
 * The candidate's media file when one under the account's `Media` folder has
 * exactly the expected size and digest. Notes' fallback renderings are never
 * accepted as the attachment's bytes.
 */
export function matchingMedia(
  candidate: StoreAttachmentCandidate,
  expected: ExpectedAttachment,
  containerDir: string = NOTES_CONTAINER_DIR
): MediaEvidence | null {
  const accountDir = resolveAccountDir(containerDir, candidate.accountIdentifier);
  if (!accountDir) return null;
  const mediaRoot = `${accountDir}${sep}Media${sep}`;
  for (const path of assetPathsFor(accountDir, candidate)) {
    if (!path.startsWith(mediaRoot)) continue;
    const evidence = digestFile(path);
    if (evidence && evidence.size === expected.size && evidence.sha256 === expected.sha256)
      return evidence;
  }
  return null;
}

/** Notes' own object types, which a file insertion never creates. */
const INTERNAL_KINDS = new Set(["table", "url", "drawing", "scan"]);

function typeMatches(uti: string | null, expected: string | null): boolean {
  if (!uti) return false;
  if (expected) return uti.toLowerCase() === expected.toLowerCase();
  return !INTERNAL_KINDS.has(classifyAttachmentKind(uti));
}

/**
 * Decide from one store read whether exactly one new attachment matching the
 * file landed. Pure apart from `media`, which looks up the media evidence.
 *
 * A row is new when its key is not in the snapshot and it was created at or
 * after the snapshot (within a small skew). Child rows (a gallery's items)
 * are ignored; any second new top-level row makes the outcome ambiguous.
 */
export function decideStoreVerification(
  read: StoreAttachmentRead,
  snapshot: StoreAttachmentSnapshot,
  expected: ExpectedAttachment,
  media: (candidate: StoreAttachmentCandidate) => MediaEvidence | null,
  returnedId?: string
): StoreVerification {
  const before = new Set(snapshot.attachmentPks);
  const fresh = read.candidates.filter(
    (candidate) =>
      !before.has(candidate.pk) &&
      candidate.parentPk === null &&
      candidate.created !== null &&
      candidate.created >= snapshot.takenAt - CREATION_SKEW_SECONDS
  );
  if (fresh.length === 0)
    return { status: "absent", reason: "No new attachment row for this note in the database" };
  if (fresh.length > 1)
    return {
      status: "ambiguous",
      reason: `${fresh.length} new attachment rows appeared for this note; cannot tell which is this file`,
    };
  const candidate = fresh[0];
  if (returnedId && !returnedId.endsWith(`/ICAttachment/p${candidate.pk}`))
    return {
      status: "id-mismatch",
      reason: "Notes returned a different attachment id than the database row",
    };
  if (!typeMatches(candidate.uti, expected.uti))
    return {
      status: "type-mismatch",
      reason: "The new attachment row's type does not match the file",
    };
  if (
    read.bodyAttachmentIds !== null &&
    !read.bodyAttachmentIds.some((id) => id.toLowerCase() === candidate.identifier.toLowerCase())
  )
    return {
      status: "not-in-body",
      reason: "The note body does not reference the new attachment yet",
    };
  const evidence = media(candidate);
  if (!evidence)
    return {
      status: "media-missing",
      reason: "No media file with the source's size and digest was found for the new attachment",
    };
  return { status: "verified", candidate, media: evidence };
}

/** Options for {@link verifyAttachmentInStore}; the defaults read the live store. */
export interface StoreVerifyOptions {
  dbPath?: string;
  containerDir?: string;
  timeoutMs?: number;
  intervalMs?: number;
  /** A persistent attachment id Notes returned, which the row must match. */
  returnedId?: string;
  sleep?: (ms: number) => void;
  now?: () => number;
}

const blockingSleep = (ms: number) =>
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/**
 * Poll the store until one new matching attachment is confirmed, the outcome
 * is ambiguous or contradicts the write, or the bound runs out. Absent rows,
 * a body not yet updated, and a media file not yet written are treated as
 * lag and retried; a store read error ends the attempt as absent.
 */
export function verifyAttachmentInStore(
  noteId: string,
  snapshot: StoreAttachmentSnapshot,
  expected: ExpectedAttachment,
  options: StoreVerifyOptions = {}
): StoreVerification {
  const {
    dbPath = NOTES_DB_PATH,
    containerDir = NOTES_CONTAINER_DIR,
    timeoutMs = STORE_VERIFY_TIMEOUT_MS,
    intervalMs = STORE_VERIFY_INTERVAL_MS,
    sleep = blockingSleep,
    now = Date.now,
  } = options;
  const deadline = now() + timeoutMs;
  const lagging = new Set(["absent", "not-in-body", "media-missing"]);
  for (;;) {
    let outcome: StoreVerification;
    try {
      outcome = decideStoreVerification(
        readStoreAttachments(noteId, dbPath),
        snapshot,
        expected,
        (candidate) => matchingMedia(candidate, expected, containerDir),
        options.returnedId
      );
    } catch (error) {
      return {
        status: "absent",
        reason: `The Notes database could not be read: ${error instanceof Error ? error.message : String(error)}`,
      };
    }
    if (!lagging.has(outcome.status) || now() >= deadline) return outcome;
    sleep(intervalMs);
  }
}
