/**
 * MCP tools for the opt-in private WRITER (fork-only layer over #181/#204).
 *
 * - `native-writer-status`: both switches, the writer's installation and
 *   checksum state, and its live probe.
 * - `native-append-plain-text`: the foundation's demonstration write, guarded
 *   by a revision token (compare-and-swap), verified by a fresh read-back,
 *   and optionally followed by the move-in-place sync nudge.
 * - `native-edit-note`: literal in-place edits resolved against one native
 *   snapshot. A dry run (the writer's read-only plan_edit) returns the plan
 *   and `revisionBefore`; the apply (edit_note) must pass it back as
 *   `ifRevision`, and its read-back proves that text, formatting, and
 *   attachments outside the edited ranges did not change.
 *
 * The read-only tools (`native-helper-status`, `native-note-state`) stay in
 * privateHelperTools.ts and never reach the writer. Every tool here is always
 * registered so the tool list does not change with the environment; each
 * refuses with a machine-readable `code` plus the raw `helperCode` when a
 * switch is off or the writer is missing, stale, or unsupported. Write
 * failures carry `committed` (false: nothing saved; true: saved but not
 * verified) or `indeterminate: true` (read the note before any retry).
 *
 * Feature modules register their own writer tools through
 * {@link registerWriterTool} so they share this envelope.
 *
 * @module tools/privateWriterTools
 */
import type { McpServer, ToolCallback } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ToolAnnotations } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { AppleNotesManager } from "../services/appleNotesManager.js";
import { PrivateHelperError } from "../services/privateHelper.js";
import {
  MAX_NUDGE_WAIT_SECONDS,
  defaultNudgeDeps,
  nudgeInPlace,
  type NudgeDeps,
} from "../services/privateSyncNudge.js";
import {
  MAX_EDIT_OPERATIONS,
  PrivateWriteError,
  WRITER_SETUP_COMMAND,
  appendPlainText,
  defaultWriterDeps,
  editNote,
  editOperationSchema,
  privateWriterCapabilities,
  type PrivateHelperDeps,
} from "../services/privateWriter.js";
import {
  CodedError,
  errorResult,
  type ErrorCode,
  type ErrorEnvelope,
} from "../utils/errorCodes.js";
import { UUID_PATTERN } from "../utils/noteIdentifiers.js";
import { envelopeCode, resolveIdentifier } from "./privateHelperTools.js";

export const coreDataId = z.string().regex(/^x-coredata:\/\/[0-9A-F-]+\/ICNote\/p\d+$/i);
export const notesUuid = z.string().regex(UUID_PATTERN);
export const revisionToken = z.string().regex(/^r1:[a-f0-9]{64}$/);
export { resolveIdentifier };

/** Map a writer code onto the server-wide error vocabulary (#185). */
export function writerEnvelopeCode(helperCode: string, message: string): ErrorCode {
  switch (helperCode) {
    case "revision_conflict":
      return "revision_conflict";
    case "verification_failed":
      return "verification_failed";
    case "writes_disabled":
    case "not_live_validated":
      return "unsupported";
    case "ambiguous":
      return "ambiguous";
    default:
      return envelopeCode(helperCode, message);
  }
}

/**
 * Route a writer failure through the shared CodedError/errorResult envelope,
 * carrying the writer's own `committed` answer.
 */
export function writerErrorResult(error: unknown) {
  if (!(error instanceof PrivateHelperError)) {
    const message = error instanceof Error ? error.message : String(error);
    return errorResult(`native writer: ${message}`, error);
  }
  const committed = error instanceof PrivateWriteError ? error.committed : undefined;
  const message = `native writer (${error.code}): ${error.message}`;
  const envelope: ErrorEnvelope = {
    ...error.details,
    code: writerEnvelopeCode(error.code, error.message),
    helperCode: error.code,
  };
  if (committed === "unknown") {
    envelope.indeterminate = true;
  } else if (committed !== undefined) {
    envelope.committed = committed;
    // Saved but not confirmed by read-back: still uncertain for the caller.
    envelope.indeterminate = committed === true;
  } else {
    // Reads and pre-spawn refusals never write.
    envelope.committed = false;
  }
  return errorResult(message, new CodedError(message, envelope));
}

/**
 * Register one writer-backed tool. The handler may be async; its result is
 * returned as `{ ok: true, ...result }` in text and structuredContent.
 */
