/** Pure Foundation fixture: no writer dispatch, NotesShared or Notes store. */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { writerSourceSha256 } from "./privateWriterSources.js";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const MACOS = process.platform === "darwin";
let directory: string;
let binary: string;

beforeAll(() => {
  if (!MACOS) return;
  directory = mkdtempSync(join(tmpdir(), "notes-legacy-projection-"));
  binary = join(directory, "fixture");
  execFileSync(
    "/usr/bin/xcrun",
    [
      "clang",
      "-fobjc-arc",
      "-Wall",
      "-Wextra",
      "-Wno-unused-function",
      "-framework",
      "Foundation",
      "-framework",
      "AppKit",
      join(root, "test/native/legacy-attribute-projection.m"),
      "-o",
      binary,
    ],
    { encoding: "utf8", timeout: 120_000 }
  );
}, 150_000);

afterAll(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
});

describe("legacy exact getter projection wiring", () => {
  it("binds the new transitive header in packaged source integrity", () => {
    const closureDirectory = mkdtempSync(join(tmpdir(), "notes-legacy-closure-"));
    try {
      for (const name of [
        "apple-notes-private-writer.m",
        "legacy-attribute-projection.h",
        "content-preservation.h",
        "attachment-evidence.h",
        "native-attribute-layouts.h",
        "public-font-preservation.h",
      ])
        writeFileSync(
          join(closureDirectory, name),
          readFileSync(join(root, "native/private-helper", name))
        );
      const deps = {
        sourcePath: join(closureDirectory, "apple-notes-private-writer.m"),
        readFile: readFileSync,
        exists: existsSync,
      };
      const before = writerSourceSha256(deps);
      const header = join(closureDirectory, "legacy-attribute-projection.h");
      writeFileSync(header, readFileSync(header, "utf8") + "\n// changed exact projection\n");
      expect(writerSourceSha256(deps)).not.toBe(before);
    } finally {
      rmSync(closureDirectory, { recursive: true, force: true });
    }
    const writer = readFileSync(
      join(root, "native/private-helper/apple-notes-private-writer.m"),
      "utf8"
    );
    expect(writer).toContain("return ANMLegacyCanonicalValue(value);");
    expect(writer).toContain(
      "return ANMLegacyCanonicalRuns(text, range, ignoreTimestamp, kTimestampKey);"
    );
    expect(writer).not.toContain('stringWithFormat:@"t:%.6f"');
    expect(writer).not.toContain('stringWithFormat:@"f:%@|%.4f|%u"');
  });
});

describe.skipIf(!MACOS)("legacy exact getter projection", () => {
  it("detects one-ULP drift, delimiter collisions, checklist/range changes and wrong getter ABI", () => {
    const result = JSON.parse(
      execFileSync(binary, [], {
        encoding: "utf8",
        timeout: 20_000,
        env: {
          PATH: process.env.PATH,
          HOME: process.env.HOME,
          CFFIXED_USER_HOME: directory,
          TMPDIR: directory,
        },
      })
    );
    expect(result).toMatchObject({
      fixture: "pure-legacy-getter-projection",
      notesSharedLoaded: false,
      storesOpened: 0,
    });
    expect(result.checks).toBe(51);
  });
});
