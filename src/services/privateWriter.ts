/**
 * Client for the opt-in native WRITE helper (a separate layer over #181/#204).
 *
 * The read-only helper in privateHelper.ts stays exactly as it is: its own
 * source, binary, manifest, action whitelist, and setup command. Writes live
 * in a second program, `native/private-helper/apple-notes-private-writer.m`,
 * built by `apple-notes-mcp setup --native-writer` into its own binary next
 * to its own checksum manifest. Nothing in the read-only path can reach it.
 *
 * This module owns the TypeScript side of the writer:
 *
 * - two switches, both required for ANY writer dispatch:
 *   `APPLE_NOTES_MCP_ENABLE_PRIVATE=1` (the existing private opt-in) and
 *   `APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES=1` (this layer's own gate). Write
 *   actions that have not passed live validation in a release also need
 *   `APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1` ({@link requireLiveValidated});
 * - refusing a missing, stale, or modified writer binary before EVERY
 *   dispatch, against `writer-manifest.json` (source and binary SHA-256);
 * - sending only actions listed in {@link WRITER_ACTIONS};
 * - reporting every write failure with `committed`: `false` (nothing was
 *   saved), `true` (saved, but read-back did not confirm it), or `"unknown"`
 *   (indeterminate: a timeout or an unreadable response after spawning).
 *
 * Each write action takes an `ifRevision` compare-and-swap token (the
 * `revision` from native-note-state or a feature's own read action), and the
 * writer re-reads the note through a brand-new Core Data stack before it
 * reports success. See TECHNICAL_NOTES.md "Private writer".
 *
 * @module services/privateWriter
 */
import { join } from "node:path";
import { z } from "zod";
import {
  ENABLE_ENV,
  PrivateHelperError,
  TIMEOUT_ENV,
  assertNoteIdentifier as assertReadIdentifier,
  defaultDeps,
  helperInstallDir,
  manifestSchema,
  noteStateSchema,
  packageRoot,
  privateHelperEnabled,
  sha256Hex,
  type PrivateHelperDeps,
  type PrivateHelperManifest,
  type PrivateNoteState,
  type PrivateUnavailableReason,
} from "./privateHelper.js";
import { UUID_PATTERN } from "../utils/noteIdentifiers.js";

export type { PrivateHelperDeps };

/** The only writer protocol version this client speaks. */
export const PRIVATE_WRITER_PROTOCOL = 1;
/** This layer's own switch. Required together with APPLE_NOTES_MCP_ENABLE_PRIVATE=1. */
export const WRITES_ENV = "APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES";
/** The repo's existing gate for native writes that have not passed live validation. */
export const ALLOW_UNVERIFIED_ENV = "APPLE_NOTES_MCP_ALLOW_UNVERIFIED";

export const WRITER_BINARY_NAME = "apple-notes-private-writer";
export const WRITER_SOURCE_RELATIVE = "native/private-helper/apple-notes-private-writer.m";
export const WRITER_MANIFEST_NAME = "writer-manifest.json";
export const WRITER_SETUP_COMMAND = "apple-notes-mcp setup --native-writer";
const DEFAULT_TIMEOUT_MS = 20_000;
const MAX_OUTPUT_BYTES = 8 * 1024 * 1024;

/**
 * Every action the writer binary offers, and whether it saves. Setup refuses
 * a writer whose action list differs from this table in either direction.
 * Read actions open the store with Core Data's read-only option.
 */
export const WRITER_ACTIONS: Readonly<Record<string, "read" | "write">> = {
  hello: "read",
  probe: "read",
  read_note_state: "read",
  append_plain_text: "write",
  read_sync_state: "read",
  plan_edit: "read",
  edit_note: "write",
  compose_note: "write",
  read_checklist: "read",
  set_checklist_item: "write",
  set_highlight: "write",
  add_url_card: "write",
  set_paragraph_id: "write",
};

/**
 * The plain-text append has not passed live end-to-end validation in a
 * released build. Until it has, it also requires APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1.
 */
export const APPEND_LIVE_VALIDATED = false;

/**
 * Applying an in-place edit (edit_note) has passed the copy-store
 * preservation checks but not a live validation that includes iCloud sync.
 * Planning (plan_edit) is read-only and needs no such gate.
 */
export const EDIT_LIVE_VALIDATED = false;

/** Same gate for structured compose (services/privateCompose.ts). */
export const COMPOSE_LIVE_VALIDATED = false;

/**
 * Checking or unchecking a checklist item has not passed live end-to-end
 * validation in a released build of the writer. Until it has, it also
 * requires APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1.
 */
export const CHECKLIST_TOGGLE_LIVE_VALIDATED = false;

/**
 * Highlighting has not passed live end-to-end validation in a released build
 * of the writer. Until it has, a write also requires
 * APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1. A dry run never writes and is not gated.
 */
