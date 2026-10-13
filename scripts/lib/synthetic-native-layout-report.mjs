// Exact metadata envelope. Reject additional fields so unexpected native
// payloads never become a shareable layout report. No native module imports.
import assert from "node:assert/strict";

// Membership in this unchanged key set says nothing about value/layout support.
export const preservationKeys = ["TTStyle", "TTHints", "TTUnderline", "TTStrikethrough",
  "TTEmphasis", "TTColor", "TTTimestamp", "TTFont", "NSFont", "NSLink", "NSAttachment"];

function record(value, keys) {
  assert.ok(value !== null && typeof value === "object" && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), [...keys].sort());
}
function metadata(value, max = 8192) {
  assert.equal(typeof value, "string");
  assert.ok(value.length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/u.test(value));
}
function integer(value, max = Number.MAX_SAFE_INTEGER) {
  assert.ok(Number.isSafeInteger(value) && value >= 0 && value <= max);
}
function list(value, max) {
  assert.ok(Array.isArray(value) && value.length <= max);
}
function sortedNames(records, field) {
  const names = records.map((r) => r[field]);
  assert.deepEqual(names, [...names].sort());
}
function uniqueNames(records, field) {
  assert.equal(new Set(records.map((r) => r[field])).size, records.length);
  sortedNames(records, field);
}
function method(value) {
  record(value, value.present
    ? ["selector", "present", "encoding", "returnType", "argumentTypes"]
    : ["selector", "present"]);
  metadata(value.selector);
  assert.equal(typeof value.present, "boolean");
  if (value.present) {
    metadata(value.encoding);
    metadata(value.returnType);
    list(value.argumentTypes, 32);
    assert.ok(value.argumentTypes.length >= 2);
    value.argumentTypes.forEach((v) => metadata(v));
  }
}

export function validateSyntheticNativeLayoutReport(report) {
  record(report, ["schemaVersion", "kind", "syntheticOnly", "fixedPublicBodyVerified", "readOnlyStore",
    "attributeFieldValuesRead", "nativeAttributeGettersInvoked", "preservationPinsChanged", "bodyUTF16",
    "attributeRuns", "attributes", "classes", "tableCellCoverage", "nestedValueCoverage"]);
  assert.equal(report.schemaVersion, 1);
  assert.equal(report.kind, "fixed-public-native-layout-metadata");
  for (const field of ["syntheticOnly", "fixedPublicBodyVerified", "readOnlyStore"])
    assert.equal(report[field], true);
  for (const field of ["attributeFieldValuesRead", "nativeAttributeGettersInvoked", "preservationPinsChanged"])
    assert.equal(report[field], false);
  assert.equal(report.bodyUTF16, 184);
  integer(report.attributeRuns, 128);
  assert.ok(report.attributeRuns > 0);
  assert.equal(report.tableCellCoverage, "unavailable:no-table-in-fixed-seed");
  assert.equal(report.nestedValueCoverage, "unavailable:no-attribute-value-traversal");
  list(report.attributes, 64);
  list(report.classes, 64);
  uniqueNames(report.attributes, "key");
  uniqueNames(report.classes, "name");
  const classes = new Set(report.classes.map((item) => item.name));
  for (const attribute of report.attributes) {
    record(attribute, ["key", "supportedKey", "valueClasses"]);
    metadata(attribute.key, 128);
    assert.equal(attribute.supportedKey, preservationKeys.includes(attribute.key));
    list(attribute.valueClasses, 64);
    assert.ok(attribute.valueClasses.length > 0);
    assert.deepEqual(attribute.valueClasses, [...new Set(attribute.valueClasses)].sort());
    for (const name of attribute.valueClasses) {
      metadata(name);
      assert.ok(classes.has(name));
    }
  }
  for (const cls of report.classes) {
    record(cls, ["name", "chain"]);
    metadata(cls.name);
    list(cls.chain, 32);
    assert.ok(cls.chain.length > 0);
    assert.equal(cls.chain[0].name, cls.name);
    const seen = new Set();
    for (const [index, layer] of cls.chain.entries()) {
      record(layer, ["name", "superclass", "instanceSize", "ivars", "properties", "zeroArgumentMethods"]);
      metadata(layer.name);
      assert.ok(!seen.has(layer.name));
      seen.add(layer.name);
      integer(layer.instanceSize);
      if (layer.superclass !== null) metadata(layer.superclass);
      assert.equal(layer.superclass, cls.chain[index + 1]?.name ?? null);
      list(layer.ivars, 1024);
      list(layer.properties, 1024);
      list(layer.zeroArgumentMethods, 2048);
      uniqueNames(layer.ivars, "name");
      // Objective-C categories/protocol declarations may duplicate names.
      // Retain every bounded metadata record, rather than dropping entries
      // or mistaking duplicate declarations for unsafe content payloads.
      sortedNames(layer.properties, "name");
      sortedNames(layer.zeroArgumentMethods, "selector");
      for (const ivar of layer.ivars) {
        record(ivar, ["name", "encoding", "offset"]);
        metadata(ivar.name);
        metadata(ivar.encoding);
        integer(ivar.offset);
      }
      for (const property of layer.properties) {
        record(property, ["name", "attributes", "getter"]);
        metadata(property.name);
        metadata(property.attributes);
        method(property.getter);
      }
      for (const getter of layer.zeroArgumentMethods) {
        method(getter);
        assert.equal(getter.present, true);
        assert.equal(getter.argumentTypes.length, 2);
      }
    }
  }
  return report;
}
