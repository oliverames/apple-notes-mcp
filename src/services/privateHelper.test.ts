/**
 * Private helper client tests. A small Node script stands in for the native
 * helper binary, so these tests exercise the real spawn, timeout, checksum,
 * and response-validation paths without NotesShared or the Notes store.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  APPEND_LIVE_VALIDATED,
  HELPER_BINARY_NAME,
  MANIFEST_NAME,
  PRIVATE_HELPER_PROTOCOL,
  PrivateHelperError,
  appendPlainText,
  assertAppendText,
  assertNoteIdentifier,
  callPrivateHelper,
  defaultDeps,
  helperInstallDir,
  inspectInstallation,
  packageRoot,
  privateHelperCapabilities,
  privateHelperEnabled,
  probePrivateHelper,
  readNoteState,
  sha256Hex,
  type PrivateHelperDeps,
} from "./privateHelper.js";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const REV = `r1:${"a".repeat(64)}`;

/**
 * Fake helper. Reads one JSON request and answers per FAKE_MODE, echoing the
 * request fields it received under `echo` so tests can assert the wire shape.
 */
const FAKE_HELPER = `#!/usr/bin/env node
let input = "";
process.stdin.on("data", (c) => (input += c));
process.stdin.on("end", () => {
  const req = JSON.parse(input);
  const mode = process.env.FAKE_MODE || "ok";
  const out = (obj, code = 0) => { process.stdout.write(JSON.stringify(obj) + "\\n"); process.exit(code); };
  if (mode === "hang") { setTimeout(() => {}, 60000); return; }
  if (mode === "garbage") { process.stdout.write("not json"); process.exit(0); }
  if (mode === "array") out([1, 2]);
  if (mode === "bad-error") out({ status: "error" }, 1);
  if (mode === "conflict") out({ status: "error", code: "revision_conflict", message: "changed", committed: false, currentRevision: "r1:x" }, 1);
  if (mode === "verify-failed") out({ status: "error", code: "verification_failed", message: "mismatch", committed: true }, 1);
  if (mode === "no-committed") out({ status: "error", code: "internal_error", message: "boom" }, 1);
  if (mode === "malformed") out({ status: "ok" });
  const feature = (name) => {
    if (mode === "missing-api") return { available: false, reason: "private_api_unavailable", missing: ["-[ICNote saveNoteData]"] };
    if (mode === "missing-api-empty") return { available: false, reason: "private_api_unavailable", missing: [] };
    if (mode === "no-store") return { available: false, reason: "store_unavailable", missing: [] };
    return { available: true, reason: null, missing: [] };
  };
  const cloudSync = { available: true, inICloudAccount: true, currentLocalVersion: 4, latestVersionSyncedToCloud: 1, uploadPending: true };
  switch (req.action) {
    case "hello":
      out({ status: "ok", protocolVersion: Number(process.env.FAKE_PROTOCOL || 1), sourceSha256: process.env.FAKE_SOURCE_SHA || "dev", actions: ["hello", "probe", "read_note_state", "append_plain_text"] });
    case "probe":
      out({ status: "ok", protocolVersion: 1, os: { version: "27.2.0", notesAppVersion: "4.13" }, framework: { loaded: true, error: null }, store: { kind: "live", opened: mode === "ok", reason: null, noteRows: 3 }, syncHostRunning: true, features: { readNoteState: feature("read"), appendPlainText: feature("append") } });
    case "read_note_state":
      out({ status: "ok", identifier: req.identifier, objectURI: "x-coredata://S/ICNote/p1", title: "t", modificationDate: "2026-09-23T00:00:00.000Z", folderIdentifier: "F", passwordProtected: false, deletedOrInTrash: false, sharedViaICloud: false, editable: true, revision: "r1:" + "b".repeat(64), cloudSync, syncHostRunning: true, echo: req });
    case "append_plain_text":
      out({ status: "updated", committed: true, verified: true, identifier: req.identifier, appendedUTF16: req.text.length + 1, revisionBefore: req.ifRevision, revisionAfter: "r1:" + "c".repeat(64), modificationDate: null, cloudSync, pushScheduled: false, pushState: "awaiting_notes_app", syncHostRunning: true, storeKind: "live", echo: req });
    default:
      out({ status: "error", code: "unknown_action", message: "no" }, 1);
  }
});
`;

