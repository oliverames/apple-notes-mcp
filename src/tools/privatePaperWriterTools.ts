/**
 * `native-add-paper`: author a drawing into one exact note through the opt-in
 * private WRITER (#181).
 *
 * Input is stroke and shape JSON, or an SVG file converted by the same
 * analyzer `analyze-svg` runs. A lossy SVG is written only when the caller
 * binds the write to that exact analysis (`ifSvgAnalysis` equal to its
 * `analysisDigest`, `allowSvgLosses` equal to its `requiredLosses`); the file
 * is analyzed again at write time. The write itself is `add_paper` in the
 * writer (services/privatePaperWriter.ts), with the foundation's contract:
 * both switches, `ifRevision`, NSErrorMergePolicy, a fresh read-back, and
 * `committed` on every failure. `nudge: true` runs the move-in-place sync
 * nudge after a verified write, as `native-append-plain-text` does.
 *
 * Reading drawings is out of scope here: `get-note-drawings` decodes classic
 * drawings, and `list-paper-attachments` / `export-paper-image` cover Paper's
 * own rendering.
 *
 * @module tools/privatePaperWriterTools
 */
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { AppleNotesManager } from "../services/appleNotesManager.js";
import { MAX_NUDGE_WAIT_SECONDS } from "../services/privateSyncNudge.js";
import { PAPER_FORMATS, addPaper } from "../services/privatePaperWriter.js";
import { PrivateWriteError } from "../services/privateWriter.js";
import { readAllowedFile } from "../utils/attachmentFs.js";
import {
  AUTHOR_INKS,
  PaperAuthoringError,
  authorizeSvgDrawing,
  drawingFromInput,
  drawingFromSvg,
  type AuthorDrawing,
  type DrawingInput,
} from "../utils/paperAuthoring.js";
import { SVG_LIMITS, SVG_LOSSES, SvgError, analyzeSvgBuffer } from "../utils/svgAnalyzer.js";
import {
  coreDataId,
  defaultWriterToolDeps,
  notesUuid,
  nudgeAfterWrite,
  registerWriterTool,
  resolveIdentifier,
  revisionToken,
  type WriterToolDeps,
} from "./privateWriterTools.js";

// Factories, not shared instances: JSON Schema conversion turns a reused zod
// instance into a $ref, and some refs (into tuple items) do not resolve under
// 2020-12. Every field gets its own schema object.
const unit = () => z.number().min(0).max(1);
const coordinate = () => z.number().finite().min(-1_000_000).max(1_000_000);
const xy = () => z.array(coordinate()).length(2);
const paintFields = () => ({
  ink: z.enum(AUTHOR_INKS).optional().describe("PencilKit ink (default pen)"),
  color: z
    .array(unit())
    .length(4)
    .optional()
    .describe("sRGB [r, g, b, a], each 0..1 (default opaque black)"),
});
const strokeWidth = () =>
  z.number().positive().max(8192).optional().describe("Stroke width (default 2)");
const positive = () => z.number().positive().max(1_000_000);

const shapeSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("rectangle"),
    x: coordinate(),
    y: coordinate(),
    width: positive(),
    height: positive(),
    cornerRadius: z.number().min(0).optional(),
    ...paintFields(),
    strokeWidth: strokeWidth(),
  }),
  z.object({
    kind: z.literal("ellipse"),
    cx: coordinate(),
    cy: coordinate(),
    rx: positive(),
    ry: positive(),
    ...paintFields(),
    strokeWidth: strokeWidth(),
  }),
  z.object({
    kind: z.literal("line"),
    from: xy(),
    to: xy(),
    arrowStart: z.boolean().optional(),
    arrowEnd: z.boolean().optional(),
    ...paintFields(),
    strokeWidth: strokeWidth(),
  }),
  z.object({
    kind: z.literal("arrow"),
    from: xy(),
    to: xy(),
    headLength: positive().optional(),
    shaftWidth: positive().optional(),
    ...paintFields(),
    strokeWidth: strokeWidth(),
  }),
  z.object({
    kind: z.literal("polygon"),
    cx: coordinate(),
    cy: coordinate(),
    radius: positive(),
    sides: z.number().int().min(3).max(512),
    rotation: z.number().finite().optional(),
    ...paintFields(),
    strokeWidth: strokeWidth(),
  }),
  z.object({
    kind: z.literal("star"),
    cx: coordinate(),
    cy: coordinate(),
    outerRadius: positive(),
    innerRadius: positive(),
    points: z.number().int().min(3).max(512),
    rotation: z.number().finite().optional(),
    ...paintFields(),
    strokeWidth: strokeWidth(),
  }),
  z.object({
    kind: z.literal("chatBubble"),
    x: coordinate(),
    y: coordinate(),
    width: positive(),
    height: positive(),
    tail: xy(),
    ...paintFields(),
    strokeWidth: strokeWidth(),
  }),
  z.object({
    kind: z.literal("polyline"),
    points: z.array(xy()).min(2).max(100_000),
    closed: z.boolean().optional(),
    ...paintFields(),
    strokeWidth: strokeWidth(),
  }),
]);

