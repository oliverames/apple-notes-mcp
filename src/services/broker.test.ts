import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { spawnSync } from "node:child_process";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  BROKER_APP_NAME,
  BROKER_BUNDLE_ID,
  BROKER_EXECUTABLE,
  BROKER_PROTOCOL,
  brokerCompileArguments,
  brokerInfoPlist,
  brokerLaunchAgentPlist,
  brokerPaths,
  brokerStatus,
  chooseNodePath,
  chooseSigningIdentity,
  defaultBrokerDeps,
  formatBrokerSetup,
  inspectBroker,
  parseBrokerArgs,
  parseTeamId,
  recordBrokerFallback,
  setupBroker,
  type BrokerDeps,
  type BrokerManifest,
} from "@/services/broker.js";
import { sha256Hex } from "@/services/publicHelper.js";

const SECURITY_OUTPUT = `  1) 1111111111111111111111111111111111111111 "Apple Development: Dev Person (AAAAAAAAAA)"
  2) 2222222222222222222222222222222222222222 "Developer ID Application: Dev Person (TEAM123456)"
     2 valid identities found
`;

let root: string;
let env: NodeJS.ProcessEnv;
let sourcePath: string;
let entryPath: string;
let nodePath: string;

type SpawnResult = { status: number | null; stdout?: string; stderr?: string; error?: Error };
type SpawnHandler = (cmd: string, args: string[], opts: { input?: string }) => SpawnResult;

function makeSpawn(handler: SpawnHandler, calls: Array<[string, string[]]>): typeof spawnSync {
  return ((cmd: string, args: string[], opts: { input?: string }) => {
    calls.push([cmd, args]);
    return {
      pid: 1,
      output: [],
      signal: null,
      stdout: "",
      stderr: "",
      ...handler(cmd, args, opts ?? {}),
    };
  }) as unknown as typeof spawnSync;
}

/** A spawn that behaves like a working toolchain, with per-step overrides. */
function toolchain(overrides: Partial<Record<string, SpawnResult>> = {}): SpawnHandler {
  const sourceSha = sha256Hex(readFileSync(sourcePath));
  return (cmd, args) => {
    if (cmd === "/usr/bin/xcrun" && args[1] === "--version")
      return overrides.version ?? { status: 0, stdout: "Apple Swift version 6.3\nTarget: arm64" };
    if (cmd === "/usr/bin/xcrun") {
      if (overrides.compile) return overrides.compile;
      writeFileSync(args[args.length - 1], "binary");
      return { status: 0 };
    }
    if (cmd === "/usr/bin/security")
      return overrides.security ?? { status: 0, stdout: SECURITY_OUTPUT };
    if (cmd === "/usr/bin/codesign" && args[0] === "-dv")
      return (
        overrides.describe ?? {
          status: 0,
          stderr: "Identifier=apple-notes-mcp.broker\nTeamIdentifier=TEAM123456\n",
        }
      );
    if (cmd === "/usr/bin/codesign") return overrides.sign ?? { status: 0 };
    if (cmd === "/bin/launchctl" && args[0] === "bootstrap")
      return overrides.bootstrap ?? { status: 0 };
    if (cmd === "/bin/launchctl") return { status: 0 };
    // the staged broker binary: the hello handshake
    return (
      overrides.hello ?? {
        status: 0,
        stdout: JSON.stringify({
          type: "hello",
          protocolVersion: BROKER_PROTOCOL,
          sourceSha256: sourceSha,
        }),
      }
    );
  };
}

function deps(overrides: Partial<BrokerDeps> = {}): BrokerDeps {
  return defaultBrokerDeps({
    env,
    platform: "darwin",
    sourcePath,
    entryPath,
    execPath: nodePath,
    packageVersion: "9.9.9",
    uid: 501,
    ping: async () => true,
    sleep: async () => {},
    now: () => new Date("2026-10-05T12:00:00Z"),
    ...overrides,
  });
}

