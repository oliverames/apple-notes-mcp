/** Source wiring checks; synthetic comparator behavior is tested separately. */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));

describe("preservation integration boundaries", () => {
  const source = readFileSync(
    join(root, "native/private-helper/apple-notes-private-writer.m"),
    "utf8"
  );
  it("captures compose attributes before materialization and compares before save and fresh readback", () => {
    const compose = source.slice(
      source.indexOf("static NSDictionary *HandleComposeNote(NSDictionary *request) {"),
      source.indexOf("// Checklist identities")
    );
    expect(compose.indexOf("ANMContentSnapshot(existing")).toBeLessThan(
      compose.indexOf("MaterializeObjects(unit, note)")
    );
    expect(compose.indexOf("ANMContentInsertionMatches")).toBeLessThan(
      compose.indexOf("SaveOrFail(context)")
    );
    expect(compose.match(/ANMContentInsertionMatches/g)).toHaveLength(2);
  });
  it("retains expected-change filters and compares complete surviving table content before and after save", () => {
    const table = source.slice(
      source.indexOf("static NSDictionary *CommitTableEdit("),
      source.indexOf("static NSDictionary *LoadedSnapshot(")
    );
    expect(table.match(/ANMTableContentMatches/g)).toHaveLength(2);
    expect(table.match(/ANMContentMatches/g)).toHaveLength(2);
    expect(table.match(/FrozenDrift/g)).toHaveLength(3);
    expect(table.indexOf("FreshFrozenAttachments")).toBeLessThan(
      table.indexOf("SaveOrFail(target.context)")
    );
    expect(table).toContain(
      "RequireExpectedChanges(target.context, @[ target.note, target.attachment ], [NSSet set])"
    );
    expect(table).toContain('"indeterminate" : @YES');
  });
  it("keeps prune tombstone verification separate from unrelated attachment and full body checks", () => {
    const prune = source.slice(
      source.indexOf("static NSDictionary *HandlePruneOrphanTable(NSDictionary *request) {"),
      source.indexOf(
        "#pragma mark",
        source.indexOf("static NSDictionary *HandlePruneOrphanTable(NSDictionary *request) {")
      )
    );
    expect(prune.match(/ANMContentMatches/g)).toHaveLength(2);
    expect(prune.match(/FrozenDrift/g)).toHaveLength(3);
    expect(prune.indexOf("FreshFrozenAttachments")).toBeLessThan(
      prune.indexOf("SaveOrFail(target.context)")
    );
    expect(prune).toContain("The pruned table's attachment row is missing after the save");
    expect(prune).toContain("The table is not marked for deletion after the save");
    expect(prune).toContain('"indeterminate" : @YES');
  });
});