export const HIGHLIGHT_LIVE_VALIDATED = false;

/**
 * URL link cards have not passed live end-to-end validation in a released
 * build of the writer. Until they have, a write also requires
 * APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1. A dry run never writes and is not gated.
 */
export const LINK_CARD_LIVE_VALIDATED = false;

/** Same gate for minting paragraph identifiers (native-set-paragraph-id). */
export const PARAGRAPH_IDS_LIVE_VALIDATED = false;

export type PrivateWriterUnavailableReason =
  PrivateUnavailableReason | "writes_disabled" | "not_live_validated";

export interface WriterInstallationReport {
  ready: boolean;
  reason: PrivateWriterUnavailableReason | null;
  detail: string | null;
  installDir: string;
  binaryPath: string;
  manifestPath: string;
  sourcePath: string;
  expectedSourceSha256: string | null;
  manifest: PrivateHelperManifest | null;
}

/** Machine dependencies with `sourcePath` pointing at the WRITER source. */
export function defaultWriterDeps(overrides: Partial<PrivateHelperDeps> = {}): PrivateHelperDeps {
  return defaultDeps({ sourcePath: join(packageRoot(), WRITER_SOURCE_RELATIVE), ...overrides });
}

/** Both switches: the private opt-in and this layer's write opt-in. */
export function privateWritesEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return privateHelperEnabled(env) && env[WRITES_ENV] === "1";
}

/**
 * Check the installed writer against the packaged writer source, before every
 * dispatch. Same rules as the read-only helper's check, against the writer's
 * own binary and manifest.
 */
export function inspectWriterInstallation(
  deps: PrivateHelperDeps = defaultWriterDeps()
): WriterInstallationReport {
  const installDir = helperInstallDir(deps.env);
  const binaryPath = join(installDir, WRITER_BINARY_NAME);
  const manifestPath = join(installDir, WRITER_MANIFEST_NAME);
  const base = {
    installDir,
    binaryPath,
    manifestPath,
    sourcePath: deps.sourcePath,
    expectedSourceSha256: null as string | null,
    manifest: null as PrivateHelperManifest | null,
  };
  const fail = (
    reason: PrivateWriterUnavailableReason,
    detail: string
  ): WriterInstallationReport => ({ ...base, ready: false, reason, detail });
  if (deps.platform !== "darwin") return fail("unsupported_platform", "macOS only");
  if (!deps.exists(deps.sourcePath))
    return fail("helper_not_installed", `Packaged writer source is missing: ${deps.sourcePath}`);
  base.expectedSourceSha256 = sha256Hex(deps.readFile(deps.sourcePath));
  if (!deps.exists(binaryPath) || !deps.exists(manifestPath))
    return fail(
      "helper_not_installed",
      `The private writer is not built. Run \`${WRITER_SETUP_COMMAND}\`.`
    );
  let manifest: PrivateHelperManifest;
  try {
    manifest = manifestSchema.parse(JSON.parse(deps.readFile(manifestPath).toString("utf8")));
  } catch (error) {
    return fail(
      "helper_manifest_invalid",
      `Unreadable writer manifest (${error instanceof Error ? error.message : String(error)}). ` +
        `Run \`${WRITER_SETUP_COMMAND}\`.`
    );
  }
  base.manifest = manifest;
  if (
    manifest.sourceSha256 !== base.expectedSourceSha256 ||
    manifest.protocolVersion !== PRIVATE_WRITER_PROTOCOL
  )
    return fail(
      "helper_stale",
      "The installed writer was built from a different writer source or protocol than this " +
        `apple-notes-mcp version ships. Run \`${WRITER_SETUP_COMMAND}\` again.`
    );
  if (sha256Hex(deps.readFile(binaryPath)) !== manifest.binarySha256)
    return fail(
      "helper_modified",
      "The writer binary does not match the checksum recorded when it was built. " +
        `Run \`${WRITER_SETUP_COMMAND}\` to rebuild it.`
    );
  return { ...base, ready: true, reason: null, detail: null };
}

/**
 * A writer failure. `committed` is set for write actions: true = the write
 * was saved, false = nothing was saved, "unknown" = indeterminate.
 */
export class PrivateWriteError extends PrivateHelperError {
  constructor(
    code: string,
    message: string,
    readonly committed?: boolean | "unknown",
    details: Record<string, unknown> = {}
  ) {
    super(code, message, details);
    this.name = "PrivateWriteError";
  }
}

const errorSchema = z
  .object({
    status: z.literal("error"),
    code: z.string(),
    message: z.string(),
    committed: z.boolean().optional(),
  })
  .passthrough();

const featureSchema = z.object({
  available: z.boolean(),
  reason: z.string().nullable(),
  missing: z.array(z.string()),
});

