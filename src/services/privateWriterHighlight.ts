/**
 * Notes' highlight through the opt-in private WRITER.
 *
 * Notes stores the highlight as the `TTEmphasis` attribute (AttributeRun
 * field 14): 1 purple, 2 pink, 3 orange, 4 mint, 5 blue. Neither AppleScript
 * nor Shortcuts can set it. The writer's `set_highlight` action applies or
 * removes it on a set of target ranges under an `ifRevision` compare-and-swap,
 * then re-reads the note from a fresh Core Data stack and requires the text to
 * be unchanged, the stored emphasis runs of the whole note to equal the
 * requested change, and Notes' derived `hasEmphasis` flag to agree. `dryRun`
 * reports the plan without writing.
 *
 * The request names a `scope`. The only scope today is `"text"`: every exact,
 * case-sensitive occurrence of a literal `match`, which must occur exactly
 * `expectedCount` times. The action, result shape, planning, and verification
 * work on any list of ranges, so a later whole-note scope is one more
 * {@link HighlightTarget} variant and one more branch in the writer's target
 * selection.
 *
 * @module services/privateWriterHighlight
 */
import { z } from "zod";
import {
  HIGHLIGHT_LIVE_VALIDATED,
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

export const HIGHLIGHT_COLORS = ["purple", "pink", "orange", "mint", "blue"] as const;
export type HighlightColor = (typeof HIGHLIGHT_COLORS)[number] | "none";
export const MAX_MATCH_UTF16 = 1000;
export const MAX_HIGHLIGHT_RANGES = 100;

/** What to highlight. Only the exact-text scope exists today. */
export type HighlightTarget = { scope: "text"; match: string; expectedCount?: number };

const revision = z.string().regex(/^r1:[a-f0-9]{64}$/);
const runSchema = z.object({
  start: z.number().int().nonnegative(),
  lengthUTF16: z.number().int().positive(),
  color: z.string().nullable(),
});

export const highlightResultSchema = z
  .object({
    status: z.enum(["planned", "unchanged", "updated"]),
    committed: z.boolean(),
    dryRun: z.boolean(),
    identifier: z.string(),
    scope: z.literal("text"),
    color: z.string(),
    rangeCount: z.number().int().positive(),
    revisionBefore: revision,
    revisionAfter: revision,
    plan: z
      .array(
        z.object({
          start: z.number().int().nonnegative(),
          lengthUTF16: z.number().int().positive(),
          currentRuns: z.array(runSchema),
          changes: z.boolean(),
        })
      )
      .optional(),
    ranges: z
      .array(
        z.object({
          start: z.number().int().nonnegative(),
          lengthUTF16: z.number().int().positive(),
          storedRuns: z.array(runSchema),
        })
      )
      .optional(),
    /** Notes' derived "note has a highlight" flag after the call; null when not modeled. */
    hasEmphasis: z.boolean().nullable(),
    modificationDate: z.string().nullable(),
    ...writeSyncFields,
  })
  .passthrough();
export type HighlightResult = z.infer<typeof highlightResultSchema>;

/**
 * Control characters (tab allowed), newlines, the attachment glyph U+FFFC,
 * and U+2028/U+2029. A match stays inside one paragraph.
 */
// eslint-disable-next-line no-control-regex
const FORBIDDEN_MATCH = /[\x00-\x08\x0A-\x1F\x7F-\x9F\uFFFC\u2028\u2029]/u;

export function assertHighlightMatch(match: string): void {
  if (!match.length) throw new PrivateWriteError("invalid_request", "match is required", false);
  if (match.length > MAX_MATCH_UTF16)
    throw new PrivateWriteError(
      "invalid_request",
      `match exceeds ${MAX_MATCH_UTF16} UTF-16 code units`,
      false
    );
  if (FORBIDDEN_MATCH.test(match))
    throw new PrivateWriteError(
      "invalid_request",
      "match must be text within one paragraph (no newlines, attachment glyphs, or control characters)",
      false
    );
}

export interface HighlightRequest {
  identifier: string;
  target: HighlightTarget;
  color: HighlightColor;
  ifRevision?: string;
  dryRun?: boolean;
}

/** The writer fields for one target. */
function targetFields(target: HighlightTarget): Record<string, unknown> {
  if (target.scope !== "text")
    throw new PrivateWriteError("invalid_request", 'scope must be "text"', false);
  assertHighlightMatch(target.match);
  const expectedCount = target.expectedCount ?? 1;
  if (!Number.isInteger(expectedCount) || expectedCount < 1 || expectedCount > MAX_HIGHLIGHT_RANGES)
    throw new PrivateWriteError(
      "invalid_request",
      `expectedCount must be an integer from 1 to ${MAX_HIGHLIGHT_RANGES}`,
      false
    );
  return { scope: "text", match: target.match, expectedCount };
}

/** Apply (or with color "none", remove) the highlight on the target ranges. */
export function setHighlight(
  request: HighlightRequest,
  deps: PrivateHelperDeps = defaultWriterDeps()
): HighlightResult {
  assertNoteIdentifier(request.identifier);
  const fields: Record<string, unknown> = {
    identifier: request.identifier,
    ...targetFields(request.target),
  };
  if (request.color !== "none" && !HIGHLIGHT_COLORS.includes(request.color))
    throw new PrivateWriteError(
      "invalid_request",
      "color must be purple, pink, orange, mint, blue, or none",
      false
    );
  fields.color = request.color;
  const dryRun = request.dryRun === true;
  if (request.ifRevision !== undefined) {
    assertRevision(request.ifRevision);
    fields.ifRevision = request.ifRevision;
  } else if (!dryRun) {
    throw new PrivateWriteError(
      "invalid_request",
      "ifRevision is required unless dryRun is true",
      false
    );
  }
  if (dryRun) fields.dryRun = true;
  else requireLiveValidated(HIGHLIGHT_LIVE_VALIDATED, "native-highlight-text", deps.env);
  try {
    return parseWriterResult(
      highlightResultSchema,
      callPrivateWriter("set_highlight", fields, deps),
      true
    );
  } catch (error) {
    // A dry run opens the store read-only and cannot write, so an
    // indeterminate outcome is still "nothing committed".
    if (dryRun && error instanceof PrivateWriteError && error.committed === "unknown")
      throw new PrivateWriteError(error.code, error.message, false, error.details);
    throw error;
  }
}
