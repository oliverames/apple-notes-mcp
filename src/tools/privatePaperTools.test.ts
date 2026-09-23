import { beforeEach, describe, expect, it, vi } from "vitest";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { AppleNotesManager } from "../services/appleNotesManager.js";

vi.mock(import("../services/privatePaper.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  readPaper: vi.fn(),
}));
import { PrivateHelperError } from "../services/privateHelper.js";
import { readPaper } from "../services/privatePaper.js";
import { registerPrivatePaperTools } from "./privatePaperTools.js";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const ATTACHMENT = "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9";
const CD = "x-coredata://8FA9FE0E-3B93-4057-AD95-A0EB6D4B5F06/ICNote/p11331";

const DECODED = {
  status: "ok",
  storeKind: "live",
  attachmentIdentifier: ATTACHMENT,
  noteIdentifier: NOTE,
  typeUTI: "com.apple.paper",
  decodePath: "NotesShared.ICSystemPaperDrawingsHelper",
  vectorDecode: "strokes",
  drawingCount: 1,
  strokeCount: 1,
  returnedStrokeCount: 1,
  pointCount: 2,
  bounds: [0, 0, 20, 20],
  inks: ["pen"],
  pointFields: ["x", "y"],
  strokes: [
    {
      ink: "pen",
      inkIdentifier: "com.apple.ink.pen",
      color: [0, 0, 1, 1],
      width: 3,
      transform: [1, 0, 0, 1, 0, 0],
      pointCount: 2,
      renderBounds: [0, 0, 20, 20],
      masked: false,
      points: [
        [1, 2, 3, 3, 1, 1, 0, 1, 0],
        [4, 5, 3, 3, 1, 1, 0, 1, 0.1],
      ],
    },
  ],
  shapes: [],
  shapeDecode: { available: false, reason: "not_exposed" },
  truncated: false,
  warnings: [],
};

function fixture(link: string | null = `notes://showNote?identifier=${NOTE}`) {
  const registerTool = vi.fn();
  const manager = { getNoteLinkById: vi.fn(() => link) } as unknown as AppleNotesManager;
  registerPrivatePaperTools({ registerTool } as unknown as McpServer, manager, () => ({}) as never);
  const call = async (args: Record<string, unknown>) => registerTool.mock.calls[0][2](args);
  return { call, config: registerTool.mock.calls[0][1], name: registerTool.mock.calls[0][0] };
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(readPaper).mockReturnValue(DECODED as never);
});

describe("native-read-paper", () => {
  it("registers one read-only tool that states its safety contract", () => {
    const { config, name } = fixture();
    expect(name).toBe("native-read-paper");
    expect(config.annotations.readOnlyHint).toBe(true);
    expect(config.description).toMatch(/Safety: read-only/);
  });

  it("returns stroke JSON by default without an SVG", async () => {
    const r = await fixture().call({ attachmentIdentifier: ATTACHMENT });
    expect(readPaper).toHaveBeenCalledWith(
      {
        identifier: undefined,
        attachmentIdentifier: ATTACHMENT,
        includePoints: undefined,
        maxPoints: undefined,
      },
      {}
    );
    expect(r.structuredContent.ok).toBe(true);
    expect(r.structuredContent.status).toBeUndefined();
    expect(r.structuredContent.strokes).toHaveLength(1);
    expect(r.structuredContent.svg).toBeUndefined();
  });

  it("renders SVG with byte-scale rgba colors and drops strokes for format svg", async () => {
    const r = await fixture().call({ identifier: NOTE, format: "svg", maxPoints: 10 });
    expect(r.structuredContent.svg).toContain('stroke="rgba(0,0,255,1)"');
    expect(r.structuredContent.svg).toContain('d="M 1 2 L 4 5"');
    expect(r.structuredContent.svgPathCount).toBe(1);
    expect(r.structuredContent.svgSkippedStrokes).toBe(0);
    expect(r.structuredContent.strokes).toBeUndefined();
    expect(r.structuredContent.strokeCount).toBe(1);
    const both = await fixture().call({ identifier: NOTE, format: "both" });
    expect(both.structuredContent.strokes).toHaveLength(1);
    expect(both.structuredContent.svg).toContain("<svg");
  });

  it("resolves an x-coredata note id to its UUID", async () => {
    await fixture().call({ id: CD, includePoints: false });
    expect(vi.mocked(readPaper).mock.calls[0][0]).toMatchObject({
      identifier: NOTE,
      includePoints: false,
    });
  });

  it("reports failures with a machine-readable code", async () => {
    vi.mocked(readPaper).mockImplementation(() => {
      throw new PrivateHelperError("bundle_unavailable", "not downloaded");
    });
    const r = await fixture().call({ attachmentIdentifier: ATTACHMENT });
    expect(r.isError).toBe(true);
    expect(JSON.parse(r.content[0].text)).toMatchObject({ ok: false, code: "bundle_unavailable" });
    const unresolved = await fixture(null).call({ id: CD });
    expect(JSON.parse(unresolved.content[0].text)).toMatchObject({ code: "not_found" });
  });
});