function writeManifest(overrides: Partial<BrokerManifest> = {}): BrokerManifest {
  const paths = brokerPaths(env);
  mkdirSync(join(paths.appPath, "Contents", "MacOS"), { recursive: true });
  writeFileSync(paths.executablePath, "binary");
  mkdirSync(join(paths.agentPath, ".."), { recursive: true });
  writeFileSync(paths.agentPath, "<plist/>");
  mkdirSync(paths.stateDir, { recursive: true });
  const manifest: BrokerManifest = {
    schemaVersion: 1,
    protocolVersion: BROKER_PROTOCOL,
    packageVersion: "9.9.9",
    sourceSha256: sha256Hex(readFileSync(sourcePath)),
    binarySha256: sha256Hex("binary"),
    appPath: paths.appPath,
    agentPath: paths.agentPath,
    socketPath: paths.socketPath,
    logPath: paths.logPath,
    nodePath,
    entryPath,
    signing: {
      identity: "Developer ID Application: Dev Person (TEAM123456)",
      teamId: "TEAM123456",
      stable: true,
    },
    builtAt: "2026-10-05T12:00:00.000Z",
    compiler: "Apple Swift version 6.3",
    ...overrides,
  };
  writeFileSync(paths.manifestPath, JSON.stringify(manifest));
  return manifest;
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "anm-broker-"));
  env = {
    APPLE_NOTES_MCP_BROKER_DIR: join(root, "state"),
    APPLE_NOTES_MCP_BROKER_APP_DIR: join(root, "Applications"),
    APPLE_NOTES_MCP_BROKER_AGENT_DIR: join(root, "LaunchAgents"),
    PATH: "",
  };
  sourcePath = join(root, "broker.swift");
  writeFileSync(sourcePath, "// broker source");
  entryPath = join(root, "build", "index.js");
  mkdirSync(join(root, "build"));
  writeFileSync(entryPath, "// entry");
  nodePath = join(root, "bin", "node");
  mkdirSync(join(root, "bin"));
  writeFileSync(nodePath, "node");
  recordBrokerFallback(null);
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

describe("brokerPaths", () => {
  it("honors the directory overrides", () => {
    const paths = brokerPaths(env);
    expect(paths.manifestPath).toBe(join(root, "state", "manifest.json"));
    expect(paths.socketPath).toBe(join(root, "state", "broker.sock"));
    expect(paths.appPath).toBe(join(root, "Applications", BROKER_APP_NAME));
    expect(paths.executablePath).toBe(
      join(root, "Applications", BROKER_APP_NAME, "Contents", "MacOS", BROKER_EXECUTABLE)
    );
    expect(paths.agentPath).toBe(join(root, "LaunchAgents", "apple-notes-mcp.broker.plist"));
  });

  it("defaults to per-user locations", () => {
    const paths = brokerPaths({});
    expect(paths.stateDir).toMatch(/Library\/Application Support\/apple-notes-mcp\/broker$/);
    expect(paths.appDir).toMatch(/\/Applications$/);
    expect(paths.agentPath).toMatch(/Library\/LaunchAgents\/apple-notes-mcp\.broker\.plist$/);
    expect(paths.logPath).toMatch(/Library\/Logs\/apple-notes-mcp-broker\.log$/);
  });
});

