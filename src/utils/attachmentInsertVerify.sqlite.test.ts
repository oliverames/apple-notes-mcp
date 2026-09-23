/**
 * Database-backed attachment verification against a real sqlite3 and a
 * throwaway fixture store plus a fixture group container. Nothing here opens
 * the live NoteStore: every read targets the temp database, and the only
 * writes go to that fixture (to stage rows the way Notes would).
 */
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import {
  buildStoreAttachmentSql,
  coreDataNow,
  readStoreAttachments,
  snapshotStoreAttachments,
  verifyAttachmentInStore,
  type ExpectedAttachment,
  type StoreAttachmentSnapshot,
} from "./attachmentInsertVerify.js";

const varint = (value: number): number[] => {
  const out: number[] = [];
  while (value > 0x7f) {
    out.push((value & 0x7f) | 0x80);
    value >>>= 7;
  }
  out.push(value);
  return out;
};
const n = (field: number, value: number) => Buffer.from([...varint(field * 8), ...varint(value)]);
const b = (field: number, value: Buffer | string) => {
  const bytes = Buffer.from(value);
  return Buffer.concat([Buffer.from([...varint(field * 8 + 2), ...varint(bytes.length)]), bytes]);
};
/** A gzipped note body: a title line, then one attachment character per id. */
const body = (ids: string[]) => {
  const text = `Title\n${"\ufffc".repeat(ids.length)}`;
  const runs = [
    Buffer.concat([n(1, 6)]),
    ...ids.map((id) =>
      Buffer.concat([n(1, 1), b(12, Buffer.concat([b(1, id), b(2, "com.adobe.pdf")]))])
    ),
  ];
  return gzipSync(b(2, b(3, Buffer.concat([b(2, text), ...runs.map((r) => b(5, r))]))));
};

const STORE = "ABCDEF-1234";
const NOTE = `x-coredata://${STORE}/ICNote/p1`;
const PDF = Buffer.from("%PDF-1.4 synthetic fixture bytes\n%%EOF\n");
const expected: ExpectedAttachment = {
  uti: "com.adobe.pdf",
  size: PDF.length,
  sha256: createHash("sha256").update(PDF).digest("hex"),
};

let dir: string;
let db: string;
let container: string;
const sql = (statements: string) => execFileSync("/usr/bin/sqlite3", [db, statements]);

/** Stage one attachment row with its media row and, optionally, its file. */
function addAttachment(
  pk: number,
  opts: {
    identifier?: string;
    uti?: string;
    created?: number;
    note?: number;
    parent?: number | null;
    deleted?: number;
    file?: Buffer | null;
  } = {}
) {
  const identifier = opts.identifier ?? `ATT-${pk}`;
  const mediaPk = pk + 1000;
  const mediaId = `MEDIA-${pk}`;
  sql(
    `INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZNOTE, ZMEDIA, ZPARENTATTACHMENT, ZFILENAME, ZCREATIONDATE, ZMARKEDFORDELETION) VALUES ` +
      `(${pk}, 5, '${identifier}', '${opts.uti ?? "com.adobe.pdf"}', ${opts.note ?? 1}, ${mediaPk}, ${opts.parent ?? "NULL"}, NULL, ${opts.created ?? coreDataNow()}, ${opts.deleted ?? 0});` +
      `INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZFILENAME, ZGENERATION1) VALUES (${mediaPk}, 11, '${mediaId}', 'file-${pk}.pdf', '1_GEN');`
  );
  if (opts.file !== null) {
    const folder = join(container, "Accounts", "ACCT-1", "Media", mediaId, "1_GEN");
    mkdirSync(folder, { recursive: true });
    writeFileSync(join(folder, `file-${pk}.pdf`), opts.file ?? PDF);
  }
  return identifier;
}
const setBody = (ids: string[] | null) =>
  sql(
    `UPDATE ZICNOTEDATA SET ZDATA = ${ids ? `X'${body(ids).toString("hex")}'` : "NULL"} WHERE ZNOTE = 1;`
  );

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), "attachment-insert-verify-"));
  db = join(dir, "NoteStore.sqlite");
  container = join(dir, "container");
});
afterAll(() => rmSync(dir, { recursive: true, force: true }));

