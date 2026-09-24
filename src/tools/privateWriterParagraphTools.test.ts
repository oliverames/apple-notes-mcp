import { beforeEach, describe, expect, it, vi } from "vitest";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { AppleNotesManager } from "../services/appleNotesManager.js";

vi.mock(import("../services/privateWriterParagraphs.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  setParagraphId: vi.fn(),
}));
vi.mock(import("../services/privateSyncNudge.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  nudgeInPlace: vi.fn(),
}));
import { nudgeInPlace } from "../services/privateSyncNudge.js";
import { PrivateWriteError } from "../services/privateWriter.js";
import { setParagraphId } from "../services/privateWriterParagraphs.js";
import { registerPrivateWriterParagraphTools } from "./privateWriterParagraphTools.js";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const REV = `r1:${"a".repeat(64)}`;
const CD = "x-coredata://8FA9FE0E-3B93-4057-AD95-A0EB6D4B5F06/ICNote/p11331";
const WRITER = { sourcePath: "writer.m" };

function fixture() {
  const registerTool = vi.fn();
  const manager = {
    getNoteLinkById: vi.fn(() => `notes://showNote?identifier=${NOTE}`),
  } as unknown as AppleNotesManager;
  registerPrivateWriterParagraphTools({ registerTool } as unknown as McpServer, manager, () => ({
    writer: WRITER as never,
    nudge: {} as never,
  }));
  const call = async (name: string, args: Record<string, unknown>) =>
    registerTool.mock.calls.find((c) => c[0] === name)![2](args);
  const config = (name: string) => registerTool.mock.calls.find((c) => c[0] === name)?.[1];
  return { call, config, registerTool, manager };
}

const args = { identifier: NOTE, blockIndex: 2, expectedText: "Heading", ifRevision: REV };

beforeEach(() => vi.clearAllMocks());

describe("native-set-paragraph-id", () => {
  it("registers one write tool with honest annotations and the writer switches", () => {
    const { config, registerTool } = fixture();
    expect(registerTool.mock.calls.map((c) => c[0])).toEqual(["native-set-paragraph-id"]);
    const tool = config("native-set-paragraph-id");
    expect(tool.annotations).toMatchObject({ readOnlyHint: false, destructiveHint: false });
    expect(tool.description).toMatch(/APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1/);
    expect(tool.description).toMatch(/list-note-paragraphs/);
    expect(tool.outputSchema.safeParse({}).success).toBe(true);
  });

  it("declares strict input schemas", () => {
    const schema = fixture().config("native-set-paragraph-id").inputSchema;
    expect(schema.blockIndex.safeParse(-1).success).toBe(false);
    expect(schema.expectedText.safeParse("").success).toBe(false);
    expect(schema.ifRevision.safeParse("r1:x").success).toBe(false);
    expect(schema.paragraphId.safeParse("nope").success).toBe(false);
  });

  it("resolves an x-coredata id and passes the request to the writer deps", async () => {
    vi.mocked(setParagraphId).mockReturnValueOnce({ status: "updated" } as never);
    const { call, manager } = fixture();
    const r = await call("native-set-paragraph-id", { ...args, identifier: undefined, id: CD });
    expect(manager.getNoteLinkById).toHaveBeenCalledWith(CD);
    expect(r.structuredContent).toEqual({ ok: true, status: "updated" });
    expect(setParagraphId).toHaveBeenCalledWith({ ...args, paragraphId: undefined }, WRITER);
    expect(nudgeInPlace).not.toHaveBeenCalled();
  });

  it("nudges only after an update, never after an unchanged answer", async () => {
    vi.mocked(nudgeInPlace).mockResolvedValue({ targets: [], before: {}, after: {} } as never);
    vi.mocked(setParagraphId).mockReturnValueOnce({ status: "unchanged" } as never);
    const same = await fixture().call("native-set-paragraph-id", { ...args, nudge: true });
    expect(same.structuredContent.sync).toBeUndefined();
    expect(nudgeInPlace).not.toHaveBeenCalled();
    vi.mocked(setParagraphId).mockReturnValueOnce({ status: "updated" } as never);
    const r = await fixture().call("native-set-paragraph-id", {
      ...args,
      nudge: true,
      nudgeWaitSeconds: 3,
    });
    expect(r.structuredContent.sync).toEqual({ ok: true, targets: [] });
    expect(vi.mocked(nudgeInPlace).mock.calls[0][0]).toEqual({
      identifiers: [NOTE],
      waitSeconds: 3,
    });
  });

  it("reports a moved paragraph as a conflict with nothing committed", async () => {
    vi.mocked(setParagraphId).mockImplementationOnce(() => {
      throw new PrivateWriteError("paragraph_changed", "moved", false);
    });
    const r = await fixture().call("native-set-paragraph-id", args);
    expect(r.isError).toBe(true);
    expect(r.structuredContent).toMatchObject({
      code: "revision_conflict",
      helperCode: "paragraph_changed",
      committed: false,
    });
  });
});
