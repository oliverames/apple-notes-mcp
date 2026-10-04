/**
 * #264: clients such as Claude Desktop give the model only a result's text
 * content, never structuredContent. Every token a follow-up call needs (the
 * revision hash for a guarded write, new ids, native tags, writable, error
 * codes, paging offsets) must therefore be in the text too. These tests read
 * ONLY the text blocks, the way such a client does, through the handlers
 * src/index.ts and the tool modules register (manager and database mocked).
 */
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ReadBuffer,
  serializeMessage,
  STDIO_DEFAULT_MAX_BUFFER_SIZE,
} from "@modelcontextprotocol/sdk/shared/stdio.js";
import { summarize, type NoteBlock } from "./utils/noteBlocks.js";

const registered = vi.hoisted(() => new Map<string, (args: unknown) => Promise<unknown>>());
const manager = vi.hoisted(() => ({
  createNote: vi.fn(),
  getNoteById: vi.fn(),
  getNoteContentById: vi.fn(),
  readNoteBodyById: vi.fn(),
  listAttachmentsById: vi.fn(),
  updateNoteByIdIfUnchanged: vi.fn(),
}));
const readRichNote = vi.hoisted(() => vi.fn());
const readNoteBlocks = vi.hoisted(() => vi.fn());
const OLD_HASH = `sha256:${"a".repeat(64)}`;
const NEW_HASH = `sha256:${"b".repeat(64)}`;
const OLD_BODY = `<div><h1>Groceries</h1></div><div>${"Milk, eggs, bread and butter. ".repeat(20)}</div>`;
const NEW_BODY = "<div><h1>Groceries</h1></div><div>Only coffee</div>";

vi.mock(import("@modelcontextprotocol/sdk/server/mcp.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  McpServer: vi.fn().mockImplementation(function () {
    return {
      registerTool: vi.fn(
        (name: string, _config: unknown, cb: (args: unknown) => Promise<unknown>) =>
          registered.set(name, cb)
      ),
      resource: vi.fn(),
      prompt: vi.fn(),
      connect: vi.fn(async () => undefined),
    };
  }) as never,
}));
vi.mock("@modelcontextprotocol/sdk/server/stdio.js", () => ({ StdioServerTransport: vi.fn() }));
vi.mock("@/utils/jsonSchemaDialect.js", () => ({ withJsonSchema2020_12: (t: unknown) => t }));
vi.mock("@/services/fileConfig.js", () => ({ loadFileConfig: vi.fn() }));
vi.mock(import("@/services/appleNotesManager.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  AppleNotesManager: vi.fn().mockImplementation(function () {
    return manager;
  }) as never,
}));
vi.mock(import("@/utils/noteIdentifiers.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  lookupStableIdentifiers: vi.fn(() => new Map()),
}));
vi.mock("@/utils/noteRichText.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/utils/noteRichText.js")>()),
  readRichNote,
  enrichNoteRead: vi.fn((_id: string, body: string) => ({
    content: body,
    links: [],
    nativeTags: ["groceries"],
    complete: true,
    writable: true,
    revision: "r1",
  })),
  richContentHash: vi.fn((body: string) => (body === OLD_BODY ? OLD_HASH : NEW_HASH)),
}));
vi.mock(import("@/utils/noteBlocks.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  readNoteBlocks,
}));

type Response = {
  content: Array<{ type: string; text: string }>;
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};
const call = (name: string, args: Record<string, unknown>) =>
  registered.get(name)!(args) as Promise<Response>;
const ID = "x-coredata://ABCDEF01-2345-6789-ABCD-EF0123456789/ICNote/p10";

/** What a text-only client shows the model. */
const textOnly = (r: Response) =>
  r.content
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n");

/** The JSON object in the mirrored `structuredContent: {...}` line. */
function mirrored(r: Response): Record<string, unknown> {
  const line = r.content.map((c) => c.text).find((t) => t.startsWith("structuredContent: "));
  if (!line) throw new Error("no structuredContent line in the text content");
  return JSON.parse(line.slice("structuredContent: ".length)) as Record<string, unknown>;
}

beforeAll(async () => {
  const on = vi.spyOn(process, "on").mockReturnValue(process);
  const stdinOn = vi.spyOn(process.stdin, "on").mockReturnValue(process.stdin);
  await import("@/index.js");
  on.mockRestore();
  stdinOn.mockRestore();
});
afterAll(() => registered.clear());
beforeEach(() => {
  vi.clearAllMocks();
  manager.getNoteById.mockReturnValue({ id: ID, title: "Groceries", shared: false });
  manager.readNoteBodyById.mockReturnValue({ body: OLD_BODY });
  manager.getNoteContentById.mockReturnValue(OLD_BODY);
  manager.listAttachmentsById.mockReturnValue([]);
});

