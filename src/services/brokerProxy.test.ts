import { Duplex, PassThrough } from "node:stream";
import type { Socket } from "node:net";
import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  brokerPaths,
  brokerStatus,
  BROKER_PROTOCOL,
  recordBrokerFallback,
  type BrokerInstallation,
} from "@/services/broker.js";
import { BrokerUnreachableError, type requestBroker } from "@/services/brokerClient.js";
import {
  BROKER_CONNECT_TIMEOUT_MS,
  BROKER_PASSED_ENV_KEYS,
  defaultBrokerProxyDeps,
  passedEnvironment,
  startBrokerProxy,
  type BrokerProxyDeps,
} from "@/services/brokerProxy.js";

function installation(overrides: Partial<BrokerInstallation> = {}): BrokerInstallation {
  const paths = brokerPaths({ APPLE_NOTES_MCP_BROKER_DIR: "/state" });
  return {
    installed: true,
    ready: true,
    reason: null,
    detail: null,
    paths,
    manifest: {
      schemaVersion: 2,
      protocolVersion: BROKER_PROTOCOL,
      packageVersion: "2.15.0",
      sourceSha256: "a".repeat(64),
      binarySha256: "b".repeat(64),
      nodeSha256: "c".repeat(64),
      entrySha256: "d".repeat(64),
      appPath: paths.appPath,
      agentPath: paths.agentPath,
      socketPath: paths.socketPath,
      logPath: paths.logPath,
      nodePath: "/node",
      entryPath: `${paths.appPath}/Contents/Resources/server/build/index.js`,
      signing: { identity: "-", teamId: null, stable: false },
      builtAt: "2026-10-08T00:00:00.000Z",
      compiler: "swiftc",
    },
    ...overrides,
  };
}

function readyAnswer(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const manifest = installation().manifest!;
  return {
    type: "ready",
    protocolVersion: BROKER_PROTOCOL,
    packageVersion: manifest.packageVersion,
    entrySha256: manifest.entrySha256,
    pid: 9,
    ...overrides,
  };
}

/** A socket stand-in: what the proxy writes lands in `sent`; `remote` writes back. */
function fakeSocket() {
  const sent: Buffer[] = [];
  const socket = new Duplex({
    read() {},
    write(chunk: Buffer, _enc, done) {
      sent.push(Buffer.from(chunk));
      done();
    },
  });
  return { socket: socket as unknown as Socket, sent, remote: (data: string) => socket.push(data) };
}

function deps(overrides: Partial<BrokerProxyDeps> = {}) {
  const stdin = new PassThrough();
  const stdout = new PassThrough();
  const output: string[] = [];
  stdout.on("data", (chunk: Buffer) => output.push(chunk.toString()));
  const logs: string[] = [];
  const exit = vi.fn();
  const d: BrokerProxyDeps = {
    env: { APPLE_NOTES_MCP_TIMEOUT_MS: "45000" },
    inspect: () => installation(),
    request: vi.fn() as unknown as typeof requestBroker,
    stdin,
    stdout,
    exit,
    log: (m) => logs.push(m),
    ...overrides,
  };
  return { d, stdin, stdout, output, logs, exit };
}

afterEach(() => recordBrokerFallback(null));

