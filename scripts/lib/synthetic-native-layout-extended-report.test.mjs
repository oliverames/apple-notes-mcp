import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { validateSyntheticNativeLayoutReport } from "./synthetic-native-layout-extended-report.mjs";
function report() {
  return {
    schemaVersion: 2, kind: "fixed-public-native-layout-metadata", syntheticOnly: true,
    fixedPublicBodyVerified: true, readOnlyStore: true, scalarAttributeFieldValuesRead: false,
    nativeAttributeGettersInvoked: false, preservationPinsChanged: false, bodyUTF16: 184,
    attributeRuns: 6, attributes: [], classes: [], tableCellCoverage: "unavailable:no-table-in-fixed-seed",
    nestedValueCoverage: "class-only:nativeFont-no-values", nestedStoredReferenceClassOnly: true,
    fixedClassMetadata: ["ICTTTodo", "ICTTMutableParagraphStyle", "ICTable", "ICTTMergeableString", "ICTTMergeableAttributedString", "ICTTAttachment"]
      .map((name) => ({ name, present: false })),
    nestedNativeFontClasses: [{ ownerClass: "ICTTFont", storedField: "_nativeFont", nil: true, valueClass: null }],
  };
}
test("strict extended class-only envelope accepts absent/nil metadata without claiming values", () => {
  const r = report();
  assert.equal(validateSyntheticNativeLayoutReport(r), r);
});
test("all value payloads, getter/value broadening and unreviewed fields refuse", () => {
  for (const mutate of [
    (r) => { r.value = "forbidden"; },
    (r) => { r.fixedClassMetadata[0].value = "forbidden"; },
    (r) => { r.nestedNativeFontClasses[0].description = "forbidden"; },
    (r) => { r.scalarAttributeFieldValuesRead = true; },
    (r) => { r.nativeAttributeGettersInvoked = true; },
    (r) => { r.nestedStoredReferenceClassOnly = false; },
    (r) => { r.nestedValueCoverage = "complete"; },
    (r) => { r.nestedNativeFontClasses[0].valueClass = "Unknown"; },
    (r) => { r.nestedNativeFontClasses[0].nil = false; },
    (r) => { r.fixedClassMetadata[0].present = true; },
    (r) => { r.fixedClassMetadata[0].name = "Unknown"; },
  ]) {
    const r = report(); mutate(r); assert.throws(() => validateSyntheticNativeLayoutReport(r));
  }
});
test("source reads one exact known nested object reference and never calls attribute getters or mutation APIs", () => {
  const source = readFileSync(new URL("../../test/native/synthetic-native-layout-extended.m", import.meta.url), "utf8");
  assert.equal((source.match(/object_getIvar\(/g) ?? []).length, 1);
  assert.ok(source.includes('strcmp(ivar_getTypeEncoding(field), "@") == 0 && ivar_getOffset(field) == 32'));
  assert.ok(source.includes('class_getInstanceSize(cls) == 40'));
  assert.ok(source.includes('options[NSReadOnlyPersistentStoreOption] = @YES;'));
  for (const forbidden of ["methodSignatureForSelector:", "NSInvocation", "NSKeyedArchiver", "setValue:", "save:",
    "insertNewObjectForEntityForName:", "ANMContentSnapshot(", "content-preservation.h", "apple-notes-private-writer.m",
    "Library/Group Containers"])
    assert.ok(!source.includes(forbidden), forbidden);
});
test("harness has unchanged inner sandbox, six preflights, fresh-root and exact raw ledgers", () => {
  const harness = readFileSync(new URL("../test-private-native-layout-extended-synthetic.mjs", import.meta.url), "utf8");
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
    'if (process.argv.length !== 2) throw new Error("This fixture accepts no paths or private input");'])
    assert.ok(harness.includes(snippet), snippet);
});

test("exact bounded Objective-C comparison 0/1 metadata stays explicit without values", () => {
  const r = report(); r.fixedClassMetadata.forEach((x) => { x.present = 0; }); r.nestedNativeFontClasses[0].nil = 1;
  assert.equal(validateSyntheticNativeLayoutReport(r), r);
  for (const invalid of [2, -1, "1", null]) {
    const a = report(); a.fixedClassMetadata[0].present = invalid; assert.throws(() => validateSyntheticNativeLayoutReport(a));
    const b = report(); b.nestedNativeFontClasses[0].nil = invalid; assert.throws(() => validateSyntheticNativeLayoutReport(b));
  }
});
