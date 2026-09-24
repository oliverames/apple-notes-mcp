/**
 * MCP tools for paragraph identifiers through the opt-in private WRITER.
 *
 * - `native-set-paragraph-id`: give one paragraph (by `blockIndex` from the
 *   read-only list-note-paragraphs) a unique identifier, guarded by
 *   `ifRevision` and the paragraph text, and return its paragraph link.
 *
 * Listing paragraphs and building links stay with upstream's read-only
 * `list-note-paragraphs` and `get-paragraph-link`; this module adds only the
 * write they leave out.
 *
 * @module tools/privateWriterParagraphTools
 */
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { AppleNotesManager } from "../services/appleNotesManager.js";
import { MAX_NUDGE_WAIT_SECONDS } from "../services/privateSyncNudge.js";
import { setParagraphId } from "../services/privateWriterParagraphs.js";
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

/** The optional post-write nudge, shared by the paragraph write tools. */
export const nudgeInput = {
  nudge: z
    .boolean()
    .optional()
    .describe(
      "After a verified write, ask Notes.app to upload the changed note(s) by moving each into its own folder (default false)"
    ),
  nudgeWaitSeconds: z
    .number()
    .int()
    .min(0)
    .max(MAX_NUDGE_WAIT_SECONDS)
    .optional()
    .describe("With nudge: how long to watch Notes' upload counters (default 30)"),
};

export function registerPrivateWriterParagraphTools(
  server: McpServer,
  manager: AppleNotesManager,
  depsFactory: () => WriterToolDeps = defaultWriterToolDeps
) {
  registerWriterTool(
    server,
    depsFactory,
    "native-set-paragraph-id",
    "Use when: list-note-paragraphs shows paragraphIdStatus `shared` or `missing` (or get-paragraph-link refuses with paragraph-id-shared / paragraph-id-missing) for a paragraph you need to link to. Gives that paragraph an identifier of its own so its paragraph link opens exactly there.\n" +
      "Returns: `status` (`updated`, or `unchanged` when the paragraph already had a unique identifier and nothing was written), `paragraphId`, `url` (applenotes://showNote?identifier=…&paragraphID=…), `previousParagraphId`, `previousParagraphIdStatus`, revisionBefore/revisionAfter, sync state (pushScheduled is always false), and with nudge: true a `sync` report.\n" +
      "Do not use when: the paragraph is already `unique` (use its url from list-note-paragraphs), or the note is locked, shared, trashed, or still downloading.\n" +
      "Safety: writes to the Notes database through unsupported private API. Needs the paragraph's `blockIndex` and exact `text` (as expectedText) from list-note-paragraphs, and a fresh `revision` from native-note-state as ifRevision; refuses on any change (revision_conflict or paragraph_changed, committed: false). Only the paragraph style's identifier changes: a fresh read-back verifies the text, the paragraph's other attributes, every other paragraph's identifier, and that no other paragraph carries the new one. A timeout is indeterminate (indeterminate: true): read native-note-state before any retry. Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1, APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1, a built writer (setup --native-writer), and APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1 until live-validated.",
    {
      identifier: notesUuid.optional().describe("Notes UUID"),
      id: coreDataId.optional().describe("x-coredata note id; resolved to a UUID via the database"),
      blockIndex: z
        .number()
        .int()
        .min(0)
        .describe("The paragraph's `blockIndex` from list-note-paragraphs"),
      expectedText: z
        .string()
        .min(1)
        .max(50_000)
        .describe("The paragraph's `text` from list-note-paragraphs"),
      ifRevision: revisionToken.describe(
        "The `revision` returned by native-note-state for this note"
      ),
      paragraphId: notesUuid
        .optional()
        .describe("Optional UUID to assign; must not be in use in the note. Omit to mint one"),
      ...nudgeInput,
    },
    { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    async (args, deps) => {
      const identifier = resolveIdentifier(manager, args);
      const result = setParagraphId(
        {
          identifier,
          blockIndex: args.blockIndex,
          expectedText: args.expectedText,
          ifRevision: args.ifRevision,
          paragraphId: args.paragraphId,
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
