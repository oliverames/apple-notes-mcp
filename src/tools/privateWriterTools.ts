/**
 * MCP tools for the opt-in private WRITER (fork-only layer over #181/#204).
 *
 * - `native-writer-status`: both switches, the writer's installation and
 *   checksum state, and its live probe.
 * - `native-append-plain-text`: the foundation's demonstration write, guarded
 *   by a revision token (compare-and-swap), verified by a fresh read-back,
 *   and optionally followed by the move-in-place sync nudge.
 * - `native-sync-push`: the nudge (or a confirmed Notes.app relaunch) on its
 *   own, for writer-saved changes Notes.app has not uploaded yet.
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
  MAX_SYNC_TARGETS,
  defaultNudgeDeps,
  nudgeInPlace,
  syncPush,
  type NudgeDeps,
} from "../services/privateSyncNudge.js";
import {
  PrivateWriteError,
  WRITER_SETUP_COMMAND,
  appendPlainText,
  defaultWriterDeps,
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
    case "confirmation_required":
      return "validation_error";
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
    "native-sync-push",
    "Use when: a note or folder changed through the private writer earlier (native-append-plain-text and the other native write tools, without nudge or with a nudge that timed out) still shows cloudSync.uploadPending, and you want Notes.app to upload it, or just to check whether it has.\n" +
      "Returns: per target, Notes' own version counters before and after, uploadRecorded (true only when Notes recorded the current version as synced to iCloud), the action taken, and a skip reason; the library-wide pendingUploadCount before and after; warnings. pushScheduled is always false: only Notes.app uploads.\n" +
      "Do not use when: the change was made through AppleScript or Shortcuts tools (Notes.app uploads those itself), or right after a native write that already ran with nudge: true and reported uploadRecorded.\n" +
      'Safety: never writes to the Notes database. method "status" is read-only. "nudge" (default) makes Notes.app save each pending note by moving it into the folder it is already in: no text, title, or modification date changes, and the writer\'s revision token is compared before and after (contentUnchanged). It skips locked, shared, trashed, and non-iCloud notes, and folders. "relaunch" quits and reopens Notes.app so its launch sweep uploads everything pending, folders included; it interrupts anyone using Notes and requires confirm: true after asking the user. Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1, APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1, and a built writer (setup --native-writer).',
    {
      identifiers: z
        .array(notesUuid)
        .min(1)
        .max(MAX_SYNC_TARGETS)
        .describe("Notes UUIDs of the notes or folders to check (from native-note-state etc.)"),
      method: z
        .enum(["status", "nudge", "relaunch"])
        .optional()
        .describe(
          "status = read only; nudge (default) = in-place Notes.app save; relaunch = quit and reopen Notes.app"
        ),
      confirm: z
        .boolean()
        .optional()
        .describe("Must be true for relaunch, after the user agreed to Notes.app being quit"),
      waitSeconds: z
        .number()
        .int()
        .min(0)
        .max(MAX_NUDGE_WAIT_SECONDS)
        .optional()
        .describe("Seconds to watch the counters afterwards (default 30; 0 for status)"),
    },
    { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
    async (args, deps) => ({ ...(await syncPush(args, deps.nudge)) })
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