describe("inspectBroker", () => {
  it("is macOS only", () => {
    expect(inspectBroker(deps({ platform: "linux" })).reason).toBe("unsupported_platform");
  });

  it("reports not installed without a manifest", () => {
    const result = inspectBroker(deps());
    expect(result).toMatchObject({
      installed: false,
      ready: false,
      reason: "broker_not_installed",
    });
  });

  it("is ready when everything matches", () => {
    writeManifest();
    expect(inspectBroker(deps())).toMatchObject({ installed: true, ready: true, reason: null });
  });

  it("fails closed on an unreadable manifest", () => {
    const paths = brokerPaths(env);
    mkdirSync(paths.stateDir, { recursive: true });
    writeFileSync(paths.manifestPath, "{not json");
    expect(inspectBroker(deps()).reason).toBe("broker_manifest_invalid");
  });

  it("reports a missing app", () => {
    writeManifest();
    rmSync(brokerPaths(env).appPath, { recursive: true });
    expect(inspectBroker(deps())).toMatchObject({
      installed: true,
      reason: "broker_not_installed",
    });
  });

  it("reports a stale build when the source or protocol changed", () => {
    writeManifest({ sourceSha256: "0".repeat(64) });
    expect(inspectBroker(deps()).reason).toBe("broker_stale");
    writeManifest({ protocolVersion: BROKER_PROTOCOL + 1 });
    expect(inspectBroker(deps()).reason).toBe("broker_stale");
    writeManifest();
    expect(inspectBroker(deps({ sourcePath: join(root, "missing.swift") })).reason).toBe(
      "broker_stale"
    );
  });

  it("reports a modified binary", () => {
    writeManifest();
    writeFileSync(brokerPaths(env).executablePath, "tampered");
    expect(inspectBroker(deps()).reason).toBe("broker_modified");
  });

  it("reports a missing LaunchAgent, Node binary, or entry point", () => {
    writeManifest();
    rmSync(brokerPaths(env).agentPath);
    expect(inspectBroker(deps()).reason).toBe("broker_agent_missing");
    writeManifest({ nodePath: join(root, "gone", "node") });
    expect(inspectBroker(deps()).reason).toBe("broker_node_missing");
    expect(inspectBroker(deps()).detail).toMatch(/grants stay with the broker app/);
    writeManifest({ entryPath: join(root, "gone.js") });
    expect(inspectBroker(deps()).reason).toBe("broker_entry_missing");
  });
});

describe("generated files", () => {
  it("builds an Info.plist that keeps the broker out of the Dock and explains Automation", () => {
    const plist = brokerInfoPlist("1.2.3 <beta>");
    expect(plist).toContain(`<string>${BROKER_BUNDLE_ID}</string>`);
    expect(plist).toContain(`<string>${BROKER_EXECUTABLE}</string>`);
    expect(plist).toContain("<key>LSUIElement</key>\n  <true/>");
    expect(plist).toContain("NSAppleEventsUsageDescription");
    expect(plist).toContain("1.2.3 &lt;beta&gt;");
  });

  it("pins the compiler arguments", () => {
    expect(brokerCompileArguments("/s.swift", "/d.swift", "/out")).toEqual([
      "swiftc",
      "-O",
      "-parse-as-library",
      "/s.swift",
      "/d.swift",
      "-o",
      "/out",
    ]);
  });

  it("writes a LaunchAgent that serves the socket with escaped paths", () => {
    const plist = brokerLaunchAgentPlist({
      executablePath: "/A&B/broker",
      socketPath: "/s.sock",
      nodePath: "/node",
      entryPath: "/index.js",
      logPath: "/log",
    });
    expect(plist).toContain("<string>/A&amp;B/broker</string>\n    <string>serve</string>");
    expect(plist).toContain("<string>--socket</string>\n    <string>/s.sock</string>");
    expect(plist).toContain("<string>--node</string>\n    <string>/node</string>");
    expect(plist).toContain("<string>--entry</string>\n    <string>/index.js</string>");
    expect(plist).toContain("<key>KeepAlive</key>\n  <true/>");
    expect(plist).toContain("<key>AssociatedBundleIdentifiers</key>");
  });
});

describe("signing", () => {
  it("prefers Developer ID, then Apple Development, then ad-hoc", () => {
    expect(chooseSigningIdentity(SECURITY_OUTPUT, undefined)).toEqual({
      identity: "2222222222222222222222222222222222222222",
      name: "Developer ID Application: Dev Person (TEAM123456)",
    });
    const devOnly = SECURITY_OUTPUT.split("\n")[0];
    expect(chooseSigningIdentity(devOnly, undefined).name).toMatch(/^Apple Development:/);
    expect(chooseSigningIdentity("0 valid identities found", undefined)).toEqual({
      identity: "-",
      name: "ad-hoc",
    });
  });

  it("honors an explicit identity", () => {
    expect(chooseSigningIdentity(SECURITY_OUTPUT, " My Cert ")).toEqual({
      identity: "My Cert",
      name: "My Cert",
    });
    expect(chooseSigningIdentity(SECURITY_OUTPUT, "-")).toEqual({ identity: "-", name: "ad-hoc" });
    expect(chooseSigningIdentity(SECURITY_OUTPUT, "  ").name).toMatch(/^Developer ID/);
  });

  it("reads the team identifier", () => {
    expect(parseTeamId("Identifier=x\nTeamIdentifier=TEAM123456\n")).toBe("TEAM123456");
    expect(parseTeamId("Signature=adhoc\nTeamIdentifier=not set\n")).toBeNull();
    expect(parseTeamId("TeamIdentifier=not set\n")).toBeNull();
    expect(parseTeamId("")).toBeNull();
  });
});

