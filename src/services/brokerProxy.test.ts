import { Duplex, PassThrough } from "node:stream";
import type { Socket } from "node:net";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  brokerPaths,
  brokerStatus,
  recordBrokerFallback,
  type BrokerInstallation,
} from "@/services/broker.js";
import { BrokerUnreachableError, type requestBroker } from "@/services/brokerClient.js";
import {
  BROKER_CONNECT_TIMEOUT_MS,
  defaultBrokerProxyDeps,
  passedEnvironment,
  startBrokerProxy,
  type BrokerProxyDeps,
} from "@/services/brokerProxy.js";

function installation(overrides: Partial<BrokerInstallation> = {}): BrokerInstallation {
  return {
    installed: true,
    ready: true,
    reason: null,
    detail: null,
    paths: brokerPaths({ APPLE_NOTES_MCP_BROKER_DIR: "/state" }),
    manifest: null,
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
    env: { APPLE_NOTES_MCP_DEFAULT_FOLDER: "Work" },
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
  it("passes APPLE_NOTES_MCP_* settings but not broker controls or anything else", () => {
    expect(
      passedEnvironment({
        APPLE_NOTES_MCP_DEFAULT_FOLDER: "Work",
        APPLE_NOTES_MCP_BROKER: "on",
        APPLE_NOTES_MCP_BROKERED: "1",
        APPLE_NOTES_MCP_UNSET: undefined,
        PATH: "/bin",
        NODE_OPTIONS: "--inspect",
      })
    ).toEqual({ APPLE_NOTES_MCP_DEFAULT_FOLDER: "Work" });
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
      answer: { type: "ready", pid: 9 },
      socket,
      leftover: Buffer.from("early "),
    }));
    const { d, stdin, output, exit } = deps({
      request: request as unknown as typeof requestBroker,
    });
    expect(await startBrokerProxy(d)).toBe(true);
    expect(request).toHaveBeenCalledWith(
      "/state/broker.sock",
      { type: "connect", protocolVersion: 1, env: { APPLE_NOTES_MCP_DEFAULT_FOLDER: "Work" } },
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
        answer: { type: "ready" },
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
          answer: { type: "ready" },
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
