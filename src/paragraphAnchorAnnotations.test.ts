/**
 * Tool annotations of the paragraph tools, read from the configs src/index.ts
 * registers. Two tools can write the local anchor registry (list-note-paragraphs
 * with recordAnchors, get-paragraph-link with recordAnchor), so a client must
 * not be told they are read-only. resolve-paragraph-anchor takes no `remint`
 * input in this build.
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

type Config = {
  description?: string;
  inputSchema?: Record<string, unknown>;
  annotations?: Record<string, unknown>;
};
const registered = vi.hoisted(() => new Map<string, Config>());

vi.mock(import("@modelcontextprotocol/sdk/server/mcp.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  McpServer: vi.fn().mockImplementation(function () {
    return {
      registerTool: vi.fn((name: string, config: Config) => registered.set(name, config)),
      resource: vi.fn(),
      prompt: vi.fn(),
      connect: vi.fn(async () => undefined),
    };
  }) as never,
}));
vi.mock("@modelcontextprotocol/sdk/server/stdio.js", () => ({
  StdioServerTransport: vi.fn(),
}));
vi.mock("@/utils/jsonSchemaDialect.js", () => ({ withJsonSchema2020_12: (t: unknown) => t }));
vi.mock("@/services/fileConfig.js", () => ({ loadFileConfig: vi.fn() }));

beforeAll(async () => {
  const on = vi.spyOn(process, "on").mockReturnValue(process);
  const stdinOn = vi.spyOn(process.stdin, "on").mockReturnValue(process.stdin);
  await import("@/index.js");
  on.mockRestore();
  stdinOn.mockRestore();
});
afterAll(() => registered.clear());

describe("paragraph tool annotations", () => {
  it.each([
    ["list-note-paragraphs", "recordAnchors"],
    ["get-paragraph-link", "recordAnchor"],
  ])("does not mark %s read-only, because %s writes the registry", (name, input) => {
    const config = registered.get(name)!;
    expect(config.inputSchema).toHaveProperty(input);
    expect(config.annotations).toMatchObject({ readOnlyHint: false, destructiveHint: false });
    expect(config.annotations?.readOnlyHint).not.toBe(true);
    expect(config.description).not.toMatch(/Safety: read-only/);
    expect(config.description).toContain("local anchor registry");
  });

  it("marks only the tools that never write anything as read-only", () => {
    const readOnly = ["list-paragraph-anchors", "get-paragraph-anchor"];
    for (const name of readOnly) expect(registered.get(name)!.annotations?.readOnlyHint).toBe(true);
    for (const name of [
      "create-paragraph-anchor",
      "resolve-paragraph-anchor",
      "prune-paragraph-anchors",
    ])
      expect(registered.get(name)!.annotations?.readOnlyHint).toBe(false);
    expect(registered.get("prune-paragraph-anchors")!.annotations?.destructiveHint).toBe(true);
  });

  it("ships resolve-paragraph-anchor without remint", () => {
    const config = registered.get("resolve-paragraph-anchor")!;
    expect(Object.keys(config.inputSchema ?? {}).sort()).toEqual([
      "anchorId",
      "minConfidence",
      "refresh",
    ]);
    expect(config.description).not.toMatch(/remint:|writer/i);
  });
});
