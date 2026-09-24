/**
 * Structured compose through the opt-in private WRITER.
 *
 * Callers describe content as ordered blocks (headings, paragraphs with
 * inline runs, lists, checklists, quotes, monospaced text) or as Markdown.
 * This module validates that input, flattens it to the writer's wire format
 * (one entry per Notes paragraph: a style name, indent, block-quote flag,
 * checklist state, and inline runs), and sends the writer's `compose_note`
 * action (services/privateWriter.ts), which follows the writer's write
 * contract: both switches, the `ifRevision` compare-and-swap, a save with
 * optimistic locking, and a fresh read-only read-back.
 *
 * The writer inserts the whole unit through the note's CRDT in one save,
 * guarded by the `ifRevision` compare-and-swap token, and verifies every
 * paragraph's style, checklist state, and runs in a fresh Core Data stack.
 *
 * @module services/privateCompose
 */
import { z } from "zod";
import {
  COMPOSE_LIVE_VALIDATED,
  PrivateWriteError,
  assertNoteIdentifier,
  callPrivateWriter,
  defaultWriterDeps,
  parseWriterResult,
  requireLiveValidated,
  writeSyncFields,
  type PrivateHelperDeps,
} from "./privateWriter.js";
import { readNoteBlocks, type NoteBlock, type NoteBlocksDocument } from "../utils/noteBlocks.js";

export const HIGHLIGHTS = ["purple", "pink", "orange", "mint", "blue"] as const;
export const MAX_INDENT = 8;
export const MAX_PARAGRAPHS = 2000;
export const MAX_COMPOSE_UTF16 = 200_000;
const LINK_SCHEMES = new Set(["http:", "https:", "mailto:", "tel:", "notes:", "applenotes:"]);

/** Paragraph styles the writer writes. The title style is never written. */
export type WireStyle =
  | "heading"
  | "subheading"
  | "body"
  | "monospaced"
  | "bulleted"
  | "dashed"
  | "numbered"
  | "checklist";

export interface WireRun {
  text: string;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
  strikethrough?: boolean;
  link?: string;
  highlight?: (typeof HIGHLIGHTS)[number];
  color?: string;
}

export interface WireParagraph {
  style: WireStyle;
  indent?: number;
  blockQuote?: boolean;
  checked?: boolean;
  /** Empty only for a blank line that is not the last paragraph. */
  runs: WireRun[];
}

// ---------------------------------------------------------------------------
// Block schema (the public input)
// ---------------------------------------------------------------------------