beforeEach(() => {
  rmSync(db, { force: true });
  rmSync(container, { recursive: true, force: true });
  mkdirSync(join(container, "Accounts", "ACCT-1", "Media"), { recursive: true });
  sql(
    "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR);" +
      "INSERT INTO Z_PRIMARYKEY VALUES (5,'ICAttachment'),(7,'ICAccount'),(11,'ICMedia'),(12,'ICNote');" +
      "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER VARCHAR, " +
      "ZTYPEUTI VARCHAR, ZNOTE INTEGER, ZMEDIA INTEGER, ZPARENTATTACHMENT INTEGER, ZFILENAME VARCHAR, " +
      "ZCREATIONDATE TIMESTAMP, ZGENERATION1 VARCHAR, ZACCOUNT3 INTEGER, ZMARKEDFORDELETION INTEGER);" +
      "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB);" +
      "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER) VALUES (2, 7, 'ACCT-1');" +
      "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZACCOUNT3) VALUES (1, 12, 'NOTE-1', 2);" +
      "INSERT INTO ZICNOTEDATA (ZNOTE, ZDATA) VALUES (1, NULL);"
  );
  // One attachment the note already had before the write.
  addAttachment(10, { created: coreDataNow() - 3600 });
  setBody(["ATT-10"]);
});

const snapshot = (): StoreAttachmentSnapshot => snapshotStoreAttachments(NOTE, db)!;
const verify = (snap: StoreAttachmentSnapshot, extra: Record<string, unknown> = {}) =>
  verifyAttachmentInStore(NOTE, snap, expected, {
    dbPath: db,
    containerDir: container,
    timeoutMs: 0,
    ...extra,
  });

describe("snapshotStoreAttachments (real sqlite3)", () => {
  it("records the note's existing attachment keys and the time", () => {
    const snap = snapshot();
    expect(snap).toMatchObject({ notePk: 1, attachmentPks: [10] });
    expect(Math.abs(snap.takenAt - coreDataNow())).toBeLessThan(5);
  });

  it("returns null when the store or the note cannot be read", () => {
    expect(snapshotStoreAttachments(NOTE, join(dir, "missing.sqlite"))).toBeNull();
    expect(snapshotStoreAttachments(`x-coredata://${STORE}/ICNote/p999`, db)).toBeNull();
    expect(snapshotStoreAttachments("not-a-note-id", db)).toBeNull();
  });
});

describe("readStoreAttachments (real sqlite3)", () => {
  it("reads live rows with media and account, skipping tombstones and other notes", () => {
    addAttachment(20, { deleted: 1 });
    addAttachment(30, { note: 99 });
    const read = readStoreAttachments(NOTE, db);
    expect(read.candidates.map((c) => c.pk)).toEqual([10]);
    expect(read.candidates[0]).toMatchObject({
      identifier: "ATT-10",
      uti: "com.adobe.pdf",
      mediaIdentifier: "MEDIA-10",
      mediaFilename: "file-10.pdf",
      mediaGeneration: "1_GEN",
      accountIdentifier: "ACCT-1",
      parentPk: null,
    });
    expect(read.bodyAttachmentIds).toEqual(["ATT-10"]);
  });

  it("reports a null body when the note data is missing or does not decode", () => {
    setBody(null);
    expect(readStoreAttachments(NOTE, db).bodyAttachmentIds).toBeNull();
    sql("UPDATE ZICNOTEDATA SET ZDATA = X'0102' WHERE ZNOTE = 1;");
    expect(readStoreAttachments(NOTE, db).bodyAttachmentIds).toBeNull();
  });

  it("refuses a store without the attachment columns", () => {
    const bare = join(dir, "bare.sqlite");
    rmSync(bare, { force: true });
    execFileSync("/usr/bin/sqlite3", [
      bare,
      "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER);",
    ]);
    expect(() => readStoreAttachments(NOTE, bare)).toThrow(/lacks the attachment columns/);
  });

  it("builds SQL that degrades missing optional columns to NULL", () => {
    const text = buildStoreAttachmentSql(new Set(["ZIDENTIFIER", "ZNOTE"]));
    expect(text).toContain("LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON 0");
    expect(text).toContain("'accountIdentifier', NULL");
    expect(text).toContain("'created', NULL");
    expect(text).toContain("a.ZNOTE = @note");
    expect(text).not.toMatch(/ZNOTE = \d/);
  });
});

