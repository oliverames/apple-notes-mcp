#!/usr/bin/env node
// Run only after source review. Fresh public seed; no writer or personal input.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildSyntheticNotePayload, text, noteIdentifier, replicaIdentifier } from "./lib/synthetic-note-payload.mjs";
import { writerSourceClosure } from "./lib/writer-source-closure.mjs";
import { readSingleLinkFile } from "./lib/synthetic-fixture-files.mjs";
import { sha256, snapshotSyntheticTree, summarizeSyntheticTree } from "./lib/synthetic-store-snapshot.mjs";
import { validateFixtureRootPath } from "./lib/synthetic-native-layout-path.mjs";
import { validateSyntheticNativeContentControl } from "./lib/synthetic-native-content-control-report.mjs";

if (process.argv.length !== 2) throw new Error("This fixture accepts no paths or private input");
if (process.platform !== "darwin") throw new Error("Native layout metadata requires macOS");
const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const root = realpathSync(mkdtempSync("/private/tmp/apple-notes-synthetic-fixture-"));
chmodSync(root, 0o700);
validateFixtureRootPath(root);
assert.ok(lstatSync(root).isDirectory() && !lstatSync(root).isSymbolicLink());
assert.deepEqual(readdirSync(root), []);
const freshRootStat = lstatSync(root);
const privateUser = join(root, "isolated-user");
mkdirSync(join(privateUser, "Library/Preferences"), { recursive: true, mode: 0o700 });
mkdirSync(join(privateUser, "Library/Caches"), { recursive: true, mode: 0o700 });
mkdirSync(join(root, "tmp"), { mode: 0o700 });
const persist = (name, value) => writeFileSync(join(root, name), JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
const report = {
  schemaVersion: 1, kind: "source-reviewed-public-native-comparator-control", syntheticOnly: true,
  personalStoreRead: false, fixtureSeedPublic: true, completed: false, nativeOutputPrivacyReviewed: false,
  writerInvoked: false, preservationPinsChanged: false, tests: [],
  persistenceClaimed: false, archiveCompletenessClaimed: false,
  freshness: { emptyAtCreation: true, mode: freshRootStat.mode & 0o777, device: freshRootStat.dev, inode: freshRootStat.ino },
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
  const diagnosticSource = join(repo, "test/native/synthetic-native-content-control.m");
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
  assert.equal(sha256(payload), "ac93f271962eddbc6511ce12064ae1ac423e91546c8eff356a9ecddc765fa0d1");
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
  const closure = writerSourceClosure(join(repo, "native/private-helper/apple-notes-private-writer.m"));
  assert.equal(closure.sha256, "4cc975742d74f769076327315f21339b3760526fd7e51b957b025553f5cb5b10");
  report.productionSourceClosure = closure;
  compile(diagnosticSource, diagnostic, ["Foundation", "CoreData", "AppKit"]);
  assert.deepEqual(writerSourceClosure(join(repo, "native/private-helper/apple-notes-private-writer.m")), closure);
  report.sources = Object.fromEntries([
    ["probe", probeSource], ["generator", generatorSource], ["diagnostic", diagnosticSource],
    ["harness", fileURLToPath(import.meta.url)], ["payload", join(repo, "scripts/lib/synthetic-note-payload.mjs")],
    ["validator", join(repo, "scripts/lib/synthetic-native-content-control-report.mjs")],
    ["pathBoundary", join(repo, "scripts/lib/synthetic-native-layout-path.mjs")],
    ["fixtureFiles", join(repo, "scripts/lib/synthetic-fixture-files.mjs")],
    ["treeSnapshot", join(repo, "scripts/lib/synthetic-store-snapshot.mjs")],
    ["preservation", join(repo, "native/private-helper/content-preservation.h")],
  ].map(([name, path]) => [name, sha256(readSingleLinkFile(path))]));
  report.binaries = Object.fromEntries([["probe", probe], ["generator", generator], ["diagnostic", diagnostic]].map(([name, path]) => [name, sha256(readSingleLinkFile(path))]));
  report.profileSha256 = sha256(readSingleLinkFile(profile));
  const excluded = new Set(["report.json", "native-content-control.json", "diagnostic.stderr", "before-state.json", "after-state.json", "public-body-ledger-before.json", "public-body-ledger-after.json"]);
  const bodyLedger = { source: "fixed-public-literals", seedPayloadSha256: sha256(payload), seedBodyUTF16: text.length,
    seedBodyUTF8Sha256: sha256(Buffer.from(text, "utf8")), constructedBodyUTF16: 70,
    constructedBodyUTF8Sha256: sha256(Buffer.from("PUBLIC NATIVE REPRESENTATION CONTROL\nChecklist generated\nAttachment \uFFFC\n", "utf8")) };
  persist("public-body-ledger-before.json", bodyLedger);
  const before = snapshotSyntheticTree(root, excluded);
  const initialStoreSha256 = sha256(readSingleLinkFile(store));
  persist("before-state.json", { storeSha256: initialStoreSha256, entries: before });
  const result = spawnSync("/usr/bin/sandbox-exec", ["-f", profile, diagnostic, root], {
    encoding: "utf8", timeout: 120000, maxBuffer: 16 * 1024 * 1024, env: childEnv, cwd: root,
  });
  // Store raw outputs privately. Only the strict envelope may be shared after
  // separate review; stderr is never printed or incorporated into summaries.
  writeFileSync(join(root, "diagnostic.stderr"), result.stderr ?? "", { mode: 0o600 });
  writeFileSync(join(root, "native-content-control.json"), result.stdout ?? "", { mode: 0o600 });
  test("read-only diagnostic preserves every store byte and non-evidence scratch entry", () => {
    assert.equal(sha256(readSingleLinkFile(store)), initialStoreSha256);
    const after = snapshotSyntheticTree(root, excluded);
    persist("after-state.json", { storeSha256: sha256(readSingleLinkFile(store)), entries: after });
    assert.deepEqual(after, before);
    assert.deepEqual(writerSourceClosure(join(repo, "native/private-helper/apple-notes-private-writer.m")), closure);
    report.unchangedTree = summarizeSyntheticTree(before);
    assert.equal(sha256(readSingleLinkFile(payloadPath)), bodyLedger.seedPayloadSha256);

  });
  const control = validateSyntheticNativeContentControl(JSON.parse(result.stdout));
  report.nativeComparatorCompleted = control.completed;
  report.nativeComparatorChecks = control.checks;
  report.nativeComparatorObservations = control.observations;
  report.nativeComparatorReportSha256 = sha256(result.stdout);
  if (!control.completed) report.nativeComparatorStage = control.stage;
  persist("report.json", report);
  assert.ok(!result.error && result.status === 0, "native control unavailable; private output retained");
  test("independent native body observations match the unchanged fixed public ledgers", () => {
    assert.equal(control.firstSeedBodyUTF8Sha256, bodyLedger.seedBodyUTF8Sha256);
    assert.equal(control.secondSeedBodyUTF8Sha256, bodyLedger.seedBodyUTF8Sha256);
    const nativeBodyLedger = { source: bodyLedger.source, seedPayloadSha256: control.seedPayloadSha256,
      seedBodyUTF16: control.seedBodyUTF16, seedBodyUTF8Sha256: control.firstSeedBodyUTF8Sha256,
      constructedBodyUTF16: control.constructedBodyUTF16, constructedBodyUTF8Sha256: control.constructedBodyUTF8Sha256 };
    persist("public-body-ledger-after.json", nativeBodyLedger);
    assert.deepEqual(JSON.parse(readSingleLinkFile(join(root, "public-body-ledger-after.json"))),
      JSON.parse(readSingleLinkFile(join(root, "public-body-ledger-before.json"))));
  });
  test("native comparator positive-control envelope and exact public scope", () => {
    assert.equal(control.readOnlyStore, true);
    assert.equal(control.completed, true);
    report.nativeComparatorReportSha256 = sha256(result.stdout);
    report.nativeComparatorChecks = control.checks;
  });
  report.completed = true;
  persist("report.json", report);
  process.stdout.write(`Synthetic native comparator control ready for privacy review: ${join(root, "report.json")}\n`);
} catch (error) {
  report.failureCode = "diagnostic_or_exact_mutation_check_failed";
  // Assertion diffs / native JSON parse errors may contain unreviewed data.
  // Keep the raw stderr/stdout private and the report failure summary bounded.
  void error;
  persist("report.json", report);
  process.stderr.write(`Synthetic native comparator control failed; private evidence: ${join(root, "report.json")}\n`);
  process.exitCode = 1;
}