export const runSchema = z
  .object({
    text: z.string().min(1),
    bold: z.boolean().optional(),
    italic: z.boolean().optional(),
    underline: z.boolean().optional(),
    strikethrough: z.boolean().optional(),
    link: z
      .string()
      .min(1)
      .max(4096)
      .optional()
      .describe("http(s), mailto, tel, notes, applenotes"),
    highlight: z.enum(HIGHLIGHTS).optional(),
    color: z
      .string()
      .regex(/^#[0-9A-Fa-f]{6}$/)
      .optional()
      .describe("Text color as #RRGGBB"),
  })
  .strict();

const indentSchema = z.number().int().min(0).max(MAX_INDENT);
const inlineShape = {
  text: z.string().optional().describe("Plain text; each \\n starts a new paragraph"),
  runs: z.array(runSchema).min(1).optional().describe("Formatted runs forming one paragraph"),
};

const textBlock = <T extends string>(type: T) =>
  z.object({ type: z.literal(type), ...inlineShape }).strict();

const listItem = z.union([
  z.string().min(1),
  z.object({ ...inlineShape, indent: indentSchema.optional() }).strict(),
]);
const checklistItem = z.union([
  z.string().min(1),
  z
    .object({ ...inlineShape, indent: indentSchema.optional(), checked: z.boolean().optional() })
    .strict(),
]);
const listBlock = <T extends string>(type: T) =>
  z
    .object({
      type: z.literal(type),
      items: z.array(listItem).min(1),
      indent: indentSchema.optional().describe("Base indent added to every item"),
    })
    .strict();

export const blockSchema = z.discriminatedUnion("type", [
  textBlock("heading"),
  textBlock("subheading"),
  textBlock("body"),
  textBlock("paragraph"),
  textBlock("quote"),
  textBlock("code"),
  textBlock("monospaced"),
  listBlock("bulleted"),
  listBlock("dashed"),
  listBlock("numbered"),
  z
    .object({
      type: z.literal("checklist"),
      items: z.array(checklistItem).min(1),
      checked: z.array(z.boolean()).optional().describe("Per-item state, same length as items"),
      indent: indentSchema.optional(),
    })
    .strict(),
]);
export type ComposeBlock = z.infer<typeof blockSchema>;

// ---------------------------------------------------------------------------
// Validation and flattening
// ---------------------------------------------------------------------------

function invalid(message: string): PrivateWriteError {
  return new PrivateWriteError("invalid_request", message, false);
}

/**
 * Control characters other than tab, the attachment glyph U+FFFC, and the
 * Unicode line and paragraph separators. Newlines are handled by the caller.
 */
// eslint-disable-next-line no-control-regex
const FORBIDDEN = /[\x00-\x08\x0A-\x1F\x7F-\x9F\uFFFC\u2028\u2029]/u;

function assertLine(text: string, where: string): void {
  if (FORBIDDEN.test(text))
    throw invalid(
      `${where}: text may contain only printable characters and tabs (no \\r, control ` +
        "characters, or attachment glyphs); a newline is allowed only in a block's `text`"
    );
}

function assertLink(link: string): void {
  let url: URL;
  try {
    url = new URL(link);
  } catch {
    throw invalid(`Run link is not an absolute URL: ${link}`);
  }
  if (!LINK_SCHEMES.has(url.protocol))
    throw invalid("Run link must use http, https, mailto, tel, notes, or applenotes");
}

function wireRun(run: z.infer<typeof runSchema>, where: string): WireRun {
  assertLine(run.text, where);
  if (run.link) assertLink(run.link);
  const out: WireRun = { text: run.text };
  for (const key of ["bold", "italic", "underline", "strikethrough"] as const)
    if (run[key]) out[key] = true;
  if (run.link) out.link = run.link;
  if (run.highlight) out.highlight = run.highlight;
  if (run.color) out.color = run.color.toUpperCase();
  return out;
}

/** `text` (split on \n) or `runs` (one paragraph), never both, never neither. */
function inlineLines(
  value: { text?: string; runs?: Array<z.infer<typeof runSchema>> },
  where: string,
  allowNewlines: boolean
): WireRun[][] {
  if ((value.text === undefined) === (value.runs === undefined))
    throw invalid(`${where}: give exactly one of text or runs`);
  if (value.runs) return [value.runs.map((run) => wireRun(run, where))];
  const text = value.text as string;
  if (!text.length) throw invalid(`${where}: text must not be empty`);
  const lines = text.split("\n");
  if (lines.length > 1 && !allowNewlines)
    throw invalid(`${where}: list and checklist items are one line each`);
  return lines.map((line) => {
    assertLine(line, where);
    return line ? [{ text: line }] : [];
  });
}

function itemFields(
  item: string | { text?: string; runs?: Array<z.infer<typeof runSchema>>; indent?: number },
  where: string
): { runs: WireRun[]; indent: number } {
  if (typeof item === "string")
    return { runs: inlineLines({ text: item }, where, false)[0], indent: 0 };
  return { runs: inlineLines(item, where, false)[0], indent: item.indent ?? 0 };
}

const TEXT_STYLES: Record<string, { style: WireStyle; blockQuote?: boolean }> = {
  heading: { style: "heading" },
  subheading: { style: "subheading" },
  body: { style: "body" },
  paragraph: { style: "body" },
  quote: { style: "body", blockQuote: true },
  code: { style: "monospaced" },
  monospaced: { style: "monospaced" },
};

/**
 * Validate blocks and flatten them to one wire paragraph per Notes paragraph.
 * Throws `invalid_request` (committed: false) before anything is sent.
 */
export function blocksToParagraphs(input: unknown): WireParagraph[] {
  const parsed = z.array(blockSchema).min(1).safeParse(input);
  if (!parsed.success)
    throw invalid(
      "Invalid blocks: " +
        parsed.error.issues.map((i) => `${i.path.join(".")} ${i.message}`).join("; ")
    );
  const out: WireParagraph[] = [];
  parsed.data.forEach((block, index) => {
    const where = `blocks[${index}] (${block.type})`;
    if (block.type in TEXT_STYLES) {
      const { style, blockQuote } = TEXT_STYLES[block.type];
      const textBlock = block as { text?: string; runs?: Array<z.infer<typeof runSchema>> };
      for (const runs of inlineLines(textBlock, where, true))
        out.push({ style, ...(blockQuote ? { blockQuote } : {}), runs });
      return;
    }
    const list = block as Extract<ComposeBlock, { items: unknown }>;
    const base = list.indent ?? 0;
    if (list.type === "checklist") {
      const perItem = list.items.some((i) => typeof i !== "string" && i.checked !== undefined);
      if (list.checked && perItem)
        throw invalid(`${where}: give checked state per item or as a checked array, not both`);
      if (list.checked && list.checked.length !== list.items.length)
        throw invalid(`${where}: checked must have one boolean per item`);
      list.items.forEach((item, i) => {
        const { runs, indent } = itemFields(item, `${where}.items[${i}]`);
        const checked =
          typeof item !== "string" && item.checked !== undefined
            ? item.checked
            : (list.checked?.[i] ?? false);
        out.push(paragraph("checklist", runs, base + indent, where, checked));
      });
      return;
    }
    list.items.forEach((item, i) => {
      const { runs, indent } = itemFields(item, `${where}.items[${i}]`);
      out.push(paragraph(list.type as WireStyle, runs, base + indent, where));
    });
  });
  return finalizeParagraphs(out);
}

function paragraph(
  style: WireStyle,
  runs: WireRun[],
  indent: number,
  where: string,
  checked?: boolean
): WireParagraph {
  if (indent > MAX_INDENT) throw invalid(`${where}: indent exceeds ${MAX_INDENT}`);
  return {
    style,
    ...(indent ? { indent } : {}),
    ...(checked !== undefined ? { checked } : {}),
    runs,
  };
}

/** Trim trailing blank paragraphs and enforce the writer's size limits. */
function finalizeParagraphs(paragraphs: WireParagraph[]): WireParagraph[] {
  while (paragraphs.length && paragraphs[paragraphs.length - 1].runs.length === 0) paragraphs.pop();
  if (!paragraphs.length) throw invalid("The composed content is empty");
  if (paragraphs.length > MAX_PARAGRAPHS)
    throw invalid(`The composed content has more than ${MAX_PARAGRAPHS} paragraphs`);
  const length = paragraphs.reduce(
    (sum, p) => sum + p.runs.reduce((n, r) => n + r.text.length, 0) + 1,
    0
  );
  if (length > MAX_COMPOSE_UTF16)
    throw invalid(`The composed content exceeds ${MAX_COMPOSE_UTF16} UTF-16 code units`);
  return paragraphs;
}

// ---------------------------------------------------------------------------
// Markdown import
// ---------------------------------------------------------------------------

type RunStyle = Omit<WireRun, "text">;

const PAIRS: Array<{ open: string; close: string; style: RunStyle }> = [
  { open: "**", close: "**", style: { bold: true } },
  { open: "__", close: "__", style: { bold: true } },
  { open: "~~", close: "~~", style: { strikethrough: true } },
  { open: "<u>", close: "</u>", style: { underline: true } },
  { open: "*", close: "*", style: { italic: true } },
  { open: "_", close: "_", style: { italic: true } },
];

const ESCAPABLE = /[\\`*_{}[\]()#+\-.!~>|<]/;
const isWord = (ch: string | undefined) => !!ch && /[\p{L}\p{N}]/u.test(ch);

/** Position of the closing delimiter for an emphasis span opened before `from`. */
function findClose(src: string, open: string, close: string, from: number): number {
  const single = open.length === 1;
  for (let j = from; j < src.length; j++) {
    if (src[j] === "\\") {
      j++;
      continue;
    }
    if (single && src.startsWith(open + open, j)) {
      j++;
      continue;
    }
    if (!src.startsWith(close, j) || j === from || /\s/.test(src[j - 1])) continue;
    let end = j;
    // `***x***`: the bold span closes on the LAST two of the three stars.
    if (!single) while (src.startsWith(close, end + 1)) end++;
    if (open === "_" && isWord(src[end + 1])) continue;
    return end;
  }
  return -1;
}

/** Parse Markdown inline syntax into runs. Unmatched syntax stays literal. */
export function parseInline(src: string, base: RunStyle = {}): WireRun[] {
  const runs: WireRun[] = [];
  let buffer = "";
  const flush = () => {
    if (buffer) runs.push({ text: buffer, ...base });
    buffer = "";
  };
  let i = 0;
  outer: while (i < src.length) {
    const ch = src[i];
    if (ch === "\\" && ESCAPABLE.test(src[i + 1] ?? "")) {
      buffer += src[i + 1];
      i += 2;
      continue;
    }
    if (ch === "`") {
      const end = src.indexOf("`", i + 1);
      if (end > i + 1) {
        buffer += src.slice(i + 1, end); // Notes has no inline code style
        i = end + 1;
        continue;
      }
    }
    if (ch === "[") {
      const m = /^\[([^\]]+)\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)/.exec(src.slice(i));
      if (m && safeLink(m[2])) {
        flush();
        runs.push(...parseInline(m[1], { ...base, link: m[2] }));
        i += m[0].length;
        continue;
      }
    }
    if (ch === "<") {
      const m = /^<((?:https?|mailto):[^\s>]+)>/.exec(src.slice(i));
      if (m) {
        flush();
        runs.push({ text: m[1], ...base, link: m[1] });
        i += m[0].length;
        continue;
      }
    }
    for (const pair of PAIRS) {
      if (!src.startsWith(pair.open, i)) continue;
      const from = i + pair.open.length;
      if (/\s/.test(src[from] ?? " ")) continue;
      if (pair.open === "_" && isWord(src[i - 1])) continue;
      const end = findClose(src, pair.open, pair.close, from);
      if (end < 0) continue;
      flush();
      runs.push(...parseInline(src.slice(from, end), { ...base, ...pair.style }));
      i = end + pair.close.length;
      continue outer;
    }
    buffer += ch;
    i++;
  }
  flush();
  return mergeRuns(runs);
}