describe("chooseNodePath", () => {
  const exists = () => true;
  it("prefers a PATH entry that resolves to the running Node", () => {
    const realpath = (p: string) => (p === "/opt/homebrew/bin/node" ? "/cellar/26/node" : p);
    expect(
      chooseNodePath({
        env: { PATH: "/usr/bin::/opt/homebrew/bin" },
        execPath: "/cellar/26/node",
        exists,
        realpath,
      })
    ).toBe("/opt/homebrew/bin/node");
  });

  it("falls back to the running binary", () => {
    expect(chooseNodePath({ env: {}, execPath: "/x/node", exists, realpath: (p) => p })).toBe(
      "/x/node"
    );
    expect(
      chooseNodePath({
        env: {},
        execPath: "/x/node",
        exists,
        realpath: () => {
          throw new Error("gone");
        },
      })
    ).toBe("/x/node");
    expect(
      chooseNodePath({
        env: { PATH: "/bad" },
        execPath: "/x/node",
        exists,
        realpath: (p) => {
          if (p.startsWith("/bad")) throw new Error("unreadable");
          return p;
        },
      })
    ).toBe("/x/node");
  });
});

describe("parseBrokerArgs", () => {
  it("reads the flags", () => {
    expect(parseBrokerArgs(["--broker"])).toEqual({
      checkOnly: false,
      uninstall: false,
      signIdentity: undefined,
    });
    expect(parseBrokerArgs(["--broker", "--check", "--uninstall", "--sign-identity", "X"])).toEqual(
      { checkOnly: true, uninstall: true, signIdentity: "X" }
    );
  });
});

