import { describe, expect, it, vi, beforeEach } from "vitest";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { AppleNotesManager } from "../services/appleNotesManager.js";

vi.mock(import("../services/privateHelper.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  privateHelperCapabilities: vi.fn(),
  readNoteState: vi.fn(),
  appendPlainText: vi.fn(),
}));
import {
  PrivateHelperError,
  appendPlainText,
  privateHelperCapabilities,
  readNoteState,
} from "../services/privateHelper.js";
import { registerPrivateHelperTools } from "./privateHelperTools.js";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const REV = `r1:${"a".repeat(64)}`;
const CD = "x-coredata://8FA9FE0E-3B93-4057-AD95-A0EB6D4B5F06/ICNote/p11331";

function fixture(link: string | null = `notes://showNote?identifier=${NOTE}`) {
  const registerTool = vi.fn();
  const manager = { getNoteLinkById: vi.fn(() => link) } as unknown as AppleNotesManager;
  registerPrivateHelperTools(
    { registerTool } as unknown as McpServer,
    manager,
    () => ({}) as never
  );
  const call = async (name: string, args: Record<string, unknown>) => {
    const item = registerTool.mock.calls.find((c) => c[0] === name);
    if (!item) throw new Error(`missing ${name}`);
    return item[2](args);
  };
  const config = (name: string) => registerTool.mock.calls.find((c) => c[0] === name)?.[1];
  return { call, config, manager };
}

beforeEach(() => vi.clearAllMocks());

describe("private helper tools", () => {
  it("registers three tools with honest annotations", () => {
    const { config } = fixture();
    expect(config("native-helper-status").annotations.readOnlyHint).toBe(true);
    expect(config("native-note-state").annotations.readOnlyHint).toBe(true);
    expect(config("native-append-plain-text").annotations).toMatchObject({
      readOnlyHint: false,
      destructiveHint: false,
    });
    expect(config("native-append-plain-text").description).toMatch(/Safety:.*ifRevision/s);
  });

  it("status adds the setup command while the helper is not installed", async () => {
    vi.mocked(privateHelperCapabilities).mockReturnValueOnce({
      enabled: true,
      installation: { ready: false } as never,
      probe: null,
      features: {} as never,
    });
    const r = await fixture().call("native-helper-status", {});
    expect(r.structuredContent).toMatchObject({
      ok: true,
      setupCommand: "apple-notes-mcp setup --native-helper",
    });
    vi.mocked(privateHelperCapabilities).mockReturnValueOnce({
      enabled: true,
      installation: { ready: true } as never,
      probe: null,
      features: {} as never,
    });
    const ready = await fixture().call("native-helper-status", {});
    expect(ready.structuredContent.setupCommand).toBeUndefined();
  });

  it("reads note state by identifier or by resolving an x-coredata id", async () => {
    vi.mocked(readNoteState).mockReturnValue({ revision: REV } as never);
    const { call, manager } = fixture();
    await call("native-note-state", { identifier: NOTE });
    expect(readNoteState).toHaveBeenLastCalledWith(NOTE, {});
    await call("native-note-state", { id: CD });
    expect(manager.getNoteLinkById).toHaveBeenCalledWith(CD);
    expect(readNoteState).toHaveBeenLastCalledWith(NOTE, {});
  });

  it("refuses ambiguous, missing, or unresolvable note references", async () => {
    const both = await fixture().call("native-note-state", { identifier: NOTE, id: CD });
    expect(JSON.parse(both.content[0].text)).toMatchObject({ code: "invalid_request" });
    const none = await fixture().call("native-note-state", {});
    expect(JSON.parse(none.content[0].text)).toMatchObject({ code: "invalid_request" });
    const unresolved = await fixture(null).call("native-note-state", { id: CD });
    expect(unresolved.isError).toBe(true);
    expect(JSON.parse(unresolved.content[0].text)).toMatchObject({ code: "not_found" });
    expect(readNoteState).not.toHaveBeenCalled();
  });

  it("appends with the resolved identifier and returns the helper result", async () => {
    vi.mocked(appendPlainText).mockReturnValue({ committed: true, verified: true } as never);
    const r = await fixture().call("native-append-plain-text", {
      id: CD,
      text: "hello",
      ifRevision: REV,
    });
    expect(appendPlainText).toHaveBeenCalledWith(
      { identifier: NOTE, text: "hello", ifRevision: REV },
      {}
    );
    expect(r.structuredContent).toEqual({ ok: true, committed: true, verified: true });
  });

  it("reports write errors with their code, committed state, and details", async () => {
    vi.mocked(appendPlainText).mockImplementation(() => {
      throw new PrivateHelperError("revision_conflict", "changed", false, { currentRevision: REV });
    });
    const r = await fixture().call("native-append-plain-text", {
      identifier: NOTE,
      text: "x",
      ifRevision: REV,
    });
    expect(r.isError).toBe(true);
    expect(JSON.parse(r.content[0].text)).toEqual({
      ok: false,
      code: "revision_conflict",
      message: "changed",
      committed: false,
      currentRevision: REV,
    });
  });

  it("wraps unexpected failures as internal errors", async () => {
    vi.mocked(privateHelperCapabilities).mockImplementationOnce(() => {
      throw new Error("kaboom");
    });
    const r = await fixture().call("native-helper-status", {});
    expect(JSON.parse(r.content[0].text)).toEqual({
      ok: false,
      code: "internal_error",
      message: "Error: kaboom",
    });
  });

  it("uses the real dependencies when none are injected", async () => {
    vi.mocked(privateHelperCapabilities).mockReturnValueOnce({
      enabled: false,
      installation: { ready: true } as never,
      probe: null,
      features: {} as never,
    });
    const registerTool = vi.fn();
    registerPrivateHelperTools({ registerTool } as unknown as McpServer, {} as AppleNotesManager);
    await registerTool.mock.calls.find((c) => c[0] === "native-helper-status")![2]({});
    const deps = vi.mocked(privateHelperCapabilities).mock.calls[0][0]!;
    expect(deps.platform).toBe(process.platform);
    expect(deps.sourcePath).toMatch(/apple-notes-private-helper\.m$/);
  });

  it("validates tool input with the declared schemas", () => {
    const schema = fixture().config("native-append-plain-text").inputSchema;
    expect(schema.ifRevision.safeParse("sha256:abc").success).toBe(false);
    expect(schema.identifier.safeParse("nope").success).toBe(false);
    expect(schema.id.safeParse(CD).success).toBe(true);
  });
});
