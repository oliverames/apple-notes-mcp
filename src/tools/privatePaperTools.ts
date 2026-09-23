/**
 * MCP tools for Paper drawings through the opt-in private helper (#181).
 *
 * - `native-read-paper`: decode one Paper drawing's strokes (ink, color,
 *   width, transform, points) as JSON, SVG, or both. Read-only.
 *
 * Always registered; refuses with a machine-readable `code` when the helper
 * is off, missing, stale, or unsupported on this macOS.
 *
 * @module tools/privatePaperTools
 */
import type { McpServer, ToolCallback } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { AppleNotesManager } from "../services/appleNotesManager.js";
import { defaultDeps, type PrivateHelperDeps } from "../services/privateHelper.js";
import { MAX_PAPER_POINTS, readPaper } from "../services/privatePaper.js";
import { paperToSvg } from "../utils/paperSvg.js";
import { coreDataId, errorResult, notesUuid, resolveIdentifier } from "./privateHelperTools.js";

export function registerPrivatePaperTools(
  server: McpServer,
  manager: AppleNotesManager,
  depsFactory: () => PrivateHelperDeps = () => defaultDeps()
) {
  const inputSchema = {
    identifier: notesUuid
      .optional()
      .describe("Note UUID; the note must hold exactly one Paper drawing"),
    id: coreDataId.optional().describe("x-coredata note id; resolved to a UUID via the database"),
    attachmentIdentifier: notesUuid.optional().describe("UUID of one Paper attachment"),
    format: z
      .enum(["json", "svg", "both"])
      .optional()
      .describe("json (default): stroke data; svg: an SVG document; both"),
    includePoints: z
      .boolean()
      .optional()
      .describe("Include per-point arrays (default true). SVG output needs points."),
    maxPoints: z
      .number()
      .int()
      .min(1)
      .max(MAX_PAPER_POINTS)
      .optional()
      .describe(`Point budget across the drawing (default 20000, max ${MAX_PAPER_POINTS})`),
  };
  type Args = z.infer<z.ZodObject<typeof inputSchema>>;

  const handler = async (args: Args) => {
    try {
      const deps = depsFactory();
      const format = args.format ?? "json";
      const byNote = args.identifier !== undefined || args.id !== undefined;
      // readPaper refuses a request naming both a note and an attachment, or neither.
      const decoded = readPaper(
        {
          identifier: byNote ? resolveIdentifier(manager, args) : undefined,
          attachmentIdentifier: args.attachmentIdentifier,
          includePoints: args.includePoints,
          maxPoints: args.maxPoints,
        },
        deps
      );
      const { status: _status, ...data } = decoded;
      void _status;
      const result: Record<string, unknown> = { ok: true, ...data };
      if (format !== "json") {
        const rendered = paperToSvg(decoded);
        result.svg = rendered.svg;
        result.svgPathCount = rendered.pathCount;
        result.svgSkippedStrokes = rendered.skippedStrokes;
      }
      if (format === "svg") delete result.strokes;
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result) }],
        structuredContent: result,
      };
    } catch (error) {
      return errorResult(error);
    }
  };

  server.registerTool(
    "native-read-paper",
    {
      description:
        "Use when: you need the vector content of an Apple Notes Paper drawing (com.apple.paper): each stroke's ink, color, width, transform and points, or an SVG outline of them.\n" +
        "Returns: decodePath, strokeCount, pointCount, bounds, inks, strokes (color as sRGB 0..1 [r,g,b,a]; points as arrays in `pointFields` order), and with format svg/both an SVG whose colors are byte-scale rgba(). Typed shapes are reported as not exposed (`shapeDecode`). `truncated` is true when the point budget cut points off.\n" +
        "Do not use when: you only need Notes' rendered image of the drawing or its handwriting text.\n" +
        "Safety: read-only. The helper decodes a private copy of the drawing's bundle and opens the Notes store read-only. Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1 and a built helper; pass exactly one of identifier, id, or attachmentIdentifier.",
      inputSchema,
      annotations: { readOnlyHint: true, openWorldHint: false },
      outputSchema: z.object({ ok: z.boolean() }).passthrough(),
    },
    handler as unknown as ToolCallback<typeof inputSchema>
  );
}