function safeLink(link: string): boolean {
  try {
    return LINK_SCHEMES.has(new URL(link).protocol);
  } catch {
    return false;
  }
}

const formatKey = (run: WireRun) => JSON.stringify({ ...run, text: undefined });

function mergeRuns(runs: WireRun[]): WireRun[] {
  const out: WireRun[] = [];
  for (const run of runs) {
    const last = out[out.length - 1];
    if (last && formatKey(last) === formatKey(run)) last.text += run.text;
    else out.push({ ...run });
  }
  return out;
}

export interface MarkdownImport {
  blocks: ComposeBlock[];
  warnings: string[];
}

const LIST_ITEM = /^([ \t]*)(?:([-*+])|(\d{1,9})[.)])[ \t]+(.*)$/;
const TASK = /^\[([ xX])\][ \t]+(.*)$/;

function columns(indent: string): number {
  let width = 0;
  for (const ch of indent) width += ch === "\t" ? 4 - (width % 4) : 1;
  return width;
}

/**
 * Convert Markdown to compose blocks: ATX headings (`#`/`##` to Heading,
 * `###`+ to Subheading), paragraphs (soft line breaks join with a space),
 * `>` quotes, fenced code, bulleted/numbered lists and `- [ ]`/`- [x]`
 * checklists with nesting, and inline bold, italic, strikethrough, `<u>`
 * underline, code spans (as plain text), and links. Horizontal rules and raw
 * HTML blocks are skipped with a warning.
 *
 * @param dropTitle - drop a leading `# ` heading equal to this note title
 */