describe("passedEnvironment", () => {
  it("passes only the explicit numeric resource and timing limits", () => {
    const allowed = Object.fromEntries(BROKER_PASSED_ENV_KEYS.map((key) => [key, "1000"]));
    expect(passedEnvironment(allowed)).toEqual(allowed);
  });

  it("never passes helper, code, path, safety, broker or unknown settings", () => {
    expect(
      passedEnvironment({
        APPLE_NOTES_MCP_TIMEOUT_MS: "45000",
        APPLE_NOTES_MCP_PUBLIC_HELPER_DIR: "/attacker/public-helper",
        APPLE_NOTES_MCP_PRIVATE_HELPER_DIR: "/attacker/private-helper",
        APPLE_NOTES_MCP_ENABLE_PRIVATE: "1",
        APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "1",
        APPLE_NOTES_MCP_ALLOW_PRIVATE_CONTENT_PATHS: "1",
        APPLE_NOTES_MCP_CONFIG_FILE: "/attacker/config.json",
        APPLE_NOTES_MCP_PRIVATE_STORE: "/attacker/store.sqlite",
        APPLE_NOTES_MCP_PERMISSIONS_WINDOW_DIR: "/attacker/window",
        APPLE_NOTES_MCP_TEMPLATE_DIR: "/attacker/templates",
        APPLE_NOTES_MCP_ANCHOR_FILE: "/attacker/anchors.json",
        APPLE_NOTES_MCP_BACKGROUND_SHORTCUT: "attacker shortcut",
        APPLE_NOTES_MCP_MARKDOWN_SHORTCUT: "attacker shortcut",
        APPLE_NOTES_MCP_TAGS_SHORTCUT: "attacker shortcut",
        APPLE_NOTES_MCP_PASTEBOARD_NAME: "attacker pasteboard",
        APPLE_NOTES_MCP_ANCHORS_TOKEN: "attacker token",
        APPLE_NOTES_MCP_FUTURE_SETTING: "1",
        APPLE_NOTES_MCP_MAX_BUFFER_EXECUTABLE: "/attacker/code",
        APPLE_NOTES_MCP_BROKER: "on",
        APPLE_NOTES_MCP_BROKERED: "1",
        APPLE_NOTES_MCP_BROKER_APP: "/attacker/app",
        APPLE_NOTES_MCP_BROKER_DIR: "/attacker/broker",
        APPLE_NOTES_MCP_BROKER_APP_DIR: "/attacker/apps",
        APPLE_NOTES_MCP_BROKER_AGENT_DIR: "/attacker/agents",
        APPLE_NOTES_MCP_BROKER_SIGN_IDENTITY: "attacker identity",
        APPLE_NOTES_MCP_UNSET: undefined,
        PATH: "/attacker/bin",
        HOME: "/attacker/home",
        NODE_OPTIONS: "--import=/attacker/code.js",
        NODE_PATH: "/attacker/modules",
        DYLD_INSERT_LIBRARIES: "/attacker/code.dylib",
        DYLD_LIBRARY_PATH: "/attacker/libraries",
      })
    ).toEqual({ APPLE_NOTES_MCP_TIMEOUT_MS: "45000" });
  });

  it.each([
    undefined,
    "",
    "0",
    "-1",
    "+1",
    "1.5",
    "1e3",
    " 1000 ",
    "NaN",
    "Infinity",
    "2147483648",
    "1000\0NODE_OPTIONS=--inspect",
    "１",
    "0".repeat(8192) + "1",
  ])("ignores non-positive, non-decimal or oversized numeric values (%j)", (value) => {
    expect(passedEnvironment({ APPLE_NOTES_MCP_TIMEOUT_MS: value })).toEqual({});
  });

  it("accepts the numeric boundaries and ignores inherited object properties", () => {
    const env: NodeJS.ProcessEnv = Object.create({ APPLE_NOTES_MCP_MAX_BUFFER: "1000" });
    env.APPLE_NOTES_MCP_MAX_RETRIES = "1";
    env.APPLE_NOTES_MCP_TIMEOUT_MS = "2147483647";
    env.APPLE_NOTES_MCP_RETRY_DELAY_MS = "00010";
    expect(passedEnvironment(env)).toEqual({
      APPLE_NOTES_MCP_MAX_RETRIES: "1",
      APPLE_NOTES_MCP_TIMEOUT_MS: "2147483647",
      APPLE_NOTES_MCP_RETRY_DELAY_MS: "00010",
    });
  });

  it("keeps the native socket enforcement allowlist identical", () => {
    const swift = readFileSync(
      new URL("../../native/broker/apple-notes-mcp-broker.swift", import.meta.url),
      "utf8"
    );
    const declaration = swift.match(/let passedEnvironmentKeys: Set<String> = \[([\s\S]*?)\]/);
    expect(declaration).not.toBeNull();
    const nativeKeys = [...declaration![1].matchAll(/"(APPLE_NOTES_MCP_[A-Z_]+)"/g)].map(
      (match) => match[1]
    );
    expect(nativeKeys.sort()).toEqual([...BROKER_PASSED_ENV_KEYS].sort());
  });
});

