// Pure confinement model shared with the fixed no-input harness. Both macOS
// temporary aliases must identify the same direct-child name; symlinks refuse.
import assert from "node:assert/strict";
import { lstatSync, realpathSync } from "node:fs";

export function equivalentFixtureRootPaths(supplied, resolved) {
  const match = (path) => /^\/(?:private\/)?tmp\/(apple-notes-synthetic-fixture-[A-Za-z0-9]+)$/u.exec(path)?.[1];
  const name = match(supplied);
  return name !== undefined && name === match(resolved);
}

export function validateFixtureRootPath(path) {
  const stat = lstatSync(path);
  assert.ok(stat.isDirectory() && !stat.isSymbolicLink());
  const canonical = realpathSync(path);
  assert.ok(equivalentFixtureRootPaths(path, canonical));
  return canonical;
}
