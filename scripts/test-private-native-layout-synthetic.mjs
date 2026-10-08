#!/usr/bin/env node
// Run only after source review. Fresh public seed; no writer or personal input.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildSyntheticNotePayload, noteIdentifier, replicaIdentifier } from "./lib/synthetic-note-payload.mjs";
import { readSingleLinkFile } from "./lib/synthetic-fixture-files.mjs";
import { sha256, snapshotSyntheticTree, summarizeSyntheticTree } from "./lib/synthetic-store-snapshot.mjs";
import { validateSyntheticNativeLayoutReport } from "./lib/synthetic-native-layout-report.mjs";

if (process.argv.length !== 2) throw new Error("This fixture accepts no paths or private input");
if (process.platform !== "darwin") throw new Error("Native layout metadata requires macOS");
const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const root = realpathSync(mkdtempSync("/private/tmp/apple-notes-synthetic-fixture-"));
chmodSync(root, 0o700);
const privateUser = join(root, "isolated-user");
mkdirSync(join(privateUser, "Library/Preferences"), { recursive: true, mode: 0o700 });
mkdirSync(join(privateUser, "Library/Caches"), { recursive: true, mode: 0o700 });
mkdirSync(join(root, "tmp"), { mode: 0o700 });
const persist = (name, value) => writeFileSync(join(root, name), JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
const report = {
  schemaVersion: 1, kind: "source-reviewed-public-layout-diagnostic", syntheticOnly: true,
  personalStoreRead: false, fixtureSeedPublic: true, completed: false, nativeOutputPrivacyReviewed: false,
  writerInvoked: false, preservationPinsChanged: false, tests: [],
};
persist("report.json", report);
function command(binary, args, options = {}) {
  const result = spawnSync(binary, args, { encoding: "utf8", timeout: 120000, maxBuffer: 16 * 1024 * 1024, ...options });
  if (result.error || result.status !== 0) throw new Error("Fixture command failed; details retained privately");
  return result;
}
function compile(source, output, frameworks) {
  command("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-O2", "-Wall", ...frameworks.flatMap((f) => ["-framework", f]), source, "-o", output]);
}
function test(name, fn) {
  fn();
  report.tests.push(name);
  persist("report.json", report);
}
const profile = join(root, "fixture.sb");
// Byte-identical sandbox policy construction to the reviewed ordinary fixture.
writeFileSync(profile,
  `(version 1)\n(allow default)\n(deny network*)\n(deny mach-lookup)\n(deny mach-register)\n` +
  `(deny file-read* (require-not (require-any (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") ` +
  `(subpath "/private/etc") (subpath "/Library/Apple") (literal "/") (literal "/private") (literal "/private/tmp") ` +
  `(literal "/tmp") (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom") (subpath ${JSON.stringify(root)}))))\n` +
  `(deny file-write* (require-not (subpath ${JSON.stringify(root)})))\n`, { mode: 0o600 });