describe("verifyAttachmentInStore (real sqlite3)", () => {
  it("verifies exactly one new matching attachment", () => {
    const snap = snapshot();
    const id = addAttachment(20);
    setBody(["ATT-10", id]);
    const outcome = verify(snap);
    expect(outcome.status).toBe("verified");
    if (outcome.status !== "verified") return;
    expect(outcome.candidate.pk).toBe(20);
    expect(outcome.media).toMatchObject({ size: PDF.length, sha256: expected.sha256 });
    expect(outcome.media.path).toContain(join("Accounts", "ACCT-1", "Media", "MEDIA-20"));
  });

  it("accepts a returned id that names the same row and refuses one that does not", () => {
    const snap = snapshot();
    setBody(["ATT-10", addAttachment(20)]);
    expect(verify(snap, { returnedId: `x-coredata://${STORE}/ICAttachment/p20` }).status).toBe(
      "verified"
    );
    expect(verify(snap, { returnedId: `x-coredata://${STORE}/ICAttachment/p21` }).status).toBe(
      "id-mismatch"
    );
  });

  it("verifies without the body check when the body does not decode", () => {
    const snap = snapshot();
    addAttachment(20);
    setBody(null);
    expect(verify(snap).status).toBe("verified");
  });

  it("reports absent when no new row appeared", () => {
    expect(verify(snapshot()).status).toBe("absent");
  });

  it("ignores rows that predate the snapshot, are tombstoned, or are gallery children", () => {
    const snap = snapshot();
    addAttachment(20, { created: snap.takenAt - 60 });
    addAttachment(21, { deleted: 1 });
    addAttachment(22, { parent: 10 });
    expect(verify(snap).status).toBe("absent");
  });

  it("stays uncertain when two new rows appeared", () => {
    const snap = snapshot();
    setBody(["ATT-10", addAttachment(20), addAttachment(21)]);
    expect(verify(snap)).toMatchObject({ status: "ambiguous", reason: /2 new attachment rows/ });
  });

  it("stays uncertain on a type, body, or byte mismatch", () => {
    const snap = snapshot();
    addAttachment(20, { uti: "public.png" });
    setBody(["ATT-10", "ATT-20"]);
    expect(verify(snap).status).toBe("type-mismatch");

    sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTYPEUTI = 'com.adobe.pdf' WHERE Z_PK = 20;");
    setBody(["ATT-10"]);
    expect(verify(snap).status).toBe("not-in-body");

    setBody(["ATT-10", "ATT-20"]);
    writeFileSync(
      join(container, "Accounts", "ACCT-1", "Media", "MEDIA-20", "1_GEN", "file-20.pdf"),
      Buffer.from("different bytes")
    );
    expect(verify(snap).status).toBe("media-missing");
  });

  it("polls through database lag within the bound", () => {
    const snap = snapshot();
    let clock = 0;
    const sleep = vi.fn(() => {
      clock += 100;
      // The row lands on the second poll and the body catches up on the third.
      if (sleep.mock.calls.length === 1) addAttachment(20);
      if (sleep.mock.calls.length === 2) setBody(["ATT-10", "ATT-20"]);
    });
    const outcome = verify(snap, { timeoutMs: 1000, intervalMs: 100, sleep, now: () => clock });
    expect(outcome.status).toBe("verified");
    expect(sleep).toHaveBeenCalledTimes(2);
  });

  it("gives up at the bound and never waits on an ambiguous result", () => {
    const snap = snapshot();
    let clock = 0;
    const sleep = vi.fn(() => {
      clock += 100;
    });
    expect(verify(snap, { timeoutMs: 350, intervalMs: 100, sleep, now: () => clock }).status).toBe(
      "absent"
    );
    expect(sleep).toHaveBeenCalledTimes(4);

    sleep.mockClear();
    addAttachment(20);
    addAttachment(21);
    expect(verify(snap, { timeoutMs: 350, sleep, now: () => clock }).status).toBe("ambiguous");
    expect(sleep).not.toHaveBeenCalled();
  });

  it("waits with the default blocking sleep", () => {
    // Long enough that at least one wait happens even when each sqlite3 read is slow.
    const started = Date.now();
    expect(verify(snapshot(), { timeoutMs: 400, intervalMs: 20 }).status).toBe("absent");
    expect(Date.now() - started).toBeGreaterThanOrEqual(400);
  });

  it("ends as absent when the store becomes unreadable", () => {
    const snap = snapshot();
    const outcome = verifyAttachmentInStore(NOTE, snap, expected, {
      dbPath: join(dir, "missing.sqlite"),
      containerDir: container,
      timeoutMs: 0,
    });
    expect(outcome).toMatchObject({ status: "absent", reason: /could not be read/ });
  });
});