export const writerHelloSchema = z
  .object({
    status: z.literal("ok"),
    protocolVersion: z.number().int(),
    sourceSha256: z.string(),
    role: z.literal("writer"),
    readOnly: z.literal(false),
    actions: z.array(z.string()),
  })
  .passthrough();

export const writerProbeSchema = z
  .object({
    status: z.literal("ok"),
    protocolVersion: z.number().int(),
    role: z.literal("writer"),
    readOnly: z.literal(false),
    writesEnabled: z.boolean(),
    os: z.object({ version: z.string(), notesAppVersion: z.string().nullable() }).passthrough(),
    framework: z.object({ loaded: z.boolean(), error: z.string().nullable() }).passthrough(),
    store: z
      .object({
        kind: z.enum(["live", "copy"]).nullable(),
        opened: z.boolean(),
        reason: z.string().nullable(),
        noteRows: z.number().int().nullable(),
      })
      .passthrough(),
    syncHostRunning: z.boolean(),
    features: z
      .object({
        readNoteState: featureSchema,
        appendPlainText: featureSchema,
        // Optional so a probe without a feature reports it as unavailable
        // instead of failing the whole status call.
        planEdit: featureSchema.optional(),
        editNote: featureSchema.optional(),
        composeNote: featureSchema.optional(),
        composeObjects: featureSchema.optional(),
        checklistToggle: featureSchema.optional(),
        highlight: featureSchema.optional(),
        linkCard: featureSchema.optional(),
        setParagraphId: featureSchema.optional(),
      })
      .passthrough(),
  })
  .passthrough();
export type PrivateWriterProbe = z.infer<typeof writerProbeSchema>;

export const cloudSyncSchema = z
  .object({
    available: z.boolean(),
    inICloudAccount: z.boolean(),
    currentLocalVersion: z.number().int().optional(),
    latestVersionSyncedToCloud: z.number().int().optional(),
    uploadPending: z.boolean().optional(),
  })
  .passthrough();

/** The fields every write result reports about sync, whatever the action. */
export const writeSyncFields = {
  cloudSync: cloudSyncSchema,
  pushScheduled: z.boolean(),
  pushState: z.enum(["awaiting_notes_app", "queued_for_next_launch"]),
  syncHostRunning: z.boolean(),
  storeKind: z.enum(["live", "copy"]),
};

export const appendResultSchema = z
  .object({
    status: z.literal("updated"),
    committed: z.literal(true),
    verified: z.literal(true),
    identifier: z.string(),
    appendedUTF16: z.number().int(),
    revisionBefore: z.string(),
    revisionAfter: z.string(),
    modificationDate: z.string().nullable(),
    ...writeSyncFields,
  })
  .passthrough();
export type PrivateAppendResult = z.infer<typeof appendResultSchema>;

export interface WriterCallOptions {
  /** Skip the opt-in checks. Only `hello` during setup uses this. */
  allowDisabled?: boolean;
  /** Run a specific binary without the installation check (setup verification only). */
  binaryPath?: string;
}

/**
 * Send one request to the writer and return its parsed JSON object. Throws
 * PrivateWriteError for every failure, with `committed` set for writes.
 */
