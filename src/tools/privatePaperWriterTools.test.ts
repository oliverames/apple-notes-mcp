import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { AppleNotesManager } from "../services/appleNotesManager.js";

vi.mock(import("../services/privatePaperWriter.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  addPaper: vi.fn(),
}));
vi.mock(import("../services/privateSyncNudge.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  nudgeInPlace: vi.fn(),
}));
import { addPaper } from "../services/privatePaperWriter.js";
import { nudgeInPlace } from "../services/privateSyncNudge.js";
import { PrivateWriteError } from "../services/privateWriter.js";
import { prepareDrawing, registerPrivatePaperWriterTools } from "./privatePaperWriterTools.js";
import { writerEnvelopeCode } from "./privateWriterTools.js";
import { analyzeSvgFile } from "../utils/svgAnalyzer.js";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const ATTACHMENT = "0F3C2B1A-1111-4222-8333-444455556666";
const CD = "x-coredata://8FA9FE0E-3B93-4057-AD95-A0EB6D4B5F06/ICNote/p11331";
const REV = `r1:${"a".repeat(64)}`;
const SVG_NS = 'xmlns="http://www.w3.org/2000/svg"';
const CREATED = {
  status: "created",
  committed: true,
  verified: true,
  attachmentIdentifier: ATTACHMENT,
};

function fixture(link: string | null = `notes://showNote?identifier=${NOTE}`) {
  const registerTool = vi.fn();
  const manager = { getNoteLinkById: vi.fn(() => link) } as unknown as AppleNotesManager;
  const writer = { env: {} };
  const nudge = { marker: "nudge" };
  registerPrivatePaperWriterTools({ registerTool } as unknown as McpServer, manager, () => ({
    writer: writer as never,
    nudge: nudge as never,
  }));
  const entry = registerTool.mock.calls.find((c) => c[0] === "native-add-paper")!;
  const call = async (args: Record<string, unknown>) => entry[2](args);
  return { call, config: entry[1], names: registerTool.mock.calls.map((c) => c[0]), writer, nudge };
}

const parsed = (r: { isError?: boolean; structuredContent: Record<string, unknown> }) => {
  expect(r.isError).toBe(true);
  return r.structuredContent;
};

