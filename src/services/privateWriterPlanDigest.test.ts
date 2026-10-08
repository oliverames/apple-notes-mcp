/**
 * Exercise the real native plan digest without loading NotesShared, opening a
 * store, or dispatching an action. Native compilation is explicitly opt-in.
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { packageRoot } from "./privateHelper.js";
import { WRITER_SOURCE_RELATIVE } from "./privateWriter.js";
import { writerCompileArguments } from "./privateWriterBuild.js";

const RUN_NATIVE =
  process.platform === "darwin" && process.env.APPLE_NOTES_MCP_RUN_NATIVE_TESTS === "1";
let directory: string;
let executable: string;

beforeAll(() => {
  if (!RUN_NATIVE) return;
  directory = mkdtempSync(join(tmpdir(), "private-plan-digest-"));
  executable = join(directory, "digest");
  const source = join(directory, "digest.m");
  const writer = join(packageRoot(), WRITER_SOURCE_RELATIVE);
  writeFileSync(
    source,
    `#define main UncalledWriterMain
#include ${JSON.stringify(writer)}
#undef main
int main(void) {
  @autoreleasepool {
    NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
    NSString *digest = PlanDigest(@"D629A948-0C61-43BA-8FDE-04CD6DED38C7", request[@"snapshotRevision"] ?: @"r1:fixture", @[], NO, @[], request);
    printf("%s\\n", digest.UTF8String);
  }
  return 0;
}
`
  );
  execFileSync("/usr/bin/xcrun", writerCompileArguments(source, executable, "fixture"), {
    stdio: "pipe",
    timeout: 120_000,
  });
}, 150_000);

afterAll(() => {
  if (directory) rmSync(directory, { recursive: true, force: true });
});

/** Spawn a pure digest calculation with no private opt-ins or store path. */
function digest(request: Record<string, unknown>) {
  return execFileSync(executable, [], {
    input: JSON.stringify(request),
    encoding: "utf8",
    env: { PATH: process.env.PATH },
    timeout: 10_000,
  }).trim();
}

const folder = "x-coredata://AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/ICFolder/p1";
const other = "x-coredata://AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/ICFolder/p2";

describe.skipIf(!RUN_NATIVE)("native edit plan scope binding", () => {
  it("versions the stronger contract and produces a stable digest", () => {
    expect(digest({})).toMatch(/^p3:[a-f0-9]{64}$/u);
    expect(digest({ ifFolderId: folder })).toBe(digest({ ifFolderId: folder }));
  });

  it("binds the revision of the snapshot used to construct the plan", () => {
    expect(digest({ snapshotRevision: "r1:before" })).not.toBe(
      digest({ snapshotRevision: "r1:after" })
    );
  });

  it.each(["ifFolderId", "ifAncestorFolderId"])("binds adding, changing and removing %s", (key) => {
    const guarded = digest({ [key]: folder });
    expect(guarded).not.toBe(digest({}));
    expect(guarded).not.toBe(digest({ [key]: other }));
  });

  it("binds the complete forbidden-ancestor list", () => {
    const guarded = digest({ forbiddenAncestorFolderIds: [folder, other] });
    expect(guarded).not.toBe(digest({}));
    expect(guarded).not.toBe(digest({ forbiddenAncestorFolderIds: [folder] }));
    expect(guarded).not.toBe(digest({ forbiddenAncestorFolderIds: [other] }));
  });

  it("includes simultaneous scope conditions regardless of JSON key order", () => {
    const request = {
      ifFolderId: folder,
      ifAncestorFolderId: other,
      forbiddenAncestorFolderIds: [other],
    };
    expect(digest(request)).toBe(
      digest({
        forbiddenAncestorFolderIds: [other],
        ifAncestorFolderId: other,
        ifFolderId: folder,
      })
    );
    expect(digest(request)).not.toBe(digest({ ifFolderId: folder, ifAncestorFolderId: other }));
  });

  it("excludes plan/apply transport fields so the identical request can apply", () => {
    expect(digest({ ifFolderId: folder, dryRun: true })).toBe(
      digest({
        ifFolderId: folder,
        dryRun: false,
        ifRevision: "r1:fixture",
        ifPlanDigest: "ignored",
      })
    );
  });
});