interface Fixture {
  root: string;
  installDir: string;
  sourcePath: string;
  binaryPath: string;
  deps: (env?: Record<string, string>) => PrivateHelperDeps;
  install: (manifest?: Record<string, unknown>) => void;
}

function makeFixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), "private-helper-test-"));
  const installDir = join(root, "install");
  const sourcePath = join(root, "helper.m");
  writeFileSync(sourcePath, "// fake helper source\n");
  const binaryPath = join(installDir, HELPER_BINARY_NAME);
  const deps = (env: Record<string, string> = {}) =>
    defaultDeps({
      env: { PATH: process.env.PATH, APPLE_NOTES_MCP_PRIVATE_HELPER_DIR: installDir, ...env },
      platform: "darwin",
      sourcePath,
    });
  const install = (manifest: Record<string, unknown> = {}) => {
    mkdirSync(installDir, { recursive: true });
    writeFileSync(binaryPath, FAKE_HELPER);
    chmodSync(binaryPath, 0o755);
    writeFileSync(
      join(installDir, MANIFEST_NAME),
      JSON.stringify({
        schemaVersion: 1,
        protocolVersion: PRIVATE_HELPER_PROTOCOL,
        sourceSha256: sha256Hex("// fake helper source\n"),
        binarySha256: sha256Hex(FAKE_HELPER),
        builtAt: "2026-09-23T00:00:00.000Z",
        osVersion: "27.2",
        compiler: "clang",
        ...manifest,
      })
    );
  };
  return { root, installDir, sourcePath, binaryPath, deps, install };
}

let fx: Fixture;
beforeEach(() => {
  fx = makeFixture();
});
afterEach(() => rmSync(fx.root, { recursive: true, force: true }));

const ON = { APPLE_NOTES_MCP_ENABLE_PRIVATE: "1" };

function caught(fn: () => unknown): PrivateHelperError {
  try {
    fn();
  } catch (error) {
    if (error instanceof PrivateHelperError) return error;
    throw error;
  }
  throw new Error("expected a PrivateHelperError");
}

describe("configuration", () => {
  it("is opt-in: only the exact value 1 enables the helper", () => {
    expect(privateHelperEnabled({})).toBe(false);
    expect(privateHelperEnabled({ APPLE_NOTES_MCP_ENABLE_PRIVATE: "true" })).toBe(false);
    expect(privateHelperEnabled({ APPLE_NOTES_MCP_ENABLE_PRIVATE: "1" })).toBe(true);
  });

  it("defaults the install dir to Application Support and honours an override", () => {
    expect(helperInstallDir({})).toMatch(
      /Library\/Application Support\/apple-notes-mcp\/private-helper$/
    );
    expect(helperInstallDir({ APPLE_NOTES_MCP_PRIVATE_HELPER_DIR: " /x/y " })).toBe("/x/y");
  });

  it("finds the package root that ships the helper source", () => {
    expect(packageRoot(__dirname)).toBe(join(__dirname, "..", ".."));
    // No apple-notes-mcp package.json above a temp dir: falls back to the parent.
    expect(packageRoot(fx.root)).toBe(join(fx.root, ".."));
    // An unrelated package.json on the way up is skipped, and so is a corrupt one.
    const nested = join(fx.root, "a", "b");
    mkdirSync(nested, { recursive: true });
    writeFileSync(join(fx.root, "a", "package.json"), JSON.stringify({ name: "other" }));
    writeFileSync(join(nested, "package.json"), "{corrupt");
    expect(packageRoot(nested)).toBe(join(fx.root, "a"));
  });

  it("uses the real platform, filesystem and spawn by default", () => {
    const deps = defaultDeps();
    expect(deps.platform).toBe(process.platform);
    expect(deps.sourcePath).toMatch(/native\/private-helper\/apple-notes-private-helper\.m$/);
    expect(deps.readFile(deps.sourcePath).length).toBeGreaterThan(0);
  });
});