let dir: string;
beforeEach(() => {
  vi.clearAllMocks();
  dir = mkdtempSync(join(tmpdir(), "add-paper-tool-"));
  vi.mocked(addPaper).mockReturnValue(CREATED as never);
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const svgFile = (body: string, name = "a.svg") => {
  const p = join(dir, name);
  writeFileSync(p, `<svg ${SVG_NS} width="20" height="20">${body}</svg>`);
  return p;
};

describe("native-add-paper registration", () => {
  it("registers one non-destructive write that documents its guards", () => {
    const { config, names } = fixture();
    expect(names).toEqual(["native-add-paper"]);
    expect(config.annotations).toMatchObject({ readOnlyHint: false, destructiveHint: false });
    expect(config.description).toMatch(/ifSvgAnalysis/);
    expect(config.description).toMatch(/APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1/);
    expect(config.description).toMatch(/APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1/);
    expect(Object.keys(config.inputSchema)).toEqual(
      expect.arrayContaining(["ifRevision", "drawing", "svgPath", "dryRun", "nudge"])
    );
  });

  it("maps SVG refusals to validation_error", () => {
    expect(writerEnvelopeCode("svg_unsafe", "")).toBe("validation_error");
    expect(writerEnvelopeCode("svg_lossy_import_refused", "")).toBe("validation_error");
  });
});

describe("native-add-paper JSON input", () => {
  it("writes strokes and shapes through the writer with the resolved identifier", async () => {
    const { call, writer } = fixture();
    const r = await call({
      id: CD,
      ifRevision: REV,
      drawing: {
        strokes: [
          {
            points: [
              [0, 0],
              [1, 1],
            ],
          },
        ],
        shapes: [{ kind: "ellipse", cx: 5, cy: 5, rx: 2, ry: 2, strokeWidth: 3 }],
      },
      format: "paper",
      dryRun: true,
    });
    expect(r.structuredContent).toMatchObject({
      ok: true,
      status: "created",
      source: "json",
      inputStrokeCount: 1,
      shapeCount: 1,
      shapePersistence: "stroke-fallback",
    });
    const [request, deps] = vi.mocked(addPaper).mock.calls[0];
    expect(deps).toBe(writer);
    expect(request).toMatchObject({
      identifier: NOTE,
      ifRevision: REV,
      format: "paper",
      dryRun: true,
    });
    expect(request.drawing.strokes).toHaveLength(2);
    expect(request.drawing.strokes[0]).toMatchObject({ ink: "pen", color: [0, 0, 0, 1], width: 2 });
    expect(request.drawing.strokes[1].width).toBe(3);
  });

  it("refuses bad selector combinations and empty drawings before the writer runs", async () => {
    const { call } = fixture();
    const neither = parsed(await call({ identifier: NOTE, ifRevision: REV }));
    expect(neither).toMatchObject({
      code: "validation_error",
      helperCode: "invalid_request",
      committed: false,
    });
    const both = parsed(
      await call({
        identifier: NOTE,
        ifRevision: REV,
        drawing: { strokes: [] },
        svgPath: "/tmp/x.svg",
      })
    );
    expect(both.helperCode).toBe("invalid_request");
    const mixed = parsed(
      await call({
        identifier: NOTE,
        ifRevision: REV,
        drawing: { strokes: [{ points: [[0, 0]] }] },
        allowSvgLosses: ["drop-content"],
      })
    );
    expect(mixed.helperCode).toBe("invalid_request");
    const empty = parsed(await call({ identifier: NOTE, ifRevision: REV, drawing: {} }));
    expect(empty).toMatchObject({ helperCode: "invalid_request", committed: false });
    expect(vi.mocked(addPaper)).not.toHaveBeenCalled();
  });

  it("reports an unresolvable id without calling the writer", async () => {
    const r = parsed(
      await fixture(null).call({
        id: CD,
        ifRevision: REV,
        drawing: { strokes: [{ points: [[0, 0]] }] },
      })
    );
    expect(r).toMatchObject({ code: "not_found", committed: false });
    expect(vi.mocked(addPaper)).not.toHaveBeenCalled();
  });
});

describe("native-add-paper SVG input", () => {
  it("writes a safe SVG and binds a lossy one to its digest and losses", async () => {
    const { call } = fixture();
    const safe = await call({
      identifier: NOTE,
      ifRevision: REV,
      svgPath: svgFile('<path d="M1 1 L9 9" stroke="red" stroke-linecap="round"/>'),
    });
    expect(safe.structuredContent).toMatchObject({
      source: "svg",
      svgAnalysis: { classification: "safe", requiredLosses: [], acceptedLosses: [] },
    });
    expect(vi.mocked(addPaper).mock.calls[0][0].drawing.strokes[0].ink).toBe("pen");

    const lossy = svgFile('<rect width="10" height="10" fill="blue"/>', "lossy.svg");
    const refused = parsed(await call({ identifier: NOTE, ifRevision: REV, svgPath: lossy }));
    expect(refused).toMatchObject({
      code: "validation_error",
      helperCode: "svg_analysis_required",
      committed: false,
    });
    const stale = parsed(
      await call({
        identifier: NOTE,
        ifRevision: REV,
        svgPath: lossy,
        ifSvgAnalysis: `sha256:${"0".repeat(64)}`,
        allowSvgLosses: ["paint-approximation"],
      })
    );
    expect(stale.helperCode).toBe("svg_analysis_conflict");
    expect(vi.mocked(addPaper)).toHaveBeenCalledTimes(1);
  });

  it("writes a lossy SVG when the digest and losses match exactly", async () => {
    const lossy = svgFile('<rect width="10" height="10" fill="blue"/>', "lossy.svg");
    const { analysis } = analyzeSvgFile(lossy);
    expect(analysis.requiredLosses.length).toBeGreaterThan(0);
    const prepared = prepareDrawing({
      svgPath: lossy,
      ifSvgAnalysis: analysis.analysisDigest,
      allowSvgLosses: [...analysis.requiredLosses, ...analysis.requiredLosses],
    });
    expect(prepared.drawing.strokes.length).toBeGreaterThan(0);
    expect(prepared.source).toMatchObject({
      source: "svg",
      svgAnalysis: {
        analysisDigest: analysis.analysisDigest,
        classification: "lossy",
        acceptedLosses: analysis.requiredLosses,
      },
    });
  });

  it("reports unsafe SVGs and bad paths with their svgCode", async () => {
    const { call } = fixture();
    const unsafe = parsed(
      await call({ identifier: NOTE, ifRevision: REV, svgPath: svgFile("<g><script/></g>") })
    );
    expect(unsafe).toMatchObject({
      code: "validation_error",
      helperCode: "svg_unsafe",
      svgCode: "svg_unsafe",
      location: "svg/g[1]/script[1]",
      committed: false,
    });
    const malformed = join(dir, "m.svg");
    writeFileSync(malformed, "<svg");
    const bad = parsed(await call({ identifier: NOTE, ifRevision: REV, svgPath: malformed }));
    expect(bad).not.toHaveProperty("location");
    const outside = parsed(
      await call({ identifier: NOTE, ifRevision: REV, svgPath: "/etc/hosts" })
    );
    expect(outside).toMatchObject({ helperCode: "svg_file_invalid", svgCode: "svg_file_invalid" });
    expect(vi.mocked(addPaper)).not.toHaveBeenCalled();
  });
});

describe("native-add-paper writer results", () => {
  const args = {
    identifier: NOTE,
    ifRevision: REV,
    drawing: { strokes: [{ points: [[0, 0]] }] },
  };

  it("carries the writer's committed answer on failure", async () => {
    const { call } = fixture();
    vi.mocked(addPaper).mockImplementationOnce(() => {
      throw new PrivateWriteError("revision_conflict", "changed", false);
    });
    expect(parsed(await call(args))).toMatchObject({ code: "revision_conflict", committed: false });
    vi.mocked(addPaper).mockImplementationOnce(() => {
      throw new PrivateWriteError("timeout", "slow", "unknown");
    });
    expect(parsed(await call(args))).toMatchObject({
      code: "timeout_indeterminate",
      indeterminate: true,
    });
    vi.mocked(addPaper).mockImplementationOnce(() => {
      throw new RangeError("boom");
    });
    expect((await call(args)).isError).toBe(true);
  });

  it("nudges only after a created write, and only when asked", async () => {
    const { call, nudge } = fixture();
    vi.mocked(nudgeInPlace).mockResolvedValue({
      before: {},
      after: {},
      targets: [{ identifier: NOTE, uploadRecorded: true }],
    } as never);
    const plain = await call(args);
    expect(plain.structuredContent.sync).toBeUndefined();
    const nudged = await call({ ...args, nudge: true, nudgeWaitSeconds: 5 });
    expect(nudged.structuredContent.sync).toMatchObject({
      ok: true,
      targets: [{ uploadRecorded: true }],
    });
    expect(vi.mocked(nudgeInPlace)).toHaveBeenCalledWith(
      { identifiers: [NOTE], waitSeconds: 5 },
      nudge
    );
    vi.mocked(addPaper).mockReturnValueOnce({ status: "planned", committed: false } as never);
    const planned = await call({ ...args, dryRun: true, nudge: true });
    expect(planned.structuredContent.sync).toBeUndefined();
    expect(vi.mocked(nudgeInPlace)).toHaveBeenCalledTimes(1);
  });
});