export function callPrivateWriter(
  action: string,
  fields: Record<string, unknown> = {},
  deps: PrivateHelperDeps = defaultWriterDeps(),
  options: WriterCallOptions = {}
): Record<string, unknown> {
  const kind = WRITER_ACTIONS[action];
  if (!kind)
    throw new PrivateWriteError(
      "unknown_action",
      `"${action}" is not a private writer action.`,
      undefined
    );
  const isWrite = kind === "write";
  const notCommitted = isWrite ? false : undefined;
  if (!options.allowDisabled) {
    if (!privateHelperEnabled(deps.env))
      throw new PrivateWriteError(
        "disabled",
        `The private helper is off. Set ${ENABLE_ENV}=1 and ${WRITES_ENV}=1 to opt in to private writes.`,
        notCommitted
      );
    if (!privateWritesEnabled(deps.env))
      throw new PrivateWriteError(
        "writes_disabled",
        `Private writes are off. Set ${WRITES_ENV}=1 (with ${ENABLE_ENV}=1) to opt in.`,
        notCommitted
      );
  }
  let binaryPath = options.binaryPath;
  if (!binaryPath) {
    const install = inspectWriterInstallation(deps);
    if (!install.ready)
      throw new PrivateWriteError(
        install.reason || "helper_not_installed",
        install.detail || "",
        notCommitted
      );
    binaryPath = install.binaryPath;
  }
  const timeout = Number.parseInt(deps.env[TIMEOUT_ENV] || "", 10) || DEFAULT_TIMEOUT_MS;
  const result = deps.spawn(binaryPath, [], {
    input: JSON.stringify({ protocol: PRIVATE_WRITER_PROTOCOL, action, ...fields }),
    encoding: "utf8",
    timeout,
    killSignal: "SIGKILL",
    maxBuffer: MAX_OUTPUT_BYTES,
    env: deps.env,
  });
  const errno = (result.error as NodeJS.ErrnoException | undefined)?.code;
  if (errno === "ETIMEDOUT" || (result.signal && result.status === null))
    throw new PrivateWriteError(
      "timeout",
      isWrite
        ? `The writer did not answer within ${timeout} ms. The write is INDETERMINATE: it may ` +
            "have been saved. Read the note state again before retrying."
        : `The writer did not answer within ${timeout} ms.`,
      isWrite ? "unknown" : undefined
    );
  if (result.error)
    throw new PrivateWriteError(
      "helper_unreachable",
      `Could not run the writer: ${result.error.message}`,
      notCommitted
    );
  const stdout = String(result.stdout ?? "").trim();
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new PrivateWriteError(
      "invalid_response",
      `The writer exited with status ${result.status} and no JSON response` +
        (isWrite ? ". The write is INDETERMINATE; read the note state before retrying." : "."),
      isWrite ? "unknown" : undefined
    );
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    throw new PrivateWriteError(
      "invalid_response",
      "The writer response is not a JSON object",
      isWrite ? "unknown" : undefined
    );
  const object = parsed as Record<string, unknown>;
  if (result.status !== 0 || object.status === "error") {
    const error = errorSchema.safeParse(object);
    if (!error.success)
      throw new PrivateWriteError(
        "invalid_response",
        `The writer failed with an unrecognized error shape (exit ${result.status})`,
        isWrite ? "unknown" : undefined
      );
    const { status: _status, code, message, committed, ...details } = error.data;
    void _status;
    throw new PrivateWriteError(
      code,
      message,
      isWrite ? (committed ?? "unknown") : undefined,
      details
    );
  }
  return object;
}

/**
 * Validate a writer response. A malformed success response after a write
 * still means the writer reported success, so it is indeterminate, not failed.
 */
export function parseWriterResult<T>(schema: z.ZodType<T>, value: unknown, isWrite: boolean): T {
  const parsed = schema.safeParse(value);
  if (!parsed.success)
    throw new PrivateWriteError(
      "invalid_response",
      `Unexpected writer response: ${parsed.error.issues.map((i) => i.path.join(".") + " " + i.message).join("; ")}`,
      isWrite ? "unknown" : undefined
    );
  return parsed.data;
}

/**
 * The per-feature live-validation gate: a write that has not passed live
 * end-to-end validation in a release also needs APPLE_NOTES_MCP_ALLOW_UNVERIFIED=1.
 */
export function requireLiveValidated(
  validated: boolean,
  toolName: string,
  env: NodeJS.ProcessEnv
): void {
  if (!validated && env[ALLOW_UNVERIFIED_ENV] !== "1")
    throw new PrivateWriteError(
      "not_live_validated",
      `${toolName} has not passed live validation in this build. ` +
        `Set ${ALLOW_UNVERIFIED_ENV}=1 to run it on a disposable note.`,
      false
    );
}

/** A Notes UUID; a refusal here never reaches the writer, so nothing was committed. */
export function assertNoteIdentifier(identifier: string): void {
  try {
    assertReadIdentifier(identifier);
  } catch (error) {
    throw new PrivateWriteError(
      "invalid_request",
      error instanceof Error ? error.message : String(error),
      false
    );
  }
}

/** A revision token from native-note-state or a feature's own read action. */
export function assertRevision(ifRevision: string, source = "native-note-state"): void {
  if (!/^r1:[a-f0-9]{64}$/.test(ifRevision))
    throw new PrivateWriteError(
      "invalid_request",
      `ifRevision must be a revision token from ${source}`,
      false
    );
}

/**
 * Control characters other than tab and newline, the object replacement
 * character Notes uses as an attachment glyph (U+FFFC), and the Unicode line
 * and paragraph separators (U+2028, U+2029). Written as escapes so no
 * invisible character lives in the source.
 */
// eslint-disable-next-line no-control-regex
const FORBIDDEN_TEXT = /[\x00-\x08\x0B-\x1F\x7F-\x9F\uFFFC\u2028\u2029]/u;

/** Mirror of the writer's text rules, checked before spawning. */
export function assertAppendText(text: string): void {
  if (!text.length) throw new PrivateWriteError("invalid_request", "text is required", false);
  if (text.length > 50_000)
    throw new PrivateWriteError("invalid_request", "text exceeds 50000 UTF-16 code units", false);
  if (FORBIDDEN_TEXT.test(text))
    throw new PrivateWriteError(
      "invalid_request",
      "text may contain only printable characters, tabs and \\n newlines",
      false
    );
}

