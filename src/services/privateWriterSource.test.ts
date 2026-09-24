/**
 * Source contract for the opt-in private WRITER (apple-notes-private-writer.m).
 *
 * The writer is allowed to save, so the read-only source test does not apply
 * to it. These tests pin the safety contract every write must keep instead:
 * the action table matches the client's, write actions take an `ifRevision`
 * compare-and-swap token, the live store is opened read-write only behind the
 * writer's own switch, saves use NSErrorMergePolicy, reads stay read-only,
 * and a fresh read-back runs through a new coordinator.
 */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { packageRoot } from "./privateHelper.js";
import { WRITER_ACTIONS, WRITER_SOURCE_RELATIVE } from "./privateWriter.js";

const SOURCE = readFileSync(join(packageRoot(__dirname), WRITER_SOURCE_RELATIVE), "utf8");
const CODE = SOURCE.replace(/\/\*[\s\S]*?\*\//g, "")
  .replace(/\/\/.*$/gm, "")
  .replace(/@?"(?:[^"\\\n]|\\.)*"/g, '""');

/**
 * Write actions that legitimately take no ifRevision. Each entry needs a
 * reason; none exist in the foundation.
 */
const NO_REVISION_WRITES: Record<string, string> = {};

function actionRows(): Array<{ name: string; keys: string[]; handler: string }> {
  const table = SOURCE.slice(SOURCE.indexOf("kActions[] = {"));
  const rows = table.slice(0, table.indexOf("};"));
  return [...rows.matchAll(/\{"([a-z_]+)",\s*"([^"]*)",\s*(\w+)\}/g)].map((m) => ({
    name: m[1],
    keys: m[2] ? m[2].split(",") : [],
    handler: m[3],
  }));
}

/** The body of `static NSDictionary *<name>(NSDictionary *request) { ... }`. */
function handlerBody(name: string): string {
  const start = CODE.indexOf(`*${name}(NSDictionary *request) {`);
  expect(start, `handler ${name}`).toBeGreaterThan(-1);
  let depth = 0;
  for (let i = CODE.indexOf("{", start); i < CODE.length; i++) {
    if (CODE[i] === "{") depth++;
    if (CODE[i] === "}" && --depth === 0) return CODE.slice(start, i + 1);
  }
  throw new Error(`unterminated ${name}`);
}

