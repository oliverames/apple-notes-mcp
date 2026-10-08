// Exact, quiescent scratch-tree evidence. Never follow links or open user paths.
import { createHash } from "node:crypto";
import { lstatSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { readSingleLinkFile } from "./synthetic-fixture-files.mjs";

export const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

/** Snapshot all scratch entries except the caller's exact evidence filenames. */
export function snapshotSyntheticTree(root, excluded = new Set()) {
  const entries = [];
  function visit(relative) {
    if (excluded.has(relative)) return;
    const path = relative ? join(root, relative) : root;
    const stat = lstatSync(path);
    if (stat.isDirectory()) {
      entries.push({ path: relative, kind: "directory", mode: stat.mode & 0o777 });
      for (const name of readdirSync(path).sort()) visit(relative ? `${relative}/${name}` : name);
    } else if (stat.isFile() && stat.nlink === 1) {
      const bytes = readSingleLinkFile(path);
      entries.push({
        path: relative,
        kind: "file",
        mode: stat.mode & 0o777,
        bytes: bytes.length,
        sha256: sha256(bytes),
      });
    } else {
      throw new Error("Synthetic scratch tree contains a link or non-regular file");
    }
  }
  visit("");
  return entries;
}

/** Share only an aggregate hash and counts; native filenames remain private. */
export function summarizeSyntheticTree(entries) {
  return {
    sha256: sha256(JSON.stringify(entries)),
    files: entries.filter((entry) => entry.kind === "file").length,
    directories: entries.filter((entry) => entry.kind === "directory").length,
    bytes: entries.reduce((total, entry) => total + (entry.bytes ?? 0), 0),
  };
}
