// Strict bounded positive-control envelope. Never expose snapshots, native
// values, exception strings or unexpected keys. No private runtime imports.
import assert from "node:assert/strict";
export const checks = [
  "native-mutable-todo-glyph-accepted",
  "independent-native-memory-values-stable",
  "native-mutable-to-immutable-copy-preserves-stored-state",
  "native-stored-field-todo-glyph-mutation-detected",
  "native-fixed-seed-accepted",
  "native-fixed-seed-repeated-projection-stable",
  "native-fixed-seed-independent-context-stable",
  "native-fixed-seed-public-body-ledgers-unchanged",
];
export const observationKeys = [
  "firstPayloadMatchesBeforeProjection", "secondPayloadMatchesBeforeProjection",
  "firstPayloadMatchesAfterProjection", "secondPayloadMatchesAfterProjection",
  "firstContextHasChangesBeforeProjection", "secondContextHasChangesBeforeProjection",
  "firstContextHasChangesAfterProjection", "secondContextHasChangesAfterProjection",
];
export const stages = [
  "input", "root-containment", "sandbox-policy", "public-payload-file", "generic-model-open", "generic-public-seed",
  "fixed-public-body-hash", "framework-load", "container-model-abi", "native-read-only-open", "fixed-seed-native-body",
  "fixed-seed-native-comparator", "fixed-seed-repeated-projection", "fixed-seed-independent-context",
  "read-only-context-before-projection", "read-only-context-after-projection",
  "read-only-first-payload-recheck", "read-only-second-payload-recheck",
  "fixed-native-memory-construction", "independent-native-memory-reconstruction", "native-immutable-copy-normalization",
  "native-deep-snapshot-mutation-controls",
];
function record(value, keys) {
  assert.ok(value !== null && typeof value === "object" && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), [...keys].sort());
}
export function validateSyntheticNativeContentControl(report) {
  assert.ok(report !== null && typeof report === "object");
  assert.equal(report.schemaVersion, 2);
  assert.equal(report.kind, "fixed-public-native-comparator-control");
  assert.equal(typeof report.completed, "boolean");
  assert.ok(Array.isArray(report.checks));
  assert.deepEqual(report.checks, checks.slice(0, report.checks.length));
  assert.ok(report.checks.length <= checks.length);
  record(report.observations, observationKeys);
  for (const value of Object.values(report.observations))
    assert.ok(value === null || typeof value === "boolean");
  if (!report.completed) {
    record(report, ["schemaVersion", "kind", "completed", "code", "stage", "observations", "checks"]);
    assert.equal(report.code, "control_boundary_or_api_unavailable");
    assert.ok(stages.includes(report.stage));
    return report;
  }
  record(report, ["schemaVersion", "kind", "completed", "syntheticOnly", "fixedPublicBodyVerified", "readOnlyStore",
    "storedAttributeFieldsRead", "snapshotValuesEmitted", "nativeAttributeGettersInvoked", "nativeObjectsConstructedInMemory",
    "storeSavesInvoked", "writerInvoked", "archiveCompletenessClaimed", "persistenceClaimed", "seedBodyUTF16",
    "seedPayloadSha256", "firstSeedBodyUTF8Sha256", "secondSeedBodyUTF8Sha256", "constructedBodyUTF16", "constructedBodyUTF8Sha256", "observations", "checks"]);
  for (const key of observationKeys) {
    assert.equal(typeof report.observations[key], "boolean");
    if (key.includes("PayloadMatches")) assert.equal(report.observations[key], true);
  }
  for (const key of ["syntheticOnly", "fixedPublicBodyVerified", "readOnlyStore", "storedAttributeFieldsRead", "nativeObjectsConstructedInMemory"])
    assert.equal(report[key], true);
  for (const key of ["snapshotValuesEmitted", "nativeAttributeGettersInvoked", "storeSavesInvoked", "writerInvoked", "archiveCompletenessClaimed", "persistenceClaimed"])
    assert.equal(report[key], false);
  assert.equal(report.seedBodyUTF16, 184);
  assert.equal(report.constructedBodyUTF16, 70);
  assert.equal(report.seedPayloadSha256, "ac93f271962eddbc6511ce12064ae1ac423e91546c8eff356a9ecddc765fa0d1");
  assert.equal(report.firstSeedBodyUTF8Sha256, "f602bfbbe3589f906994178f6cdc3dc1f2977cfe9282ea152f210d7dbbbfd374");
  assert.equal(report.secondSeedBodyUTF8Sha256, "f602bfbbe3589f906994178f6cdc3dc1f2977cfe9282ea152f210d7dbbbfd374");
  assert.equal(report.constructedBodyUTF8Sha256, "f7957b1e93cb21231eca2bd923f4ead6cef62e48c65ba074b72ca19f3af2966f");
  assert.deepEqual(report.checks, checks);
  return report;
}