/** One note's native state and `revision`, read by the writer with the store opened read-only. */
export function readWriterNoteState(
  identifier: string,
  deps: PrivateHelperDeps = defaultWriterDeps()
): PrivateNoteState {
  assertNoteIdentifier(identifier);
  return parseWriterResult(
    noteStateSchema,
    callPrivateWriter("read_note_state", { identifier }, deps),
    false
  );
}

export function probePrivateWriter(
  deps: PrivateHelperDeps = defaultWriterDeps()
): PrivateWriterProbe {
  return parseWriterResult(writerProbeSchema, callPrivateWriter("probe", {}, deps), false);
}

/** Append plain text paragraphs, guarded by `ifRevision` and verified by read-back. */
export function appendPlainText(
  request: { identifier: string; text: string; ifRevision: string },
  deps: PrivateHelperDeps = defaultWriterDeps()
): PrivateAppendResult {
  assertNoteIdentifier(request.identifier);
  assertAppendText(request.text);
  assertRevision(request.ifRevision);
  requireLiveValidated(APPEND_LIVE_VALIDATED, "native-append-plain-text", deps.env);
  return parseWriterResult(
    appendResultSchema,
    callPrivateWriter("append_plain_text", request, deps),
    true
  );
}

// ---------------------------------------------------------------------------
// In-place edit (plan_edit, edit_note)
// ---------------------------------------------------------------------------

export const MAX_EDIT_OPERATIONS = 64;
const MAX_EDIT_TEXT = 10_000;

/**
 * Text that must stay inside one paragraph: no control characters other
 * than tab, no attachment glyph (U+FFFC), and no line or paragraph
 * separators. Mirrors the writer's rule so a bad request never spawns it.
 */
// eslint-disable-next-line no-control-regex
const FORBIDDEN_EDIT_TEXT = /[\x00-\x08\x0A-\x1F\x7F-\x9F\uFFFC\u2028\u2029]/u;
const paragraphText = (min: number) =>
  z
    .string()
    .min(min)
    .max(MAX_EDIT_TEXT)
    .refine((text) => !FORBIDDEN_EDIT_TEXT.test(text), {
      message:
        "must stay inside one paragraph: no line breaks, attachment glyphs, or control characters",
    });

export const EDIT_STYLES = [
  "title",
  "heading",
  "subheading",
  "body",
  "monospaced",
  "bulleted",
  "dashed",
  "numbered",
  "checklist",
] as const;
const styleName = z.enum(EDIT_STYLES);
const count = z.number().int().min(1).max(1000);
const operationId = z.string().min(1).max(128).optional();

const runSchema = z
  .object({
    text: paragraphText(1),
    bold: z.boolean().optional(),
    italic: z.boolean().optional(),
    underline: z.boolean().optional(),
    strikethrough: z.boolean().optional(),
  })
  .strict();
const runsSchema = z.array(runSchema).min(1).max(200);

/** Plain `text` inherits the replaced range's formatting; `runs` states it. */
const replacementSchema = z.union([
  z.object({ text: paragraphText(0) }).strict(),
  z.object({ runs: runsSchema }).strict(),
]);

/**
 * Selectors are keyed by `kind` so a later kind is one more union member here
 * and one more branch in the writer's ResolveSelector().
 */
const textSelector = z
  .object({
    kind: z.literal("text").optional(),
    text: paragraphText(1),
    scope: z.enum(["body", "title", "all"]).optional(),
    occurrence: count.optional(),
  })
  .strict();
const styleSelector = z
  .object({ kind: z.literal("style"), style: styleName, occurrence: count.optional() })
  .strict();
const blankSelector = z
  .object({
    kind: z.literal("blank"),
    style: styleName.exclude(["title", "body"]),
    occurrence: count.optional(),
  })
  .strict();

/** An attachment's x-coredata id, as list-attachments and get-note-structure return it. */
const attachmentCoreDataId = z.string().regex(/^x-coredata:\/\/[0-9A-F-]+\/ICAttachment\/p\d+$/i);

/**
 * One of the note's attachments (not an inline object such as a hashtag or
 * note link), named by exactly one of `identifier` (its Notes UUID), `id`
 * (its x-coredata id), or `ordinal` (1-based, in body order). It is the only
 * selector whose target may contain an attachment glyph, and then only the
 * glyph of the attachment it names. In a replace, `position` "self" (default)
 * replaces the glyph (empty text removes the attachment from the body), and
 * "before"/"after" insert the replacement text inline beside it. In
 * delete_paragraph it names the attachment's own paragraph, which must hold
 * nothing else; as an insert anchor, the paragraph holding it.
 */
