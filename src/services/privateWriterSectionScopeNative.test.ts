/** Production scope/save functions on an original generic in-memory model.
 * dlopen is blocked; no installed Notes model, Notes store, or live API is used.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { packageRoot } from "./privateHelper.js";
import { writerCompileArguments } from "./privateWriterBuild.js";

const MACOS = process.platform === "darwin";
let directory: string;
let binary: string;

beforeAll(() => {
  if (!MACOS) return;
  directory = mkdtempSync(join(tmpdir(), "private-writer-section-scope-"));
  binary = join(directory, "fixture");
  execFileSync(
    "/usr/bin/xcrun",
    writerCompileArguments(
      join(packageRoot(), "test/native/private-writer-section-scope.m"),
      binary,
      "section-scope-fixture"
    ).map((arg) => (arg === "-O2" ? "-O0" : arg)),
    { encoding: "utf8", timeout: 120_000 }
  );
}, 150_000);

afterAll(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
});

describe.skipIf(!MACOS)("synthetic native section-link target scope", () => {
  it("checks both subjects and rolls back refused notes, identifiers, and inline rows", () => {
    const result = JSON.parse(
      execFileSync(binary, [], {
        encoding: "utf8",
        timeout: 20_000,
        env: { PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: directory },
      })
    ) as { frameworkLoaded: boolean; passed: string[] };
    expect(result.frameworkLoaded).toBe(false);
    expect(result.passed).toEqual([
      "self-link policies are explicit and equivalent",
      "receiver guards never infer a target policy",
      "unminted target outside ancestor refuses before mutation",
      "minted target reparent drift rolls back both notes and chip",
      "unique target outside ancestor refuses before mutation",
      "unique target reparent drift rolls back both notes and chip",
      "target-only exact-folder guard refuses atomically",
      "unchanged unique target direct-folder drift is reread",
      "missing target ancestor refuses atomically",
      "deleted target ancestor refuses atomically",
      "cycle target ancestor refuses atomically",
      "deleted forbidden target id refuses atomically",
      "valid independent policies pass the guarded save",
    ]);
  });
});
