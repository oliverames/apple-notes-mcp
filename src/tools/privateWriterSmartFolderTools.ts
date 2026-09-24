/**
 * MCP tools for smart folders through the opt-in private WRITER (#181).
 *
 * `list-smart-folders` (read-only, upstream) finds smart folders and decodes
 * their rules. These tools add:
 *
 * - `native-read-smart-folder`: one smart folder's writer state and `f1:`
 *   revision, the token the update and delete need.
 * - `native-create-smart-folder`: idempotent create.
 * - `native-update-smart-folder`: replace one smart folder's query.
 * - `native-delete-smart-folder`: dry-run plan, then an apply bound to the
 *   plan's revision. Empty smart folders only.
 *
 * All four share the writer envelope from privateWriterTools.ts. None offers
 * the sync nudge: it moves notes in place, and a folder has no equivalent.
 *
 * @module tools/privateWriterSmartFolderTools
 */
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  FOLDER_REVISION,
  createSmartFolder,
  deleteSmartFolder,
  readSmartFolder,
  updateSmartFolder,
} from "../services/privateWriterSmartFolders.js";
import {
  defaultWriterToolDeps,
  notesUuid,
  registerWriterTool,
  type WriterToolDeps,
} from "./privateWriterTools.js";

const query = z
  .union([z.string(), z.record(z.string(), z.unknown())])
  .describe(
    'Smart-folder query: {"entity":"note","type":{...}} as an object or a JSON string (a rawQuery from list-smart-folders works). ' +
      'Clauses: {"and":[...]}, {"or":[...]}, {"not":{...}}; booleans checklist, checklistInProgress, ' +
      "checklistCompleted, attachment, pinned, systemPaper, passwordProtected, shared, mention, tagged; " +
      '{"attachmentSection":1-7}; {"tag":"display name"}; {"folder":"<folder identifier or x-coredata id>"}; ' +
      '{"creationDateRelativeRange"|"modificationDateRelativeRange":{"type":0-5} or {"type":6,"customAmount":n,"customUnit":0-4}}; ' +
      '{"creationDateRange"|"modificationDateRange":{"fromDate":s,"toDate":s}} (seconds since 2001-01-01 UTC); ' +
      '{"sharedParticipant"|"mentionParticipant":"<participant id>"}.'
  );
const smartFolderId = notesUuid.describe("Smart folder identifier (UUID) from list-smart-folders");
const ifRevision = z
  .string()
  .regex(FOLDER_REVISION)
  .describe("The folder `revision` from native-read-smart-folder or the dry run");

const GATE =
  "Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1, APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1, a built writer (setup --native-writer), and, until live-validated, APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1. The writer cannot upload; Notes.app uploads the folder (pushScheduled is always false; check cloudSync with native-read-smart-folder). There is no sync nudge for folders.";

export function registerPrivateWriterSmartFolderTools(
  server: McpServer,
  depsFactory: () => WriterToolDeps = defaultWriterToolDeps
) {
  registerWriterTool(
    server,
    depsFactory,
    "native-read-smart-folder",
    "Use when: you need one smart folder's `revision` before native-update-smart-folder or native-delete-smart-folder, or its writer-side state (canonical queryJSON, child and note counts, cloudSync).\n" +
      "Returns: identifier, title, accountIdentifier, parentIdentifier (null at an account root), queryJSON (canonical, sorted keys), decoded rules, childFolderCount, physicalNoteCount, `revision`, and cloudSync versions.\n" +
      "Do not use when: listing or finding smart folders (list-smart-folders returns every smart folder's identifier and rules).\n" +
      "Safety: read-only; the writer opens the store with Core Data's read-only option. Requires APPLE_NOTES_MCP_ENABLE_PRIVATE=1, APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1, and a built writer.",
    { identifier: smartFolderId },
    { readOnlyHint: true, openWorldHint: false },
    (args, deps) => ({ ...readSmartFolder(args.identifier, deps.writer) })
  );

  registerWriterTool(
    server,
    depsFactory,
    "native-create-smart-folder",
    "Use when: creating a Notes smart folder from a query, at an account root or inside an ordinary folder.\n" +
      "Returns: status created, or ok when an identical smart folder (same title, destination, and query) already exists and nothing was written; the stored queryJSON Notes regenerated, requestedQueryJSON, resolvedTags, filterCount, decoded rules, the folder identifier and revision, and sync state.\n" +
      "Do not use when: you want an ordinary folder (create-folder), to change an existing smart folder's query (native-update-smart-folder), or to put notes in it (its query decides membership).\n" +
      "Safety: writes to the Notes database through unsupported private API. Tag names must resolve to one existing tag in the destination account; folder filters must name ordinary folders there. The query goes through Notes' own parser, and one Notes cannot store without changing its meaning is refused (query_not_representable). A smart folder is never a parent (reason smart_folder_destination), nor Recently Deleted or a shared folder. A folder with the same title in the destination is refused (folder_exists) unless it is an identical smart folder. Verified by a fresh read-back. A timeout is indeterminate: read list-smart-folders before any retry. " +
      GATE,
    {
      title: z.string().min(1).max(256).describe("Exact smart-folder title"),
      query,
      account: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Account identifier or exact name for an account-root smart folder (default: Notes' default account)"
        ),
      parentIdentifier: z
        .string()
        .min(1)
        .optional()
        .describe("Ordinary folder (identifier or x-coredata folder id) to create it inside"),
    },
    { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    (args, deps) => ({ ...createSmartFolder(args, deps.writer) })
  );

  registerWriterTool(
    server,
    depsFactory,
    "native-update-smart-folder",
    "Use when: replacing the query (rules) of one existing smart folder.\n" +
      "Returns: status updated, or ok when the stored query already equals the request (nothing written); previousQueryJSON, the stored queryJSON, decoded rules, revisionBefore/revisionAfter, and sync state.\n" +
      "Do not use when: renaming the folder, creating one (native-create-smart-folder), or editing an ordinary folder.\n" +
      "Safety: writes through unsupported private API. Needs the folder `revision` from a fresh native-read-smart-folder as ifRevision and refuses on any change since (revision_conflict, committed: false). The query is validated exactly as in native-create-smart-folder. Verified by a fresh read-back. A timeout is indeterminate. " +
      GATE,
    { identifier: smartFolderId, query, ifRevision },
    { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    (args, deps) => ({ ...updateSmartFolder(args, deps.writer) })
  );

  registerWriterTool(
    server,
    depsFactory,
    "native-delete-smart-folder",
    "Use when: deleting one exact, empty smart folder. Two phases: dryRun: true, show the plan (title and rules) to the user, then apply with dryRun: false and the plan's `revision` as ifRevision.\n" +
      "Returns: dry run: status planned with the folder state and revision (nothing written). Apply: status deleted, committed, verified (fresh read-back of the tombstone), revisionBefore/revisionAfter, and sync state.\n" +
      "Do not use when: deleting an ordinary folder (delete-folder-by-id); this refuses anything that is not a smart folder.\n" +
      "Safety: marks the folder deleted through unsupported private API, the way Notes deletes one, so the deletion syncs. Refuses folders with child folders or with notes physically stored in them, and any change since the dry run (revision_conflict). A dry run needs only the two switches; the apply is also gated. " +
      GATE,
    {
      identifier: smartFolderId,
      dryRun: z.boolean().describe("true = plan only; false = apply the planned deletion"),
      ifRevision: ifRevision.optional(),
    },
    { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
    (args, deps) => ({ ...deleteSmartFolder(args, deps.writer) })
  );
}
