import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { checks, stages, validateSyntheticNativeContentControl } from "./synthetic-native-content-control-report.mjs";
import { buildSyntheticNotePayload, text } from "./synthetic-note-payload.mjs";
function report() {
  return { schemaVersion: 1, kind: "fixed-public-native-comparator-control", completed: true,
    syntheticOnly: true, fixedPublicBodyVerified: true, readOnlyStore: true, storedAttributeFieldsRead: true,
    snapshotValuesEmitted: false, nativeAttributeGettersInvoked: false, nativeObjectsConstructedInMemory: true,
    storeSavesInvoked: false, writerInvoked: false, archiveCompletenessClaimed: false, persistenceClaimed: false,
    seedBodyUTF16: 184, seedPayloadSha256: "ac93f271962eddbc6511ce12064ae1ac423e91546c8eff356a9ecddc765fa0d1",
    firstSeedBodyUTF8Sha256: "f602bfbbe3589f906994178f6cdc3dc1f2977cfe9282ea152f210d7dbbbfd374",
    secondSeedBodyUTF8Sha256: "f602bfbbe3589f906994178f6cdc3dc1f2977cfe9282ea152f210d7dbbbfd374",
    constructedBodyUTF8Sha256: "f7957b1e93cb21231eca2bd923f4ead6cef62e48c65ba074b72ca19f3af2966f",
    constructedBodyUTF16: 70, checks: [...checks] };
}
test("success claims require every fixed native comparator control in order", () => {
  const r = report(); assert.equal(validateSyntheticNativeContentControl(r), r);
  for (const mutate of [(x) => x.checks.pop(), (x) => x.checks.reverse(), (x) => { x.checks.push("private payload"); },
    (x) => { x.checks[0] = "not completed"; }]) {
    const value = report(); mutate(value); assert.throws(() => validateSyntheticNativeContentControl(value));
  }
});
test("a failure carries only a bounded stage and completed prefix, never native values", () => {
  for (const stage of stages) {
    const value = { schemaVersion: 1, kind: "fixed-public-native-comparator-control", completed: false,
      code: "control_boundary_or_api_unavailable", stage, checks: checks.slice(0, 3) };
    assert.equal(validateSyntheticNativeContentControl(value), value);
    value.reason = "native object description";
    assert.throws(() => validateSyntheticNativeContentControl(value));
  }
  for (const stage of ["unknown", "body payload", null])
    assert.throws(() => validateSyntheticNativeContentControl({ schemaVersion: 1, kind: "fixed-public-native-comparator-control",
      completed: false, code: "control_boundary_or_api_unavailable", stage, checks: [] }));
});
test("truthful stored-value scope, exact body constants and boolean markers cannot broaden", () => {
  for (const [key, value] of [["readOnlyStore", false], ["storedAttributeFieldsRead", false], ["storeSavesInvoked", true],
    ["writerInvoked", true], ["snapshotValuesEmitted", true], ["nativeAttributeGettersInvoked", true],
    ["persistenceClaimed", true], ["archiveCompletenessClaimed", true], ["completed", 1], ["seedBodyUTF16", 0],
    ["constructedBodyUTF16", 69], ["seedPayloadSha256", "wrong"], ["firstSeedBodyUTF8Sha256", "wrong"],
    ["secondSeedBodyUTF8Sha256", "wrong"], ["constructedBodyUTF8Sha256", "wrong"]])
    assert.throws(() => validateSyntheticNativeContentControl({ ...report(), [key]: value }));
  assert.throws(() => validateSyntheticNativeContentControl({ ...report(), snapshot: "native values" }));
});
test("source pins independent public body, actual production comparator and typed fresh-memory calls", () => {
  const source = readFileSync(new URL("../../test/native/synthetic-native-content-control.m", import.meta.url), "utf8");
  const digest = createHash("sha256").update(buildSyntheticNotePayload()).digest("hex");
  assert.equal(text.length, 184);
  assert.ok(source.includes(`@"${digest}"`));
  assert.ok(source.includes('#include "../../native/private-helper/content-preservation.h"'));
  for (const required of ["ANMContentSnapshot(body,", "ANMContentMatches(frozen, secondBody", "firstMergeable != secondMergeable",
    "first.persistentStoreCoordinator != second.persistentStoreCoordinator", 'options[NSReadOnlyPersistentStoreOption] = @YES;',
    'TypedMethod(allocated, "initWithIdentifier:done:", "@", @[ @"@", @(@encode(BOOL)) ]);'])
    assert.ok(source.includes(required), required);
  for (const forbidden of ["save:", "insertNewObjectForEntityForName:", "NSKeyedArchiver", "NSInvocation", "setValue:",
    "apple-notes-private-writer.m", "Library/Group Containers", "setNativeFont:", "NSUUID.UUID"])
    assert.ok(!source.includes(forbidden), forbidden);
  assert.ok(source.indexOf('(void)FixedNote(generic);') < source.indexOf('Require(dlopen('));
  assert.ok(source.indexOf('"sandbox-policy"') < source.indexOf('"generic-model-open"'));
  assert.ok(source.indexOf('"generic-model-open"') < source.indexOf('"framework-load"'));
  assert.deepEqual([...new Set([...source.matchAll(/DiagnosticStage = "([^"]+)"/g)].map((m) => m[1]))].sort(), [...stages].sort());
  assert.ok(source.includes('@"done": @[ @"stored-scalar", @(@encode(BOOL)), [NSData dataWithBytes:&done length:sizeof(done)] ]'));
});
test("harness retains fresh scratch, six preflights, exact sandbox, production closure and raw/public ledgers", () => {
  const harness = readFileSync(new URL("../test-private-native-content-control-synthetic.mjs", import.meta.url), "utf8");
  const ordinary = readFileSync(new URL("../test-private-writer-synthetic-store.mjs", import.meta.url), "utf8");
  const policy = (source) => {
    const start = source.indexOf('`(version 1)'); const end = source.indexOf('`(deny file-write*', start);
    return source.slice(start, source.indexOf('`', end + 1) + 1).replace(/\s+\+\s+/g, "+");
  };
  assert.equal(policy(harness), policy(ordinary));
  for (const field of ["realHomeDenied", "globalPreferencesDenied", "preferencesDaemonDenied", "networkDenied", "fixedUserHomeVerified", "productionBundleVerified"])
    assert.ok(harness.includes(`"${field}"`));
  for (const snippet of ['assert.deepEqual(readdirSync(root), []);', 'assert.equal(childEnv.HOME, process.env.HOME);',
    'persist("before-state.json",', 'persist("after-state.json",', 'assert.deepEqual(after, before);',
    'persist("public-body-ledger-before.json",', 'persist("public-body-ledger-after.json",',
    'report.productionSourceClosure = closure;', 'assert.deepEqual(writerSourceClosure(',
    'if (process.argv.length !== 2) throw new Error("This fixture accepts no paths or private input");'])
    assert.ok(harness.includes(snippet), snippet);
  assert.ok(harness.indexOf('report.isolation = JSON.parse(sandbox(probe).stdout);') < harness.indexOf('report.generator = JSON.parse(sandbox(generator,'));
  for (const forbidden of ["APPLE_NOTES_MCP_ALLOW_UNVERIFIED", "ALLOW_NOTES_RUNNING", "compose_note", "APPLE_NOTES_MCP_PRIVATE_STORE"])
    assert.ok(!harness.includes(forbidden), forbidden);
});