describe("inspectInstallation fails closed", () => {
  it("refuses other platforms", () => {
    const r = inspectInstallation({ ...fx.deps(), platform: "linux" });
    expect(r).toMatchObject({ ready: false, reason: "unsupported_platform" });
  });

  it("reports a missing packaged source", () => {
    rmSync(fx.sourcePath);
    expect(inspectInstallation(fx.deps())).toMatchObject({
      ready: false,
      reason: "helper_not_installed",
      detail: expect.stringMatching(/source is missing/),
    });
  });

  it("reports a helper that was never built, with the setup command", () => {
    const r = inspectInstallation(fx.deps());
    expect(r.reason).toBe("helper_not_installed");
    expect(r.detail).toMatch(/apple-notes-mcp setup --native-helper/);
    expect(r.expectedSourceSha256).toBe(sha256Hex("// fake helper source\n"));
  });

  it("reports an unreadable manifest", () => {
    fx.install();
    writeFileSync(join(fx.installDir, MANIFEST_NAME), "{not json");
    expect(inspectInstallation(fx.deps()).reason).toBe("helper_manifest_invalid");
    writeFileSync(join(fx.installDir, MANIFEST_NAME), JSON.stringify({ schemaVersion: 2 }));
    expect(inspectInstallation(fx.deps()).reason).toBe("helper_manifest_invalid");
  });

  it("treats a helper built from other source as stale", () => {
    fx.install({ sourceSha256: "0".repeat(64) });
    expect(inspectInstallation(fx.deps())).toMatchObject({ ready: false, reason: "helper_stale" });
  });

  it("treats a helper built for another protocol as stale", () => {
    fx.install({ protocolVersion: PRIVATE_HELPER_PROTOCOL + 1 });
    expect(inspectInstallation(fx.deps()).reason).toBe("helper_stale");
  });

  it("refuses a binary changed after it was built", () => {
    fx.install();
    writeFileSync(fx.binaryPath, FAKE_HELPER + "\n// tampered\n");
    expect(inspectInstallation(fx.deps())).toMatchObject({
      ready: false,
      reason: "helper_modified",
    });
  });

  it("accepts a matching installation", () => {
    fx.install();
    expect(inspectInstallation(fx.deps())).toMatchObject({
      ready: true,
      reason: null,
      binaryPath: fx.binaryPath,
    });
  });
});