export function registerWriterTool<S extends z.ZodRawShape, D>(
  server: McpServer,
  depsFactory: () => D,
  name: string,
  description: string,
  inputSchema: S,
  annotations: ToolAnnotations,
  handler: (
    args: z.infer<z.ZodObject<S>>,
    deps: D
  ) => Record<string, unknown> | Promise<Record<string, unknown>>
) {
  server.registerTool(
    name,
    {
      description,
      inputSchema,
      annotations,
      outputSchema: z.object({ ok: z.boolean().optional() }).passthrough(),
    },
    (async (args: z.infer<z.ZodObject<S>>) => {
      try {
        const result = { ok: true, ...(await handler(args, depsFactory())) };
        return {
          content: [{ type: "text" as const, text: JSON.stringify(result) }],
          structuredContent: result,
        };
      } catch (error) {
        return writerErrorResult(error);
      }
    }) as unknown as ToolCallback<S>
  );
}

export interface WriterToolDeps {
  writer: PrivateHelperDeps;
  nudge: NudgeDeps;
}

export function defaultWriterToolDeps(): WriterToolDeps {
  const writer = defaultWriterDeps();
  return { writer, nudge: defaultNudgeDeps({ helper: writer }) };
}

export function registerPrivateWriterTools(
  server: McpServer,
  manager: AppleNotesManager,
  depsFactory: () => WriterToolDeps = defaultWriterToolDeps
) {
  registerWriterTool(
    server,
    depsFactory,
    "native-writer-status",
    "Use when: checking whether the opt-in private WRITER is enabled, built, current, and working before any native write tool (native-append-plain-text and the other native-* write tools).\n" +
      "Returns: enabled and writesEnabled flags, the writer's installation state (path, manifest, stale/modified checks), its live probe, and per-feature availability with a machine reason (disabled, writes_disabled, helper_not_installed, helper_stale, not_live_validated, ...).\n" +
      "Do not use when: you only need reads (native-helper-status covers the read-only helper).\n" +
      "Safety: read-only. The probe opens the Notes store read-only, and only when both switches are on and the writer is installed.",
    {},
    { readOnlyHint: true, openWorldHint: false },
    (_args, deps) => {
      const capabilities = privateWriterCapabilities(deps.writer);
      return {
        ...capabilities,
        ...(capabilities.installation.ready ? {} : { setupCommand: WRITER_SETUP_COMMAND }),
      };
    }
  );

  registerWriterTool(
    server,
    depsFactory,
    "native-append-plain-text",
    "Use when: appending plain text paragraphs to one exact note through Notes' own data model, with a compare-and-swap guard. This is the private-writer path, distinct from append-native (Shortcuts) and append-to-note (AppleScript HTML rewrite).\n" +
      "Returns: committed/verified flags, revisionBefore/revisionAfter, the new modification date, and sync state: pushScheduled (always false; the writer cannot upload), pushState, cloudSync versions, and with nudge: true a `sync` report of the move-in-place nudge (uploadRecorded per target).\n" +
      "Do not use when: the note is locked, shared, trashed, or still downloading, or you need formatting (text is appended as plain body paragraphs).\n" +
      "Safety: writes to the Notes database through unsupported private API. Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1, APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1, a built writer (setup --native-writer), and a fresh `revision` from native-note-state as ifRevision; refuses on any change since. Verifies by re-reading in a new Core Data stack. A timeout is indeterminate (indeterminate: true): read native-note-state before any retry. Not yet live-validated, so it also requires APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1.",
    {
      identifier: notesUuid.optional().describe("Notes UUID"),
      id: coreDataId.optional().describe("x-coredata note id; resolved to a UUID via the database"),
      text: z
        .string()
        .min(1)
        .max(50_000)
        .describe(
          "Plain text to append. \\n starts a new paragraph; no \\r or control characters."
        ),
      ifRevision: revisionToken.describe(
        "The `revision` returned by native-note-state for this note"
      ),
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
      const identifier = resolveIdentifier(manager, args);
      const result = appendPlainText(
        { identifier, text: args.text, ifRevision: args.ifRevision },
        deps.writer
      );
      if (!args.nudge) return { ...result };
      return {
        ...result,
        sync: await nudgeAfterWrite(identifier, args.nudgeWaitSeconds, deps.nudge),
      };
    }
  );

  registerWriterTool(
    server,
    depsFactory,
    "native-edit-note",
    "Use when: changing selected text inside one existing note in place while everything outside the edited ranges (attachments, tables, checklist state, paragraph styles, inline formatting) stays untouched: replace literal text (with expectedCount and occurrence), insert paragraphs before or after a paragraph matched by its exact text or by style and position (for example the 2nd subheading), delete a paragraph or list row, or retitle. Always run twice: dryRun: true to get the plan and revisionBefore, then the IDENTICAL request with dryRun: false and ifRevision set to that revisionBefore.\n" +
      "Returns: per-operation matched counts and target ranges, lengthBefore/lengthAfter, unchangedUTF16, wouldChange, titleChanged, attachmentGlyphs, and revisionBefore. An apply also returns committed/verified, revisionAfter, `preservation` (what the read-back proved: formatting outside the edits, the attachment glyph sequence, and the attachment rows), sync state (pushScheduled is always false; pushState, cloudSync), and with nudge: true a `sync` report of the move-in-place nudge.\n" +
      "Do not use when: replacing a whole note (update-note), appending (native-append-plain-text, append-native), or the note is locked, shared, trashed, or still downloading. Matching is literal and case-sensitive, never crosses a line break, and never touches attachments or inline objects.\n" +
      "Safety: a dry run is read-only. Applying writes through unsupported private API and requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1, APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1, a built writer (setup --native-writer), and, until live-validated, APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1. Refuses with a code and commits nothing on: revision_conflict (note changed since the dry run), match_count_mismatch, mixed_formatting (plain text over mixed formatting; pass replacement.runs), conflicting_operations, title_invariant, unsupported_selection, unexpected_side_effect. Each apply is verified by re-reading in a new Core Data stack; verification_failed means committed: true and indeterminate. A timeout is indeterminate: read native-note-state before any retry.",
    {
      identifier: notesUuid.optional().describe("Notes UUID"),
      id: coreDataId.optional().describe("x-coredata note id; resolved to a UUID via the database"),
      dryRun: z
        .boolean()
        .describe("true: plan only and return revisionBefore. false: apply; requires ifRevision"),
      ifRevision: revisionToken
        .optional()
        .describe("The revisionBefore of an identical dry run (required when dryRun is false)"),
      requireNonSystemPaper: z
        .boolean()
        .optional()
        .describe("Refuse Quick Notes; repeat it in both the dry run and the apply"),
      operations: z
        .array(editOperationSchema)
        .min(1)
        .max(MAX_EDIT_OPERATIONS)
        .describe(
          "Applied together against one snapshot. ops: replace {selector:{text, scope?, match?, occurrence?}, replacement:{text}|{runs}}, delete_paragraph {selector:{text, scope?, occurrence?}|{kind:'blank', style, occurrence?}}, insert_after/insert_before {anchor:{text, scope?, occurrence?}|{kind:'style', style, occurrence?}, blocks:[{type, text|runs, checked?}]}, set_title {replacement:{text}|{runs}}. expectedCount (default 1) must equal the full match count; occurrence picks one of them."
        ),
      nudge: z
        .boolean()
        .optional()
        .describe(
          "After a verified apply, ask Notes.app to upload the note by moving it into its own folder (default false)"
        ),
      nudgeWaitSeconds: z
        .number()
        .int()
        .min(0)
        .max(MAX_NUDGE_WAIT_SECONDS)
        .optional()
        .describe("With nudge: how long to watch Notes' upload counters (default 30)"),
    },
    { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
    async (args, deps) => {
      const identifier = resolveIdentifier(manager, args);
      const result = editNote(
        {
          identifier,
          dryRun: args.dryRun,
          ifRevision: args.ifRevision,
          requireNonSystemPaper: args.requireNonSystemPaper,
          operations: args.operations,
        },
        deps.writer
      );
      if (!args.nudge || result.status !== "updated") return { ...result };
      return {
        ...result,
        sync: await nudgeAfterWrite(identifier, args.nudgeWaitSeconds, deps.nudge),
      };
    }
  );
}

/**
 * The post-write nudge. A failure here never hides the committed write: it
 * is reported inside `sync` instead of failing the tool.
 */
export async function nudgeAfterWrite(
  identifier: string,
  waitSeconds: number | undefined,
  deps: NudgeDeps
): Promise<Record<string, unknown>> {
  try {
    const report = await nudgeInPlace({ identifiers: [identifier], waitSeconds }, deps);
    const { before: _before, after: _after, ...rest } = report;
    void _before;
    void _after;
    return { ok: true, ...rest };
  } catch (error) {
    return {
      ok: false,
      code: error instanceof PrivateHelperError ? error.code : "internal_error",
      message: error instanceof Error ? error.message : String(error),
    };
  }
}
