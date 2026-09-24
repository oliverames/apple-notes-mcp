/**
 * Structured compose: block validation and flattening, the Markdown importer,
 * and the writer client. A Node script stands in for the native writer so the
 * real spawn, checksum, gating, and response-validation paths run.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sha256Hex } from "./privateHelper.js";
import {
  COMPOSE_LIVE_VALIDATED,
  PRIVATE_WRITER_PROTOCOL,
  PrivateWriteError,
  WRITER_BINARY_NAME,
  WRITER_MANIFEST_NAME,
  defaultWriterDeps,
  privateWriterCapabilities,
  type PrivateHelperDeps,
} from "./privateWriter.js";
import {
  MAX_COMPOSE_UTF16,
  assertComposeWritesAllowed,
  blocksToParagraphs,
  composeNote,
  crossCheckWithDatabase,
  markdownToBlocks,
  noteLinkUrl,
  parseInline,
  type WireParagraph,
} from "./privateCompose.js";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const REV = `r1:${"a".repeat(64)}`;

function caught(fn: () => unknown): PrivateWriteError {
  try {
    fn();
  } catch (error) {
    if (error instanceof PrivateWriteError) return error;
    throw error;
  }
  throw new Error("expected a PrivateWriteError");
}

describe("blocksToParagraphs", () => {
  it("maps every text block type to a Notes paragraph style", () => {
    const out = blocksToParagraphs([
      { type: "heading", text: "H" },
      { type: "subheading", text: "S" },
      { type: "body", text: "B" },
      { type: "paragraph", text: "P" },
      { type: "quote", text: "Q" },
      { type: "code", text: "C" },
      { type: "monospaced", text: "M" },
    ]);
    expect(out.map((p) => [p.style, p.blockQuote ?? false])).toEqual([
      ["heading", false],
      ["subheading", false],
      ["body", false],
      ["body", false],
      ["body", true],
      ["monospaced", false],
      ["monospaced", false],
    ]);
  });

  it("splits block text on newlines and keeps inner blank lines", () => {
    const out = blocksToParagraphs([{ type: "code", text: "a\n\n\tb\n" }]);
    expect(out).toEqual([
      { style: "monospaced", runs: [{ text: "a" }] },
      { style: "monospaced", runs: [] },
      { style: "monospaced", runs: [{ text: "\tb" }] },
    ]);
  });

  it("keeps runs as one paragraph and normalizes their attributes", () => {
    const [p] = blocksToParagraphs([
      {
        type: "body",
        runs: [
          { text: "a", bold: true, italic: false },
          { text: "b", underline: true, strikethrough: true },
          { text: "c", link: "https://example.com/x", highlight: "mint", color: "#abcdef" },
        ],
      },
    ]);
    expect(p.runs).toEqual([
      { text: "a", bold: true },
      { text: "b", underline: true, strikethrough: true },
      { text: "c", link: "https://example.com/x", highlight: "mint", color: "#ABCDEF" },
    ]);
  });

  it("flattens lists with a base indent plus per-item indent", () => {
    const out = blocksToParagraphs([
      { type: "bulleted", items: ["a", { text: "b", indent: 1 }] },
      { type: "dashed", indent: 2, items: [{ runs: [{ text: "c", bold: true }] }] },
      { type: "numbered", items: ["one", "two"] },
    ]);
    expect(out).toEqual([
      { style: "bulleted", runs: [{ text: "a" }] },
      { style: "bulleted", indent: 1, runs: [{ text: "b" }] },
      { style: "dashed", indent: 2, runs: [{ text: "c", bold: true }] },
      { style: "numbered", runs: [{ text: "one" }] },
      { style: "numbered", runs: [{ text: "two" }] },
    ]);
  });

  it("takes checklist state from a checked array or from each item", () => {
    expect(
      blocksToParagraphs([{ type: "checklist", items: ["a", "b"], checked: [true, false] }]).map(
        (p) => p.checked
      )
    ).toEqual([true, false]);
    expect(
      blocksToParagraphs([
        { type: "checklist", items: [{ text: "a", checked: true }, "b", { text: "c", indent: 1 }] },
      ]).map((p) => [p.checked, p.indent ?? 0])
    ).toEqual([
      [true, 0],
      [false, 0],
      [false, 1],
    ]);
  });

  it.each([
    ["an empty list", []],
    ["an unknown block type", [{ type: "image" }]],
    ["a title block", [{ type: "title", text: "T" }]],
    ["an unknown run key", [{ type: "body", runs: [{ text: "x", size: 3 }] }]],
    ["both text and runs", [{ type: "body", text: "x", runs: [{ text: "y" }] }]],
    ["neither text nor runs", [{ type: "body" }]],
    ["empty text", [{ type: "body", text: "" }]],
    ["a newline in a list item", [{ type: "bulleted", items: ["a\nb"] }]],
    ["a carriage return", [{ type: "body", text: "a\rb" }]],
    ["an attachment glyph", [{ type: "body", text: "a\uFFFCb" }]],
    ["a newline inside a run", [{ type: "body", runs: [{ text: "a\nb" }] }]],
    ["a relative link", [{ type: "body", runs: [{ text: "x", link: "/path" }] }]],
    ["a javascript link", [{ type: "body", runs: [{ text: "x", link: "javascript:alert(1)" }] }]],
    ["a bad color", [{ type: "body", runs: [{ text: "x", color: "red" }] }]],
    ["an unknown highlight", [{ type: "body", runs: [{ text: "x", highlight: "green" }] }]],
    ["indent past the limit", [{ type: "bulleted", indent: 8, items: [{ text: "x", indent: 1 }] }]],
    [
      "two checklist state sources",
      [{ type: "checklist", items: [{ text: "a", checked: true }], checked: [true] }],
    ],
    ["a short checked array", [{ type: "checklist", items: ["a", "b"], checked: [true] }]],
    ["only blank lines", [{ type: "body", text: "\n\n" }]],
    ["a ragged table", [{ type: "table", rows: [["a", "b"], ["c"]] }]],
    ["an empty table row", [{ type: "table", rows: [[]] }]],
    ["a newline in a table cell", [{ type: "table", rows: [["a\nb"]] }]],
    ["a table past 10000 cells", [{ type: "table", rows: Array(101).fill(Array(100).fill("")) }]],
    ["a divider with fields", [{ type: "divider", text: "x" }]],
    ["a noteLink without a UUID", [{ type: "noteLink", identifier: "x", text: "t" }]],
    ["a noteLink without text", [{ type: "noteLink", identifier: NOTE, text: "" }]],
  ])("rejects %s before anything is sent", (_label, blocks) => {
    const e = caught(() => blocksToParagraphs(blocks));
    expect(e).toMatchObject({ code: "invalid_request", committed: false });
  });

  it("flattens dividers, tables, and note links", () => {
    expect(
      blocksToParagraphs([
        { type: "divider" },
        {
          type: "table",
          rows: [
            ["a", ""],
            ["", "d"],
          ],
        },
        { type: "noteLink", identifier: NOTE.toLowerCase(), text: "See" },
      ])
    ).toEqual([
      { kind: "divider" },
      {
        kind: "table",
        rows: [
          ["a", ""],
          ["", "d"],
        ],
      },
      { style: "body", runs: [{ text: "See", link: `notes://showNote?identifier=${NOTE}` }] },
    ]);
    expect(noteLinkUrl(NOTE.toLowerCase())).toBe(`notes://showNote?identifier=${NOTE}`);
  });

  it("does not trim a trailing object as if it were a blank line", () => {
    expect(blocksToParagraphs([{ type: "body", text: "x\n" }, { type: "divider" }])).toHaveLength(
      3
    );
  });

  it("enforces the paragraph and length limits", () => {
    expect(
      caught(() => blocksToParagraphs([{ type: "body", text: "x\n".repeat(2001) + "x" }])).message
    ).toMatch(/2000 paragraphs/);
    expect(
      caught(() => blocksToParagraphs([{ type: "body", text: "x".repeat(MAX_COMPOSE_UTF16) }]))
        .message
    ).toMatch(/UTF-16/);
  });
});

describe("parseInline", () => {
  it("parses emphasis, strikethrough, underline, code, and links", () => {
    expect(
      parseInline("a **b** *c* ~~d~~ <u>e</u> `f` [g](https://x.test/) <https://y.test/>")
    ).toEqual([
      { text: "a " },
      { text: "b", bold: true },
      { text: " " },
      { text: "c", italic: true },
      { text: " " },
      { text: "d", strikethrough: true },
      { text: " " },
      { text: "e", underline: true },
      { text: " f " },
      { text: "g", link: "https://x.test/" },
      { text: " " },
      { text: "https://y.test/", link: "https://y.test/" },
    ]);
  });

  it("nests styles and handles triple stars and underscores", () => {
    expect(parseInline("***both*** __b__ _i_")).toEqual([
      { text: "both", bold: true, italic: true },
      { text: " " },
      { text: "b", bold: true },
      { text: " " },
      { text: "i", italic: true },
    ]);
    expect(parseInline("*a **b** c*")).toEqual([
      { text: "a ", italic: true },
      { text: "b", italic: true, bold: true },
      { text: " c", italic: true },
    ]);
    expect(parseInline("[**x**](https://x.test/)")).toEqual([
      { text: "x", link: "https://x.test/", bold: true },
    ]);
  });

  it("leaves unmatched or unsafe syntax literal", () => {
    expect(parseInline("snake_case_name and 2 * 3 and * a*")).toEqual([
      { text: "snake_case_name and 2 * 3 and * a*" },
    ]);
    expect(parseInline("[x](javascript:alert(1)) `open")).toEqual([
      { text: "[x](javascript:alert(1)) `open" },
    ]);
    expect(parseInline("\\*not\\* **a\\*b**")).toEqual([
      { text: "*not* " },
      { text: "a*b", bold: true },
    ]);
    expect(parseInline("[x](not a url)")).toEqual([{ text: "[x](not a url)" }]);
  });
});

describe("markdownToBlocks", () => {
  it("imports headings, paragraphs, quotes, lists, checklists, and code", () => {
    const md = [
      "# Title",
      "## Section",
      "### Sub",
      "#### Deeper ###",
      "",
      "Line one",
      "line two  ",
      "hard break\\",
      "",
      "> quoted",
      "> more",
      ">",
      "> second",
      "",
      "- a",
      "  - a.1",
      "    continued",
      "- b",
      "1. one",
      "2) two",
      "- [ ] open",
      "- [x] done",
      "\t- [X] nested",
      "",
      "```js",
      "let x = 1;",
      "",
      "  y();",
      "",
      "```",
    ].join("\r\n");
    const { blocks, warnings } = markdownToBlocks(md, "Title");
    expect(warnings).toEqual([]);
    expect(blocks).toEqual([
      { type: "heading", runs: [{ text: "Section" }] },
      { type: "subheading", runs: [{ text: "Sub" }] },
      { type: "subheading", runs: [{ text: "Deeper" }] },
      { type: "body", runs: [{ text: "Line one line two" }] },
      { type: "body", runs: [{ text: "hard break" }] },
      { type: "quote", runs: [{ text: "quoted more" }] },
      { type: "quote", runs: [{ text: "second" }] },
      {
        type: "bulleted",
        items: [
          { runs: [{ text: "a" }], indent: 0 },
          { runs: [{ text: "a.1 continued" }], indent: 1 },
          { runs: [{ text: "b" }], indent: 0 },
        ],
      },
      {
        type: "numbered",
        items: [
          { runs: [{ text: "one" }], indent: 0 },
          { runs: [{ text: "two" }], indent: 0 },
        ],
      },
      {
        type: "checklist",
        items: [
          { runs: [{ text: "open" }], indent: 0, checked: false },
          { runs: [{ text: "done" }], indent: 0, checked: true },
          { runs: [{ text: "nested" }], indent: 1, checked: true },
        ],
      },
      { type: "code", text: "let x = 1;\n\n  y();" },
    ]);
    const paragraphs = blocksToParagraphs(blocks);
    expect(paragraphs.filter((p) => p.style === "checklist").map((p) => p.checked)).toEqual([
      false,
      true,
      true,
    ]);
  });

  it("keeps a leading H1 that is not the title, maps rules to dividers, and skips raw HTML", () => {
    const { blocks, warnings } = markdownToBlocks("# Other\n\n---\n<div>\nText\n\n```\n```", "T");
    expect(blocks).toEqual([
      { type: "heading", runs: [{ text: "Other" }] },
      { type: "divider" },
      { type: "body", runs: [{ text: "Text" }] },
    ]);
    expect(warnings).toEqual(["line 4: raw HTML block skipped"]);
  });

  it("imports GFM pipe tables as plain-text native tables", () => {
    const md = [
      "| Name | **Qty** |",
      "|:-----|----:|",
      "| a \\| b | 3 |",
      "| only |",
      "x | y | z",
      "",
      "after",
    ].join("\n");
    expect(markdownToBlocks(md).blocks).toEqual([
      {
        type: "table",
        rows: [
          ["Name", "Qty"],
          ["a | b", "3"],
          ["only", ""],
          ["x", "y"],
        ],
      },
      { type: "body", runs: [{ text: "after" }] },
    ]);
    expect(markdownToBlocks("a | b\nnot a separator").blocks).toEqual([
      { type: "body", runs: [{ text: "a | b not a separator" }] },
    ]);
  });

  it("drops syntax that leaves no text", () => {
    expect(markdownToBlocks("- \\\n#  \n>  ").blocks).toEqual([
      { type: "bulleted", items: [{ runs: [{ text: "\\" }], indent: 0 }] },
    ]);
  });

  it("returns to the outer level when a nested list ends", () => {
    const { blocks } = markdownToBlocks("- a\n    - b\n  - c\n- d\ntext");
    expect(blocks[0]).toMatchObject({
      items: [{ indent: 0 }, { indent: 1 }, { indent: 1 }, { indent: 0 }],
    });
    expect(blocks[1]).toEqual({ type: "body", runs: [{ text: "text" }] });
  });
});

// ---------------------------------------------------------------------------
// Writer client
// ---------------------------------------------------------------------------

const FAKE_WRITER = `#!/usr/bin/env node
let input = "";
process.stdin.on("data", (c) => (input += c));
process.stdin.on("end", () => {
  const req = JSON.parse(input);
  const mode = process.env.FAKE_MODE || "ok";
  const out = (obj, code = 0) => { process.stdout.write(JSON.stringify(obj) + "\\n"); process.exit(code); };
  const summary = (req.paragraphs || []).map((p) => ({ style: p.style, indent: p.indent || 0, blockQuote: !!p.blockQuote, ...(p.checked === undefined ? {} : { checked: p.checked }), lengthUTF16: 1, runs: [] }));
  const feature = { available: mode !== "no-compose", reason: mode === "no-compose" ? "private_api_unavailable" : null, missing: mode === "no-compose" ? ["-[ICTTTodo done]"] : [] };
  if (req.action === "probe") out({ status: "ok", protocolVersion: 1, role: "writer", readOnly: false, writesEnabled: true, os: { version: "27.2.0", notesAppVersion: "4.13" }, framework: { loaded: true, error: null }, store: { kind: "live", opened: true, reason: null, noteRows: 3 }, syncHostRunning: true, features: { readNoteState: feature, appendPlainText: feature, ...(mode === "old-writer" ? {} : { composeNote: feature }) } });
  if (req.action !== "compose_note") out({ status: "error", code: "unknown_action", message: "no" }, 1);
  if (mode === "conflict") out({ status: "error", code: "revision_conflict", message: "changed", committed: false }, 1);
  if (mode === "verify-failed") out({ status: "error", code: "verification_failed", message: "differs", committed: true, indeterminate: true }, 1);
  if (mode === "no-committed") out({ status: "error", code: "store_unavailable", message: "gone" }, 1);
  if (mode === "malformed") out({ status: "updated" });
  const base = { identifier: req.identifier, mode: req.mode, paragraphs: summary.length, insertedUTF16: 9, insertAt: 4, unitStart: 5, objectURI: "x-coredata://S/ICNote/p1", revisionBefore: "r1:" + "a".repeat(64), requiredNonSystemPaper: !!req.requireNonSystemPaper, storeKind: "live", echo: req };
  if (req.dryRun) out({ ...base, status: "planned", dryRun: true, committed: false, plan: summary });
  out({ ...base, status: "updated", committed: true, verified: true, placementVerified: true, revisionAfter: "r1:" + "c".repeat(64), modificationDate: null, title: "t", readBack: summary, cloudSync: { available: true, inICloudAccount: true, uploadPending: true }, pushScheduled: false, pushState: "awaiting_notes_app", syncHostRunning: true });
});
`;

let root: string;
let deps: (env?: Record<string, string>) => PrivateHelperDeps;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "private-compose-test-"));
  const installDir = join(root, "install");
  const sourcePath = join(root, "writer.m");
  writeFileSync(sourcePath, "// fake\n");
  mkdirSync(installDir);
  writeFileSync(join(installDir, WRITER_BINARY_NAME), FAKE_WRITER);
  chmodSync(join(installDir, WRITER_BINARY_NAME), 0o755);
  writeFileSync(
    join(installDir, WRITER_MANIFEST_NAME),
    JSON.stringify({
      schemaVersion: 1,
      protocolVersion: PRIVATE_WRITER_PROTOCOL,
      sourceSha256: sha256Hex("// fake\n"),
      binarySha256: sha256Hex(FAKE_WRITER),
      builtAt: "2026-09-23T00:00:00.000Z",
      osVersion: "27.2",
      compiler: "clang",
    })
  );
  deps = (env = {}) =>
    defaultWriterDeps({
      env: {
        PATH: process.env.PATH,
        APPLE_NOTES_MCP_PRIVATE_HELPER_DIR: installDir,
        APPLE_NOTES_MCP_ENABLE_PRIVATE: "1",
        APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES: "1",
        ...env,
      },
      platform: "darwin",
      sourcePath,
    });
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

const ALLOW = { APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "1" };
const PARAGRAPHS: WireParagraph[] = [
  { style: "heading", runs: [{ text: "H" }] },
  { style: "checklist", checked: true, runs: [{ text: "done" }] },
];
const SPAWN_TIMEOUT = { timeout: 20_000 };

describe("composeNote", SPAWN_TIMEOUT, () => {
  it("plans without the live-validation gate and sends no ifRevision", () => {
    const plan = composeNote(
      { identifier: NOTE, mode: "prepend", paragraphs: PARAGRAPHS, dryRun: true },
      deps()
    );
    expect(plan).toMatchObject({ status: "planned", committed: false, paragraphs: 2 });
    expect(plan.echo).toEqual({
      protocol: 1,
      action: "compose_note",
      identifier: NOTE,
      mode: "prepend",
      paragraphs: PARAGRAPHS,
      dryRun: true,
    });
  });

  it("applies with ifRevision, the Quick Note policy, and a heading anchor", () => {
    const result = composeNote(
      {
        identifier: NOTE,
        mode: "append",
        paragraphs: PARAGRAPHS,
        ifRevision: REV,
        requireNonSystemPaper: true,
        insertBeforeHeading: { text: "Next", occurrence: 1, expectedCount: 1 },
      },
      deps(ALLOW)
    );
    expect(result).toMatchObject({ committed: true, verified: true, pushScheduled: false });
    expect(result.echo).toMatchObject({
      ifRevision: REV,
      requireNonSystemPaper: true,
      insertBeforeHeading: { text: "Next", occurrence: 1, expectedCount: 1 },
    });
    expect(result.echo).not.toHaveProperty("dryRun");
  });

  it("refuses unguarded or unvalidated applies before spawning", () => {
    expect(COMPOSE_LIVE_VALIDATED).toBe(false);
    const base = { identifier: NOTE, mode: "append" as const, paragraphs: PARAGRAPHS };
    expect(caught(() => composeNote(base, deps(ALLOW)))).toMatchObject({
      code: "invalid_request",
      committed: false,
    });
    expect(caught(() => composeNote({ ...base, ifRevision: "r1:x" }, deps(ALLOW))).code).toBe(
      "invalid_request"
    );
    expect(caught(() => composeNote({ ...base, ifRevision: REV }, deps()))).toMatchObject({
      code: "not_live_validated",
      committed: false,
    });
    expect(caught(() => composeNote({ ...base, dryRun: true, ifRevision: REV }, deps())).code).toBe(
      "invalid_request"
    );
    expect(
      caught(() =>
        composeNote(
          { ...base, mode: "prepend", dryRun: true, insertBeforeHeading: { text: "x" } },
          deps()
        )
      ).message
    ).toMatch(/append mode/);
    expect(
      caught(() => composeNote({ ...base, identifier: "nope", dryRun: true }, deps())).code
    ).toBe("invalid_request");
  });

  it("passes conflicts and committed verification failures through", () => {
    const apply = {
      identifier: NOTE,
      mode: "append" as const,
      paragraphs: PARAGRAPHS,
      ifRevision: REV,
    };
    expect(
      caught(() => composeNote(apply, deps({ ...ALLOW, FAKE_MODE: "conflict" })))
    ).toMatchObject({
      code: "revision_conflict",
      committed: false,
    });
    const failed = caught(() => composeNote(apply, deps({ ...ALLOW, FAKE_MODE: "verify-failed" })));
    expect(failed).toMatchObject({ code: "verification_failed", committed: true });
    expect(failed.details).toMatchObject({ indeterminate: true });
  });

  it("refuses every call, dry runs included, without both switches", () => {
    const plan = {
      identifier: NOTE,
      mode: "append" as const,
      paragraphs: PARAGRAPHS,
      dryRun: true,
    };
    expect(
      caught(() => composeNote(plan, deps({ APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES: "0" })))
    ).toMatchObject({ code: "writes_disabled", committed: false });
    expect(
      caught(() => composeNote(plan, deps({ APPLE_NOTES_MCP_ENABLE_PRIVATE: "0" })))
    ).toMatchObject({ code: "disabled", committed: false });
  });

  it("never reports a dry run as possibly committed", () => {
    const plan = {
      identifier: NOTE,
      mode: "append" as const,
      paragraphs: PARAGRAPHS,
      dryRun: true,
    };
    expect(caught(() => composeNote(plan, deps({ FAKE_MODE: "no-committed" })))).toMatchObject({
      code: "store_unavailable",
      committed: false,
    });
    expect(caught(() => composeNote(plan, deps({ FAKE_MODE: "conflict" })))).toMatchObject({
      code: "revision_conflict",
      committed: false,
    });
    expect(caught(() => composeNote(plan, deps({ FAKE_MODE: "malformed" })))).toMatchObject({
      code: "invalid_response",
      committed: false,
    });
  });

  it("treats a malformed apply response as indeterminate", () => {
    const apply = {
      identifier: NOTE,
      mode: "append" as const,
      paragraphs: PARAGRAPHS,
      ifRevision: REV,
    };
    expect(
      caught(() => composeNote(apply, deps({ ...ALLOW, FAKE_MODE: "malformed" })))
    ).toMatchObject({
      code: "invalid_response",
      committed: "unknown",
    });
  });
});

describe("compose capability", SPAWN_TIMEOUT, () => {
  it("reports compose from the probe behind the live-validation gate", () => {
    expect(privateWriterCapabilities(deps()).features.composeNote).toMatchObject({
      available: false,
      reason: "not_live_validated",
    });
    expect(privateWriterCapabilities(deps(ALLOW)).features.composeNote.available).toBe(true);
    expect(
      privateWriterCapabilities(deps({ ...ALLOW, FAKE_MODE: "no-compose" })).features.composeNote
    ).toMatchObject({ available: false, reason: "private_api_unavailable" });
    expect(
      privateWriterCapabilities(deps({ ...ALLOW, FAKE_MODE: "old-writer" })).features.composeNote
    ).toMatchObject({ available: false, reason: "private_api_unavailable" });
  });

  it("exposes the write gate", () => {
    expect(() => assertComposeWritesAllowed({})).toThrow(/live validation/);
    expect(() => assertComposeWritesAllowed(ALLOW)).not.toThrow();
  });
});

describe("crossCheckWithDatabase", () => {
  const readBack = [
    {
      style: "heading",
      indent: 0,
      blockQuote: false,
      lengthUTF16: 1,
      runs: [{ length: 1, attributes: {} }],
    },
    {
      style: "checklist",
      indent: 1,
      blockQuote: false,
      checked: true,
      lengthUTF16: 4,
      runs: [
        { length: 2, attributes: { bold: true } },
        { length: 2, attributes: { link: "https://x.test/" } },
      ],
    },
  ];
  const result = {
    storeKind: "live",
    objectURI: "x-coredata://S/ICNote/p1",
    unitStart: 5,
    readBack,
  } as unknown as Parameters<typeof crossCheckWithDatabase>[0];
  const block = (extra: Record<string, unknown>) => ({
    style: "body",
    indent: 0,
    blockQuote: false,
    length: 1,
    runs: [],
    ...extra,
  });
  const doc = (blocks: unknown[]) => () => ({ blocks }) as never;
  const matching = [
    block({ start: 0, style: "title" }),
    block({ start: 5, style: "heading", runs: [{ length: 1 }] }),
    block({
      start: 7,
      style: "checklist",
      indent: 1,
      length: 4,
      checklist: { id: "a", done: true },
      runs: [
        { length: 2, bold: true },
        { length: 2, link: "https://x.test/", linkSafe: true },
      ],
    }),
  ];

  it("confirms a matching decode", () => {
    expect(crossCheckWithDatabase(result, doc(matching))).toEqual({ checked: true, matches: true });
  });

  it("names every mismatched field", () => {
    const changed = [...matching];
    changed[2] = {
      ...matching[2],
      checklist: { id: "a", done: false },
      runs: [{ length: 4, bold: true }],
    };
    const check = crossCheckWithDatabase(result, doc(changed));
    expect(check.matches).toBe(false);
    expect(check.mismatches).toEqual([
      "paragraph 1 checked: database false, writer true",
      'paragraph 1 attributes: database {"bold":4}, writer {"bold":2,"link":2}',
    ]);
    expect(crossCheckWithDatabase(result, doc(matching.slice(0, 2))).mismatches).toEqual([
      "paragraph 1: missing",
    ]);
    expect(crossCheckWithDatabase(result, doc([block({ start: 0 })])).mismatches).toEqual([
      "no paragraph starts at unitStart",
    ]);
  });

  it("reports why it could not check, without throwing", () => {
    expect(
      crossCheckWithDatabase({ ...result, storeKind: "copy" } as never, doc([]))
    ).toMatchObject({ checked: false });
    const failing = () => {
      throw new Error("The Notes database is not readable");
    };
    expect(crossCheckWithDatabase(result, failing)).toEqual({
      checked: false,
      reason: "The Notes database is not readable",
    });
    const raw = () => {
      throw "raw";
    };
    expect(crossCheckWithDatabase(result, raw)).toEqual({ checked: false, reason: "raw" });
  });

  it("reads NoteStore by default and reports an unreadable note", () => {
    const check = crossCheckWithDatabase({ ...result, objectURI: "not-an-id" } as never);
    expect(check).toMatchObject({ checked: false });
    expect(check.reason).toMatch(/Invalid note ID/);
  });
});
