/**
 * Socket client for the permission broker (see {@link module:services/broker}).
 *
 * The broker reads exactly one JSON request line per connection and answers
 * with one JSON line. After a `ready` answer to `connect`, the same connection
 * carries the MCP stdio stream to and from the server the broker started.
 *
 * @module services/brokerClient
 */
import { connect as netConnect, type Socket } from "node:net";

export interface BrokerAnswer {
  /** The parsed first line from the broker. */
  answer: Record<string, unknown>;
  socket: Socket;
  /** Bytes that arrived after the answer line; they belong to the stream. */
  leftover: Buffer;
}

export class BrokerUnreachableError extends Error {
  constructor(
    message: string,
    readonly code: string
  ) {
    super(message);
    this.name = "BrokerUnreachableError";
  }
}

const MAX_ANSWER_BYTES = 65_536;

/**
 * Connect, send one request line, and wait for the answer line. The socket is
 * left open and paused for the caller; it is destroyed on any failure.
 */
export function requestBroker(
  socketPath: string,
  request: Record<string, unknown>,
  timeoutMs: number,
  connect: (path: string) => Socket = (path) => netConnect(path)
): Promise<BrokerAnswer> {
  return new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    let buffered = Buffer.alloc(0);
    let settled = false;
    const fail = (message: string, code: string) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      reject(new BrokerUnreachableError(message, code));
    };
    const timer = setTimeout(
      () => fail(`The broker did not answer within ${timeoutMs} ms.`, "timeout"),
      timeoutMs
    );
    socket.once("connect", () => {
      socket.write(JSON.stringify(request) + "\n");
    });
    socket.on("error", (error: NodeJS.ErrnoException) =>
      fail(`Could not reach the broker at ${socketPath}: ${error.message}`, error.code ?? "error")
    );
    socket.on("close", () => fail("The broker closed the connection without answering.", "closed"));
    const onData = (chunk: Buffer) => {
      buffered = Buffer.concat([buffered, chunk]);
      const newline = buffered.indexOf(0x0a);
      if (newline < 0) {
        if (buffered.length > MAX_ANSWER_BYTES)
          fail("The broker's answer was too long.", "bad_answer");
        return;
      }
      let answer: unknown;
      try {
        answer = JSON.parse(buffered.subarray(0, newline).toString("utf8"));
      } catch {
        fail("The broker's answer was not JSON.", "bad_answer");
        return;
      }
      if (!answer || typeof answer !== "object") {
        fail("The broker's answer was not a JSON object.", "bad_answer");
        return;
      }
      settled = true;
      clearTimeout(timer);
      socket.off("data", onData);
      socket.removeAllListeners("close");
      socket.removeAllListeners("error");
      socket.pause();
      resolve({
        answer: answer as Record<string, unknown>,
        socket,
        leftover: buffered.subarray(newline + 1),
      });
    };
    socket.on("data", onData);
  });
}

/** True when a broker answers `ping` on this socket with a pong. */
export async function pingBroker(socketPath: string, timeoutMs = 1500): Promise<boolean> {
  try {
    const { answer, socket } = await requestBroker(socketPath, { type: "ping" }, timeoutMs);
    socket.destroy();
    return answer.type === "pong";
  } catch {
    return false;
  }
}