const attachmentSelectorFields = {
  kind: z.literal("attachment"),
  identifier: z.string().regex(UUID_PATTERN).optional(),
  id: attachmentCoreDataId.optional(),
  ordinal: count.optional(),
  occurrence: count.optional(),
};
const oneAttachment = <T extends { identifier?: string; id?: string; ordinal?: number }>(s: T) =>
  [s.identifier, s.id, s.ordinal].filter((v) => v !== undefined).length === 1;
const oneAttachmentMessage = {
  message: "an attachment selector needs exactly one of identifier, id, or ordinal",
};
const attachmentSelector = z
  .object(attachmentSelectorFields)
  .strict()
  .refine(oneAttachment, oneAttachmentMessage);
const attachmentReplaceSelector = z
  .object({ ...attachmentSelectorFields, position: z.enum(["self", "before", "after"]).optional() })
  .strict()
  .refine(oneAttachment, oneAttachmentMessage);

const blockSchema = z
  .object({
    type: styleName.exclude(["title"]),
    text: paragraphText(0).optional(),
    runs: runsSchema.optional(),
    checked: z.boolean().optional(),
  })
  .strict()
  .refine((b) => (b.text === undefined) !== (b.runs === undefined), {
    message: "each block needs exactly one of text or runs",
  })
  .refine((b) => b.checked === undefined || b.type === "checklist", {
    message: "checked is only valid on checklist blocks",
  });

const insertSchema = (op: "insert_after" | "insert_before") =>
  z
    .object({
      op: z.literal(op),
      id: operationId,
      anchor: z.union([textSelector, styleSelector, attachmentSelector]),
      blocks: z.array(blockSchema).min(1).max(200),
      expectedCount: count.optional(),
    })
    .strict();

export const MAX_TRIM_KEEP = 10;

/**
 * Removes redundant empty paragraphs, each with its own newline, so no
 * non-empty paragraph loses a character, its terminator, or its style. An
 * empty paragraph is one with only whitespace, no attachment or inline
 * object, and a text style (title, heading, subheading, body); empty list,
 * checklist, and monospaced rows are never trimmed, and the title paragraph
 * never is. mode "runs" keeps the first `keep` (default 1) of every run,
 * "end" trims the run that ends the note (keep default 0), and "around"
 * trims the runs directly before and/or after (`side`) the one paragraph
 * `anchor` names (keep default 0). `expectedCount`, when given, must equal
 * the number of paragraphs removed.
 */
const trimSchema = z
  .object({
    op: z.literal("trim_blank_lines"),
    id: operationId,
    mode: z.enum(["runs", "end", "around"]),
    keep: z.number().int().min(0).max(MAX_TRIM_KEEP).optional(),
    anchor: z.union([textSelector, styleSelector]).optional(),
    side: z.enum(["before", "after", "both"]).optional(),
    expectedCount: count.optional(),
  })
  .strict();

const editOperationUnion = z.discriminatedUnion("op", [
  z
    .object({
      op: z.literal("replace"),
      id: operationId,
      selector: z.union([
        textSelector.extend({ match: z.enum(["substring", "equals"]).optional() }).strict(),
        attachmentReplaceSelector,
      ]),
      replacement: replacementSchema,
      expectedCount: count.optional(),
    })
    .strict(),
  z
    .object({
      op: z.literal("delete_paragraph"),
      id: operationId,
      selector: z.union([textSelector, blankSelector, attachmentSelector]),
      expectedCount: count.optional(),
    })
    .strict(),
  insertSchema("insert_after"),
  insertSchema("insert_before"),
  z
    .object({
      op: z.literal("set_title"),
      id: operationId,
      replacement: z.union([
        z.object({ text: paragraphText(1) }).strict(),
        z.object({ runs: runsSchema }).strict(),
      ]),
    })
    .strict(),
  trimSchema,
]);

/** The operation union plus the one cross-field rule a union member cannot carry. */
export const editOperationSchema = editOperationUnion.superRefine((operation, context) => {
  if (operation.op !== "trim_blank_lines") return;
  const around = operation.mode === "around";
  if (around && !operation.anchor)
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["anchor"],
      message: "mode around needs an anchor",
    });
  if (!around && (operation.anchor || operation.side))
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: [operation.anchor ? "anchor" : "side"],
      message: "anchor and side are only valid with mode around",
    });
});
export type EditOperation = z.infer<typeof editOperationSchema>;

const editTargetSchema = z
  .object({
    paragraphIndex: z.number().int(),
    paragraphStyle: z.string(),
    location: z.number().int(),
    length: z.number().int(),
    newLength: z.number().int(),
    /** For a trimmed empty paragraph: how many whitespace characters it held. */
    blankUTF16: z.number().int().optional(),
  })
  .passthrough();

