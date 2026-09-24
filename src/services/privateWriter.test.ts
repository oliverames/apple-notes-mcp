/**
 * Private writer client tests. A small Node script stands in for the native
 * writer binary, so these tests exercise the real spawn, timeout, checksum,
 * gating, and committed/indeterminate paths without NotesShared or the store.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  HELPER_BINARY_NAME,
  MANIFEST_NAME,
  READ_ONLY_ACTIONS,
  sha256Hex,
} from "./privateHelper.js";
import {
  APPEND_LIVE_VALIDATED,
  PRIVATE_WRITER_PROTOCOL,
  PrivateWriteError,
  WRITER_ACTIONS,
  WRITER_BINARY_NAME,
  WRITER_MANIFEST_NAME,
  WRITER_SOURCE_RELATIVE,
  appendPlainText,
  assertAppendText,
  assertRevision,
  callPrivateWriter,
  defaultWriterDeps,
  inspectWriterInstallation,
  parseWriterResult,
  privateWriterCapabilities,
  privateWritesEnabled,
  probePrivateWriter,
  requireLiveValidated,
  type PrivateHelperDeps,
} from "./privateWriter.js";
import { z } from "zod";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const REV = `r1:${"a".repeat(64)}`;
const SOURCE = "// fake writer source\n";

const FAKE_WRITER = `#!/usr/bin/env node
let input = "";
process.stdin.on("data", (c) => (input += c));
process.stdin.on("end", () => {
  const req = JSON.parse(input);
  const mode = process.env.FAKE_MODE || "ok";
  const out = (obj, code = 0) => { process.stdout.write(JSON.stringify(obj) + "\\n"); process.exit(code); };
  if (mode === "hang") { setTimeout(() => {}, 60000); return; }
  if (mode === "garbage") { process.stdout.write("not json"); process.exit(0); }
  if (mode === "array") out([1]);
  if (mode === "bad-error") out({ status: "error" }, 1);
  if (mode === "conflict") out({ status: "error", code: "revision_conflict", message: "changed", committed: false, currentRevision: "r1:" + "c".repeat(64) }, 1);
  if (mode === "verify-failed") out({ status: "error", code: "verification_failed", message: "mismatch", committed: true }, 1);
  if (mode === "no-committed") out({ status: "error", code: "save_failed", message: "?" }, 1);
  if (mode === "malformed") out({ status: "updated" });
  const feature = () => {
    if (mode === "missing-api") return { available: false, reason: "private_api_unavailable", missing: ["-[ICNote saveNoteData]"] };
    if (mode === "missing-api-empty") return { available: false, reason: "private_api_unavailable", missing: [] };
    if (mode === "no-store") return { available: false, reason: "store_unavailable", missing: [] };
    return { available: true, reason: null, missing: [] };
  };
  const cloudSync = { available: true, inICloudAccount: true, currentLocalVersion: 5, latestVersionSyncedToCloud: 4, uploadPending: true };
  switch (req.action) {
    case "hello":
      out({ status: "ok", protocolVersion: 1, sourceSha256: "dev", role: "writer", readOnly: false, actions: ["hello"] });
    case "probe":
      out({ status: "ok", protocolVersion: 1, role: "writer", readOnly: false, writesEnabled: process.env.APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES === "1", os: { version: "27.2.0", notesAppVersion: "4.13" }, framework: { loaded: true, error: null }, store: { kind: "live", opened: true, reason: null, noteRows: 3 }, syncHostRunning: true, features: process.env.FAKE_MODE === "old-probe" ? { readNoteState: feature(), appendPlainText: feature() } : { readNoteState: feature(), appendPlainText: feature(), smartFolders: feature() } });
    case "append_plain_text":
      out({ status: "updated", committed: true, verified: true, identifier: req.identifier, appendedUTF16: req.text.length, separatorInserted: false, revisionBefore: req.ifRevision, revisionAfter: "r1:" + "d".repeat(64), modificationDate: "2026-09-23T00:00:00.000Z", title: "t", cloudSync, pushScheduled: false, pushState: "awaiting_notes_app", syncHostRunning: true, storeKind: "live", echo: req });
    case "read_note_state":
      out({ status: "ok", identifier: req.identifier, echo: req });
    case "delete_smart_folder":
      out({ status: "planned", echo: req });
    default:
      out({ status: "error", code: "unknown_action", message: "no" }, 1);
  }
});
`;

let root: string;
let installDir: string;
let sourcePath: string;

function deps(env: Record<string, string> = {}): PrivateHelperDeps {
  return defaultWriterDeps({
    env: { PATH: process.env.PATH, APPLE_NOTES_MCP_PRIVATE_HELPER_DIR: installDir, ...env },
    platform: "darwin",
    sourcePath,
  });
}

function install(manifest: Record<string, unknown> = {}, binary = FAKE_WRITER) {
  mkdirSync(installDir, { recursive: true });
  writeFileSync(join(installDir, WRITER_BINARY_NAME), binary);
  chmodSync(join(installDir, WRITER_BINARY_NAME), 0o755);
  writeFileSync(
    join(installDir, WRITER_MANIFEST_NAME),
    JSON.stringify({
      schemaVersion: 1,
      protocolVersion: PRIVATE_WRITER_PROTOCOL,
      sourceSha256: sha256Hex(SOURCE),
      binarySha256: sha256Hex(FAKE_WRITER),
      builtAt: "2026-09-23T00:00:00.000Z",
      osVersion: "27.2",
      compiler: "clang",
      ...manifest,
    })
  );
}

const ON = {
  APPLE_NOTES_MCP_ENABLE_PRIVATE: "1",
  APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES: "1",
};
const UNVERIFIED = { ...ON, APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "1" };

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "private-writer-test-"));
  installDir = join(root, "install");
  sourcePath = join(root, "writer.m");
  writeFileSync(sourcePath, SOURCE);
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

function thrown(fn: () => unknown): PrivateWriteError {
  try {
    fn();
  } catch (error) {
    expect(error).toBeInstanceOf(PrivateWriteError);
    return error as PrivateWriteError;
  }
  throw new Error("expected a throw");
}

describe("layer separation", () => {
  it("uses its own source, binary, and manifest, distinct from the read-only helper", () => {
    expect(WRITER_BINARY_NAME).not.toBe(HELPER_BINARY_NAME);
    expect(WRITER_MANIFEST_NAME).not.toBe(MANIFEST_NAME);
    expect(defaultWriterDeps().sourcePath.endsWith(WRITER_SOURCE_RELATIVE)).toBe(true);
  });

  it("shares no write action with the read-only whitelist", () => {
    for (const [action, kind] of Object.entries(WRITER_ACTIONS))
      if (kind === "write") expect(READ_ONLY_ACTIONS.has(action)).toBe(false);
  });

  it("needs both switches", () => {
    expect(privateWritesEnabled({})).toBe(false);
    expect(privateWritesEnabled({ APPLE_NOTES_MCP_ENABLE_PRIVATE: "1" })).toBe(false);
    expect(privateWritesEnabled({ APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES: "1" })).toBe(false);
    expect(privateWritesEnabled(ON)).toBe(true);
  });
});

describe("inspectWriterInstallation", () => {
  it("reports unsupported off macOS", () => {
    expect(inspectWriterInstallation({ ...deps(), platform: "linux" }).reason).toBe(
      "unsupported_platform"
    );
  });

  it("reports a missing source, binary, or manifest", () => {
    expect(inspectWriterInstallation({ ...deps(), sourcePath: join(root, "nope.m") }).reason).toBe(
      "helper_not_installed"
    );
    const report = inspectWriterInstallation(deps());
    expect(report.reason).toBe("helper_not_installed");
    expect(report.detail).toMatch(/setup --native-writer/);
  });

  it("refuses an unreadable, stale, or modified install", () => {
    install();
    writeFileSync(join(installDir, WRITER_MANIFEST_NAME), "{");
    expect(inspectWriterInstallation(deps()).reason).toBe("helper_manifest_invalid");
    install({ sourceSha256: "0".repeat(64) });
    expect(inspectWriterInstallation(deps()).reason).toBe("helper_stale");
    install({ protocolVersion: 99 });
    expect(inspectWriterInstallation(deps()).reason).toBe("helper_stale");
    install({}, FAKE_WRITER + "// tampered\n");
    expect(inspectWriterInstallation(deps()).reason).toBe("helper_modified");
    install();
    expect(inspectWriterInstallation(deps())).toMatchObject({ ready: true, reason: null });
  });

  it("never reads the read-only helper's manifest", () => {
    mkdirSync(installDir, { recursive: true });
    writeFileSync(join(installDir, MANIFEST_NAME), "{}");
    writeFileSync(join(installDir, HELPER_BINARY_NAME), "x");
    expect(inspectWriterInstallation(deps()).reason).toBe("helper_not_installed");
  });
});

describe("callPrivateWriter", () => {
  beforeEach(() => install());

  it("refuses unknown actions before spawning", () => {
    const error = thrown(() => callPrivateWriter("drop_everything", {}, deps(ON)));
    expect(error.code).toBe("unknown_action");
  });

  it("refuses unless both switches are on, with committed false for writes", () => {
    const off = thrown(() => callPrivateWriter("append_plain_text", {}, deps()));
    expect(off).toMatchObject({ code: "disabled", committed: false });
    const readOnly = thrown(() =>
      callPrivateWriter("append_plain_text", {}, deps({ APPLE_NOTES_MCP_ENABLE_PRIVATE: "1" }))
    );
    expect(readOnly).toMatchObject({ code: "writes_disabled", committed: false });
    const read = thrown(() =>
      callPrivateWriter("read_note_state", {}, deps({ APPLE_NOTES_MCP_ENABLE_PRIVATE: "1" }))
    );
    expect(read).toMatchObject({ code: "writes_disabled", committed: undefined });
  });

  it("refuses when the install is not ready", () => {
    rmSync(join(installDir, WRITER_MANIFEST_NAME));
    expect(thrown(() => callPrivateWriter("append_plain_text", {}, deps(ON)))).toMatchObject({
      code: "helper_not_installed",
      committed: false,
    });
    expect(thrown(() => callPrivateWriter("probe", {}, deps(ON))).committed).toBeUndefined();
  });

  it("sends the protocol, action, and fields", () => {
    const out = callPrivateWriter("read_note_state", { identifier: NOTE }, deps(ON));
    expect(out.echo).toEqual({ protocol: 1, action: "read_note_state", identifier: NOTE });
  });

  it("allows hello with allowDisabled against an explicit binary", () => {
    const out = callPrivateWriter("hello", {}, deps(), {
      allowDisabled: true,
      binaryPath: join(installDir, WRITER_BINARY_NAME),
    });
    expect(out).toMatchObject({ role: "writer", readOnly: false });
  });

  it("marks a timed-out write indeterminate and a timed-out read not committed", () => {
    const env = { ...ON, FAKE_MODE: "hang", APPLE_NOTES_MCP_PRIVATE_HELPER_TIMEOUT_MS: "300" };
    const write = thrown(() => callPrivateWriter("append_plain_text", {}, deps(env)));
    expect(write).toMatchObject({ code: "timeout", committed: "unknown" });
    expect(write.message).toMatch(/INDETERMINATE/);
    const read = thrown(() => callPrivateWriter("probe", {}, deps(env)));
    expect(read).toMatchObject({ code: "timeout", committed: undefined });
  }, 20_000);

  it("treats a dry run of a write action as a read", () => {
    const env = { ...ON, FAKE_MODE: "hang", APPLE_NOTES_MCP_PRIVATE_HELPER_TIMEOUT_MS: "300" };
    const dry = thrown(() =>
      callPrivateWriter("delete_smart_folder", {}, deps(env), { dryRun: true })
    );
    expect(dry).toMatchObject({ code: "timeout", committed: undefined });
    const apply = thrown(() => callPrivateWriter("delete_smart_folder", {}, deps(env)));
    expect(apply).toMatchObject({ code: "timeout", committed: "unknown" });
    const off = thrown(() =>
      callPrivateWriter("delete_smart_folder", {}, deps({ APPLE_NOTES_MCP_ENABLE_PRIVATE: "1" }), {
        dryRun: true,
      })
    );
    expect(off).toMatchObject({ code: "writes_disabled", committed: undefined });
  }, 20_000);

  it("reports an unrunnable binary as not committed", () => {
    const error = thrown(() =>
      callPrivateWriter("append_plain_text", {}, deps(ON), {
        binaryPath: join(root, "missing-binary"),
      })
    );
    expect(error).toMatchObject({ code: "helper_unreachable", committed: false });
  });

  it("treats unparseable output after a write as indeterminate", () => {
    for (const mode of ["garbage", "array", "bad-error"]) {
      const write = thrown(() =>
        callPrivateWriter("append_plain_text", {}, deps({ ...ON, FAKE_MODE: mode }))
      );
      expect(write).toMatchObject({ code: "invalid_response", committed: "unknown" });
      const read = thrown(() => callPrivateWriter("probe", {}, deps({ ...ON, FAKE_MODE: mode })));
      expect(read).toMatchObject({ code: "invalid_response", committed: undefined });
    }
  });

  it("passes the writer's committed answer and details through", () => {
    const conflict = thrown(() =>
      callPrivateWriter("append_plain_text", {}, deps({ ...ON, FAKE_MODE: "conflict" }))
    );
    expect(conflict).toMatchObject({ code: "revision_conflict", committed: false });
    expect(conflict.details.currentRevision).toMatch(/^r1:c/);
    const verify = thrown(() =>
      callPrivateWriter("append_plain_text", {}, deps({ ...ON, FAKE_MODE: "verify-failed" }))
    );
    expect(verify).toMatchObject({ code: "verification_failed", committed: true });
    const unknown = thrown(() =>
      callPrivateWriter("append_plain_text", {}, deps({ ...ON, FAKE_MODE: "no-committed" }))
    );
    expect(unknown).toMatchObject({ code: "save_failed", committed: "unknown" });
    const read = thrown(() =>
      callPrivateWriter("read_note_state", {}, deps({ ...ON, FAKE_MODE: "conflict" }))
    );
    expect(read.committed).toBeUndefined();
  });
});

describe("validation helpers", () => {
  it("parseWriterResult marks a malformed write success indeterminate", () => {
    const schema = z.object({ status: z.literal("updated"), committed: z.literal(true) });
    expect(thrown(() => parseWriterResult(schema, { status: "updated" }, true)).committed).toBe(
      "unknown"
    );
    expect(
      thrown(() => parseWriterResult(schema, { status: "updated" }, false)).committed
    ).toBeUndefined();
    expect(parseWriterResult(schema, { status: "updated", committed: true }, true)).toEqual({
      status: "updated",
      committed: true,
    });
  });

  it("requireLiveValidated gates unvalidated writes on ALLOW_UNVERIFIED", () => {
    expect(thrown(() => requireLiveValidated(false, "x", {}))).toMatchObject({
      code: "not_live_validated",
      committed: false,
    });
    expect(() =>
      requireLiveValidated(false, "x", { APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "1" })
    ).not.toThrow();
    expect(() => requireLiveValidated(true, "x", {})).not.toThrow();
  });

  it("assertRevision and assertAppendText refuse bad input with committed false", () => {
    expect(thrown(() => assertRevision("r1:xyz")).code).toBe("invalid_request");
    expect(thrown(() => assertRevision("nope", "native-x")).message).toMatch(/native-x/);
    expect(() => assertRevision(REV)).not.toThrow();
    expect(thrown(() => assertAppendText("")).committed).toBe(false);
    expect(thrown(() => assertAppendText("x".repeat(50_001))).code).toBe("invalid_request");
    for (const bad of ["a\rb", "a\u0000", "a\uFFFCb", "a\u2028b", "a\u2029b", "a\u007fb"])
      expect(thrown(() => assertAppendText(bad)).code).toBe("invalid_request");
    expect(() => assertAppendText("line one\n\tline two")).not.toThrow();
  });
});

describe("appendPlainText", () => {
  beforeEach(() => install());

  it("is not live-validated, so it needs ALLOW_UNVERIFIED", () => {
    expect(APPEND_LIVE_VALIDATED).toBe(false);
    const error = thrown(() =>
      appendPlainText({ identifier: NOTE, text: "x", ifRevision: REV }, deps(ON))
    );
    expect(error).toMatchObject({ code: "not_live_validated", committed: false });
  });

  it("validates before spawning", () => {
    expect(
      thrown(() =>
        appendPlainText({ identifier: "nope", text: "x", ifRevision: REV }, deps(UNVERIFIED))
      ).code
    ).toBe("invalid_request");
    expect(
      thrown(() =>
        appendPlainText({ identifier: NOTE, text: "x", ifRevision: "r1:1" }, deps(UNVERIFIED))
      ).code
    ).toBe("invalid_request");
  });

  it("returns the verified result and sends exactly the guarded request", () => {
    const result = appendPlainText(
      { identifier: NOTE, text: "hello", ifRevision: REV },
      deps(UNVERIFIED)
    );
    expect(result).toMatchObject({ status: "updated", committed: true, verified: true });
    expect(result.revisionBefore).toBe(REV);
    expect((result as Record<string, unknown>).echo).toEqual({
      protocol: 1,
      action: "append_plain_text",
      identifier: NOTE,
      text: "hello",
      ifRevision: REV,
    });
  });

  it("treats a malformed success as indeterminate", () => {
    const error = thrown(() =>
      appendPlainText(
        { identifier: NOTE, text: "x", ifRevision: REV },
        deps({ ...UNVERIFIED, FAKE_MODE: "malformed" })
      )
    );
    expect(error).toMatchObject({ code: "invalid_response", committed: "unknown" });
  });
});

describe("privateWriterCapabilities", () => {
  it("reports each gate in order without throwing", () => {
    expect(
      privateWriterCapabilities({ ...deps(ON), platform: "linux" }).features.appendPlainText
    ).toMatchObject({ reason: "unsupported_platform" });
    expect(privateWriterCapabilities(deps()).features.appendPlainText.reason).toBe("disabled");
    expect(
      privateWriterCapabilities(deps({ APPLE_NOTES_MCP_ENABLE_PRIVATE: "1" })).features
        .appendPlainText.reason
    ).toBe("writes_disabled");
    expect(privateWriterCapabilities(deps(ON)).features.appendPlainText.reason).toBe(
      "helper_not_installed"
    );
  });

  it("probes an installed writer and applies the live-validation gate", () => {
    install();
    const gated = privateWriterCapabilities(deps(ON));
    expect(gated.probe?.writesEnabled).toBe(true);
    expect(gated.features.appendPlainText.reason).toBe("not_live_validated");
    expect(privateWriterCapabilities(deps(UNVERIFIED)).features.appendPlainText).toEqual({
      available: true,
      reason: null,
      detail: null,
    });
  });

  it("reports the smart-folder features, gating only the writes", () => {
    install();
    const gated = privateWriterCapabilities(deps(ON)).features;
    expect(gated.readSmartFolders).toEqual({ available: true, reason: null, detail: null });
    expect(gated.editSmartFolders.reason).toBe("not_live_validated");
    expect(privateWriterCapabilities(deps(UNVERIFIED)).features.editSmartFolders.available).toBe(
      true
    );
    const off = privateWriterCapabilities(deps()).features;
    expect(Object.values(off).every((f) => f.reason === "disabled")).toBe(true);
    const old = privateWriterCapabilities(deps({ ...UNVERIFIED, FAKE_MODE: "old-probe" }));
    expect(old.features.readSmartFolders).toMatchObject({
      available: false,
      reason: "private_api_unavailable",
    });
    expect(old.features.appendPlainText.available).toBe(true);
  });

  it("maps probe feature failures and unreachable writers", () => {
    install();
    expect(
      privateWriterCapabilities(deps({ ...ON, FAKE_MODE: "missing-api" })).features.appendPlainText
    ).toMatchObject({
      reason: "private_api_unavailable",
      detail: "missing: -[ICNote saveNoteData]",
    });
    expect(
      privateWriterCapabilities(deps({ ...ON, FAKE_MODE: "missing-api-empty" })).features
        .appendPlainText.detail
    ).toBe("private_api_unavailable");
    expect(
      privateWriterCapabilities(deps({ ...ON, FAKE_MODE: "no-store" })).features.appendPlainText
        .reason
    ).toBe("store_unavailable");
    expect(
      privateWriterCapabilities(deps({ ...ON, FAKE_MODE: "garbage" })).features.appendPlainText
        .reason
    ).toBe("helper_unreachable");
    expect(probePrivateWriter(deps(ON)).role).toBe("writer");
  });
});
