/**
 * Paper decode client tests. A Node script stands in for the native helper,
 * answering `read_paper` with synthetic stroke data, so the real spawn,
 * request shape and response validation run without NotesShared.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  HELPER_BINARY_NAME,
  MANIFEST_NAME,
  PRIVATE_HELPER_PROTOCOL,
  PrivateHelperError,
  defaultDeps,
  sha256Hex,
  type PrivateHelperDeps,
} from "./privateHelper.js";
import {
  DEFAULT_PAPER_POINTS,
  MAX_PAPER_POINTS,
  PAPER_POINT_FIELDS,
  assertPaperReadRequest,
  readPaper,
} from "./privatePaper.js";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const ATTACHMENT = "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9";

const FAKE_HELPER = `#!/usr/bin/env node
let input = "";
process.stdin.on("data", (c) => (input += c));
process.stdin.on("end", () => {
  const req = JSON.parse(input);
  const mode = process.env.FAKE_MODE || "ok";
  const out = (obj, code = 0) => { process.stdout.write(JSON.stringify(obj) + "\\n"); process.exit(code); };
  if (req.action !== "read_paper") out({ status: "error", code: "unknown_action", message: "no" }, 1);
  if (mode === "ambiguous") out({ status: "error", code: "ambiguous_attachment", message: "two", attachmentIdentifiers: ["A", "B"] }, 1);
  if (mode === "malformed") out({ status: "ok", strokes: "nope" });
  const pt = (x, y) => [x, y, 2.5, 2.5, 1, 1, 0, 1.5708, 0.01];
  out({
    status: "ok", storeKind: "copy", attachmentIdentifier: "${ATTACHMENT}", noteIdentifier: "${NOTE}",
    typeUTI: "com.apple.paper", decodePath: "NotesShared.ICSystemPaperDrawingsHelper", vectorDecode: "strokes",
    drawingCount: 1, strokeCount: 2, returnedStrokeCount: 2, pointCount: 3, bounds: [0, 0, 100, 50],
    inks: ["pen"], pointFields: ${JSON.stringify(PAPER_POINT_FIELDS)},
    strokes: [
      { ink: "pen", inkIdentifier: "com.apple.ink.pen", color: [0, 0, 0, 1], width: 2.5, transform: [1, 0, 0, 1, 0, 0], pointCount: 2, renderBounds: [0, 0, 10, 10], masked: false, points: [pt(0, 0), pt(10, 10)] },
      { ink: "marker", inkIdentifier: "com.apple.ink.marker", color: null, width: 8, transform: null, pointCount: 1, renderBounds: [0, 0, 1, 1], masked: true, pointsOmitted: true },
    ],
    shapes: [], shapeDecode: { available: false, reason: "not_exposed" }, truncated: true, warnings: [],
    snapshot: { files: 2, bytes: 1024 }, echo: req,
  });
});
`;

let root: string;
let deps: (env?: Record<string, string>) => PrivateHelperDeps;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "private-paper-test-"));
  const installDir = join(root, "install");
  const sourcePath = join(root, "helper.m");
  writeFileSync(sourcePath, "// fake\n");
  mkdirSync(installDir, { recursive: true });
  writeFileSync(join(installDir, HELPER_BINARY_NAME), FAKE_HELPER);
  chmodSync(join(installDir, HELPER_BINARY_NAME), 0o755);
  writeFileSync(
    join(installDir, MANIFEST_NAME),
    JSON.stringify({
      schemaVersion: 1,
      protocolVersion: PRIVATE_HELPER_PROTOCOL,
      sourceSha256: sha256Hex("// fake\n"),
      binarySha256: sha256Hex(FAKE_HELPER),
      builtAt: "2026-09-23T00:00:00.000Z",
      osVersion: "27.2",
      compiler: "clang",
    })
  );
  deps = (env = {}) =>
    defaultDeps({
      env: {
        PATH: process.env.PATH,
        APPLE_NOTES_MCP_PRIVATE_HELPER_DIR: installDir,
        APPLE_NOTES_MCP_ENABLE_PRIVATE: "1",
        ...env,
      },
      platform: "darwin",
      sourcePath,
    });
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

function caught(fn: () => unknown): PrivateHelperError {
  try {
    fn();
  } catch (error) {
    if (error instanceof PrivateHelperError) return error;
    throw error;
  }
  throw new Error("expected a PrivateHelperError");
}

const SPAWN_TIMEOUT = { timeout: 20_000 };

describe("assertPaperReadRequest", () => {
  it("requires exactly one selector", () => {
    expect(caught(() => assertPaperReadRequest({})).code).toBe("invalid_request");
    expect(
      caught(() => assertPaperReadRequest({ identifier: NOTE, attachmentIdentifier: ATTACHMENT }))
        .code
    ).toBe("invalid_request");
    expect(() => assertPaperReadRequest({ identifier: NOTE })).not.toThrow();
    expect(() => assertPaperReadRequest({ attachmentIdentifier: ATTACHMENT })).not.toThrow();
  });
  it("validates identifier shapes and the point budget", () => {
    expect(caught(() => assertPaperReadRequest({ identifier: "nope" })).message).toMatch(/UUID/);
    expect(caught(() => assertPaperReadRequest({ attachmentIdentifier: "nope" })).message).toBe(
      "attachmentIdentifier must be a UUID"
    );
    for (const maxPoints of [0, 1.5, MAX_PAPER_POINTS + 1])
      expect(caught(() => assertPaperReadRequest({ identifier: NOTE, maxPoints })).code).toBe(
        "invalid_request"
      );
    expect(() => assertPaperReadRequest({ identifier: NOTE, maxPoints: 1 })).not.toThrow();
    expect(DEFAULT_PAPER_POINTS).toBeLessThanOrEqual(MAX_PAPER_POINTS);
  });
});

describe("readPaper", SPAWN_TIMEOUT, () => {
  it("sends only the fields given and returns the validated decode", () => {
    const result = readPaper(
      { attachmentIdentifier: ATTACHMENT, includePoints: true, maxPoints: 5 },
      deps()
    );
    expect(result.strokeCount).toBe(2);
    expect(result.strokes[0].points?.[1].slice(0, 2)).toEqual([10, 10]);
    expect(result.strokes[1].pointsOmitted).toBe(true);
    expect(result.shapeDecode).toEqual({ available: false, reason: "not_exposed" });
    expect((result as Record<string, unknown>).echo).toEqual({
      protocol: 1,
      action: "read_paper",
      attachmentIdentifier: ATTACHMENT,
      includePoints: true,
      maxPoints: 5,
    });
    const byNote = readPaper({ identifier: NOTE }, deps());
    expect((byNote as Record<string, unknown>).echo).toEqual({
      protocol: 1,
      action: "read_paper",
      identifier: NOTE,
    });
  });

  it("validates before spawning and refuses while disabled", () => {
    expect(caught(() => readPaper({}, deps())).code).toBe("invalid_request");
    expect(
      caught(() => readPaper({ identifier: NOTE }, deps({ APPLE_NOTES_MCP_ENABLE_PRIVATE: "0" })))
        .code
    ).toBe("disabled");
  });

  it("passes helper refusals through with their details", () => {
    const e = caught(() => readPaper({ identifier: NOTE }, deps({ FAKE_MODE: "ambiguous" })));
    expect(e.code).toBe("ambiguous_attachment");
    expect(e.committed).toBeUndefined();
    expect(e.details).toMatchObject({ attachmentIdentifiers: ["A", "B"] });
  });

  it("rejects a malformed success response", () => {
    const e = caught(() => readPaper({ identifier: NOTE }, deps({ FAKE_MODE: "malformed" })));
    expect(e.code).toBe("invalid_response");
    expect(e.committed).toBeUndefined();
  });
});