const editPlanFields = {
  identifier: z.string(),
  revisionBefore: z.string().regex(/^r1:[a-f0-9]{64}$/),
  planDigest: z.string(),
  operationCount: z.number().int(),
  targetCount: z.number().int(),
  operations: z.array(
    z
      .object({
        index: z.number().int(),
        op: z.string(),
        matchedCount: z.number().int(),
        targets: z.array(editTargetSchema),
      })
      .passthrough()
  ),
  lengthBefore: z.number().int(),
  lengthAfter: z.number().int(),
  unchangedUTF16: z.number().int(),
  wouldChange: z.boolean(),
  titleChanged: z.boolean(),
  attachmentGlyphs: z.number().int(),
  /** Glyphs left in the planned text. */
  attachmentGlyphsAfter: z.number().int().optional(),
  /** Identifiers of attachments the plan removes from the body (attachment selectors only). */
  removedAttachments: z.array(z.string()).optional(),
  storeKind: z.enum(["live", "copy"]),
};

export const editPlanSchema = z
  .object({
    status: z.literal("planned"),
    dryRun: z.literal(true),
    committed: z.literal(false),
    ...editPlanFields,
  })
  .passthrough();

/** What the writer's fresh read-back proved about everything outside the edits. */
const preservationSchema = z
  .object({
    unchangedUTF16: z.number().int(),
    formattingOutsideEditsVerified: z.literal(true),
    attachmentGlyphs: z.number().int(),
    attachmentGlyphSequenceVerified: z.literal(true),
    attachmentRows: z.number().int(),
    attachmentRowsVerified: z.literal(true),
    /** Attachment rows other than a removed one, proven present with the same stored values. */
    otherAttachmentRowsUnchanged: z.number().int().optional(),
    /** What became of each removed attachment's row (Notes may keep it or mark it for deletion). */
    removedAttachments: z
      .array(
        z
          .object({
            identifier: z.string(),
            rowStillInNote: z.boolean(),
            markedForDeletion: z.boolean().nullable(),
          })
          .passthrough()
      )
      .optional(),
  })
  .passthrough();

export const editResultSchema = z.union([
  z
    .object({
      status: z.literal("updated"),
      dryRun: z.literal(false),
      committed: z.literal(true),
      verified: z.literal(true),
      revisionAfter: z.string(),
      modificationDate: z.string().nullable(),
      preservation: preservationSchema,
      ...writeSyncFields,
      ...editPlanFields,
    })
    .passthrough(),
  z
    .object({
      status: z.literal("unchanged"),
      dryRun: z.literal(false),
      committed: z.literal(false),
      revisionAfter: z.string(),
      ...editPlanFields,
    })
    .passthrough(),
]);
export type PrivateEditPlan = z.infer<typeof editPlanSchema>;
export type PrivateEditResult = z.infer<typeof editResultSchema>;

export interface EditNoteRequest {
  identifier: string;
  operations: EditOperation[];
  /** true: plan only (plan_edit, read-only). false: apply (edit_note). */
  dryRun: boolean;
  /** Required to apply: the plan's revisionBefore. */
  ifRevision?: string;
  requireNonSystemPaper?: boolean;
}

/**
 * Plan (dryRun: true, the writer's read-only plan_edit) or apply
 * (dryRun: false, edit_note, with the plan's revisionBefore as ifRevision)
 * literal in-place edits to one note.
 */
export function editNote(
  request: EditNoteRequest,
  deps: PrivateHelperDeps = defaultWriterDeps()
): PrivateEditPlan | PrivateEditResult {
  const notCommitted = request.dryRun ? undefined : false;
  const refuse = (message: string) =>
    new PrivateWriteError("invalid_request", message, notCommitted);
  try {
    assertReadIdentifier(request.identifier);
  } catch (error) {
    throw refuse(error instanceof Error ? error.message : String(error));
  }
  if (!request.operations.length || request.operations.length > MAX_EDIT_OPERATIONS)
    throw refuse(`operations must hold 1 to ${MAX_EDIT_OPERATIONS} entries`);
  const operations = z.array(editOperationSchema).safeParse(request.operations);
  if (!operations.success)
    throw refuse(
      `Invalid operations: ${operations.error.issues.map((i) => i.path.join(".") + " " + i.message).join("; ")}`
    );
  const fields: Record<string, unknown> = {
    identifier: request.identifier,
    operations: operations.data,
  };
  if (request.requireNonSystemPaper !== undefined)
    fields.requireNonSystemPaper = request.requireNonSystemPaper;
  if (request.dryRun) {
    return parseWriterResult(editPlanSchema, callPrivateWriter("plan_edit", fields, deps), false);
  }
  if (!request.ifRevision)
    throw refuse(
      "Applying an edit requires ifRevision: run the identical request with dryRun: true first " +
        "and pass its revisionBefore."
    );
  assertRevision(request.ifRevision, "a dry run's revisionBefore");
  requireLiveValidated(EDIT_LIVE_VALIDATED, "native-edit-note", deps.env);
  return parseWriterResult(
    editResultSchema,
    callPrivateWriter("edit_note", { ...fields, ifRevision: request.ifRevision }, deps),
    true
  );
}