describe("callPrivateHelper", () => {
  it("refuses while the opt-in flag is off, before anything runs", () => {
    fx.install();
    const e = caught(() => callPrivateHelper("probe", {}, fx.deps()));
    expect(e.code).toBe("disabled");
    expect(e.committed).toBeUndefined();
    expect(caught(() => callPrivateHelper("append_plain_text", {}, fx.deps())).committed).toBe(
      false
    );
  });

  it("refuses a missing or stale helper even when enabled", () => {
    expect(caught(() => callPrivateHelper("probe", {}, fx.deps(ON))).code).toBe(
      "helper_not_installed"
    );
    fx.install({ sourceSha256: "1".repeat(64) });
    expect(caught(() => callPrivateHelper("probe", {}, fx.deps(ON))).code).toBe("helper_stale");
  });

  it("sends the protocol version and request fields on stdin", () => {
    fx.install();
    const r = callPrivateHelper("read_note_state", { identifier: NOTE }, fx.deps(ON));
    expect(r.echo).toEqual({ protocol: 1, action: "read_note_state", identifier: NOTE });
  });

  it("can run a staged binary for the setup handshake without the opt-in", () => {
    fx.install();
    const r = callPrivateHelper("hello", {}, fx.deps(), {
      allowDisabled: true,
      binaryPath: fx.binaryPath,
    });
    expect(r).toMatchObject({ status: "ok", protocolVersion: 1 });
  });

  it("treats a timed-out write as indeterminate", () => {
    fx.install();
    const deps = fx.deps({
      ...ON,
      FAKE_MODE: "hang",
      APPLE_NOTES_MCP_PRIVATE_HELPER_TIMEOUT_MS: "300",
    });
    const write = caught(() => callPrivateHelper("append_plain_text", {}, deps));
    expect(write.code).toBe("timeout");
    expect(write.committed).toBe("unknown");
    expect(write.message).toMatch(/INDETERMINATE/);
    const read = caught(() => callPrivateHelper("probe", {}, deps));
    expect(read.code).toBe("timeout");
    expect(read.committed).toBeUndefined();
  });

  it("rejects output that is not a JSON object", () => {
    fx.install();
    const garbage = fx.deps({ ...ON, FAKE_MODE: "garbage" });
    expect(caught(() => callPrivateHelper("probe", {}, garbage)).code).toBe("invalid_response");
    expect(caught(() => callPrivateHelper("append_plain_text", {}, garbage)).committed).toBe(
      "unknown"
    );
    const array = fx.deps({ ...ON, FAKE_MODE: "array" });
    expect(caught(() => callPrivateHelper("probe", {}, array)).code).toBe("invalid_response");
    expect(caught(() => callPrivateHelper("append_plain_text", {}, array)).committed).toBe(
      "unknown"
    );
  });

  it("passes the helper's error code, committed flag and details through", () => {
    fx.install();
    const conflict = caught(() =>
      callPrivateHelper("append_plain_text", {}, fx.deps({ ...ON, FAKE_MODE: "conflict" }))
    );
    expect(conflict).toMatchObject({
      code: "revision_conflict",
      committed: false,
      details: { currentRevision: "r1:x" },
    });
    const verify = caught(() =>
      callPrivateHelper("append_plain_text", {}, fx.deps({ ...ON, FAKE_MODE: "verify-failed" }))
    );
    expect(verify).toMatchObject({ code: "verification_failed", committed: true });
  });

  it("marks a write error without a committed flag as indeterminate", () => {
    fx.install();
    const deps = fx.deps({ ...ON, FAKE_MODE: "no-committed" });
    expect(caught(() => callPrivateHelper("append_plain_text", {}, deps)).committed).toBe(
      "unknown"
    );
    expect(caught(() => callPrivateHelper("probe", {}, deps)).committed).toBeUndefined();
  });

  it("rejects an error response of unknown shape", () => {
    fx.install();
    const deps = fx.deps({ ...ON, FAKE_MODE: "bad-error" });
    expect(caught(() => callPrivateHelper("probe", {}, deps)).code).toBe("invalid_response");
    expect(caught(() => callPrivateHelper("append_plain_text", {}, deps)).committed).toBe(
      "unknown"
    );
  });

  it("reports a helper that cannot be started", () => {
    const deps = fx.deps(ON);
    const e = caught(() =>
      callPrivateHelper("append_plain_text", {}, deps, { binaryPath: join(fx.root, "absent") })
    );
    expect(e).toMatchObject({ code: "helper_unreachable", committed: false });
    expect(
      caught(() => callPrivateHelper("probe", {}, deps, { binaryPath: join(fx.root, "absent") }))
        .committed
    ).toBeUndefined();
  });

  it("falls back to the default timeout for a non-numeric override", () => {
    fx.install();
    const r = callPrivateHelper(
      "probe",
      {},
      fx.deps({ ...ON, APPLE_NOTES_MCP_PRIVATE_HELPER_TIMEOUT_MS: "soon" })
    );
    expect(r.status).toBe("ok");
  });
});

describe("typed actions", () => {
  it("parses the probe", () => {
    fx.install();
    const probe = probePrivateHelper(fx.deps(ON));
    expect(probe.features.appendPlainText.available).toBe(true);
    expect(probe.os.version).toBe("27.2.0");
  });

  it("validates the identifier before reading note state", () => {
    fx.install();
    expect(caught(() => readNoteState("not-a-uuid", fx.deps(ON))).code).toBe("invalid_request");
    const state = readNoteState(NOTE, fx.deps(ON));
    expect(state.revision).toMatch(/^r1:/);
    expect(state.cloudSync.uploadPending).toBe(true);
  });

  it("rejects a malformed success response", () => {
    fx.install();
    const e = caught(() => readNoteState(NOTE, fx.deps({ ...ON, FAKE_MODE: "malformed" })));
    expect(e.code).toBe("invalid_response");
    expect(e.committed).toBeUndefined();
  });

  it("gates the unvalidated append behind APPLE_NOTES_MCP_ALLOW_UNVERIFIED", () => {
    expect(APPEND_LIVE_VALIDATED).toBe(false);
    fx.install();
    const e = caught(() =>
      appendPlainText({ identifier: NOTE, text: "hi", ifRevision: REV }, fx.deps(ON))
    );
    expect(e).toMatchObject({ code: "not_live_validated", committed: false });
  });

  it("validates append input before spawning", () => {
    const deps = fx.deps({ ...ON, APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "1" });
    expect(
      caught(() => appendPlainText({ identifier: NOTE, text: "x", ifRevision: "sha256:x" }, deps))
        .code
    ).toBe("invalid_request");
    expect(
      caught(() => appendPlainText({ identifier: "x", text: "x", ifRevision: REV }, deps)).code
    ).toBe("invalid_request");
  });

  it("appends and returns the verified result", () => {
    fx.install();
    const r = appendPlainText(
      { identifier: NOTE, text: "hello\nworld", ifRevision: REV },
      fx.deps({ ...ON, APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "1" })
    );
    expect(r).toMatchObject({ committed: true, verified: true, pushScheduled: false });
    expect(r.echo).toEqual({
      protocol: 1,
      action: "append_plain_text",
      identifier: NOTE,
      text: "hello\nworld",
      ifRevision: REV,
    });
  });

  it("treats a malformed append success as indeterminate", () => {
    fx.install();
    const e = caught(() =>
      appendPlainText(
        { identifier: NOTE, text: "x", ifRevision: REV },
        fx.deps({ ...ON, APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "1", FAKE_MODE: "malformed" })
      )
    );
    expect(e).toMatchObject({ code: "invalid_response", committed: "unknown" });
  });
});

