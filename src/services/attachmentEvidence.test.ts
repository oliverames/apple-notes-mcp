/** Pure Foundation fixture: no writer, NotesShared, store, opt-ins or preferences. */
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { packageRoot } from "./privateHelper.js";

const RUN = process.platform === "darwin";
let directory: string;
let executable: string;
beforeAll(() => {
  if (!RUN) return;
  directory = mkdtempSync(join(tmpdir(), "attachment-evidence-"));
  executable = join(directory, "fixture");
  execFileSync(
    "/usr/bin/xcrun",
    [
      "clang",
      "-fobjc-arc",
      "-Wall",
      "-Wextra",
      "-framework",
      "Foundation",
      join(packageRoot(), "test/native/attachment-evidence.m"),
      "-o",
      executable,
    ],
    { stdio: "pipe", timeout: 120_000 }
  );
}, 150_000);
afterAll(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
});
function fixture(request: Record<string, unknown>): {
  token: string;
  files: Array<Record<string, unknown>>;
  dates: unknown[];
  numbers: unknown[];
  unsupported: boolean;
} {
  return JSON.parse(
    execFileSync(executable, [], {
      input: JSON.stringify(request),
      encoding: "utf8",
      env: { PATH: process.env.PATH },
      timeout: 10_000,
    })
  );
}

describe.skipIf(!RUN)("complete descriptor-bound attachment evidence", () => {
  it("consumes a small cumulative budget and refuses a later file, without a size/time fallback", () => {
    const result = fixture({ budget: 8, files: [{ text: "123456" }, { text: "789" }] });
    expect(result.files[0]).toMatchObject({ bytes: 6, error: 0, remainingBudget: 2, closed: 1 });
    expect(result.files[1]).toEqual({ error: 4, remainingBudget: 2, closed: 1 });
  });
  it("accepts the exact boundary and zero-byte regular files", () => {
    const result = fixture({ budget: 4, files: [{ text: "abcd" }, { text: "" }] });
    expect(result.files).toEqual([
      expect.objectContaining({ bytes: 4, remainingBudget: 0, error: 0 }),
      expect.objectContaining({ bytes: 0, remainingBudget: 0, error: 0 }),
    ]);
  });
  it("distinguishes changed equal-length bytes with identical size/mtime", () => {
    const result = fixture({ files: [{ text: "abcd" }, { text: "wxyz" }] });
    expect(result.files[0].sha256).not.toBe(result.files[1].sha256);
  });
  it.each([
    ["missing", 1],
    ["nonregular", 1],
    ["symlink", 1],
    ["unreadable", 2],
    ["read-error", 2],
    ["drift", 3],
    ["replaced", 3],
  ])("refuses %s evidence and keeps the budget", (mode, code) => {
    const [result] = fixture({ budget: 4, files: [{ text: "abcd", mode }] }).files;
    expect(result).toMatchObject({ error: code, remainingBudget: 4 });
    expect(result).not.toHaveProperty("sha256");
  });
  it.each([3, 5])("refuses changed read length against descriptor size %i", (size) => {
    expect(fixture({ files: [{ text: "abcd", size }] }).files[0]).toMatchObject({
      error: 3,
      closed: 1,
      remainingBudget: 8,
    });
  });
});

describe.skipIf(!RUN)("complete attachment snapshot receipt", () => {
  const before = {
    "attachment:visible": "row",
    "media:visible": "media",
    "file:visible": "4:abcd",
    "inline:tag": "tag",
    "attachment:orphan": "hidden",
    glyphs: "visible,tag",
    "version:attachment:visible": 2,
  };
  const token = (snapshot: object) => fixture({ snapshot }).token;
  it("versions its policy and ignores dictionary enumeration order", () => {
    expect(token(before)).toMatch(/^a1:[a-f0-9]{64}$/u);
    expect(token(before)).toBe(token(Object.fromEntries(Object.entries(before).reverse())));
  });
  it.each(Object.keys(before))("binds %s independent of the note r1 token", (key) => {
    const changed = { ...before, [key]: "changed" };
    expect(token(changed)).not.toBe(token(before));
  });
  it("binds added and removed hidden/orphan rows", () => {
    const removed = { ...before } as Record<string, unknown>;
    delete removed["attachment:orphan"];
    expect(token(removed)).not.toBe(token(before));
    expect(token({ ...before, "attachment:other": "another" })).not.toBe(token(before));
  });
  it("keeps submicrosecond dates and neighboring floating-point values distinct", () => {
    const result = fixture({ dates: [1, 1.0000001], numbers: [true, 1, 1.0000000000000002] });
    expect(result.dates[0]).not.toEqual(result.dates[1]);
    expect(result.numbers[1]).not.toEqual(result.numbers[2]);
    expect(result.unsupported).toBe(true);
  });
});
