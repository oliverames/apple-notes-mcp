/**
 * The real CLI wiring: `defaultPermissionsCliDeps` must reach the AppleScript
 * layer only when the user asked for the Automation probe. Every other
 * dependency of the check is mocked so nothing touches this Mac.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const executeAppleScript = vi.hoisted(() => vi.fn());

vi.mock("@/utils/applescript.js", () => ({
  executeAppleScript,
  isPermissionDenied: (error?: string) => Boolean(error && /-1743/.test(error)),
}));
vi.mock("@/utils/checklistParser.js", () => ({ hasFullDiskAccess: () => true }));
vi.mock("@/setupShortcuts.js", () => ({
  setupShortcuts: () => ({ ready: true, checkOnly: true, items: [] }),
}));
vi.mock("@/services/capabilityMatrix.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/services/capabilityMatrix.js")>()),
  readMacOSVersion: () => "27.2",
}));
vi.mock("@/services/publicHelper.js", () => ({
  inspectPublicHelper: () => ({ ready: false, detail: "not built" }),
  callPublicHelper: vi.fn(),
  PUBLIC_HELPER_SETUP_COMMAND: "apple-notes-mcp setup --public-helper",
}));

import { defaultPermissionsCliDeps, parsePermissionsArgs } from "./permissions.js";

describe("defaultPermissionsCliDeps and the Automation probe", () => {
  beforeEach(() => {
    executeAppleScript.mockReset();
    executeAppleScript.mockReturnValue({ success: true });
    vi.stubEnv("SSH_CONNECTION", "");
  });
  afterEach(() => vi.unstubAllEnvs());

  const run = (args: string[]) => {
    const deps = defaultPermissionsCliDeps(parsePermissionsArgs(["--permissions", ...args]));
    try {
      return deps.check();
    } finally {
      deps.close();
    }
  };
  const automation = (report: ReturnType<typeof run>) =>
    report.items.find((candidate) => candidate.id === "notesAutomation")!;

  it("sends no Apple event for a plain run", () => {
    const report = run([]);
    expect(executeAppleScript).not.toHaveBeenCalled();
    expect(automation(report).status).toBe("unknown");
  });

  it("sends no Apple event under --check, with or without --probe-automation", () => {
    for (const args of [["--check"], ["--check", "--probe-automation"]]) {
      const report = run(args);
      expect(automation(report).status).toBe("unknown");
    }
    expect(executeAppleScript).not.toHaveBeenCalled();
  });

  it("sends no Apple event over SSH, even with --probe-automation", () => {
    vi.stubEnv("SSH_CONNECTION", "10.0.0.2 51234 10.0.0.9 22");
    const report = run(["--probe-automation"]);
    expect(executeAppleScript).not.toHaveBeenCalled();
    expect(automation(report).status).toBe("unknown");
    expect(automation(report).detail).toContain("SSH");
  });

  it("sends exactly one read-only Apple event with --probe-automation", () => {
    const report = run(["--probe-automation"]);
    expect(executeAppleScript).toHaveBeenCalledTimes(1);
    expect(executeAppleScript.mock.calls[0][0]).toBe(
      'tell application "Notes" to get name of account 1'
    );
    expect(automation(report).status).toBe("granted");
  });
});
