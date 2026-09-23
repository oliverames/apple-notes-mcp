/**
 * MCP tools for the opt-in native private helper (#181).
 *
 * - `native-helper-status`: install state, opt-in state, and the live probe.
 * - `native-note-state`: read one note's native state and revision token.
 * - `native-append-plain-text`: the one demonstration write, guarded by that
 *   revision token (compare-and-swap) and verified by a fresh read-back.
 *
 * All three are always registered so the tool list does not change with the
 * environment. Each refuses with a machine-readable `code` when the helper is
 * off, missing, stale, or unsupported on this macOS.
 *
 * @module tools/privateHelperTools
 */
import type { McpServer, ToolCallback } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ToolAnnotations } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { AppleNotesManager } from "../services/appleNotesManager.js";
import {
  PrivateHelperError,
  appendPlainText,
  defaultDeps,
  privateHelperCapabilities,
  readNoteState,
  type PrivateHelperDeps,
} from "../services/privateHelper.js";

export const coreDataId = z.string().regex(/^x-coredata:\/\/[0-9A-F-]+\/ICNote\/p\d+$/i);
export const notesUuid = z
  .string()
  .regex(/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i);

/** Resolve the Notes UUID from either an explicit identifier or an x-coredata id. */
export function resolveIdentifier(
  manager: AppleNotesManager,
  args: { identifier?: string; id?: string }
): string {
  if (args.identifier && args.id)
    throw new PrivateHelperError("invalid_request", "Pass identifier or id, not both");
  if (args.identifier) return args.identifier;
  if (!args.id) throw new PrivateHelperError("invalid_request", "identifier or id is required");
  const link = manager.getNoteLinkById(args.id);
  const match = link?.match(/identifier=([0-9A-F-]{36})$/i);
  if (!match)
    throw new PrivateHelperError(
      "not_found",
      "Could not resolve that id to a Notes UUID (needs Full Disk Access); pass identifier instead"
    );
  return match[1];
}

export function errorResult(error: unknown) {
  const payload =
    error instanceof PrivateHelperError
      ? {
          ok: false,
          code: error.code,
          message: error.message,
          ...(error.committed !== undefined ? { committed: error.committed } : {}),
          ...error.details,
        }
      : { ok: false, code: "internal_error", message: String(error) };
  return {
    content: [{ type: "text" as const, text: JSON.stringify(payload) }],
    isError: true,
  };
}

export function registerPrivateHelperTools(
  server: McpServer,
  manager: AppleNotesManager,
  depsFactory: () => PrivateHelperDeps = () => defaultDeps()
) {
  function tool<S extends z.ZodRawShape>(
    name: string,
    description: string,
    inputSchema: S,
    annotations: ToolAnnotations,
    handler: (args: z.infer<z.ZodObject<S>>, deps: PrivateHelperDeps) => Record<string, unknown>
  ) {
    server.registerTool(
      name,
      {
        description,
        inputSchema,
        annotations,
        outputSchema: z.object({ ok: z.boolean() }).passthrough(),
      },
      (async (args: z.infer<z.ZodObject<S>>) => {
        try {
          const result = { ok: true, ...handler(args, depsFactory()) };
          return {
            content: [{ type: "text" as const, text: JSON.stringify(result) }],
            structuredContent: result,
          };
        } catch (error) {
          return errorResult(error);
        }
      }) as unknown as ToolCallback<S>
    );
  }

  tool(
    "native-helper-status",
    "Use when: checking whether the opt-in native private helper is enabled, built, current, and working on this macOS before calling native-note-state or native-append-plain-text.\n" +
      "Returns: enabled flag, installation state (path, manifest, stale/modified checks), the live probe (macOS and Notes versions, framework, store access), and per-feature availability with a machine reason.\n" +
      "Do not use when: checking the Shortcuts bridges (native-tags-status, get-capabilities).\n" +
      "Safety: read-only. The probe opens the Notes store read-only and only when the helper is enabled and installed.",
    {},
    { readOnlyHint: true, openWorldHint: false },
    (_args, deps) => {
      const capabilities = privateHelperCapabilities(deps);
      return {
        ...capabilities,
        ...(capabilities.installation.ready
          ? {}
          : { setupCommand: "apple-notes-mcp setup --native-helper" }),
      };
    }
  );

  tool(
    "native-note-state",
    "Use when: you need a note's native revision token before native-append-plain-text, or its native title, modification date, folder identifier, and iCloud upload state.\n" +
      "Returns: identifier, title, modificationDate, folderIdentifier, lock/trash/shared/editable flags, `revision` (pass it as ifRevision), and cloudSync versions.\n" +
      "Do not use when: reading note content (get-note-content, get-note-markdown).\n" +
      "Safety: read-only; the helper opens the store with Core Data's read-only option. Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1 and a built helper.",
    {
      identifier: notesUuid.optional().describe("Notes UUID (the notes://showNote identifier)"),
      id: coreDataId.optional().describe("x-coredata note id; resolved to a UUID via the database"),
    },
    { readOnlyHint: true, openWorldHint: false },
    (args, deps) => ({ ...readNoteState(resolveIdentifier(manager, args), deps) })
  );

  tool(
    "native-append-plain-text",
    "Use when: appending plain text paragraphs to one exact note through Notes' own data model, with a compare-and-swap guard. This is the private-helper path, distinct from append-native (Shortcuts) and append-to-note (AppleScript HTML rewrite).\n" +
      "Returns: committed/verified flags, revisionBefore/revisionAfter, the new modification date, and sync state: pushScheduled (always false; the helper cannot upload), pushState, and cloudSync versions.\n" +
      "Do not use when: the note is locked, shared, trashed, or still downloading, or you need formatting (text is appended as plain body paragraphs).\n" +
      'Safety: writes to the Notes database through unsupported private API. Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1, a built helper, and a fresh `revision` from native-note-state as ifRevision; refuses on any change since. Verifies by re-reading in a new Core Data stack. A timeout is indeterminate (committed: "unknown"): read native-note-state before any retry. Not yet live-validated, so it also requires APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1.',
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
      ifRevision: z
        .string()
        .regex(/^r1:[a-f0-9]{64}$/)
        .describe("The `revision` returned by native-note-state for this note"),
    },
    { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    (args, deps) => ({
      ...appendPlainText(
        {
          identifier: resolveIdentifier(manager, args),
          text: args.text,
          ifRevision: args.ifRevision,
        },
        deps
      ),
    })
  );
}
