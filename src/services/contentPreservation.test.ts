/** Pure Foundation/AppKit fixture; never imports the writer or loads NotesShared. */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const MACOS = process.platform === "darwin";
let directory: string;
let binary: string;

beforeAll(() => {
  if (!MACOS) return;
  directory = mkdtempSync(join(tmpdir(), "notes-content-preservation-"));
  binary = join(directory, "fixture");
  execFileSync(
    "/usr/bin/xcrun",
    [
      "clang",
      "-fobjc-arc",
      "-Wall",
      "-Wextra",
      "-framework",
      "Foundation",
      "-framework",
      "AppKit",
      join(root, "test/native/content-preservation.m"),
      "-o",
      binary,
    ],
    { encoding: "utf8", timeout: 120_000 }
  );
}, 150_000);

afterAll(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
});

describe.skipIf(!MACOS)("pure untouched content preservation", () => {
  it("detects attribute and identity loss and accepts explicit table and insertion deltas", () => {
    const result = JSON.parse(
      execFileSync(binary, [], {
        encoding: "utf8",
        timeout: 20_000,
        env: { PATH: process.env.PATH, HOME: directory, TMPDIR: directory },
      })
    );
    expect(result.fixture).toBe("pure-attributed-text");
    expect(result.checks).toBeGreaterThanOrEqual(90);
  });
  it.each(["hidden-ivar", "extra-property", "getter-abi", "subclass"])(
    "refuses the unsupported %s native layout",
    (mode) => {
      const result = JSON.parse(
        execFileSync(binary, [mode], {
          encoding: "utf8",
          timeout: 20_000,
          env: { PATH: process.env.PATH, HOME: directory, TMPDIR: directory },
        })
      );
      expect(result.checks).toBeGreaterThanOrEqual(3);
    }
  );
});
