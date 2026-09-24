/**
 * Highlight tool on the opt-in private WRITER.
 *
 * `native-highlight-text` applies or removes Notes' highlight on every exact
 * occurrence of a literal string, with a count guard, a dry run, an
 * `ifRevision` compare-and-swap, a fresh read-back, and the optional
 * move-in-place sync nudge. It sends the writer's `set_highlight` action with
 * `scope: "text"`; a later whole-note option can reuse the same action with
 * another scope. It shares the envelope in privateWriterTools.ts.
 *
 * @module tools/privateWriterHighlightTools
 */
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { AppleNotesManager } from "../services/appleNotesManager.js";
import { MAX_NUDGE_WAIT_SECONDS } from "../services/privateSyncNudge.js";
import {
  HIGHLIGHT_COLORS,
  MAX_HIGHLIGHT_RANGES,
  MAX_MATCH_UTF16,
  setHighlight,
} from "../services/privateWriterHighlight.js";
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

export function registerPrivateWriterHighlightTools(
  server: McpServer,
  manager: AppleNotesManager,
  depsFactory: () => WriterToolDeps = defaultWriterToolDeps
) {
  registerWriterTool(
    server,
    depsFactory,
    "native-highlight-text",
    "Use when: applying or removing Notes' highlight (the purple, pink, orange, mint, and blue highlight colors) on exact text in one note. AppleScript and Shortcuts cannot set it.\n" +
      "Returns: status (planned for a dry run, unchanged when every match already has that state, updated), rangeCount, a per-match plan with current runs (dry run or no-op) or the stored runs re-read after the write (`ranges`), hasEmphasis (Notes' derived flag), revisionBefore/revisionAfter, sync state (pushScheduled is always false), and with nudge: true a `sync` report.\n" +
      "Do not use when: the text spans paragraphs, or you need bold, italic, or text color.\n" +
      "Safety: writes to the Notes database through unsupported private API, changing only the highlight attribute of the matched characters. `match` is literal and case-sensitive; the call refuses (match_count_mismatch, nothing written) unless it occurs exactly `expectedCount` times. Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1, APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1, a built writer, and a fresh `revision` from native-note-state as ifRevision (optional for dryRun). Verifies every highlight run in the note by re-reading it in a new Core Data stack. A timeout is indeterminate (indeterminate: true). Writes are not yet live-validated, so they also require APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1; dryRun does not.",
    {
      identifier: notesUuid.optional().describe("Notes UUID"),
      id: coreDataId.optional().describe("x-coredata note id; resolved to a UUID via the database"),
      match: z
        .string()
        .min(1)
        .max(MAX_MATCH_UTF16)
        .describe("Exact, case-sensitive text to highlight, within one paragraph"),
      color: z
        .enum([...HIGHLIGHT_COLORS, "none"])
        .describe("Highlight color, or none to remove the highlight"),
      expectedCount: z
        .number()
        .int()
        .min(1)
        .max(MAX_HIGHLIGHT_RANGES)
        .optional()
        .describe("How many times `match` must occur (default 1); every occurrence is changed"),
      ifRevision: revisionToken
        .optional()
        .describe("The `revision` from native-note-state; required unless dryRun is true"),
      dryRun: z
        .boolean()
        .optional()
        .describe("Report the matches and their current highlight without writing"),
      nudge: z
        .boolean()
        .optional()
        .describe(
          "After a verified change, ask Notes.app to upload the note by moving it into its own folder (default false; skipped when nothing was written)"
        ),
      nudgeWaitSeconds: z
        .number()
        .int()
        .min(0)
        .max(MAX_NUDGE_WAIT_SECONDS)
        .optional()
        .describe("With nudge: how long to watch Notes' upload counters (default 30)"),
    },
    { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    async (args, deps) => {
      const identifier = resolveIdentifier(manager, args);
      const result = setHighlight(
        {
          identifier,
          target: { scope: "text", match: args.match, expectedCount: args.expectedCount },
          color: args.color,
          ifRevision: args.ifRevision,
          dryRun: args.dryRun,
        },
        deps.writer
      );
      if (!args.nudge || !result.committed) return { ...result };
      return {
        ...result,
        sync: await nudgeAfterWrite(identifier, args.nudgeWaitSeconds, deps.nudge),
      };
    }
  );
}