describe("setupBroker install", () => {
  it("builds, signs, installs, starts, and verifies the broker", async () => {
    const calls: Array<[string, string[]]> = [];
    const report = await setupBroker(
      { checkOnly: false, uninstall: false },
      deps({ spawn: makeSpawn(toolchain(), calls) })
    );
    expect(report.ok).toBe(true);
    expect(report.running).toBe(true);
    expect(report.warnings).toEqual([]);
    const paths = brokerPaths(env);
    const manifest = JSON.parse(readFileSync(paths.manifestPath, "utf8")) as BrokerManifest;
    expect(manifest).toMatchObject({
      packageVersion: "9.9.9",
      nodePath,
      entryPath,
      signing: { teamId: "TEAM123456", stable: true },
    });
    expect(readFileSync(join(paths.appPath, "Contents", "Info.plist"), "utf8")).toContain(
      BROKER_BUNDLE_ID
    );
    expect(readFileSync(paths.agentPath, "utf8")).toContain(paths.socketPath);
    const sign = calls.find(([cmd, args]) => cmd === "/usr/bin/codesign" && args[0] === "--force");
    expect(sign?.[1]).toEqual([
      "--force",
      "--sign",
      "2222222222222222222222222222222222222222",
      "--identifier",
      BROKER_BUNDLE_ID,
      "--timestamp=none",
      expect.stringContaining(BROKER_APP_NAME),
    ]);
    expect(calls).toContainEqual(["/bin/launchctl", ["bootout", "gui/501/apple-notes-mcp.broker"]]);
    expect(calls).toContainEqual(["/bin/launchctl", ["bootstrap", "gui/501", paths.agentPath]]);
    const text = formatBrokerSetup(report);
    expect(text).toContain("installed and running");
    expect(text).toContain("Full Disk Access: click +");
  });

  it("warns that an ad-hoc signature loses grants on rebuild", async () => {
    const report = await setupBroker(
      { checkOnly: false, uninstall: false, signIdentity: "-" },
      deps({
        spawn: makeSpawn(
          toolchain({ describe: { status: 0, stderr: "Signature=adhoc\nTeamIdentifier=not set" } }),
          []
        ),
      })
    );
    expect(report.ok).toBe(true);
    expect(report.steps.find((s) => s.step === "sign")?.detail).toBe("ad-hoc");
    expect(report.warnings.join(" ")).toMatch(/ad-hoc signed/);
    expect(formatBrokerSetup(report)).toContain("! The broker is ad-hoc signed");
  });

  it("warns when run from the npx cache", async () => {
    const npxEntry = join(root, "_npx", "abc", "build", "index.js");
    mkdirSync(join(npxEntry, ".."), { recursive: true });
    writeFileSync(npxEntry, "//");
    const report = await setupBroker(
      { checkOnly: false, uninstall: false },
      deps({ entryPath: npxEntry, spawn: makeSpawn(toolchain(), []) })
    );
    expect(report.warnings.join(" ")).toMatch(/npx cache/);
  });

  it.each([
    ["find compiler", { version: { status: 1 } }],
    ["compile", { compile: { status: 1, stderr: "error: nope" } }],
    ["compile", { compile: { status: null, error: new Error("timeout") } }],
    ["sign", { sign: { status: 1, stderr: "no identity" } }],
    ["handshake", { hello: { status: 1, stdout: "" } }],
    ["handshake", { hello: { status: 0, stdout: JSON.stringify({ protocolVersion: 99 }) } }],
    ["start LaunchAgent", { bootstrap: { status: 5, stderr: "Bootstrap failed" } }],
  ] as Array<[string, Partial<Record<string, SpawnResult>>]>)(
    "stops at a failed %s step",
    async (step, overrides) => {
      const report = await setupBroker(
        { checkOnly: false, uninstall: false },
        deps({ spawn: makeSpawn(toolchain(overrides), []) })
      );
      expect(report.ok).toBe(false);
      expect(report.steps.at(-1)).toMatchObject({ step, ok: false });
      expect(formatBrokerSetup(report)).toContain("The broker was not installed.");
    }
  );

  it("reports a broker that never answers", async () => {
    const report = await setupBroker(
      { checkOnly: false, uninstall: false },
      deps({ spawn: makeSpawn(toolchain(), []), ping: async () => false })
    );
    expect(report.ok).toBe(false);
    expect(report.steps.at(-1)).toMatchObject({ step: "broker answers", ok: false });
  });

  it("refuses a socket path macOS cannot bind", async () => {
    env.APPLE_NOTES_MCP_BROKER_DIR = join(root, "x".repeat(120));
    const report = await setupBroker({ checkOnly: false, uninstall: false }, deps());
    expect(report.steps[0]).toMatchObject({ step: "socket path", ok: false });
  });

  it("needs the packaged source and a built entry point", async () => {
    let report = await setupBroker(
      { checkOnly: false, uninstall: false },
      deps({ sourcePath: join(root, "none.swift") })
    );
    expect(report.steps[0]).toMatchObject({ step: "locate source", ok: false });
    report = await setupBroker(
      { checkOnly: false, uninstall: false },
      deps({ entryPath: join(root, "none.js") })
    );
    expect(report.steps[0]).toMatchObject({ step: "locate server entry point", ok: false });
  });

  it("is macOS only", async () => {
    const report = await setupBroker(
      { checkOnly: false, uninstall: false },
      deps({ platform: "linux" })
    );
    expect(report.ok).toBe(false);
    expect(report.steps[0]).toMatchObject({ step: "platform", ok: false });
  });
});