const childEnv = { ...process.env, CFFIXED_USER_HOME: privateUser, TMPDIR: join(root, "tmp") };
for (const key of Object.keys(childEnv)) if (key.startsWith("APPLE_NOTES_MCP_")) delete childEnv[key];
const sandbox = (binary, args = []) => command("/usr/bin/sandbox-exec", ["-f", profile, binary, ...args], { env: childEnv, cwd: root });
try {
  const probeSource = join(repo, "scripts/lib/replica-isolation-probe.m");
  const generatorSource = join(repo, "test/native/synthetic-notes-store.m");
  const diagnosticSource = join(repo, "test/native/synthetic-native-layout.m");
  const probe = join(root, "isolation-probe"), generator = join(root, "generator"), diagnostic = join(root, "diagnostic");
  compile(probeSource, probe, ["Foundation"]);
  report.isolation = JSON.parse(sandbox(probe).stdout);
  test("all six existing isolation preflights before model/framework access", () => {
    for (const field of ["realHomeDenied", "globalPreferencesDenied", "preferencesDaemonDenied", "networkDenied", "fixedUserHomeVerified", "productionBundleVerified"])
      assert.equal(report.isolation[field], true);
    assert.notEqual(privateUser, homedir());
    assert.equal(childEnv.HOME, process.env.HOME);
  });
  const payload = buildSyntheticNotePayload();
  const payloadPath = join(root, "generated-baseline.gz");
  writeFileSync(payloadPath, payload, { mode: 0o600 });
  report.baselinePayloadSha256 = sha256(payload);
  const model = "/System/Library/PrivateFrameworks/NotesShared.framework/Resources/NoteData.mom";
  report.modelSha256 = sha256(readFileSync(realpathSync(model)));
  compile(generatorSource, generator, ["Foundation", "CoreData"]);
  const store = join(root, "NoteStore.sqlite");
  report.generator = JSON.parse(sandbox(generator, [store, payloadPath, noteIdentifier, replicaIdentifier, "--receipt-fixture"]).stdout);
  test("generic generator creates only the fixed public note/scope/hidden-inline seed", () => {
    assert.deepEqual(report.generator, { created: true, frameworkLoaded: false, notes: 1, accounts: 1, folders: 4, inlineAttachments: 1 });
  });
  compile(diagnosticSource, diagnostic, ["Foundation", "CoreData", "AppKit"]);
  report.sources = Object.fromEntries([
    ["probe", probeSource], ["generator", generatorSource], ["diagnostic", diagnosticSource],
    ["harness", fileURLToPath(import.meta.url)], ["payload", join(repo, "scripts/lib/synthetic-note-payload.mjs")],
    ["validator", join(repo, "scripts/lib/synthetic-native-layout-report.mjs")],
    ["fixtureFiles", join(repo, "scripts/lib/synthetic-fixture-files.mjs")],
    ["treeSnapshot", join(repo, "scripts/lib/synthetic-store-snapshot.mjs")],
    ["preservation", join(repo, "native/private-helper/content-preservation.h")],
  ].map(([name, path]) => [name, sha256(readSingleLinkFile(path))]));
  report.binaries = Object.fromEntries([["probe", probe], ["generator", generator], ["diagnostic", diagnostic]].map(([name, path]) => [name, sha256(readSingleLinkFile(path))]));
  report.profileSha256 = sha256(readSingleLinkFile(profile));
  const excluded = new Set(["report.json", "native-layout.json", "diagnostic.stderr"]);
  const before = snapshotSyntheticTree(root, excluded);
  const initialStoreSha256 = sha256(readSingleLinkFile(store));
  const result = spawnSync("/usr/bin/sandbox-exec", ["-f", profile, diagnostic, root], {
    encoding: "utf8", timeout: 120000, maxBuffer: 16 * 1024 * 1024, env: childEnv, cwd: root,
  });
  // Store raw outputs privately. Only the strict envelope may be shared after
  // separate review; stderr is never printed or incorporated into summaries.
  writeFileSync(join(root, "diagnostic.stderr"), result.stderr ?? "", { mode: 0o600 });
  writeFileSync(join(root, "native-layout.json"), result.stdout ?? "", { mode: 0o600 });
  test("read-only diagnostic preserves every store byte and non-evidence scratch entry", () => {
    assert.equal(sha256(readSingleLinkFile(store)), initialStoreSha256);
    assert.deepEqual(snapshotSyntheticTree(root, excluded), before);
    report.unchangedTree = summarizeSyntheticTree(before);
  });
  assert.ok(!result.error && result.status === 0, "native diagnostic unavailable; private output retained");
  const layout = validateSyntheticNativeLayoutReport(JSON.parse(result.stdout));
  test("native output contains only bounded schema metadata", () => {
    assert.equal(layout.readOnlyStore, true);
    report.layoutMetadataSha256 = sha256(result.stdout);
    report.unsupportedKeyCount = layout.attributes.filter((a) => !a.supportedKey).length;
    report.observedValueClassCount = layout.classes.length;
  });
  report.completed = true;
  persist("report.json", report);
  process.stdout.write(`Synthetic native layout metadata ready for privacy review: ${join(root, "report.json")}\n`);
} catch (error) {
  report.failureCode = "diagnostic_or_exact_mutation_check_failed";
  // Assertion diffs / native JSON parse errors may contain unreviewed data.
  // Keep the raw stderr/stdout private and the report failure summary bounded.
  void error;
  persist("report.json", report);
  process.stderr.write(`Synthetic native layout diagnostic failed; private evidence: ${join(root, "report.json")}\n`);
  process.exitCode = 1;
}
