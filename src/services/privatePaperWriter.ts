/**
 * Paper authoring through the opt-in private WRITER (#181).
 *
 * `add_paper` appends one drawing to the end of an exact note as a new
 * attachment: a Paper drawing (`com.apple.paper`) or a classic drawing
 * (`com.apple.drawing.2`). The drawing arrives already normalized by
 * utils/paperAuthoring.ts. The writer builds it as a public PencilKit
 * drawing, lets NotesShared create the attachment, saves with
 * NSErrorMergePolicy, and verifies by decoding the saved drawing through a
 * brand-new read-only Core Data stack.
 *
 * A dry run validates the drawing and the revision and reports the plan. It
 * opens the store read-only, so it never commits and does not need the
 * live-validation gate; it still needs both writer switches.
 *
 * @module services/privatePaperWriter
 */
import { z } from "zod";
import type { AuthorDrawing } from "../utils/paperAuthoring.js";
import {
  PAPER_WRITE_LIVE_VALIDATED,
  PrivateWriteError,
  assertNoteIdentifier,
  assertRevision,
  callPrivateWriter,
  defaultWriterDeps,
  parseWriterResult,
  requireLiveValidated,
  writeSyncFields,
  type PrivateHelperDeps,
} from "./privateWriter.js";
import { writerScopeFields, type ScopeGuard } from "./privateWriterScope.js";

export const PAPER_FORMATS = ["auto", "paper", "drawing"] as const;
export type PaperFormat = (typeof PAPER_FORMATS)[number];

const rect = z.array(z.number()).length(4);

const addPaperPlanSchema = z
  .object({
    format: z.enum(["paper", "drawing"]),
    availableFormats: z.array(z.string()),
    strokeCount: z.number().int().nonnegative(),
    pointCount: z.number().int().nonnegative(),
    inks: z.array(z.string()),
    bounds: rect,
    revisionBefore: z.string(),
    storeKind: z.enum(["live", "copy"]),
  })
  .passthrough();

export const addPaperPlannedSchema = addPaperPlanSchema.extend({
  status: z.literal("planned"),
  committed: z.literal(false),
});

export const addPaperCreatedSchema = addPaperPlanSchema.extend({
  status: z.literal("created"),
  committed: z.literal(true),
  verified: z.literal(true),
  identifier: z.string(),
  attachmentIdentifier: z.string(),
  typeUTI: z.string().nullable(),
  decodedStrokeCount: z.number().int().nonnegative(),
  decodedPointCount: z.number().int().nonnegative(),
  glyphInserted: z.boolean(),
  previewUpdated: z.boolean(),
  revisionAfter: z.string(),
  modificationDate: z.string().nullable(),
  ...writeSyncFields,
});

export type AddPaperPlan = z.infer<typeof addPaperPlannedSchema>;
export type AddPaperCreated = z.infer<typeof addPaperCreatedSchema>;
export type AddPaperResult = AddPaperPlan | AddPaperCreated;

export interface AddPaperRequest {
  identifier: string;
  ifRevision: string;
  drawing: AuthorDrawing;
  format?: PaperFormat;
  dryRun?: boolean;
  /** Folder preconditions, checked by the writer just before the save. */
  scope?: ScopeGuard;
}

/**
 * Add one drawing to the end of a note as a new Paper (or classic drawing)
 * attachment. Guarded by `ifRevision`, verified by a fresh read-back that
 * decodes the saved drawing. `dryRun` validates and plans without writing.
 */
export function addPaper(
  request: AddPaperRequest,
  deps: PrivateHelperDeps = defaultWriterDeps()
): AddPaperResult {
  assertNoteIdentifier(request.identifier);
  assertRevision(request.ifRevision);
  const dryRun = request.dryRun === true;
  if (!dryRun) requireLiveValidated(PAPER_WRITE_LIVE_VALIDATED, "native-add-paper", deps.env);
  const fields: Record<string, unknown> = {
    identifier: request.identifier,
    ifRevision: request.ifRevision,
    drawing: request.drawing,
    format: request.format ?? "auto",
    ...writerScopeFields(request.scope),
  };
  if (dryRun) fields.dryRun = true;
  if (!dryRun)
    return parseWriterResult(
      addPaperCreatedSchema,
      callPrivateWriter("add_paper", fields, deps),
      true
    );
  // A dry run opens the store read-only, so no failure of it can have
  // committed anything, whatever the transport reports.
  try {
    return parseWriterResult(
      addPaperPlannedSchema,
      callPrivateWriter("add_paper", fields, deps),
      false
    );
  } catch (error) {
    if (error instanceof PrivateWriteError && error.committed !== false)
      throw new PrivateWriteError(error.code, error.message, false, error.details);
    throw error;
  }
}