describe("setupBroker --check and --uninstall", () => {
  it("checks an installed, running broker", async () => {
    writeManifest();
    const report = await setupBroker({ checkOnly: true, uninstall: false }, deps());
    expect(report).toMatchObject({ ok: true, mode: "check", running: true });
    expect(formatBrokerSetup(report)).toContain("installed and running");
  });

  it("flags an installed broker that does not answer, and an ad-hoc one", async () => {
    writeManifest({ signing: { identity: "ad-hoc", teamId: null, stable: false } });
    const report = await setupBroker(
      { checkOnly: true, uninstall: false },
      deps({ ping: async () => false })
    );
    expect(report.ok).toBe(false);
    expect(report.warnings.join(" ")).toMatch(/ad-hoc/);
    expect(formatBrokerSetup(report)).toContain("installed but not answering");
  });

  it("points at setup when nothing is installed", async () => {
    const report = await setupBroker({ checkOnly: true, uninstall: false }, deps());
    expect(report.ok).toBe(false);
    expect(formatBrokerSetup(report)).toContain("to install it");
  });

  it("stops and removes the broker", async () => {
    writeManifest();
    const calls: Array<[string, string[]]> = [];
    const report = await setupBroker(
      { checkOnly: false, uninstall: true },
      deps({ spawn: makeSpawn(() => ({ status: 0 }), calls) })
    );
    expect(report).toMatchObject({ ok: true, mode: "uninstall", running: false });
    expect(calls).toContainEqual(["/bin/launchctl", ["bootout", "gui/501/apple-notes-mcp.broker"]]);
    expect(inspectBroker(deps()).installed).toBe(false);
    expect(formatBrokerSetup(report)).toContain("The broker is removed.");
    expect(report.warnings.join(" ")).toContain(`tccutil reset All ${BROKER_BUNDLE_ID}`);
  });

  it("formats a failed uninstall", () => {
    const text = formatBrokerSetup({
      ok: false,
      mode: "uninstall",
      steps: [{ step: "remove broker", ok: false, detail: "busy" }],
      installation: inspectBroker(deps()),
      running: false,
      warnings: [],
    });
    expect(text).toContain("✗ remove broker: busy");
    expect(text).toContain("was not fully removed");
  });
});

describe("brokerStatus", () => {
  it("reports a brokered process", () => {
    const status = brokerStatus(
      deps({ env: { ...env, APPLE_NOTES_MCP_BROKERED: "1", APPLE_NOTES_MCP_BROKER_APP: "/A.app" } })
    );
    expect(status).toMatchObject({ inUse: true, appPath: "/A.app", fallbackReason: null });
    expect(status.detail).toMatch(/^In use: this server runs under \/A\.app/);
  });

  it("reports a brokered process without an app path", () => {
    const status = brokerStatus(deps({ env: { ...env, APPLE_NOTES_MCP_BROKERED: "1" } }));
    expect(status.detail).toContain("the broker app");
  });

  it("reports no broker", () => {
    const status = brokerStatus(deps());
    expect(status).toMatchObject({ inUse: false, installed: false, stableSigning: null });
    expect(status.detail).toMatch(/^Not installed/);
  });

  it("reports an installed broker that is turned off or unreachable", () => {
    writeManifest();
    expect(brokerStatus(deps({ env: { ...env, APPLE_NOTES_MCP_BROKER: "off" } })).detail).toMatch(
      /turned off/
    );
    recordBrokerFallback("The broker did not answer within 5000 ms.");
    const status = brokerStatus(deps());
    expect(status).toMatchObject({
      inUse: false,
      installed: true,
      ready: true,
      stableSigning: true,
    });
    expect(status.detail).toContain("did not answer");
  });

  it("survives an inspection failure", () => {
    const status = brokerStatus(
      deps({
        exists: () => {
          throw new Error("boom");
        },
      })
    );
    expect(status.installed).toBe(false);
  });
});

describe("defaultBrokerDeps", () => {
  it("points at the packaged source and entry point", () => {
    const d = defaultBrokerDeps();
    expect(d.sourcePath).toMatch(/native\/broker\/apple-notes-mcp-broker\.swift$/);
    expect(d.entryPath).toMatch(/build\/index\.js$/);
    expect(d.packageVersion).toMatch(/^\d+\.\d+\.\d+/);
  });

  it("wires real filesystem, clock, and socket helpers", async () => {
    const d = defaultBrokerDeps();
    expect(d.readFile(sourcePath).toString()).toBe("// broker source");
    expect(d.realpath(root)).toContain("anm-broker-");
    expect(d.now()).toBeInstanceOf(Date);
    await d.sleep(0);
    expect(await d.ping(join(root, "absent.sock"))).toBe(false);
  });
});