export interface PrivateWriterFeatureStatus {
  available: boolean;
  reason: PrivateWriterUnavailableReason | null;
  detail: string | null;
}

/**
 * One row per writer feature: its key in `features`, the probe's key for it,
 * and whether it has passed live validation (read-only features have nothing
 * to validate). A branch adding a feature adds one row.
 */
export const WRITER_FEATURES = [
  { key: "appendPlainText", probeKey: "appendPlainText", liveValidated: APPEND_LIVE_VALIDATED },
  { key: "planEdit", probeKey: "planEdit", liveValidated: true },
  { key: "editNote", probeKey: "editNote", liveValidated: EDIT_LIVE_VALIDATED },
  { key: "composeNote", probeKey: "composeNote", liveValidated: COMPOSE_LIVE_VALIDATED },
  { key: "composeObjects", probeKey: "composeObjects", liveValidated: COMPOSE_LIVE_VALIDATED },
  {
    key: "checklistToggle",
    probeKey: "checklistToggle",
    liveValidated: CHECKLIST_TOGGLE_LIVE_VALIDATED,
  },
  { key: "highlight", probeKey: "highlight", liveValidated: HIGHLIGHT_LIVE_VALIDATED },
  { key: "linkCard", probeKey: "linkCard", liveValidated: LINK_CARD_LIVE_VALIDATED },
  {
    key: "setParagraphId",
    probeKey: "setParagraphId",
    liveValidated: PARAGRAPH_IDS_LIVE_VALIDATED,
  },
] as const;
export type WriterFeatureKey = (typeof WRITER_FEATURES)[number]["key"];

export interface PrivateWriterCapabilities {
  enabled: boolean;
  writesEnabled: boolean;
  installation: WriterInstallationReport;
  probe: PrivateWriterProbe | null;
  features: Record<WriterFeatureKey, PrivateWriterFeatureStatus>;
}

/** Never throws. Runs the live probe only when both switches are on and the writer is installed. */
export function privateWriterCapabilities(
  deps: PrivateHelperDeps = defaultWriterDeps()
): PrivateWriterCapabilities {
  const enabled = privateHelperEnabled(deps.env);
  const writesEnabled = privateWritesEnabled(deps.env);
  const installation = inspectWriterInstallation(deps);
  const base = { enabled, writesEnabled, installation, probe: null };
  const every = (
    status: (row: (typeof WRITER_FEATURES)[number]) => PrivateWriterFeatureStatus
  ): Record<WriterFeatureKey, PrivateWriterFeatureStatus> =>
    Object.fromEntries(WRITER_FEATURES.map((row) => [row.key, status(row)])) as Record<
      WriterFeatureKey,
      PrivateWriterFeatureStatus
    >;
  const off = (
    reason: PrivateWriterUnavailableReason,
    detail: string | null
  ): PrivateWriterCapabilities => ({
    ...base,
    features: every(() => ({ available: false, reason, detail })),
  });
  if (installation.reason === "unsupported_platform") return off("unsupported_platform", null);
  if (!enabled) return off("disabled", `Set ${ENABLE_ENV}=1 and ${WRITES_ENV}=1 to opt in.`);
  if (!writesEnabled) return off("writes_disabled", `Set ${WRITES_ENV}=1 to opt in to writes.`);
  if (!installation.ready)
    return off(installation.reason || "helper_not_installed", installation.detail);
  let probe: PrivateWriterProbe;
  try {
    probe = probePrivateWriter(deps);
  } catch (error) {
    return off("helper_unreachable", error instanceof Error ? error.message : String(error));
  }
  const probed = probe.features as Record<string, z.infer<typeof featureSchema> | undefined>;
  const features = every((row): PrivateWriterFeatureStatus => {
    const feature = probed[row.probeKey];
    if (!feature)
      return {
        available: false,
        reason: "private_api_unavailable",
        detail: `The installed writer does not report ${row.probeKey}`,
      };
    if (!feature.available) {
      const reason =
        feature.reason === "store_unavailable" || feature.reason === "disabled"
          ? (feature.reason as PrivateWriterUnavailableReason)
          : "private_api_unavailable";
      return {
        available: false,
        reason,
        detail: feature.missing.length ? `missing: ${feature.missing.join(", ")}` : feature.reason,
      };
    }
    if (!row.liveValidated && deps.env[ALLOW_UNVERIFIED_ENV] !== "1")
      return {
        available: false,
        reason: "not_live_validated",
        detail: `Not yet live-validated; ${ALLOW_UNVERIFIED_ENV}=1 enables it for testing.`,
      };
    return { available: true, reason: null, detail: null };
  });
  return { ...base, probe, features };
}
