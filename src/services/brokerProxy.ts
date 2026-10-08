/**
 * The stdio proxy side of the permission broker.
 *
 * When `setup --broker` has installed a broker and it answers, the process an
 * MCP host launches does not run the server itself. It forwards its stdin and
 * stdout to a server the broker starts, so macOS attributes that server's
 * Notes database reads and Apple events to the broker app instead of the host
 * or this Node binary. The proxy never parses MCP traffic; it moves bytes.
 *
 * If no broker is installed, nothing happens here and the server runs
 * in-process as always. If one is installed but cannot be reached, the server
 * also runs in-process, and doctor reports why.
 *
 * @module services/brokerProxy
 */
import type { Socket } from "node:net";
import {
  BROKER_MODE_ENV,
  BROKER_PROTOCOL,
  BROKERED_ENV,
  inspectBroker,
  recordBrokerFallback,
  type BrokerInstallation,
} from "@/services/broker.js";
import { BrokerUnreachableError, requestBroker } from "@/services/brokerClient.js";

/** How long the proxy waits for the broker before running in-process. */
export const BROKER_CONNECT_TIMEOUT_MS = 5000;

/**
 * Only numeric resource and timing limits may cross the socket. Keep this
 * list in sync with `passedEnvironmentKeys` in the native broker, which must
 * enforce the same policy even for clients that bypass this proxy.
 */
export const BROKER_PASSED_ENV_KEYS = [
  "APPLE_NOTES_MCP_BLOCKS_MAX_BYTES",
  "APPLE_NOTES_MCP_EXPORT_MAX_BYTES",
  "APPLE_NOTES_MCP_MAX_ATTACHMENT_BYTES",
  "APPLE_NOTES_MCP_MAX_BUFFER",
  "APPLE_NOTES_MCP_MAX_INLINE_IMAGE_BYTES",
  "APPLE_NOTES_MCP_MAX_RETRIES",
  "APPLE_NOTES_MCP_PRIVATE_HELPER_TIMEOUT_MS",
  "APPLE_NOTES_MCP_PUBLIC_HELPER_TIMEOUT_MS",
  "APPLE_NOTES_MCP_RETRY_DELAY_MS",
  "APPLE_NOTES_MCP_TIMEOUT_MS",
] as const;

const passedEnvironmentKeys: ReadonlySet<string> = new Set(BROKER_PASSED_ENV_KEYS);
const MAX_PASSED_VALUE = 2_147_483_647;
const MAX_VARIABLE_BYTES = 8192;

export interface BrokerProxyDeps {
  env: NodeJS.ProcessEnv;
  inspect: () => BrokerInstallation;
  request: typeof requestBroker;
  stdin: NodeJS.ReadableStream;
  stdout: NodeJS.WritableStream & { writableLength?: number };
  exit: (code: number) => void;
  log: (message: string) => void;
}

export function defaultBrokerProxyDeps(overrides: Partial<BrokerProxyDeps> = {}): BrokerProxyDeps {
  return {
    env: process.env,
    inspect: () => inspectBroker(),
    request: requestBroker,
    stdin: process.stdin,
    stdout: process.stdout,
    exit: (code) => process.exit(code),
    log: (message) => process.stderr.write(`[apple-notes-mcp] ${message}\n`),
    ...overrides,
  };
}

/**
 * The client's harmless numeric settings that travel to the brokered server.
 * Paths, executable/helper choices, safety overrides and unknown future
 * settings never travel over the socket. The native broker repeats this
 * allowlist check; a same-user client must not choose privileged server code.
 */
export function passedEnvironment(env: NodeJS.ProcessEnv): Record<string, string> {
  const passed: Record<string, string> = {};
  for (const [key, value] of Object.entries(env)) {
    if (
      !passedEnvironmentKeys.has(key) ||
      typeof value !== "string" ||
      value.length > MAX_VARIABLE_BYTES ||
      !/^[0-9]+$/.test(value)
    )
      continue;
    const numeric = Number(value);
    if (!Number.isInteger(numeric) || numeric < 1 || numeric > MAX_PASSED_VALUE) continue;
    passed[key] = value;
  }
  return passed;
}

/**
 * Hand this process's stdio to the broker when one is installed and answers.
 * Resolves true once the proxy is running (the process then lives until
 * either side closes), or false to run the server in-process.
 */
export async function startBrokerProxy(
  deps: BrokerProxyDeps = defaultBrokerProxyDeps()
): Promise<boolean> {
  if (deps.env[BROKERED_ENV] === "1" || deps.env[BROKER_MODE_ENV] === "off") return false;
  let installation: BrokerInstallation;
  try {
    installation = deps.inspect();
  } catch {
    return false;
  }
  if (!installation.installed) return false;
  const fallBack = (reason: string): false => {
    recordBrokerFallback(reason);
    deps.log(`Permission broker not used, running in-process: ${reason}`);
    return false;
  };
  if (!installation.ready) return fallBack(installation.detail ?? "the broker is not ready.");
  const manifest = installation.manifest;
  if (!manifest) return fallBack("the broker has no verified runtime manifest.");

  let socket: Socket;
  let leftover: Buffer;
  try {
    const result = await deps.request(
      installation.paths.socketPath,
      {
        type: "connect",
        protocolVersion: BROKER_PROTOCOL,
        packageVersion: manifest.packageVersion,
        entrySha256: manifest.entrySha256,
        env: passedEnvironment(deps.env),
      },
      BROKER_CONNECT_TIMEOUT_MS
    );
    if (result.answer.type !== "ready") {
      result.socket.destroy();
      const message =
        typeof result.answer.message === "string" ? result.answer.message : "no reason given";
      return fallBack(`the broker refused the connection (${message})`);
    }
    if (
      result.answer.protocolVersion !== BROKER_PROTOCOL ||
      result.answer.packageVersion !== manifest.packageVersion ||
      result.answer.entrySha256 !== manifest.entrySha256
    ) {
      result.socket.destroy();
      return fallBack(
        "the running broker serves a different server version. Run `apple-notes-mcp setup --broker` again."
      );
    }
    socket = result.socket;
    leftover = result.leftover;
  } catch (error) {
    return fallBack(
      error instanceof BrokerUnreachableError ? error.message : `unexpected error: ${String(error)}`
    );
  }

  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    // Let a pending response reach the client before exiting.
    if ((deps.stdout.writableLength ?? 0) > 0) {
      const timer = setTimeout(() => deps.exit(0), 2000);
      deps.stdout.once("drain", () => {
        clearTimeout(timer);
        deps.exit(0);
      });
    } else {
      deps.exit(0);
    }
  };
  if (leftover.length > 0) deps.stdout.write(leftover);
  socket.pipe(deps.stdout, { end: false });
  deps.stdin.pipe(socket);
  socket.on("error", (error) => deps.log(`Broker connection error: ${error.message}`));
  socket.on("close", finish);
  socket.resume();
  return true;
}
