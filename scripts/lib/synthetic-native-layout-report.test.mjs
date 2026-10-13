import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { preservationKeys, validateSyntheticNativeLayoutReport } from "./synthetic-native-layout-report.mjs";
import { buildSyntheticNotePayload } from "./synthetic-note-payload.mjs";

function report() {
  const getter = { selector: "opaque", present: true, encoding: "{fixture=Q}@:",
    returnType: "{fixture=Q}", argumentTypes: ["@", ":"] };
  return {
    schemaVersion: 1, kind: "fixed-public-native-layout-metadata", syntheticOnly: true,
    fixedPublicBodyVerified: true, readOnlyStore: true, attributeFieldValuesRead: false,
    nativeAttributeGettersInvoked: false, preservationPinsChanged: false, bodyUTF16: 184,
    attributeRuns: 6, attributes: [{ key: "FixtureUnknown", supportedKey: false, valueClasses: ["FixtureOpaque"] }],
    classes: [{ name: "FixtureOpaque", chain: [
      { name: "FixtureOpaque", superclass: "NSObject", instanceSize: 16,
        ivars: [{ name: "_opaque", encoding: "{fixture=Q}", offset: 8 }],
        properties: [{ name: "opaque", attributes: "T{fixture=Q},R,N", getter }],
        zeroArgumentMethods: [getter] },
      { name: "NSObject", superclass: null, instanceSize: 8, ivars: [], properties: [], zeroArgumentMethods: [] },
    ] }],
    tableCellCoverage: "unavailable:no-table-in-fixed-seed",
    nestedValueCoverage: "unavailable:no-attribute-value-traversal",
  };
}

test("metadata preserves opaque encodings without claiming projection support", () => {
  const value = report();
  assert.equal(validateSyntheticNativeLayoutReport(value), value);
  assert.equal(value.attributes[0].supportedKey, false);
  assert.equal(value.classes[0].chain[0].ivars[0].encoding, "{fixture=Q}");
});

test("payload-shaped additions are refused at every nested record", () => {
  const additions = [
    (r) => r, (r) => r.attributes[0], (r) => r.classes[0], (r) => r.classes[0].chain[0],
    (r) => r.classes[0].chain[0].ivars[0], (r) => r.classes[0].chain[0].properties[0],
    (r) => r.classes[0].chain[0].properties[0].getter,
  ];
  for (const select of additions) {
    const value = report();
    select(value).value = "native payload must not be emitted";
    assert.throws(() => validateSyntheticNativeLayoutReport(value));
  }
});

test("read-only, no-getter and coverage constraints cannot be broadened", () => {
  for (const [key, value] of [
    ["syntheticOnly", false], ["fixedPublicBodyVerified", false], ["readOnlyStore", false],
    ["attributeFieldValuesRead", true], ["nativeAttributeGettersInvoked", true], ["preservationPinsChanged", true],
    ["bodyUTF16", 0], ["tableCellCoverage", "complete"], ["nestedValueCoverage", "complete"],
  ]) {
    assert.throws(() => validateSyntheticNativeLayoutReport({ ...report(), [key]: value }));
  }
});

test("inconsistent, duplicate or unbounded metadata refuses", () => {
  for (const mutate of [
    (r) => { r.classes[0].chain[0].superclass = "Missing"; },
    (r) => { r.attributes[0].valueClasses = ["Missing"]; },
    (r) => { r.attributes[0].supportedKey = true; },
    (r) => { r.classes[0].chain[0].ivars[0].offset = -1; },
    (r) => { r.classes[0].chain[0].ivars[0].name = "A\nB"; },
    (r) => { r.classes[0].chain[0].ivars[0].encoding = "A".repeat(8193); },
    (r) => { r.classes.push(r.classes[0]); },
    (r) => { r.classes[0].chain[0].zeroArgumentMethods[0].argumentTypes.push("Q"); },
  ]) {
    const value = report();
    mutate(value);
    assert.throws(() => validateSyntheticNativeLayoutReport(value));
  }
});

