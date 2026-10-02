// Exercise the actual workflow shell against disposable Git histories. npm is
// stubbed, so these tests need neither the registry nor a populated Notes store.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const workflow = readFileSync(
  new URL("../.github/workflows/version-guard.yml", import.meta.url),
  "utf8"
).split("\n");
const step = workflow.indexOf("      - name: Require a version bump when shipped bytes change");
assert.ok(step >= 0, "version guard step is present");
const run = workflow.findIndex((line, index) => index > step && line === "        run: |");
assert.ok(run > step, "version guard shell is present");
const body = [];
for (const line of workflow.slice(run + 1)) {
  if (line && !line.startsWith("          ")) break;
  body.push(line.slice(10));
}
const guard = body.join("\n");
assert.ok(guard.includes("set -euo pipefail"));

function exercise(options = {}) {
  const directory = mkdtempSync(join(tmpdir(), "version-guard-fixture-"));
  try {
    const repository = join(directory, "repo");
    const bin = join(directory, "bin");
    const npmLog = join(directory, "npm.log");
    mkdirSync(repository);
    mkdirSync(bin);
    // Never inherit Git locations, hooks or signing settings from the caller.
    const env = Object.fromEntries(
      Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_"))
    );
    Object.assign(env, {
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_CONFIG_GLOBAL: "/dev/null",
      PATH: `${bin}:${process.env.PATH}`,
      NPM_STUB_LOG: npmLog,
      NPM_STUB_VERSION: options.publishedVersion ?? "2.9.34",
    });
    writeFileSync(
      join(bin, "npm"),
      '#!/bin/sh\nprintf "%s\\n" "$*" >> "$NPM_STUB_LOG"\nprintf "%s\\n" "$NPM_STUB_VERSION"\n',
      { mode: 0o700 }
    );
    function git(...args) {
      const result = spawnSync("git", args, { cwd: repository, env, encoding: "utf8" });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout.trim();
    }
    git("init", "--quiet", "--initial-branch=main");
    git("config", "user.name", "Version Guard Fixture");
    git("config", "user.email", "fixture@example.invalid");
    git("config", "core.hooksPath", "/dev/null");
    const baseVersion = "2.9.30";
    const version = options.version ?? "2.9.34";
    function packageJson(value, dependencies = {}) {
      writeFileSync(
        join(repository, "package.json"),
        JSON.stringify({ name: "apple-notes-mcp", version: value, dependencies })
      );
    }
    packageJson(baseVersion);
    writeFileSync(
      join(repository, "CHANGELOG.md"),
      `## [Unreleased]\n\n## [${baseVersion}] - 2026-09-25\n\nExisting release.\n`
    );
    mkdirSync(join(repository, "build"));
    writeFileSync(join(repository, "build/index.js"), "// original bytes\n");
    writeFileSync(join(repository, "README.md"), "Base documentation.\n");
    git("add", ".");
    git("commit", "--quiet", "-m", "fixture base");
    const base = git("rev-parse", "HEAD");

    packageJson(version, options.dependencies);
    const headings = new Set([version, baseVersion]);
    if (options.removeHistory) headings.delete(baseVersion);
    if (options.missingVersionHeading) headings.delete(version);
    const unreleased = options.missingUnreleased
      ? ""
      : `## [Unreleased]\n\n${options.unreleasedContent ?? ""}\n`;
    writeFileSync(
      join(repository, "CHANGELOG.md"),
      unreleased + [...headings].map((v) => `## [${v}] - 2026-10-02\n\nRelease.\n`).join("\n")
    );
    if (options.buildChanged !== false)
      writeFileSync(join(repository, "build/index.js"), "// changed shipped bytes\n");
    writeFileSync(join(repository, "README.md"), "Updated documentation.\n");
    git("add", ".");
    git("commit", "--quiet", "-m", "fixture proposal");
    env.BASE_SHA = base;
    env.HEAD_SHA = git("rev-parse", "HEAD");
    if (options.repository === null) delete env.GITHUB_REPOSITORY;
    else env.GITHUB_REPOSITORY = options.repository ?? "oliverames/apple-notes-mcp";
    const result = spawnSync("/bin/bash", ["-c", guard], {
      cwd: repository,
      env,
      encoding: "utf8",
      timeout: 10_000,
    });
    assert.ifError(result.error);
    return {
      status: result.status,
      output: result.stdout + result.stderr,
      npmCalls: existsSync(npmLog) ? readFileSync(npmLog, "utf8").trim().split("\n") : [],
    };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("publishing repository rejects an already-published bump", () => {
  const result = exercise({ repository: "sweetrb/apple-notes-mcp" });
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /already published on npm/);
  assert.deepEqual(result.npmCalls, ["view apple-notes-mcp@2.9.34 version"]);
});

test("publishing repository permits an unclaimed bump", () => {
  const result = exercise({ repository: "sweetrb/apple-notes-mcp", publishedVersion: "" });
  assert.equal(result.status, 0, result.output);
  assert.equal(result.npmCalls.length, 1);
});

for (const repository of ["oliverames/apple-notes-mcp", "sweetrb/another-repository"]) {
  test(`${repository} can sync a published version without querying npm`, () => {
    const result = exercise({ repository });
    assert.equal(result.status, 0, result.output);
    assert.match(result.output, /Shipped bytes changed and version is bumped/);
    assert.deepEqual(result.npmCalls, []);
  });
}

for (const repository of [null, ""]) {
  test(`missing repository identity fails closed (${JSON.stringify(repository)})`, () => {
    const result = exercise({ repository });
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /GITHUB_REPOSITORY is required/);
    assert.deepEqual(result.npmCalls, []);
  });
}

const forkRefusals = [
  [
    "shipped bytes without a bump",
    { version: "2.9.30" },
    /Shipped bytes changed .*version is unchanged/,
  ],
  [
    "runtime dependencies without a bump",
    { version: "2.9.30", buildChanged: false, dependencies: { example: "1.0.0" } },
    /Runtime dependencies changed .*version is unchanged/,
  ],
  ["downgrade", { version: "2.9.29" }, /not an increase/],
  ["removed historical heading", { removeHistory: true }, /no longer has a .*heading for release/],
  ["missing new heading", { missingVersionHeading: true }, /has no '## \[2.9.34\]' heading/],
  ["missing Unreleased marker", { missingUnreleased: true }, /has no '## \[Unreleased\]' heading/],
  [
    "nonempty Unreleased",
    { unreleasedContent: "Unfiled notes." },
    /'## \[Unreleased\]' is not empty/,
  ],
];
for (const [name, options, message] of forkRefusals) {
  test(`fork still rejects ${name}`, () => {
    const result = exercise(options);
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, message);
    assert.deepEqual(result.npmCalls, []);
  });
}

test("fork permits documentation-only changes without a bump", () => {
  const result = exercise({ version: "2.9.30", buildChanged: false });
  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /No shipped-byte changes/);
  assert.deepEqual(result.npmCalls, []);
});
