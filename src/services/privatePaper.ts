/**
 * Paper drawing decode through the opt-in private helper (#181).
 *
 * Notes keeps a Paper drawing (`com.apple.paper`) in a Coherence bundle that
 * public PaperKit cannot open. The helper asks NotesShared for the drawing's
 * public PKDrawing objects and reports each PKStroke's ink, color, width,
 * transform and points. It reads a private copy of the bundle, never the live
 * one, and never derives geometry from bundle bytes or the rendered image.
 *
 * @module services/privatePaper
 */
import { z } from "zod";
import {
  PrivateHelperError,
  assertNoteIdentifier,
  callPrivateHelper,
  defaultDeps,
  type PrivateHelperDeps,
} from "./privateHelper.js";

/** Points returned when the caller does not choose a budget. */
export const DEFAULT_PAPER_POINTS = 20_000;
/** Hard ceiling on returned points, matching the helper's MAX_PAPER_POINTS. */
export const MAX_PAPER_POINTS = 40_000;

/** Order of the values in each compact point array. */
export const PAPER_POINT_FIELDS = [
  "x",
  "y",
  "width",
  "height",
  "opacity",
  "force",
  "azimuth",
  "altitude",
  "timeOffset",
] as const;

const finite = z.number().finite();
const rgba = z.tuple([finite, finite, finite, finite]);
const rect = z.tuple([finite, finite, finite, finite]);

export const paperStrokeSchema = z
  .object({
    ink: z.string(),
    inkIdentifier: z.string(),
    /** sRGB red, green, blue, alpha, each 0..1. Null when the ink color has no sRGB form. */
    color: rgba.nullable(),
    /** Mean rendered point width. */
    width: finite,
    /** Affine transform [a, b, c, d, tx, ty] from point space to drawing space. */
    transform: z.tuple([finite, finite, finite, finite, finite, finite]).nullable(),
    pointCount: z.number().int().nonnegative(),
    renderBounds: rect,
    masked: z.boolean(),
    points: z.array(z.array(finite).length(PAPER_POINT_FIELDS.length)).optional(),
    pointsOmitted: z.literal(true).optional(),
  })
  .passthrough();
export type PaperStroke = z.infer<typeof paperStrokeSchema>;

export const paperReadSchema = z
  .object({
    status: z.literal("ok"),
    storeKind: z.enum(["live", "copy"]),
    attachmentIdentifier: z.string(),
    noteIdentifier: z.string().nullable(),
    typeUTI: z.string(),
    decodePath: z.string(),
    vectorDecode: z.enum(["strokes", "empty"]),
    drawingCount: z.number().int().nonnegative(),
    strokeCount: z.number().int().nonnegative(),
    returnedStrokeCount: z.number().int().nonnegative(),
    pointCount: z.number().int().nonnegative(),
    bounds: rect.nullable(),
    inks: z.array(z.string()),
    pointFields: z.array(z.string()),
    strokes: z.array(paperStrokeSchema),
    shapes: z.array(z.unknown()),
    shapeDecode: z.object({ available: z.boolean(), reason: z.string().nullable() }).passthrough(),
    truncated: z.boolean(),
    warnings: z.array(z.string()),
  })
  .passthrough();
export type PaperRead = z.infer<typeof paperReadSchema>;

export interface PaperReadRequest {
  /** Note UUID: decodes the note's single Paper drawing. */
  identifier?: string;
  /** Attachment UUID of one Paper drawing. */
  attachmentIdentifier?: string;
  /** Include per-point arrays (default true). */
  includePoints?: boolean;
  /** Point budget, 1..40000 (default 20000). */
  maxPoints?: number;
}

/** Validate a read request before anything is spawned. */
export function assertPaperReadRequest(request: PaperReadRequest): void {
  const hasNote = request.identifier !== undefined;
  const hasAttachment = request.attachmentIdentifier !== undefined;
  if (hasNote === hasAttachment)
    throw new PrivateHelperError(
      "invalid_request",
      "Pass exactly one of identifier (note) or attachmentIdentifier"
    );
  if (hasNote) assertNoteIdentifier(request.identifier as string);
  else {
    try {
      assertNoteIdentifier(request.attachmentIdentifier as string);
    } catch {
      throw new PrivateHelperError("invalid_request", "attachmentIdentifier must be a UUID");
    }
  }
  if (
    request.maxPoints !== undefined &&
    (!Number.isInteger(request.maxPoints) ||
      request.maxPoints < 1 ||
      request.maxPoints > MAX_PAPER_POINTS)
  )
    throw new PrivateHelperError(
      "invalid_request",
      `maxPoints must be an integer from 1 to ${MAX_PAPER_POINTS}`
    );
}

/** Decode one Paper drawing's strokes. Read-only. */
export function readPaper(
  request: PaperReadRequest,
  deps: PrivateHelperDeps = defaultDeps()
): PaperRead {
  assertPaperReadRequest(request);
  const fields: Record<string, unknown> = {};
  if (request.identifier !== undefined) fields.identifier = request.identifier;
  if (request.attachmentIdentifier !== undefined)
    fields.attachmentIdentifier = request.attachmentIdentifier;
  if (request.includePoints !== undefined) fields.includePoints = request.includePoints;
  if (request.maxPoints !== undefined) fields.maxPoints = request.maxPoints;
  const response = callPrivateHelper("read_paper", fields, deps);
  const parsed = paperReadSchema.safeParse(response);
  if (!parsed.success)
    throw new PrivateHelperError(
      "invalid_response",
      `Unexpected helper response: ${parsed.error.issues
        .slice(0, 5)
        .map((i) => i.path.join(".") + " " + i.message)
        .join("; ")}`
    );
  return parsed.data;
}