test("native diagnostic pins generated public payload and leaves preservation source independent", () => {
  const source = readFileSync(new URL("../../test/native/synthetic-native-layout.m", import.meta.url), "utf8");
  const digest = createHash("sha256").update(buildSyntheticNotePayload()).digest("hex");
  assert.ok(source.includes(`@"${digest}"`));
  assert.ok(source.includes("options[NSReadOnlyPersistentStoreOption] = @YES;"));
  const genericCheck = source.indexOf("(void)FixedNote(generic);");
  assert.ok(genericCheck > 0 && genericCheck < source.indexOf("Require(dlopen("));
  for (const forbidden of ["object_getIvar(", "methodSignatureForSelector:", "NSInvocation", "NSKeyedArchiver",
    "setValue:", "save:", "insertNewObjectForEntityForName:", "CanonicalValue(", "ANMContentSnapshot(",
    "content-preservation.h", "apple-notes-private-writer.m", "Library/Group Containers"])
    assert.ok(!source.includes(forbidden), forbidden);
  const header = readFileSync(new URL("../../native/private-helper/content-preservation.h", import.meta.url), "utf8");
  const keys = (s, start, end) => [...s.slice(s.indexOf(start), s.indexOf(end, s.indexOf(start))).matchAll(/@"([^"]+)"/g)]
    .map((m) => m[1]).sort();
  const pinned = keys(header, "NSSet *keys =", "NSMutableArray *runs");
  assert.deepEqual(keys(source, "NSSet *supported =", "NSMutableDictionary *keyClasses"), pinned);
  assert.deepEqual([...preservationKeys].sort(), pinned);
});

test("harness retains the exact ordinary sandbox and six preflights without invoking writer", () => {
  const harness = readFileSync(new URL("../test-private-native-layout-synthetic.mjs", import.meta.url), "utf8");
  const ordinary = readFileSync(new URL("../test-private-writer-synthetic-store.mjs", import.meta.url), "utf8");
  const policy = (source) => {
    const start = source.indexOf('`(version 1)');
    const end = source.indexOf('`(deny file-write*', start);
    return source.slice(start, source.indexOf('`', end + 1) + 1).replace(/\s+\+\s+/g, "+");
  };
  assert.deepEqual(policy(harness), policy(ordinary));
  for (const field of ["realHomeDenied", "globalPreferencesDenied", "preferencesDaemonDenied", "networkDenied", "fixedUserHomeVerified", "productionBundleVerified"])
    assert.ok(harness.includes(`"${field}"`));
  assert.ok(harness.includes('if (process.argv.length !== 2) throw new Error("This fixture accepts no paths or private input");'));
  assert.ok(harness.includes('assert.equal(childEnv.HOME, process.env.HOME);'));
  assert.ok(harness.includes('report.generator = JSON.parse(sandbox(generator,'));
  assert.ok(harness.includes('"--receipt-fixture"'));
  for (const forbidden of ["APPLE_NOTES_MCP_ALLOW_UNVERIFIED", "ALLOW_NOTES_RUNNING", "compose_note", "APPLE_NOTES_MCP_PRIVATE_STORE", "apple-notes-private-writer.m"])
    assert.ok(!harness.includes(forbidden), forbidden);
});


test("duplicate category declarations remain explicit bounded metadata", () => {
  const value = report();
  const layer = value.classes[0].chain[0];
  // Public metadata spellings observed in NSObject categories. No native
  // values or actual private-class acceptance layout is pinned by this case.
  const getter = { selector: "description", present: true, encoding: "@16@0:8",
    returnType: "@", argumentTypes: ["@", ":"] };
  layer.properties = [
    { name: "description", attributes: 'T@"NSString",R,C', getter },
    { name: "description", attributes: 'T@"NSString",?,R,C', getter },
  ];
  layer.zeroArgumentMethods = [getter, structuredClone(getter)];
  assert.equal(validateSyntheticNativeLayoutReport(value), value);
  assert.equal(layer.properties.length, 2);
  assert.notEqual(layer.properties[0].attributes, layer.properties[1].attributes);
  assert.equal(layer.zeroArgumentMethods.length, 2);
  layer.properties[1].value = "payload additions still refuse";
  assert.throws(() => validateSyntheticNativeLayoutReport(value));
});