describe("text and identifier rules", () => {
  it("accepts printable text, tabs and newlines", () => {
    expect(() => assertAppendText("a\tb\nc é 漢字 🙂")).not.toThrow();
  });

  it.each([
    ["empty", ""],
    ["carriage return", "a\rb"],
    ["NUL", "a\u0000b"],
    ["attachment glyph", "a￼b"],
    ["line separator", "a b"],
    ["C1 control", "a\u0085b"],
    ["too long", "x".repeat(50_001)],
  ])("rejects %s", (_label, text) => {
    expect(() => assertAppendText(text)).toThrow(PrivateHelperError);
  });

  it("requires a UUID-shaped identifier", () => {
    expect(() => assertNoteIdentifier(NOTE.toLowerCase())).not.toThrow();
    expect(() => assertNoteIdentifier("x-coredata://A/ICNote/p1")).toThrow(/UUID/);
  });
});

describe("privateHelperCapabilities never throws", () => {
  it("reports unsupported platforms", () => {
    const c = privateHelperCapabilities({ ...fx.deps(ON), platform: "linux" });
    expect(c.features.readNoteState).toMatchObject({
      available: false,
      reason: "unsupported_platform",
    });
  });

  it("explains that the helper is off", () => {
    fx.install();
    const c = privateHelperCapabilities(fx.deps());
    expect(c.enabled).toBe(false);
    expect(c.probe).toBeNull();
    expect(c.features.appendPlainText).toMatchObject({ available: false, reason: "disabled" });
  });

  it("explains a missing helper", () => {
    const c = privateHelperCapabilities(fx.deps(ON));
    expect(c.features.readNoteState).toMatchObject({
      available: false,
      reason: "helper_not_installed",
    });
  });

  it("turns a probe failure into helper_unreachable", () => {
    fx.install();
    const c = privateHelperCapabilities(fx.deps({ ...ON, FAKE_MODE: "garbage" }));
    expect(c.features.readNoteState.reason).toBe("helper_unreachable");
  });

  it("names missing private API from the live probe", () => {
    fx.install();
    const c = privateHelperCapabilities(fx.deps({ ...ON, FAKE_MODE: "missing-api" }));
    expect(c.features.appendPlainText).toMatchObject({
      available: false,
      reason: "private_api_unavailable",
      detail: "missing: -[ICNote saveNoteData]",
    });
    const empty = privateHelperCapabilities(fx.deps({ ...ON, FAKE_MODE: "missing-api-empty" }));
    expect(empty.features.readNoteState.detail).toBe("private_api_unavailable");
  });

  it("passes a store failure through", () => {
    fx.install();
    const c = privateHelperCapabilities(fx.deps({ ...ON, FAKE_MODE: "no-store" }));
    expect(c.features.readNoteState.reason).toBe("store_unavailable");
  });

  it("keeps the append off until live validation unless explicitly allowed", () => {
    fx.install();
    const gated = privateHelperCapabilities(fx.deps(ON));
    expect(gated.features.readNoteState.available).toBe(true);
    expect(gated.features.appendPlainText).toMatchObject({
      available: false,
      reason: "not_live_validated",
    });
    const allowed = privateHelperCapabilities(
      fx.deps({ ...ON, APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "1" })
    );
    expect(allowed.features.appendPlainText.available).toBe(true);
  });
});