describe("private writer source contract", () => {
  it("offers exactly the actions the client table lists", () => {
    const names = actionRows().map((row) => row.name);
    expect(new Set(names)).toEqual(new Set(Object.keys(WRITER_ACTIONS)));
    expect(names).toHaveLength(Object.keys(WRITER_ACTIONS).length);
  });

  it("takes an ifRevision compare-and-swap token on every write action", () => {
    for (const row of actionRows()) {
      if (WRITER_ACTIONS[row.name] !== "write" || row.name in NO_REVISION_WRITES) continue;
      expect(row.keys, row.name).toContain("ifRevision");
      expect(handlerBody(row.handler), row.name).toMatch(/ifRevision/);
    }
  });

  it("never opens a read-write context from a read action", () => {
    for (const row of actionRows()) {
      if (WRITER_ACTIONS[row.name] !== "read") continue;
      const body = handlerBody(row.handler);
      expect(body, row.name).not.toMatch(/OpenContext\([^)]*,\s*NO\)/);
      expect(body, row.name).not.toMatch(/\bsave\s*:/);
    }
  });

  it("opens the live store read-write only behind its own switch", () => {
    expect(SOURCE).toMatch(/kWritesEnv = @"APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES"/);
    expect(CODE).toMatch(/if \(!readOnly && !store\.isCopy &&/);
    expect(SOURCE).toMatch(/Fail\(@"writes_disabled"/);
    // Exactly one opener adds a persistent store; reads pass YES.
    expect(CODE.match(/addPersistentStoreWithType/g)).toHaveLength(1);
    expect(CODE).toMatch(/if \(readOnly\) options\[NSReadOnlyPersistentStoreOption\] = @YES/);
    expect(CODE).toMatch(/options\[NSMigratePersistentStoresAutomaticallyOption\] = @NO/);
  });

  it("saves with optimistic locking and verifies through a fresh read-only stack", () => {
    expect(CODE).toMatch(/context\.mergePolicy = NSErrorMergePolicy/);
    expect(CODE).toMatch(/OpenContext\(store, YES\)/);
    expect(SOURCE).toMatch(/@"committed" : @YES/);
    expect(SOURCE).toMatch(/@"committed" : @NO/);
  });

  it("never issues SQL or a batch request", () => {
    expect(CODE).not.toMatch(/sqlite3_(?:exec|prepare)/);
    expect(CODE).not.toMatch(/NSBatch(?:Update|Delete|Insert)Request/);
  });

  it("plans edits read-only and verifies an applied edit outside its ranges", () => {
    const plan = handlerBody("HandlePlanEdit");
    expect(plan).toMatch(/OpenContext\(store, YES\)/);
    expect(plan).toMatch(/\[context rollback\]/);
    const apply = handlerBody("HandleEditNote");
    expect(apply).toMatch(/RequireString\(request, ""\)/);
    expect(apply).toMatch(
      /OpenContext\(store, NO\)[\s\S]*SaveOrFail\(context\)[\s\S]*OpenContext\(store, YES\)/
    );
    expect(apply).toMatch(/VerifyAgainstPlan\(persisted, plan\)/);
    expect(apply).toMatch(/AttachmentIdentifiers\(reread\)/);
    // Formatting outside the edits is compared run by run, including
    // timestamps, and the glyph sequence against the planned text.
    expect(CODE).toMatch(/CanonicalRuns\(plan\.snapshot, oldRange, NO\)/);
    expect(CODE).toMatch(
      /AttachmentGlyphs\(persisted\) isEqual:AttachmentGlyphs\(plan\.expected\)/
    );
    // One entry per glyph character, so two adjacent glyphs of one attachment
    // (Notes stores AppleScript-added images that way) are not merged into one run.
    expect(CODE).toMatch(
      /for \(NSUInteger i = 0; i < range\.length; i\+\+\) \[glyphs addObject:canonical\]/
    );
    // No target may contain an attachment glyph unless its selector kind allows it.
    expect(CODE).toMatch(
      /static BOOL TargetMayTouchAttachment\(NSString \*kind\) \{\s*\(void\)kind;\s*return NO;/
    );
    // Only the note, its data, and its cloud state may be dirty before a save.
    expect(SOURCE).toMatch(
      /Fail\(@"unexpected_side_effect",[\s\S]{0,400}?@"objects" : unexpected\}/
    );
  });

  it("trims only whole empty text paragraphs, never the title or an attachment", () => {
    const trimmable = CODE.slice(CODE.indexOf("static BOOL IsTrimmableBlank("));
    const body = trimmable.slice(0, trimmable.indexOf("\n}\n"));
    expect(body).toMatch(/if \(p\.index == 0\) return NO;/);
    expect(SOURCE).toMatch(
      /IsTrimmableBlank[\s\S]{0,400}rangeOfString:@"\\uFFFC"\]\.location != NSNotFound\) return NO;/
    );
    expect(body).toMatch(/whitespaceCharacterSet\]\.length\) return NO;/);
    expect(body).toMatch(
      /return style == kStyleTitle \|\| style == 1 \|\| style == 2 \|\| style == kStyleBody;/
    );
    // Each removed paragraph goes with its own terminator and nothing else,
    // and the glyph guard still runs with a kind that may not touch one.
    expect(CODE).toMatch(
      /RequireNoAttachmentGlyph\(snapshot, p\.full, index, ""\);\s*NSMutableDictionary \*target = Target\(p\.full, \[NSAttributedString new\], index, p\);/
    );
  });

  it("identifies itself as the writer in hello and probe", () => {
    expect(SOURCE.match(/@"role" : @"writer"/g)).toHaveLength(2);
    expect(SOURCE.match(/@"readOnly" : @NO/g)).toHaveLength(2);
  });
});