const drawingSchema = z.object({
  strokes: z
    .array(
      z.object({
        ...paintFields(),
        width: strokeWidth(),
        points: z
          .array(z.array(coordinate()).min(2).max(9))
          .min(1)
          .max(100_000)
          .describe(
            "[x, y] or [x, y, width] per point; longer rows (up to 9 values) use their first three"
          ),
      })
    )
    .max(4096)
    .optional(),
  shapes: z
    .array(shapeSchema)
    .max(1000)
    .optional()
    .describe(
      "rectangle, ellipse, line, arrow, polygon, star, chatBubble, polyline; each is written as strokes tracing it"
    ),
});

/** Input and analysis refusals happen before the writer runs: nothing committed. */
function asWriteError(error: unknown): unknown {
  if (error instanceof PaperAuthoringError)
    return new PrivateWriteError(error.code, error.message, false);
  if (error instanceof SvgError)
    return new PrivateWriteError(error.code, error.message, false, {
      svgCode: error.code,
      ...(error.location ? { location: error.location } : {}),
    });
  return error;
}

export interface AddPaperArgs {
  /** A DrawingInput; the input schema has already checked its shape. */
  drawing?: object;
  svgPath?: string;
  ifSvgAnalysis?: string;
  allowSvgLosses?: string[];
}

/**
 * Turn the tool's drawing or SVG input into the writer's drawing, plus the
 * fields that say where it came from. Throws PrivateWriteError (committed:
 * false) on any refusal.
 */
export function prepareDrawing(
  args: AddPaperArgs,
  roots?: string[]
): { drawing: AuthorDrawing; source: Record<string, unknown> } {
  if ((args.drawing === undefined) === (args.svgPath === undefined))
    throw new PrivateWriteError("invalid_request", "Pass exactly one of drawing or svgPath", false);
  if (args.drawing && (args.ifSvgAnalysis !== undefined || args.allowSvgLosses !== undefined))
    throw new PrivateWriteError(
      "invalid_request",
      "ifSvgAnalysis and allowSvgLosses apply to svgPath only",
      false
    );
  try {
    if (args.svgPath !== undefined) {
      // Same read policy as analyze-svg's path (see readAllowedFile).
      let source: Buffer;
      try {
        source = readAllowedFile(args.svgPath, SVG_LIMITS.maxSourceBytes, {
          roots,
          label: "SVG file",
        });
      } catch (error) {
        throw new PrivateWriteError("svg_file_invalid", (error as Error).message, false, {
          svgCode: "svg_file_invalid",
        });
      }
      const analyzed = analyzeSvgBuffer(source);
      const drawing = drawingFromSvg(
        authorizeSvgDrawing(analyzed, {
          ifSvgAnalysis: args.ifSvgAnalysis,
          allowSvgLosses: args.allowSvgLosses,
        })
      );
      return {
        drawing,
        source: {
          source: "svg",
          svgAnalysis: {
            analysisDigest: analyzed.analysis.analysisDigest,
            classification: analyzed.analysis.classification,
            requiredLosses: analyzed.analysis.requiredLosses,
            acceptedLosses: [...new Set(args.allowSvgLosses ?? [])],
          },
        },
      };
    }
    const converted = drawingFromInput(args.drawing as DrawingInput);
    return {
      drawing: converted.drawing,
      source: {
        source: "json",
        inputStrokeCount: converted.inputStrokeCount,
        shapeCount: converted.shapeCount,
        shapePersistence: converted.shapePersistence,
      },
    };
  } catch (error) {
    throw asWriteError(error);
  }
}

