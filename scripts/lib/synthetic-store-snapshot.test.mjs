import assert from "node:assert/strict";
import {
  chmodSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { snapshotSyntheticTree, summarizeSyntheticTree } from "./synthetic-store-snapshot.mjs";

const fixture = () => mkdtempSync(join(tmpdir(), "synthetic-snapshot-"));

test("snapshot detects changed bytes, file names, modes and additional directories", () => {
  const root = fixture();
  try {
    const path = join(root, "store");
    writeFileSync(path, "AAAA", { mode: 0o600 });
    const baseline = snapshotSyntheticTree(root);
    const summary = summarizeSyntheticTree(baseline);
    assert.equal(summary.files, 1);
    assert.equal(summary.directories, 1);
    assert.equal(summary.bytes, 4);
    assert.equal(JSON.stringify(summary).includes("store"), false);
    assert.deepEqual(snapshotSyntheticTree(root), baseline);
    writeFileSync(path, "BBBB");
    assert.notDeepEqual(snapshotSyntheticTree(root), baseline);
    writeFileSync(path, "AAAA");
    chmodSync(path, 0o400);
    assert.notDeepEqual(snapshotSyntheticTree(root), baseline);
    chmodSync(path, 0o600);
    mkdirSync(join(root, "Media"));
    assert.notDeepEqual(snapshotSyntheticTree(root), baseline);
    rmSync(join(root, "Media"), { recursive: true });
    writeFileSync(join(root, "store-wal"), "AAAA");
    assert.notDeepEqual(snapshotSyntheticTree(root), baseline);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("excludes only exact evidence filenames and still detects materialized files", () => {
  const root = fixture();
  try {
    writeFileSync(join(root, "store"), "fixture");
    const exclude = new Set(["report.json", "writer-1.json"]);
    const baseline = snapshotSyntheticTree(root, exclude);
    writeFileSync(join(root, "report.json"), "evidence");
    writeFileSync(join(root, "writer-1.json"), "response");
    assert.deepEqual(snapshotSyntheticTree(root, exclude), baseline);
    writeFileSync(join(root, "writer-1.json.extra"), "unexpected");
    assert.notDeepEqual(snapshotSyntheticTree(root, exclude), baseline);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("refuses symbolic and hard links without reading their targets", () => {
  for (const link of [symlinkSync, linkSync]) {
    const root = fixture();
    try {
      writeFileSync(join(root, "target"), "synthetic");
      link(join(root, "target"), join(root, "link"));
      assert.throws(() => snapshotSyntheticTree(root), /link or non-regular file/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }
});
