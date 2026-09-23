/**
 * Unit tests for the database fallback's decision rules. The store reads are
 * covered against real sqlite3 in attachmentInsertVerify.sqlite.test.ts.
 */
import { afterAll, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  coreDataNow,
  decideStoreVerification,
  digestFile,
  expectedUtiForName,
  matchingMedia,
  type ExpectedAttachment,
  type MediaEvidence,
  type StoreAttachmentCandidate,
  type StoreAttachmentRead,
} from "./attachmentInsertVerify.js";

const dir = mkdtempSync(join(tmpdir(), "attachment-insert-decide-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

const snapshot = { notePk: 1, attachmentPks: [10], takenAt: 1000 };
const expected: ExpectedAttachment = { uti: "com.adobe.pdf", size: 4, sha256: "abc" };
const evidence: MediaEvidence = { path: "/media/file.pdf", size: 4, sha256: "abc" };
const row = (pk: number, extra: Partial<StoreAttachmentCandidate> = {}) =>
  ({
    pk,
    identifier: `ATT-${pk}`,
    uti: "com.adobe.pdf",
    parentPk: null,
    filename: null,
    created: 1001,
    mediaIdentifier: `MEDIA-${pk}`,
    mediaFilename: "file.pdf",
    mediaGeneration: "1_GEN",
    fallbackImageGeneration: null,
    fallbackPdfGeneration: null,
    accountIdentifier: "ACCT",
    ...extra,
  }) as StoreAttachmentCandidate;
const read = (candidates: StoreAttachmentCandidate[], body: string[] | null = null) =>
  ({ candidates, bodyAttachmentIds: body }) as StoreAttachmentRead;
const decide = (
  r: StoreAttachmentRead,
  exp: ExpectedAttachment = expected,
  media: MediaEvidence | null = evidence,
  returnedId?: string
) => decideStoreVerification(r, snapshot, exp, () => media, returnedId);

describe("decideStoreVerification", () => {
  it("verifies one new row that matches type, body, and bytes", () => {
    const outcome = decide(read([row(10), row(11)], ["ATT-10", "att-11"]));
    expect(outcome).toMatchObject({ status: "verified", candidate: { pk: 11 }, media: evidence });
  });

  it("treats rows in the snapshot, without a date, or older than the skew as not new", () => {
    expect(decide(read([row(10)])).status).toBe("absent");
    expect(decide(read([row(11, { created: null })])).status).toBe("absent");
    expect(decide(read([row(11, { created: 997 })])).status).toBe("absent");
    // Within the two-second skew still counts as new.
    expect(decide(read([row(11, { created: 998.5 })])).status).toBe("verified");
  });

  it("ignores child rows but refuses a second new top-level row", () => {
    expect(decide(read([row(11), row(12, { parentPk: 11 })])).status).toBe("verified");
    expect(decide(read([row(11), row(12)])).status).toBe("ambiguous");
  });

  it("refuses a returned id for another row", () => {
    expect(
      decide(read([row(11)]), expected, evidence, "x-coredata://S/ICAttachment/p11").status
    ).toBe("verified");
    expect(
      decide(read([row(11)]), expected, evidence, "x-coredata://S/ICAttachment/p111").status
    ).toBe("id-mismatch");
  });

  it("checks the type exactly when known and excludes Notes' own objects otherwise", () => {
    expect(decide(read([row(11, { uti: "public.png" })])).status).toBe("type-mismatch");
    expect(decide(read([row(11, { uti: null })])).status).toBe("type-mismatch");
    const unknown = { ...expected, uti: null };
    expect(decide(read([row(11, { uti: "com.example.data" })]), unknown).status).toBe("verified");
    expect(decide(read([row(11, { uti: "com.apple.notes.table" })]), unknown).status).toBe(
      "type-mismatch"
    );
  });

  it("requires the body to reference the row when the body decodes", () => {
    expect(decide(read([row(11)], ["ATT-10"])).status).toBe("not-in-body");
    expect(decide(read([row(11)], null)).status).toBe("verified");
  });

  it("requires byte-identical media", () => {
    expect(decide(read([row(11)]), expected, null).status).toBe("media-missing");
  });
});

describe("helpers", () => {
  it("maps known extensions to UTIs, case-insensitively", () => {
    expect(expectedUtiForName("Report.PDF")).toBe("com.adobe.pdf");
    expect(expectedUtiForName("a.jpeg")).toBe("public.jpeg");
    expect(expectedUtiForName("a.bin")).toBeNull();
    expect(expectedUtiForName("noext")).toBeNull();
  });

  it("converts to Core Data time", () => {
    expect(coreDataNow(Date.UTC(2001, 0, 1, 0, 0, 10))).toBe(10);
  });

  it("digests regular files only, without following links", () => {
    const file = join(dir, "file.bin");
    writeFileSync(file, "data");
    expect(digestFile(file)).toEqual({
      path: file,
      size: 4,
      sha256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
    });
    const link = join(dir, "link.bin");
    symlinkSync(file, link);
    expect(digestFile(link)).toBeNull();
    expect(digestFile(dir)).toBeNull();
    expect(digestFile(join(dir, "missing"))).toBeNull();
    expect(digestFile(file, 3)).toBeNull();
  });

  it("finds media only under the account's Media folder", () => {
    const container = join(dir, "container");
    const account = join(container, "Accounts", "ACCT");
    mkdirSync(join(account, "Media", "MEDIA-11", "1_GEN"), { recursive: true });
    mkdirSync(join(account, "FallbackPDFs", "ATT-11", "1_GEN"), { recursive: true });
    writeFileSync(join(account, "Media", "MEDIA-11", "1_GEN", "file.pdf"), "nope");
    writeFileSync(join(account, "FallbackPDFs", "ATT-11", "1_GEN", "FallbackPDF.pdf"), "data");
    const want: ExpectedAttachment = {
      uti: null,
      size: 4,
      sha256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
    };
    const candidate = row(11, { fallbackPdfGeneration: "1_GEN" });
    // The fallback rendering has the right bytes but is never accepted.
    expect(matchingMedia(candidate, want, container)).toBeNull();
    writeFileSync(join(account, "Media", "MEDIA-11", "1_GEN", "file.pdf"), "data");
    expect(matchingMedia(candidate, want, container)?.path).toContain(join("Media", "MEDIA-11"));
    expect(matchingMedia(candidate, want, join(dir, "no-container"))).toBeNull();
  });
});