describe("get-note-content text carries the revision token (#264)", () => {
  it("puts contentHash, id, writable and nativeTags in the text", async () => {
    const r = await call("get-note-content", { id: ID });
    expect(r.isError).toBeFalsy();
    const text = textOnly(r);
    expect(text).toContain(`"contentHash":"${OLD_HASH}"`);
    expect(mirrored(r)).toMatchObject({
      id: ID,
      contentHash: OLD_HASH,
      writable: true,
      nativeTags: ["groceries"],
      truncated: false,
    });
  });

  it("does not send the body twice", async () => {
    const r = await call("get-note-content", { id: ID });
    expect(r.content[0].text).toBe(OLD_BODY);
    expect(textOnly(r).split(OLD_BODY)).toHaveLength(2);
    expect(mirrored(r).content).toBe("[shown in full above]");
    // structuredContent itself is unchanged.
    expect(r.structuredContent?.content).toBe(OLD_BODY);
  });
});

describe("get-native-objects text carries the rich content hash (#264)", () => {
  it("retains every object and checklist ID when the result exceeds 16 KB", async () => {
    const objects = Array.from({ length: 250 }, (_, i) => ({
      id: `object-${i}`,
      type: "checklist",
      start: i * 100,
      length: 100,
    }));
    const checklistItems = objects.map((object, i) => ({
      id: `checklist-${i}`,
      start: object.start,
      text: `Item ${i}: ${"synthetic text ".repeat(8)}`,
      done: false,
    }));
    readRichNote.mockReturnValue({
      objects,
      checklistItems,
      links: [],
      nativeTags: ["synthetic"],
      hasNativeObjects: true,
      hasChecklist: true,
      revision: "r1",
      objectData: [],
    });
    const r = await call("get-native-objects", { id: ID });
    expect(r.isError).toBeFalsy();
    expect(r.content[0].text).toBe("Native objects read from the exact note");
    expect(JSON.stringify(r.structuredContent).length).toBeGreaterThan(16_384);
    expect(mirrored(r)).toEqual(r.structuredContent);
    expect(mirrored(r)).toMatchObject({ contentHash: OLD_HASH, objects, checklistItems });
  });

  it("puts contentHash, nativeTags and object ids in the text", async () => {
    readRichNote.mockReturnValue({
      text: "Buy milk",
      links: [],
      nativeTags: ["groceries"],
      nativeObjectIds: ["C1"],
      hasNativeObjects: true,
      hasChecklist: true,
      revision: "r1",
      objects: [{ id: "C1", type: "checklist", start: 0, length: 8 }],
      checklistItems: [{ id: "aa", start: 0, text: "Buy milk", done: false }],
      objectData: [],
    });
    const r = await call("get-native-objects", { id: ID });
    expect(r.isError).toBeFalsy();
    expect(r.content[0].text).toBe("Native objects read from the exact note");
    const m = mirrored(r);
    expect(m.contentHash).toMatch(/^sha256:[a-f0-9]{64}$/);
    expect(m.contentHash).toBe(r.structuredContent?.contentHash);
    expect(m).toMatchObject({
      id: ID,
      nativeTags: ["groceries"],
      checklistItems: [{ id: "aa", done: false }],
    });
  });
});