export function registerPrivatePaperWriterTools(
  server: McpServer,
  manager: AppleNotesManager,
  depsFactory: () => WriterToolDeps = defaultWriterToolDeps
) {
  registerWriterTool(
    server,
    depsFactory,
    "native-add-paper",
    "Use when: adding a hand-drawn-style drawing to the end of one exact note as editable ink, from stroke and shape JSON or from an SVG file, through the opt-in private writer.\n" +
      "Returns: status (planned or created), the attachment format (paper or drawing) and typeUTI, stroke and point counts, decodedStrokeCount/decodedPointCount from the verifying read-back, attachmentIdentifier, revisionBefore/revisionAfter, and sync state: pushScheduled (always false; the writer cannot upload), pushState, cloudSync versions, and with nudge: true a `sync` report. For an SVG, svgAnalysis names the digest and the losses accepted; for JSON, shapeCount and shapePersistence (shapes are written as strokes tracing them).\n" +
      "Do not use when: you want a picture of the SVG exactly as it looks (attach a PNG with add-attachment instead), or the note is locked, shared, trashed, or still downloading.\n" +
      "Safety: writes to the Notes database through unsupported private API. Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1, APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1, a built writer (setup --native-writer), and a fresh `revision` from native-note-state as ifRevision; refuses on any change since. An SVG is re-analyzed at write time: a lossy one needs ifSvgAnalysis equal to analyze-svg's analysisDigest and allowSvgLosses equal to its requiredLosses. Verifies by decoding the saved drawing in a new Core Data stack. A timeout is indeterminate (indeterminate: true): read native-note-state before any retry. Not yet live-validated, so a write also requires APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1; dryRun does not.",
    {
      identifier: notesUuid.optional().describe("Notes UUID"),
      id: coreDataId.optional().describe("x-coredata note id; resolved to a UUID via the database"),
      ifRevision: revisionToken.describe(
        "The `revision` returned by native-note-state for this note"
      ),
      drawing: drawingSchema
        .optional()
        .describe("Strokes and shapes to draw; pass this or svgPath, not both"),
      svgPath: z
        .string()
        .min(1)
        .max(4096)
        .optional()
        .describe(
          "Absolute path of an SVG file to convert with the analyze-svg analyzer, read under analyze-svg's rules (home, temp, or /Volumes; not a hidden path or ~/Library outside iCloud Drive and CloudStorage; not a symbolic link)"
        ),
      ifSvgAnalysis: z
        .string()
        .regex(/^sha256:[a-f0-9]{64}$/)
        .optional()
        .describe("The analysisDigest from analyze-svg; required when the SVG needs any loss"),
      allowSvgLosses: z
        .array(z.enum(SVG_LOSSES))
        .max(3)
        .optional()
        .describe("Exactly the requiredLosses analyze-svg reported for this digest"),
      format: z
        .enum(PAPER_FORMATS)
        .optional()
        .describe(
          "auto (default): Paper when this macOS can create it, else a classic drawing; paper or drawing to insist"
        ),
      dryRun: z.boolean().optional().describe("Validate and plan without writing"),
      nudge: z
        .boolean()
        .optional()
        .describe(
          "After a verified write, ask Notes.app to upload the note by moving it into its own folder (default false)"
        ),
      nudgeWaitSeconds: z
        .number()
        .int()
        .min(0)
        .max(MAX_NUDGE_WAIT_SECONDS)
        .optional()
        .describe("With nudge: how long to watch Notes' upload counters (default 30)"),
    },
    { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    async (args, deps) => {
      const { drawing, source } = prepareDrawing(args);
      const identifier = resolveIdentifier(manager, args);
      const result = addPaper(
        {
          identifier,
          ifRevision: args.ifRevision,
          drawing,
          format: args.format,
          dryRun: args.dryRun,
        },
        deps.writer
      );
      const payload = { ...source, ...result };
      if (!args.nudge || result.status !== "created") return payload;
      return {
        ...payload,
        sync: await nudgeAfterWrite(identifier, args.nudgeWaitSeconds, deps.nudge),
      };
    }
  );
}