export function markdownToBlocks(markdown: string, dropTitle?: string): MarkdownImport {
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
  const blocks: ComposeBlock[] = [];
  const warnings: string[] = [];
  let prose: string[] = [];
  let quote: string[] = [];
  let listStack: number[] = [];

  const pushText = (type: "body" | "quote" | "heading" | "subheading", text: string) => {
    const runs = parseInline(text);
    if (runs.length) blocks.push({ type, runs });
  };
  const flushProse = () => {
    if (prose.length) pushText("body", prose.join(" "));
    prose = [];
  };
  const flushQuote = () => {
    if (quote.length) pushText("quote", quote.join(" "));
    quote = [];
  };
  const flushAll = () => {
    flushProse();
    flushQuote();
  };

  // Adjacent items of one kind share a block; the paragraphs are the same
  // either way, since each item is its own Notes paragraph.
  const addItem = (
    kind: "bulleted" | "numbered" | "checklist",
    level: number,
    text: string,
    checked: boolean
  ) => {
    const runs = parseInline(text);
    if (!runs.length) return;
    const item = kind === "checklist" ? { runs, indent: level, checked } : { runs, indent: level };
    const last = blocks[blocks.length - 1];
    if (last && last.type === kind) (last.items as unknown[]).push(item);
    else blocks.push({ type: kind, items: [item] } as ComposeBlock);
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = /^[ ]{0,3}(`{3,}|~{3,})/.exec(line);
    if (fence) {
      flushAll();
      listStack = [];
      const body: string[] = [];
      let j = i + 1;
      while (j < lines.length && !lines[j].trimStart().startsWith(fence[1])) body.push(lines[j++]);
      i = j;
      while (body.length && !body[body.length - 1].trim()) body.pop();
      if (body.length) blocks.push({ type: "code", text: body.join("\n") });
      continue;
    }
    if (!line.trim()) {
      flushAll();
      continue;
    }
    const heading = /^[ ]{0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/.exec(line);
    if (heading) {
      flushAll();
      listStack = [];
      const text = heading[2];
      const isTitle = !blocks.length && heading[1] === "#" && text.trim() === dropTitle?.trim();
      if (!isTitle) pushText(heading[1].length <= 2 ? "heading" : "subheading", text);
      continue;
    }
    if (/^[ ]{0,3}([-*_])([ \t]*\1){2,}[ \t]*$/.test(line)) {
      flushAll();
      listStack = [];
      warnings.push(`line ${i + 1}: horizontal rule skipped (dividers are not supported yet)`);
      continue;
    }
    const quoted = /^[ ]{0,3}>[ ]?(.*)$/.exec(line);
    if (quoted) {
      flushProse();
      listStack = [];
      if (quoted[1].trim()) quote.push(quoted[1].trim());
      else flushQuote();
      continue;
    }
    const item = LIST_ITEM.exec(line);
    if (item) {
      flushAll();
      const width = columns(item[1]);
      while (listStack.length && width < listStack[listStack.length - 1]) listStack.pop();
      if (!listStack.length || width > listStack[listStack.length - 1]) listStack.push(width);
      const level = Math.min(listStack.length - 1, MAX_INDENT);
      const task = item[2] ? TASK.exec(item[4]) : null;
      if (task) addItem("checklist", level, task[2], task[1] !== " ");
      else addItem(item[2] ? "bulleted" : "numbered", level, item[4], false);
      continue;
    }
    if (/^[ ]{0,3}<\/?[A-Za-z][^>]*>\s*$/.test(line)) {
      flushAll();
      warnings.push(`line ${i + 1}: raw HTML block skipped`);
      continue;
    }
    // A continuation line inside a list item joins that item.
    const last = blocks[blocks.length - 1];
    if (listStack.length && /^[ \t]+\S/.test(line) && last && "items" in last && !prose.length) {
      const items = last.items as Array<{ runs: WireRun[] }>;
      const target = items[items.length - 1];
      target.runs = mergeRuns([...target.runs, { text: " " }, ...parseInline(line.trim())]);
      continue;
    }
    flushQuote();
    listStack = [];
    prose.push(line.trim());
    if (/( {2}|\\)$/.test(line)) {
      prose[prose.length - 1] = prose[prose.length - 1].replace(/\\$/, "");
      flushProse();
    }
  }
  flushAll();
  return { blocks, warnings };
}

// ---------------------------------------------------------------------------
// Writer call
// ---------------------------------------------------------------------------

const summarySchema = z.array(
  z
    .object({
      style: z.string(),
      indent: z.number().int(),
      blockQuote: z.boolean(),
      checked: z.boolean().optional(),
      lengthUTF16: z.number().int(),
      runs: z.array(z.object({ length: z.number().int(), attributes: z.record(z.unknown()) })),
    })
    .passthrough()
);

const REVISION = /^r1:[a-f0-9]{64}$/;

export const composePlanSchema = z
  .object({
    status: z.literal("planned"),
    dryRun: z.literal(true),
    committed: z.literal(false),
    identifier: z.string(),
    mode: z.enum(["append", "prepend"]),
    paragraphs: z.number().int(),
    insertedUTF16: z.number().int(),
    insertAt: z.number().int(),
    unitStart: z.number().int(),
    revisionBefore: z.string().regex(REVISION),
    plan: summarySchema,
  })
  .passthrough();
export type ComposePlan = z.infer<typeof composePlanSchema>;

export const composeResultSchema = z
  .object({
    status: z.literal("updated"),
    committed: z.literal(true),
    verified: z.literal(true),
    placementVerified: z.literal(true),
    identifier: z.string(),
    mode: z.enum(["append", "prepend"]),
    paragraphs: z.number().int(),
    insertedUTF16: z.number().int(),
    revisionBefore: z.string().regex(REVISION),
    revisionAfter: z.string().regex(REVISION),
    unitStart: z.number().int(),
    objectURI: z.string(),
    readBack: summarySchema,
    ...writeSyncFields,
  })
  .passthrough();
export type ComposeResult = z.infer<typeof composeResultSchema>;

export interface InsertBeforeHeading {
  text: string;
  occurrence?: number;
  expectedCount?: number;
}

export interface ComposeRequest {
  identifier: string;
  mode: "append" | "prepend";
  paragraphs: WireParagraph[];
  ifRevision?: string;
  dryRun?: boolean;
  requireNonSystemPaper?: boolean;
  insertBeforeHeading?: InsertBeforeHeading;
}

// ---------------------------------------------------------------------------
// Independent read-back through the NoteStore decoder
// ---------------------------------------------------------------------------

const RUN_KEYS = ["bold", "italic", "underline", "strikethrough", "link", "highlight", "color"];

/** UTF-16 characters carrying each inline attribute, keyed by attribute. */
function attributeTotals(runs: Array<{ length: number; attributes: Record<string, unknown> }>) {
  const totals: Record<string, number> = {};
  for (const run of runs)
    for (const key of RUN_KEYS)
      if (run.attributes[key] !== undefined) totals[key] = (totals[key] ?? 0) + run.length;
  return totals;
}

export interface DatabaseReadBack {
  /** False when the independent read could not run; `reason` says why. */
  checked: boolean;
  matches?: boolean;
  mismatches?: string[];
  reason?: string;
}

/**
 * Re-read the written paragraphs from NoteStore.sqlite with this server's own
 * protobuf decoder (utils/noteBlocks), independent of NotesShared, and compare
 * each paragraph's style, indent, block quote, checklist state, and how many
 * characters carry each inline attribute with the writer's `readBack`.
 * Never throws: the writer already verified the write, so this only reports.
 */
export function crossCheckWithDatabase(
  result: ComposeResult,
  read: (id: string) => NoteBlocksDocument = (id) => readNoteBlocks(id)
): DatabaseReadBack {
  if (result.storeKind !== "live")
    return { checked: false, reason: "the writer wrote a store copy, not NoteStore.sqlite" };
  const { objectURI, unitStart } = result;
  let blocks: NoteBlock[];
  try {
    blocks = read(objectURI).blocks;
  } catch (error) {
    return { checked: false, reason: error instanceof Error ? error.message : String(error) };
  }
  const first = blocks.findIndex((block) => block.start === unitStart);
  if (first < 0)
    return { checked: true, matches: false, mismatches: ["no paragraph starts at unitStart"] };
  const mismatches: string[] = [];
  result.readBack.forEach((expected, i) => {
    const block = blocks[first + i];
    const where = `paragraph ${i}`;
    if (!block) {
      mismatches.push(`${where}: missing`);
      return;
    }
    const actual = {
      style: block.style,
      indent: block.indent,
      blockQuote: block.blockQuote,
      checked: block.checklist?.done,
      lengthUTF16: block.length,
      attributes: attributeTotals(
        block.runs.map((run) => ({ length: run.length, attributes: { ...run } }))
      ),
    };
    const want = {
      style: expected.style,
      indent: expected.indent,
      blockQuote: expected.blockQuote,
      checked: expected.checked,
      lengthUTF16: expected.lengthUTF16,
      attributes: attributeTotals(expected.runs),
    };
    for (const key of Object.keys(want) as Array<keyof typeof want>)
      if (JSON.stringify(actual[key]) !== JSON.stringify(want[key]))
        mismatches.push(
          `${where} ${key}: database ${JSON.stringify(actual[key])}, writer ${JSON.stringify(want[key])}`
        );
  });
  return {
    checked: true,
    matches: mismatches.length === 0,
    ...(mismatches.length ? { mismatches } : {}),
  };
}

/** Refuse an unvalidated compose write unless APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1. */
export function assertComposeWritesAllowed(env: NodeJS.ProcessEnv): void {
  requireLiveValidated(COMPOSE_LIVE_VALIDATED, "compose-note", env);
}

/**
 * Plan (dryRun) or apply one compose. Apply requires `ifRevision` from a
 * fresh plan or native-note-state; a stale token fails with nothing written.
 */
export function composeNote(
  request: ComposeRequest,
  deps: PrivateHelperDeps = defaultWriterDeps()
): ComposePlan | ComposeResult {
  assertNoteIdentifier(request.identifier);
  const dryRun = request.dryRun === true;
  if (dryRun && request.ifRevision !== undefined)
    throw invalid("A dry run does not take ifRevision");
  if (!dryRun) {
    if (!request.ifRevision || !REVISION.test(request.ifRevision))
      throw invalid("ifRevision (the revisionBefore of a dry run) is required to apply");
    assertComposeWritesAllowed(deps.env);
  }
  if (request.insertBeforeHeading && request.mode !== "append")
    throw invalid("insertBeforeHeading is valid only in append mode");
  const fields: Record<string, unknown> = {
    identifier: request.identifier,
    mode: request.mode,
    paragraphs: request.paragraphs,
  };
  if (dryRun) fields.dryRun = true;
  else fields.ifRevision = request.ifRevision;
  if (request.requireNonSystemPaper) fields.requireNonSystemPaper = true;
  if (request.insertBeforeHeading) fields.insertBeforeHeading = request.insertBeforeHeading;

  try {
    const response = callPrivateWriter("compose_note", fields, deps);
    return dryRun
      ? parseWriterResult(composePlanSchema, response, false)
      : parseWriterResult(composeResultSchema, response, true);
  } catch (error) {
    // A dry run opens the store read-only, so it can never have committed.
    if (dryRun && error instanceof PrivateWriteError && error.committed !== false)
      throw new PrivateWriteError(error.code, error.message, false, error.details);
    throw error;
  }
}