describe("get-note-blocks text preserves large paginated results", () => {
  it("keeps escaped block pages within the SDK stdio limit without losing blocks", async () => {
    // Quotes and backslashes expand twice: in the mirror's JSON and again in
    // the enclosing JSON-RPC string. Count the complete wire response, not
    // only the structuredContent payload.
    const text = '"\\'.repeat(1050);
    const blocks: NoteBlock[] = Array.from({ length: 500 }, (_, index) => ({
      index,
      start: index * (text.length + 1),
      length: text.length,
      text,
      style: "body",
      styleType: null,
      indent: 0,
      alignment: "left",
      blockQuote: false,
      runs: [{ start: index * (text.length + 1), length: text.length, text }],
      attachments: [],
    }));
    readNoteBlocks.mockReturnValue({
      text: blocks.map((block) => block.text).join("\n"),
      textLength: blocks.length * (text.length + 1) - 1,
      blocks,
      attachments: [],
      summary: summarize(blocks, []),
      undecodedFields: { attributeRun: {}, paragraphStyle: {} },
    });

    vi.stubEnv("APPLE_NOTES_MCP_BLOCKS_MAX_BYTES", undefined);
    try {
      const received: NoteBlock[] = [];
      let pages = 0;
      let offset = 0;
      while (offset < blocks.length) {
        const result = await call("get-note-blocks", { id: ID, offset });
        expect(result.isError).toBeFalsy();
        const wire = Buffer.from(serializeMessage({ jsonrpc: "2.0", id: pages, result }));
        const reader = new ReadBuffer();
        reader.append(wire);
        const message = reader.readMessage();
        if (!message || !("result" in message)) throw new Error("expected a tool response");
        expect(wire.length).toBeLessThanOrEqual(STDIO_DEFAULT_MAX_BUFFER_SIZE);
        const response = message.result as Response;
        const mirror = mirrored(response);
        expect(mirror).toEqual(response.structuredContent);
        const page = mirror.page as {
          offset: number;
          returned: number;
          hasMore: boolean;
          nextOffset?: number;
        };
        expect(page.offset).toBe(offset);
        expect(page.returned).toBeGreaterThan(0);
        expect(mirror.blocks).toEqual(blocks.slice(offset, offset + page.returned));
        received.push(...(mirror.blocks as NoteBlock[]));
        offset += page.returned;
        expect(page.hasMore).toBe(offset < blocks.length);
        expect(page.nextOffset).toBe(page.hasMore ? offset : undefined);
        pages++;
      }
      expect(pages).toBeGreaterThan(1);
      expect(received).toEqual(blocks);
    } finally {
      vi.unstubAllEnvs();
    }
  });

  it("returns the full default page and continuation offset through text alone", async () => {
    const blocks: NoteBlock[] = Array.from({ length: 501 }, (_, index) => ({
      index,
      start: index * 81,
      length: 80,
      text: `${index}: ${"x".repeat(80)}`.slice(0, 80),
      style: "body",
      styleType: null,
      indent: 0,
      alignment: "left",
      blockQuote: false,
      runs: [],
      attachments: [],
    }));
    readNoteBlocks.mockReturnValue({
      text: blocks.map((block) => block.text).join("\n"),
      textLength: 501 * 81 - 1,
      blocks,
      attachments: [],
      summary: summarize(blocks, []),
      undecodedFields: { attributeRun: {}, paragraphStyle: {} },
    });
    const first = await call("get-note-blocks", { id: ID });
    expect(first.isError).toBeFalsy();
    expect(first.content[0].text).toContain("returned 500 from offset 0");
    expect(JSON.stringify(first.structuredContent).length).toBeGreaterThan(16_384);
    const firstText = mirrored(first);
    expect(firstText).toEqual(first.structuredContent);
    expect(firstText.blocks).toEqual(blocks.slice(0, 500));
    expect(firstText.page).toMatchObject({ hasMore: true, nextOffset: 500 });

    const nextOffset = (firstText.page as { nextOffset: number }).nextOffset;
    const second = await call("get-note-blocks", { id: ID, offset: nextOffset });
    expect(second.isError).toBeFalsy();
    expect(mirrored(second)).toMatchObject({
      blocks: blocks.slice(500),
      page: { offset: 500, returned: 1, hasMore: false },
    });
  });
});

describe("guarded writes return the next token in the text (#264)", () => {
  it("update-note: the new contentHash is readable for the next write", async () => {
    manager.updateNoteByIdIfUnchanged.mockReturnValue({ status: "updated", writtenBody: NEW_BODY });
    manager.getNoteContentById.mockReturnValue(NEW_BODY);
    const r = await call("update-note", {
      id: ID,
      expectedContentHash: OLD_HASH,
      newContent: NEW_BODY,
      format: "html",
    });
    expect(r.isError).toBeFalsy();
    expect(mirrored(r)).toMatchObject({
      ok: true,
      id: ID,
      previousContentHash: OLD_HASH,
      contentHash: NEW_HASH,
      verifiedVisibleText: true,
    });
  });

  it("create-note: the new id and its contentHash are in the text", async () => {
    manager.createNote.mockReturnValue({ id: ID, title: "Groceries" });
    const r = await call("create-note", { title: "Groceries", content: "Milk" });
    expect(r.isError).toBeFalsy();
    expect(mirrored(r)).toMatchObject({ id: ID, contentHash: OLD_HASH, verified: true });
  });

  it("a revision conflict's code and committed flag are in the text", async () => {
    const r = await call("update-note", {
      id: ID,
      expectedContentHash: NEW_HASH,
      newContent: NEW_BODY,
    });
    expect(r.isError).toBe(true);
    expect(mirrored(r)).toEqual(r.structuredContent);
    expect(mirrored(r)).toMatchObject({ code: "revision_conflict", committed: false });
  });
});

describe("text that already is the JSON is not repeated", () => {
  it("get-note-by-id keeps its single JSON block", async () => {
    manager.getNoteById.mockReturnValue({
      id: ID,
      title: "Groceries",
      created: new Date(0),
      modified: new Date(0),
      shared: false,
      passwordProtected: false,
    });
    const r = await call("get-note-by-id", { id: ID });
    expect(r.content).toHaveLength(1);
    expect(JSON.parse(r.content[0].text)).toMatchObject({ id: ID });
  });
});

describe("every registered tool is wrapped", () => {
  it("tool-module tools (add-native-tags, add-attachment) still expose tokens in text", async () => {
    // Their text is already the JSON of structuredContent, so no extra block;
    // either way a text-only client sees every field.
    const r = await call("add-native-tags", {
      id: ID,
      expectedContentHash: OLD_HASH,
      title: "Groceries",
      scopeText: "Milk",
      tags: ["x"],
    });
    const text = textOnly(r);
    for (const [key, value] of Object.entries(r.structuredContent ?? {})) {
      if (typeof value === "string" || typeof value === "boolean") {
        expect(text).toContain(JSON.stringify(key));
      }
    }
  });
});