describe("startBrokerProxy", () => {
  it("stays in-process inside the broker, when turned off, or without a broker", async () => {
    const inspect = vi.fn(() => installation());
    for (const env of [{ APPLE_NOTES_MCP_BROKERED: "1" }, { APPLE_NOTES_MCP_BROKER: "off" }]) {
      const { d } = deps({ env, inspect });
      expect(await startBrokerProxy(d)).toBe(false);
    }
    expect(inspect).not.toHaveBeenCalled();
    const { d } = deps({ inspect: () => installation({ installed: false, ready: false }) });
    expect(await startBrokerProxy(d)).toBe(false);
    expect(d.request).not.toHaveBeenCalled();
    const { d: throwing } = deps({
      inspect: () => {
        throw new Error("fs");
      },
    });
    expect(await startBrokerProxy(throwing)).toBe(false);
  });

  it("falls back and records why when the installed broker is not ready", async () => {
    const { d, logs } = deps({
      inspect: () => installation({ ready: false, reason: "broker_stale", detail: "Stale build." }),
    });
    expect(await startBrokerProxy(d)).toBe(false);
    expect(logs[0]).toMatch(/running in-process: Stale build\./);
    expect(brokerStatus({ ...defaultEnvDeps() }).fallbackReason).toBe("Stale build.");
  });

  it("requires a verified runtime manifest before connecting", async () => {
    const { d, logs } = deps({ inspect: () => installation({ manifest: null }) });
    expect(await startBrokerProxy(d)).toBe(false);
    expect(d.request).not.toHaveBeenCalled();
    expect(logs[0]).toContain("no verified runtime manifest");
  });

  it.each([
    { protocolVersion: undefined },
    { protocolVersion: BROKER_PROTOCOL - 1 },
    { packageVersion: undefined },
    { packageVersion: "2.14.3" },
    { entrySha256: undefined },
    { entrySha256: "e".repeat(64) },
  ])("rejects a ready answer from a different runtime (%j)", async (overrides) => {
    const { socket } = fakeSocket();
    const destroy = vi.spyOn(socket, "destroy");
    const { d, output, logs } = deps({
      request: vi.fn(async () => ({
        answer: readyAnswer(overrides),
        socket,
        leftover: Buffer.from("unverified output"),
      })) as unknown as typeof requestBroker,
    });
    expect(await startBrokerProxy(d)).toBe(false);
    expect(destroy).toHaveBeenCalled();
    expect(output).toEqual([]);
    expect(logs[0]).toContain("different server version");
  });

  it("falls back when the broker cannot be reached or refuses", async () => {
    const unreachable = deps({
      request: vi.fn(async () => {
        throw new BrokerUnreachableError("Could not reach the broker.", "ENOENT");
      }) as unknown as typeof requestBroker,
    });
    expect(await startBrokerProxy(unreachable.d)).toBe(false);
    expect(unreachable.logs[0]).toContain("Could not reach the broker.");

    const odd = deps({
      request: vi.fn(async () => {
        throw new Error("weird");
      }) as unknown as typeof requestBroker,
    });
    expect(await startBrokerProxy(odd.d)).toBe(false);
    expect(odd.logs[0]).toContain("unexpected error: Error: weird");

    for (const answer of [
      { type: "error", code: "busy", message: "Too many." },
      { type: "error" },
    ]) {
      const { socket } = fakeSocket();
      const destroy = vi.spyOn(socket, "destroy");
      const refused = deps({
        request: vi.fn(async () => ({
          answer,
          socket,
          leftover: Buffer.alloc(0),
        })) as unknown as typeof requestBroker,
      });
      expect(await startBrokerProxy(refused.d)).toBe(false);
      expect(destroy).toHaveBeenCalled();
      expect(refused.logs[0]).toMatch(/refused the connection/);
    }
  });

  it("relays stdio through the broker after a ready answer", async () => {
    const { socket, sent, remote } = fakeSocket();
    const request = vi.fn(async () => ({
      answer: readyAnswer(),
      socket,
      leftover: Buffer.from("early "),
    }));
    const { d, stdin, output, exit } = deps({
      request: request as unknown as typeof requestBroker,
    });
    expect(await startBrokerProxy(d)).toBe(true);
    expect(request).toHaveBeenCalledWith(
      "/state/broker.sock",
      {
        type: "connect",
        protocolVersion: BROKER_PROTOCOL,
        packageVersion: "2.15.0",
        entrySha256: "d".repeat(64),
        env: { APPLE_NOTES_MCP_TIMEOUT_MS: "45000" },
      },
      BROKER_CONNECT_TIMEOUT_MS
    );
    stdin.write('{"jsonrpc":"2.0","id":1}\n');
    remote('{"jsonrpc":"2.0","id":1,"result":{}}\n');
    await new Promise((r) => setTimeout(r, 10));
    expect(Buffer.concat(sent).toString()).toBe('{"jsonrpc":"2.0","id":1}\n');
    expect(output.join("")).toBe('early {"jsonrpc":"2.0","id":1,"result":{}}\n');
    socket.on("error", () => {});
    socket.emit("error", new Error("reset"));
    socket.destroy();
    await new Promise((r) => setTimeout(r, 10));
    expect(exit).toHaveBeenCalledWith(0);
    expect(exit).toHaveBeenCalledTimes(1);
  });

  it("waits for pending output to drain before exiting", async () => {
    const { socket } = fakeSocket();
    const stdout = new PassThrough() as PassThrough & { writableLength: number };
    Object.defineProperty(stdout, "writableLength", { value: 10 });
    const { d, exit } = deps({
      stdout,
      request: vi.fn(async () => ({
        answer: readyAnswer(),
        socket,
        leftover: Buffer.alloc(0),
      })) as unknown as typeof requestBroker,
    });
    expect(await startBrokerProxy(d)).toBe(true);
    socket.destroy();
    await new Promise((r) => setTimeout(r, 10));
    expect(exit).not.toHaveBeenCalled();
    stdout.emit("drain");
    expect(exit).toHaveBeenCalledWith(0);
  });

  it("exits anyway if pending output never drains", async () => {
    vi.useFakeTimers();
    try {
      const { socket } = fakeSocket();
      const stdout = new PassThrough();
      Object.defineProperty(stdout, "writableLength", { value: 10 });
      const { d, exit } = deps({
        stdout,
        request: vi.fn(async () => ({
          answer: readyAnswer(),
          socket,
          leftover: Buffer.alloc(0),
        })) as unknown as typeof requestBroker,
      });
      expect(await startBrokerProxy(d)).toBe(true);
      socket.emit("close");
      vi.advanceTimersByTime(2000);
      expect(exit).toHaveBeenCalledWith(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("has process-backed defaults", () => {
    const d = defaultBrokerProxyDeps();
    expect(d.stdin).toBe(process.stdin);
    expect(d.stdout).toBe(process.stdout);
    const write = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    d.log("hello");
    expect(write).toHaveBeenCalledWith("[apple-notes-mcp] hello\n");
    write.mockRestore();
    const exit = vi.spyOn(process, "exit").mockImplementation((() => undefined) as never);
    d.exit(3);
    expect(exit).toHaveBeenCalledWith(3);
    exit.mockRestore();
    expect(d.inspect().paths.socketPath).toMatch(/broker\.sock$/);
  });
});

function defaultEnvDeps() {
  // Inspect an empty location so only the recorded fallback matters.
  return {
    env: { APPLE_NOTES_MCP_BROKER_DIR: "/nonexistent-anm-broker" },
    platform: "darwin" as const,
    sourcePath: "/nonexistent",
    entryPath: "/nonexistent",
    execPath: "/nonexistent",
    packageVersion: "0.0.0",
    uid: 501,
    exists: () => false,
    readFile: () => Buffer.alloc(0),
    realpath: (p: string) => p,
    spawn: (() => ({})) as never,
    ping: async () => false,
    sleep: async () => {},
    now: () => new Date(),
  };
}
