import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { equivalentFixtureRootPaths, validateFixtureRootPath } from "./synthetic-native-layout-path.mjs";

test("temporary aliases accept only the same direct public-fixture child", () => {
  const privatePath = "/private/tmp/apple-notes-synthetic-fixture-Ab12Cd";
  const shortPath = "/tmp/apple-notes-synthetic-fixture-Ab12Cd";
  for (const a of [privatePath, shortPath]) for (const b of [privatePath, shortPath])
    assert.equal(equivalentFixtureRootPaths(a, b), true);
  for (const outside of ["/Users/test/apple-notes-synthetic-fixture-Ab12Cd", "/private/tmp/other-Ab12Cd",
    privatePath + "/nested", "/tmp/apple-notes-synthetic-fixture-../outside", "/tmp/apple-notes-synthetic-fixture-Other"])
    assert.equal(equivalentFixtureRootPaths(privatePath, outside), false);
});

test("root symlinks and nonfixture roots are rejected without traversal", () => {
  const root = mkdtempSync("/private/tmp/apple-notes-synthetic-fixture-");
  const outside = mkdtempSync("/private/tmp/layout-boundary-negative-");
  const link = join(outside, "fixture-link");
  try {
    assert.ok(validateFixtureRootPath(root).endsWith(root.split("/").at(-1)));
    symlinkSync(root, link, "dir");
    assert.throws(() => validateFixtureRootPath(link));
    assert.throws(() => validateFixtureRootPath(outside));
  } finally {
    rmSync(outside, { recursive: true });
    rmSync(root, { recursive: true });
  }
});

test("native equivalent boundary uses POSIX canonical paths and rejects root symlinks", () => {
  const source = readFileSync(new URL("../../test/native/synthetic-native-layout-extended.m", import.meta.url), "utf8");
  assert.ok(source.includes("EquivalentFixtureRoots(root, Metadata(resolvedRoot))"));
  assert.ok(source.includes("realpath(root.fileSystemRepresentation, resolvedRoot)"));
  assert.ok(source.includes("lstat(root.fileSystemRepresentation, &rootStat)"));
  assert.ok(source.includes("S_ISDIR(rootStat.st_mode)"));
  assert.ok(!source.includes("stringByResolvingSymlinksInPath"));
  assert.ok(source.includes('[@[ @"/tmp", @"/private/tmp" ] containsObject:parent]'));
});
