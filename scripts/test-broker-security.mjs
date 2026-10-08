#!/usr/bin/env node
/**
 * Isolated macOS security regression checks for the native permission broker.
 * Run: node scripts/test-broker-security.mjs
 *
 * Uses temporary, ad-hoc signed app bundles and a tiny C echo runtime. It does
 * not run the Notes server, install a LaunchAgent, inspect signing identities,
 * request TCC permissions, or access any installed broker or Notes data.
 * Requires macOS and the Xcode command-line tools. No npm dependencies needed.
 */
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import {
  appendFileSync,
  copyFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createConnection } from "node:net";
import { userInfo } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

if (process.platform !== "darwin") {
  console.log("SKIP: native broker security checks require macOS.");
  process.exit(0);
}
if (process.argv.length !== 2) {
  console.error("usage: node scripts/test-broker-security.mjs");
  process.exit(64);
}

const root = dirname(dirname(fileURLToPath(import.meta.url)));
// A short, canonical path also stays below Darwin's Unix socket path limit.
const temporary = realpathSync(mkdtempSync("/tmp/anmb-security-"));
const source = join(root, "native/broker/apple-notes-mcp-broker.swift");
const sourceSha256 = sha256(readFileSync(source));
const compiledBroker = join(temporary, "broker");
const compiledRuntime = join(temporary, "echo-runtime");
const injectionLibrary = join(temporary, "injection.dylib");
const injectionMarker = join(temporary, "dyld-loaded");
const injectionSource = join(temporary, "injection.c");
const diagnosticFixtures = [];
let positiveControlRecords;
const brokers = new Set();
const connections = new Set();
const refusedExecutionCounts = new Map();
let fixtureNumber = 0;
let checks = 0;
let cleaningUp;

const numericKeys = [
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
];

mkdirSync(join(temporary, "home"));
mkdirSync(join(temporary, "tmp"));
const cleanEnvironment = {
  PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
  HOME: join(temporary, "home"),
  TMPDIR: `${join(temporary, "tmp")}/`,
  LANG: "en_US.UTF-8",
};
const hostileEnvironment = {
  APPLE_NOTES_MCP_CONFIG_FILE: join(temporary, "untrusted-config.json"),
  APPLE_NOTES_MCP_PUBLIC_HELPER_DIR: join(temporary, "untrusted-public"),
  APPLE_NOTES_MCP_PRIVATE_HELPER_DIR: join(temporary, "untrusted-private"),
  APPLE_NOTES_MCP_PERMISSIONS_WINDOW_DIR: join(temporary, "untrusted-window"),
  APPLE_NOTES_MCP_PRIVATE_STORE: join(temporary, "untrusted-store"),
  APPLE_NOTES_MCP_ENABLE_PRIVATE: "1",
  APPLE_NOTES_MCP_ALLOW_PRIVATE_CONTENT_PATHS: "1",
  APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "1",
  APPLE_NOTES_MCP_BACKGROUND_SHORTCUT: "untrusted-shortcut",
  APPLE_NOTES_MCP_MARKDOWN_SHORTCUT: "untrusted-shortcut",
  APPLE_NOTES_MCP_TAGS_SHORTCUT: "untrusted-shortcut",
  APPLE_NOTES_MCP_DEFAULT_FOLDER: "untrusted-folder",
  APPLE_NOTES_MCP_TEMPLATE_DIR: join(temporary, "untrusted-templates"),
  APPLE_NOTES_MCP_ANCHOR_FILE: join(temporary, "untrusted-anchors.json"),
  APPLE_NOTES_MCP_PASTEBOARD_NAME: "untrusted-pasteboard",
  APPLE_NOTES_MCP_BROKER: "off",
  APPLE_NOTES_MCP_BROKERED: "untrusted",
  APPLE_NOTES_MCP_BROKER_APP: join(temporary, "Untrusted.app"),
  APPLE_NOTES_MCP_BROKER_DIR: join(temporary, "untrusted-state"),
  APPLE_NOTES_MCP_BROKER_SIGN_IDENTITY: "untrusted-identity",
  APPLE_NOTES_MCP_UNKNOWN_FUTURE_SETTING: "untrusted",
  NODE_OPTIONS: "--require=/nonexistent/broker-security-fixture.js",
  NODE_PATH: join(temporary, "untrusted-node-modules"),
  DYLD_INSERT_LIBRARIES: injectionLibrary,
  DYLD_LIBRARY_PATH: temporary,
  DYLD_FRAMEWORK_PATH: temporary,
  DYLD_FALLBACK_LIBRARY_PATH: temporary,
  LD_PRELOAD: injectionLibrary,
  HOME: cleanEnvironment.HOME,
  TMPDIR: cleanEnvironment.TMPDIR,
  USER: "untrusted-user",
  LOGNAME: "untrusted-user",
  PATH: join(temporary, "untrusted-bin"),
  SHELL: "/untrusted-shell",
  LANG: "untrusted-language",
  LC_ALL: "untrusted-locale",
  __CFBundleIdentifier: "untrusted.bundle",
};

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function command(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    env: cleanEnvironment,
    cwd: temporary,
    encoding: "utf8",
    timeout: 120_000,
    maxBuffer: 4 * 1024 * 1024,
    ...options,
  });
  if (result.error) throw result.error;
  assert.equal(
    result.status,
    0,
    `${executable} failed (${result.status}, ${result.signal}):\n${result.stderr}\n${result.stdout}`
  );
  return result;
}

async function check(name, action) {
  await action();
  checks += 1;
  console.log(`ok ${checks}: ${name}`);
}

function compileFixtures() {
  console.log("Compiling isolated broker and harmless runtime fixtures...");
  const digestFile = join(temporary, "source-digest.swift");
  writeFileSync(digestFile, `let helperSourceSHA256 = ${JSON.stringify(sourceSha256)}\n`);
  command("/usr/bin/xcrun", [
    "swiftc",
    "-O",
    "-parse-as-library",
    "-module-cache-path",
    join(temporary, "module-cache"),
    source,
    digestFile,
    "-o",
    compiledBroker,
  ]);
  // This runtime treats the sealed JavaScript path only as an argument. Its
  // only filesystem write is a launch marker beside its own temporary binary.
  const cSource = join(temporary, "runtime.c");
  writeFileSync(
    cSource,
    String.raw`
#include <limits.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
extern char **environ;
extern int csops(pid_t, unsigned int, void *, size_t);
static void json_string(const char *s) {
  putchar('"');
  for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
    if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
    else if (*p < 0x20) printf("\\u%04x", *p);
    else putchar(*p);
  }
  putchar('"');
}
static int write_bytes(int fd, const unsigned char *bytes, size_t length) {
  while (length) {
    ssize_t count = write(fd, bytes, length);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return 0;
    bytes += count; length -= count;
  }
  return 1;
}
int main(int argc, char **argv) {
  if (fcntl(STDIN_FILENO, F_GETFL) & O_NONBLOCK) return 6;
  char marker[PATH_MAX], cwd[PATH_MAX], line[1024];
  if (snprintf(marker, sizeof(marker), "%s.spawned", argv[0]) >= sizeof(marker)) return 2;
  FILE *f = fopen(marker, "a");
  if (!f) return 3;
  fputs("spawn\n", f); fclose(f);
  if (!fgets(line, sizeof(line), stdin)) return 0;
  if (strstr(line, "signal-exit")) { raise(SIGTERM); return 99; }
  if (strstr(line, "halfclose")) {
    while (getchar() != EOF) {}
    fputs("final stdout after stdin EOF\n", stdout);
    fputs("final stderr after stdin EOF\n", stderr);
    return 7;
  }
  if (strstr(line, "binary") || strstr(line, "stderr-only") || strstr(line, "flood")) {
    unsigned char out[4096], err[4096];
    for (int i = 0; i < 4096; ++i) { out[i] = i % 256; err[i] = 255 - (i % 256); }
    if (strstr(line, "stderr-only")) {
      close(STDOUT_FILENO);
      if (!write_bytes(STDERR_FILENO, err, sizeof(err))) return 4;
      return 17;
    }
    for (int i = 0; i < 64 || strstr(line, "flood"); ++i) {
      if (!write_bytes(STDOUT_FILENO, out, sizeof(out)) ||
          !write_bytes(STDERR_FILENO, err, sizeof(err))) return 4;
    }
    return 23;
  }
  if (strstr(line, "hold") || strstr(line, "orphan")) {
    pid_t descendant = fork();
    if (descendant < 0) return 5;
    if (descendant == 0) { for (;;) pause(); }
    printf("{\"child\":%d,\"grandchild\":%d}\n", getpid(), descendant); fflush(stdout);
    if (strstr(line, "orphan")) return 0;
    for (;;) pause();
  }
  fputs("{\"argv\":[", stdout);
  for (int i = 0; i < argc; i++) { if (i) putchar(','); json_string(argv[i]); }
  fputs("],\"cwd\":", stdout);
  json_string(getcwd(cwd, sizeof(cwd)) ? cwd : "");
  uint32_t flags = 0;
  errno = 0;
  int cs_status = csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof(flags));
  int cs_errno = errno;
  printf(",\"codeSigning\":{\"pid\":%d,\"ppid\":%d,\"csopsStatus\":%d,\"csopsErrno\":%d,\"csopsFlags\":%u}",
         getpid(), getppid(), cs_status, cs_errno, flags);
  fputs(",\"env\":{", stdout);
  int first = 1;
  for (char **e = environ; *e; ++e) {
    char *copy = strdup(*e), *equals = strchr(copy, '=');
    if (equals) {
      *equals = 0;
      if (!first) putchar(','); first = 0;
      json_string(copy); putchar(':'); json_string(equals + 1);
    }
    free(copy);
  }
  fputs("}}\n", stdout); fflush(stdout);
  return 0;
}
`
  );
  command("/usr/bin/xcrun", ["clang", "-O2", cSource, "-o", compiledRuntime]);
  writeFileSync(
    injectionSource,
    `#define INJECTION_MARKER ${JSON.stringify(injectionMarker)}\n` +
      String.raw`
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/types.h>
#include <unistd.h>
extern int csops(pid_t, unsigned int, void *, size_t);
static void json_string(FILE *f, const char *s) {
  fputc('"', f);
  for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
    if (*p == '"' || *p == '\\') { fputc('\\', f); fputc(*p, f); }
    else if (*p < 0x20) fprintf(f, "\\u%04x", *p);
    else fputc(*p, f);
  }
  fputc('"', f);
}
__attribute__((constructor)) static void injected(void) {
  char executable[PATH_MAX] = "";
  uint32_t size = sizeof(executable), flags = 0;
  int path_status = _NSGetExecutablePath(executable, &size);
  errno = 0;
  int cs_status = csops(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof(flags));
  int cs_errno = errno;
  FILE *f = fopen(INJECTION_MARKER, "a");
  if (!f) return;
  flock(fileno(f), LOCK_EX);
  fprintf(f, "{\"pid\":%d,\"ppid\":%d,\"executable\":", getpid(), getppid());
  json_string(f, path_status == 0 ? executable : "<path unavailable>");
  fprintf(f, ",\"executablePathStatus\":%d,\"csopsStatus\":%d,\"csopsErrno\":%d,\"csopsFlags\":%u}\n",
          path_status, cs_status, cs_errno, flags);
  fflush(f);
  flock(fileno(f), LOCK_UN);
  fclose(f);
}
`
  );
  command("/usr/bin/xcrun", ["clang", "-dynamiclib", injectionSource, "-o", injectionLibrary]);
}

function fixture({ hardened = true, entitlement } = {}) {
  const directory = join(temporary, `case-${++fixtureNumber}`);
  const app = join(directory, "Broker.app");
  const resources = join(app, "Contents/Resources");
  const executable = join(app, "Contents/MacOS/apple-notes-mcp-broker");
  const runtime = join(directory, "runtime");
  const entry = join(resources, "server/build/index.js");
  mkdirSync(dirname(executable), { recursive: true });
  mkdirSync(dirname(entry), { recursive: true });
  copyFileSync(compiledBroker, executable);
  copyFileSync(compiledRuntime, runtime);
  writeFileSync(
    join(app, "Contents/Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.apple-notes-mcp.broker-security</string>
<key>CFBundleExecutable</key><string>apple-notes-mcp-broker</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>\n`
  );
  writeFileSync(
    entry,
    `// Harmless sealed entry fixture; no Notes code is imported.
import { createInterface } from "node:readline";
createInterface({ input: process.stdin }).once("line", () => {
  console.log(JSON.stringify({ argv: process.argv, env: process.env }));
  process.exit(0);
});\n`
  );
  writeFileSync(
    join(resources, "server/package.json"),
    JSON.stringify({
      name: "apple-notes-mcp",
      version: "fixture",
      type: "module",
    })
  );
  writeFileSync(join(resources, "config.json"), "{}\n");
  const config = {
    schemaVersion: 1,
    nodePath: runtime,
    nodeSha256: sha256(readFileSync(runtime)),
    packageVersion: "fixture",
    entrySha256: sha256(readFileSync(entry)),
  };
  const configPath = join(resources, "broker-config.json");
  writeFileSync(configPath, `${JSON.stringify(config)}\n`);
  const signArgs = ["--force", "--sign", "-"];
  if (hardened) signArgs.push("--options", "runtime");
  if (entitlement) {
    const entitlements = join(directory, "entitlements.plist");
    writeFileSync(
      entitlements,
      `<plist version="1.0"><dict><key>${entitlement}</key><true/></dict></plist>\n`
    );
    signArgs.push("--entitlements", entitlements);
  }
  command("/usr/bin/codesign", [...signArgs, app]);
  command("/usr/bin/codesign", ["--verify", "--strict", app]);
  diagnosticFixtures.push({ app, hardened, entitlement });
  return {
    directory,
    app,
    resources,
    executable,
    runtime,
    entry,
    configPath,
    config,
    socket: join(directory, "socket"),
    marker: `${runtime}.spawned`,
  };
}

function hello(fx, args = [], environment = cleanEnvironment) {
  return spawnSync(fx.executable, args, {
    env: environment,
    cwd: temporary,
    input: '{"type":"hello"}\n',
    encoding: "utf8",
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
  });
}

function assertRefusedStartup(fx, label, args = []) {
  const invocations = args.length ? [args] : [[], ["serve", "--socket", fx.socket]];
  for (const invocation of invocations) {
    const result = hello(fx, invocation);
    assert.ifError(result.error);
    assert.notEqual(result.status, 0, `${label} unexpectedly started`);
    assert.equal(result.signal, null, `${label} crashed instead of refusing: ${result.stderr}`);
    assert.equal(result.stdout.trim(), "", `${label} advertised a trusted hello`);
    assert.equal(existsSync(fx.socket), false, `${label} opened a listening socket`);
    assert.equal(existsSync(fx.marker), false, `${label} launched its runtime`);
  }
}

async function openConnection(path) {
  const socket = createConnection({ path, allowHalfOpen: true });
  connections.add(socket);
  let buffer = Buffer.alloc(0);
  let framed = false;
  let ended;
  const messages = [];
  const waiting = [];
  const finish = (error) => {
    ended ??= error;
    for (const waiter of waiting.splice(0)) waiter.reject(ended);
  };
  const deliver = (value) => {
    const waiter = waiting.shift();
    if (waiter) waiter.resolve(value);
    else messages.push(value);
  };
  socket.on("data", (data) => {
    buffer = Buffer.concat([buffer, data]);
    if (buffer.length > 1024 * 1024) {
      socket.destroy(new Error("fixture response exceeded 1 MiB"));
      return;
    }
    try {
      while (buffer.length) {
        if (!framed) {
          const newline = buffer.indexOf(10);
          if (newline < 0) return;
          const answer = JSON.parse(buffer.subarray(0, newline).toString());
          buffer = buffer.subarray(newline + 1);
          framed = answer.type === "ready";
          deliver(answer);
        } else {
          if (buffer.length < 5) return;
          const channel = buffer[0],
            length = buffer.readUInt32BE(1);
          assert.ok(channel >= 1 && channel <= 3, "unknown native output channel");
          assert.ok(length > 0 && length <= 65536, "unbounded native output frame");
          if (channel === 3) assert.equal(length, 4);
          if (buffer.length < 5 + length) return;
          const payload = Buffer.from(buffer.subarray(5, 5 + length));
          buffer = buffer.subarray(5 + length);
          deliver({ channel, payload });
        }
      }
    } catch (error) {
      socket.destroy(error);
    }
  });
  socket.on("error", finish);
  socket.on("end", () => finish(new Error("broker ended before the expected response")));
  socket.on("close", () => {
    connections.delete(socket);
    finish(new Error("broker closed the socket before the expected response"));
  });
  await once(socket, "connect");
  return {
    socket,
    write(value) {
      socket.write(`${JSON.stringify(value)}\n`);
    },
    async read() {
      if (messages.length) return messages.shift();
      if (ended) throw ended;
      return await new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => socket.destroy(new Error("timed out waiting for a broker response")),
          10_000
        );
        waiting.push({
          resolve(value) {
            clearTimeout(timer);
            resolve(value);
          },
          reject(error) {
            clearTimeout(timer);
            reject(error);
          },
        });
      });
    },
  };
}

async function outputUntilExit(connection) {
  const stdout = [],
    stderr = [];
  while (true) {
    const frame = await connection.read();
    if (frame.channel === 3) {
      const status = frame.payload.readUInt32BE();
      assert.ok(status <= 255);
      return { stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr), status };
    }
    (frame.channel === 1 ? stdout : stderr).push(frame.payload);
  }
}

async function readyConnection(fx) {
  const connection = await openConnection(fx.socket);
  connection.write(connectRequest(fx));
  const answer = await connection.read();
  assert.equal(answer.type, "ready", JSON.stringify(answer));
  assert.equal(answer.protocolVersion, 3);
  assert.equal(answer.packageVersion, "fixture");
  assert.equal(answer.entrySha256, fx.config.entrySha256);
  return { ...connection, pid: answer.pid };
}

async function request(fx, value, echo = false) {
  const connection = await openConnection(fx.socket);
  try {
    connection.write(value);
    const answer = await connection.read();
    if (!echo) return answer;
    assert.equal(answer.type, "ready", JSON.stringify(answer));
    assert.equal(answer.protocolVersion, 3);
    assert.equal(answer.packageVersion, "fixture");
    assert.equal(answer.entrySha256, fx.config.entrySha256);
    connection.write({ echo: true });
    const output = await outputUntilExit(connection);
    assert.equal(output.status, 0);
    assert.equal(output.stderr.length, 0);
    return JSON.parse(output.stdout.toString());
  } finally {
    connection.socket.destroy();
  }
}

async function waitFor(condition, label, timeout = 3000) {
  const deadline = Date.now() + timeout;
  while (!(await condition())) {
    assert.ok(Date.now() < deadline, `timed out: ${label}`);
    await delay(20);
  }
}

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    throw error;
  }
}

async function heldProcesses(connection, mode) {
  connection.write({ mode });
  let line = Buffer.alloc(0);
  while (!line.includes(10)) {
    const frame = await connection.read();
    assert.equal(frame.channel, 1);
    line = Buffer.concat([line, frame.payload]);
  }
  const pids = JSON.parse(line.toString());
  assert.equal(pids.child, connection.pid);
  assert.ok(pids.grandchild > 1);
  return pids;
}

async function assertProcessesGone(pids) {
  await waitFor(
    () => Object.values(pids).every((pid) => !processExists(pid)),
    "fixture children reaped",
    5000
  );
}

function connectRequest(fx, env = {}, overrides = {}) {
  return {
    type: "connect",
    protocolVersion: 3,
    packageVersion: "fixture",
    entrySha256: fx.config.entrySha256,
    env,
    ...overrides,
  };
}

async function start(fx, environment = cleanEnvironment) {
  const child = spawn(fx.executable, ["serve", "--socket", fx.socket], {
    env: environment,
    cwd: temporary,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const broker = { child, output: "", exited: false };
  brokers.add(broker);
  const capture = (data) => {
    broker.output = `${broker.output}${data}`.slice(-16_384);
  };
  child.stdout.on("data", capture);
  child.stderr.on("data", capture);
  broker.done = new Promise((resolve) => {
    child.once("exit", () => {
      broker.exited = true;
      resolve();
    });
    child.once("error", (error) => {
      broker.exited = true;
      capture(error.message);
      resolve();
    });
  });
  const deadline = Date.now() + 10_000;
  let pong;
  while (!pong) {
    assert.equal(broker.exited, false, `broker exited during startup:\n${broker.output}`);
    assert.ok(Date.now() < deadline, `broker did not listen:\n${broker.output}`);
    if (existsSync(fx.socket)) {
      try {
        pong = await request(fx, { type: "ping" });
        break;
      } catch (error) {
        // bind() creates the path before listen() can accept a connection.
        if (!["ECONNREFUSED", "ENOENT"].includes(error.code)) throw error;
      }
    }
    await delay(25);
  }
  assert.equal(pong.type, "pong");
  assert.equal(pong.protocolVersion, 3);
  assert.equal(pong.sourceSha256, sourceSha256);
  assert.equal(pong.packageVersion, "fixture");
  assert.equal(pong.entrySha256, fx.config.entrySha256);
  return broker;
}

async function stop(broker) {
  // Ask the broker to cancel and reap its separate session process groups.
  // The outer process-group kill is only an emergency fixture cleanup.
  function signal(name) {
    if (!broker.child.pid) return;
    try {
      process.kill(-broker.child.pid, name);
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
  signal("SIGTERM");
  await Promise.race([broker.done, delay(1000)]);
  if (!broker.exited) {
    signal("SIGKILL");
    await broker.done;
  }
  brokers.delete(broker);
}

function launchCount(fx) {
  return existsSync(fx.marker) ? readFileSync(fx.marker, "utf8") : "";
}

async function assertNoSpawn(fx, value, code) {
  const before = launchCount(fx);
  const answer = await request(fx, value);
  assert.equal(answer.type, "error", JSON.stringify(answer));
  assert.equal(answer.code, code);
  // An incorrectly executed child may be scheduled after the error response.
  // These markers detect fixture execution; the error protocol assertion is
  // separate. Check cumulatively again before stopping each broker and at end.
  await delay(150);
  assert.equal(launchCount(fx), before, "refused request executed the runtime fixture");
  refusedExecutionCounts.set(fx, before);
}

function assertNoUnexpectedExecution() {
  for (const [fx, expected] of refusedExecutionCounts) {
    assert.equal(launchCount(fx), expected, "a refused request executed the runtime fixture later");
  }
}

function markerRecords(path = injectionMarker) {
  return existsSync(path) ? readFileSync(path, "utf8") : null;
}

function assertInjectionAbsent(stage) {
  assert.equal(
    existsSync(injectionMarker),
    false,
    `the injected dylib constructor ran ${stage}: ${markerRecords()}`
  );
}

function diagnosticCommand(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    env: cleanEnvironment,
    cwd: temporary,
    encoding: "utf8",
    timeout: 10_000,
    maxBuffer: 128 * 1024,
    ...options,
  });
  return {
    command: [executable, ...args],
    status: result.status,
    signal: result.signal,
    error: result.error?.message,
    stdout: result.stdout?.slice(-16_384),
    stderr: result.stderr?.slice(-16_384),
  };
}

async function detachedDiagnostic(executable, env) {
  const child = spawn(executable, [], {
    cwd: temporary,
    env,
    detached: true,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const processRecord = { child, exited: false };
  const result = { pid: child.pid, stdout: "", stderr: "" };
  brokers.add(processRecord);
  child.stdout.on("data", (data) => {
    result.stdout = `${result.stdout}${data}`.slice(-16_384);
  });
  child.stderr.on("data", (data) => {
    result.stderr = `${result.stderr}${data}`.slice(-16_384);
  });
  child.stdin.on("error", (error) => {
    result.stdinError = error.message;
  });
  processRecord.done = new Promise((resolve) => {
    child.once("error", (error) => {
      result.error = error.message;
      processRecord.exited = true;
      resolve();
    });
    child.once("close", (status, signal) => {
      result.status = status;
      result.signal = signal;
      processRecord.exited = true;
      resolve();
    });
  });
  child.stdin.end("{}\n");
  try {
    let timer;
    await Promise.race([
      processRecord.done,
      new Promise((resolve) => {
        timer = setTimeout(() => {
          result.error = "control timed out after 10 seconds";
          resolve();
        }, 10_000);
      }),
    ]);
    clearTimeout(timer);
    return result;
  } finally {
    await stop(processRecord);
  }
}

async function reportFailureDiagnostics() {
  // Preserve the broker's marker. Independent probes use a separately compiled
  // dylib/marker and run only after the original security assertion has failed.
  const report = {
    node: process.version,
    architecture: process.arch,
    positiveControlRecords,
    brokerInjectionRecords: markerRecords(),
    fixtures: diagnosticFixtures,
    system: [
      diagnosticCommand("/usr/bin/sw_vers", []),
      diagnosticCommand("/usr/bin/uname", ["-mrs"]),
      diagnosticCommand("/usr/sbin/sysctl", ["-n", "kern.bootargs"]),
      diagnosticCommand("/usr/bin/csrutil", ["status"]),
    ],
  };
  if (diagnosticFixtures.length) {
    report.brokerSignature = diagnosticCommand("/usr/bin/codesign", [
      "-d",
      "--verbose=4",
      "--entitlements",
      ":-",
      diagnosticFixtures[0].app,
    ]);
  }
  if (report.brokerInjectionRecords && existsSync(compiledRuntime) && existsSync(injectionSource)) {
    const control = join(temporary, "hardened-control");
    const controlSource = join(temporary, "control-injection.c");
    const controlLibrary = join(temporary, "control-injection.dylib");
    const controlMarker = join(temporary, "control-dyld-loaded");
    copyFileSync(compiledRuntime, control);
    writeFileSync(
      controlSource,
      readFileSync(injectionSource, "utf8").replace(
        /^#define INJECTION_MARKER .*$/m,
        `#define INJECTION_MARKER ${JSON.stringify(controlMarker)}`
      )
    );
    report.controlSetup = [
      diagnosticCommand("/usr/bin/codesign", [
        "--force",
        "--sign",
        "-",
        "--options",
        "runtime",
        control,
      ]),
      diagnosticCommand("/usr/bin/xcrun", [
        "clang",
        "-dynamiclib",
        controlSource,
        "-o",
        controlLibrary,
      ]),
      diagnosticCommand("/usr/bin/codesign", [
        "-d",
        "--verbose=4",
        "--entitlements",
        ":-",
        control,
      ]),
    ];
    if (report.controlSetup.every((result) => result.status === 0)) {
      const env = { ...cleanEnvironment, DYLD_INSERT_LIBRARIES: controlLibrary };
      report.synchronousHardenedControl = diagnosticCommand(control, [], { env, input: "{}\n" });
      report.synchronousHardenedControl.injectionRecords = markerRecords(controlMarker);
      rmSync(controlMarker, { force: true });
      report.detachedHardenedControl = await detachedDiagnostic(control, env);
      report.detachedHardenedControl.injectionRecords = markerRecords(controlMarker);
    }
  }
  console.error(
    `Native broker failure diagnostics (read-only host queries; ephemeral controls):\n${JSON.stringify(report, null, 2)}`
  );
}

function assertEnvironment(fx, actual, expectedNumeric = {}) {
  assert.deepEqual(actual.argv, [fx.runtime, fx.entry]);
  assert.equal(actual.cwd, join(fx.resources, "server"));
  const controlled = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    LANG: "en_US.UTF-8",
    SHELL: "/bin/sh",
    HOME: userInfo().homedir,
    USER: userInfo().username,
    LOGNAME: userInfo().username,
    APPLE_NOTES_MCP_BROKERED: "1",
    APPLE_NOTES_MCP_BROKER_APP: fx.app,
    APPLE_NOTES_MCP_CONFIG_FILE: join(fx.resources, "config.json"),
    APPLE_NOTES_MCP_PUBLIC_HELPER_DIR: "/dev/null",
    APPLE_NOTES_MCP_PRIVATE_HELPER_DIR: "/dev/null",
    APPLE_NOTES_MCP_ENABLE_PRIVATE: "0",
    APPLE_NOTES_MCP_ALLOW_PRIVATE_CONTENT_PATHS: "0",
    APPLE_NOTES_MCP_ALLOW_UNVERIFIED: "0",
  };
  for (const [key, value] of Object.entries(controlled)) {
    assert.equal(actual.env[key], value, `${key} did not use the broker's trusted value`);
  }
  assert.ok(actual.env.TMPDIR?.startsWith("/"), "TMPDIR must be derived from the OS");
  assert.notEqual(actual.env.TMPDIR, hostileEnvironment.TMPDIR, "inherited TMPDIR escaped");
  for (const key of Object.keys(hostileEnvironment)) {
    if (key in controlled || key === "TMPDIR") continue;
    assert.equal(actual.env[key], undefined, `${key} escaped the environment boundary`);
  }
  for (const key of numericKeys) {
    assert.equal(actual.env[key], expectedNumeric[key], `${key} violated the numeric policy`);
  }
  assertInjectionAbsent("while checking the runtime environment");
}

function cleanup() {
  cleaningUp ??= (async () => {
    for (const socket of connections) socket.destroy();
    for (const broker of [...brokers]) await stop(broker);
    rmSync(temporary, { recursive: true, force: true });
  })();
  return cleaningUp;
}

for (const [signal, status] of [
  ["SIGINT", 130],
  ["SIGTERM", 143],
]) {
  process.once(signal, () => {
    void cleanup().finally(() => process.exit(status));
  });
}

try {
  compileFixtures();
  await check("harmless DYLD injection fixture works before testing the boundary", () => {
    command(compiledRuntime, [], {
      input: "{}\n",
      env: { ...cleanEnvironment, DYLD_INSERT_LIBRARIES: injectionLibrary },
    });
    assert.equal(existsSync(injectionMarker), true, "injection fixture did not load");
    positiveControlRecords = markerRecords();
    rmSync(injectionMarker);
    assertInjectionAbsent("after removing the positive-control marker");
  });

  const base = fixture();
  await check("sealed, hardened bundle returns a protocol 3 build fingerprint", () => {
    const result = hello(base);
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      type: "hello",
      protocolVersion: 3,
      sourceSha256,
      packageVersion: "fixture",
      entrySha256: base.config.entrySha256,
    });
    assert.equal(existsSync(base.marker), false);
  });
  await check("LaunchAgent command-line code-path overrides are refused", () => {
    for (const flag of ["--node", "--entry", "--log"]) {
      assertRefusedStartup(base, flag, ["serve", "--socket", base.socket, flag, compiledRuntime]);
    }
  });
  await check("ad-hoc signatures without hardened runtime are refused", () => {
    assertRefusedStartup(fixture({ hardened: false }), "missing hardened runtime");
  });
  await check("loader and debugger escape entitlements are refused", () => {
    for (const entitlement of [
      "com.apple.security.cs.allow-dyld-environment-variables",
      "com.apple.security.cs.disable-library-validation",
      "com.apple.security.get-task-allow",
    ])
      assertRefusedStartup(fixture({ entitlement }), entitlement);
  });

  const inherited = {
    ...cleanEnvironment,
    ...hostileEnvironment,
    ...Object.fromEntries(numericKeys.map((key) => [key, "9999"])),
  };
  assertInjectionAbsent("before launching the broker");
  const running = await start(base, inherited);
  try {
    assertInjectionAbsent("after broker ping, before any child request");
    await check("hardened launch ignores DYLD and all inherited overrides", async () => {
      assertEnvironment(base, await request(base, connectRequest(base), true));
      assert.equal(statSync(base.socket).mode & 0o777, 0o600);
      assert.equal(statSync(base.directory).mode & 0o777, 0o700);
    });
    await check(
      "raw socket clients cannot select helpers, config, safety flags or loaders",
      async () => {
        assertEnvironment(
          base,
          await request(base, connectRequest(base, hostileEnvironment), true)
        );
      }
    );
    await check("all 10 approved numeric fields pass through raw socket requests", async () => {
      const values = Object.fromEntries(numericKeys.map((key, index) => [key, String(index + 1)]));
      assertEnvironment(base, await request(base, connectRequest(base, values), true), values);
    });
    await check(
      "numeric values reject non-integers, zero, overflow, NUL and oversized input",
      async () => {
        const invalid = [
          "",
          "0",
          "-1",
          "+1",
          "1.5",
          "1e3",
          " 1",
          "1\n",
          "１",
          "1\0",
          "2147483648",
          "9".repeat(8193),
          1,
          true,
          null,
          { value: "1" },
        ];
        for (const value of invalid) {
          const values = { APPLE_NOTES_MCP_TIMEOUT_MS: value };
          assertEnvironment(base, await request(base, connectRequest(base, values), true));
        }
      }
    );
    await check("numeric bounds and long leading-zero values match the proxy policy", async () => {
      for (const value of ["1", "2147483647", "0001", `${"0".repeat(8191)}1`]) {
        const values = { APPLE_NOTES_MCP_TIMEOUT_MS: value };
        assertEnvironment(base, await request(base, connectRequest(base, values), true), values);
      }
    });
    await check("stale protocols and mismatched server fingerprints do not spawn", async () => {
      await assertNoSpawn(
        base,
        connectRequest(base, {}, { protocolVersion: 1 }),
        "protocol_mismatch"
      );
      await assertNoSpawn(
        base,
        connectRequest(base, {}, { packageVersion: "stale" }),
        "version_mismatch"
      );
      await assertNoSpawn(
        base,
        connectRequest(base, {}, { entrySha256: "0".repeat(64) }),
        "version_mismatch"
      );
      await assertNoSpawn(base, { type: "connect", protocolVersion: 3 }, "version_mismatch");
    });
  } finally {
    assertNoUnexpectedExecution();
    await stop(running);
  }

  const streams = fixture();
  const streamBroker = await start(streams);
  try {
    await check(
      "binary stdout and stderr remain exact and isolated for concurrent clients",
      async () => {
        const binary = await readyConnection(streams);
        const errors = await readyConnection(streams);
        try {
          binary.write({ mode: "binary" });
          errors.write({ mode: "stderr-only" });
          const [first, second] = await Promise.all([
            outputUntilExit(binary),
            outputUntilExit(errors),
          ]);
          assert.deepEqual(
            first.stdout,
            Buffer.from(Array.from({ length: 64 * 4096 }, (_, i) => i % 256))
          );
          assert.deepEqual(
            first.stderr,
            Buffer.from(Array.from({ length: 64 * 4096 }, (_, i) => 255 - (i % 256)))
          );
          assert.equal(first.status, 23);
          assert.equal(second.stdout.length, 0);
          assert.deepEqual(
            second.stderr,
            Buffer.from(Array.from({ length: 4096 }, (_, i) => 255 - (i % 256)))
          );
          assert.equal(second.status, 17);
        } finally {
          binary.socket.destroy();
          errors.socket.destroy();
        }
      }
    );
    await check(
      "stdin half-close preserves final stdout, stderr and child exit status",
      async () => {
        const connection = await readyConnection(streams);
        try {
          connection.socket.end('{"mode":"halfclose"}\n');
          const result = await outputUntilExit(connection);
          assert.equal(result.stdout.toString(), "final stdout after stdin EOF\n");
          assert.equal(result.stderr.toString(), "final stderr after stdin EOF\n");
          assert.equal(result.status, 7);
          assert.equal(
            streamBroker.output.includes("final stderr"),
            false,
            "child stderr entered the broker diagnostic log"
          );
        } finally {
          connection.socket.destroy();
        }
      }
    );
    await check("signal exits are normalized without corrupting output frames", async () => {
      const connection = await readyConnection(streams);
      try {
        connection.write({ mode: "signal-exit" });
        const result = await outputUntilExit(connection);
        assert.equal(result.status, 143);
      } finally {
        connection.socket.destroy();
      }
    });
    await check("slow readers apply backpressure and resume with exact output", async () => {
      const connection = await readyConnection(streams);
      try {
        connection.socket.pause();
        connection.write({ mode: "binary" });
        await delay(300);
        connection.socket.resume();
        const result = await outputUntilExit(connection);
        assert.equal(result.stdout.length, 64 * 4096);
        assert.equal(result.stderr.length, 64 * 4096);
        assert.equal(result.status, 23);
      } finally {
        connection.socket.destroy();
      }
    });
    await check(
      "disconnect during an output flood releases the child and session slot",
      async () => {
        const connection = await readyConnection(streams);
        connection.socket.pause();
        connection.write({ mode: "flood" });
        await delay(300);
        connection.socket.destroy();
        await assertProcessesGone({ child: connection.pid });
        await waitFor(
          async () => (await request(streams, { type: "ping" })).activeChildren === 0,
          "session slot released"
        );
      }
    );
    await check("a client that never reads output reaches the bounded stall deadline", async () => {
      const connection = await readyConnection(streams);
      try {
        connection.socket.pause();
        connection.write({ mode: "flood" });
        await delay(300);
        assert.equal(processExists(connection.pid), true, "fixture must first block on output");
        await waitFor(
          () => !processExists(connection.pid),
          "stalled output child terminated",
          35_000
        );
        assert.equal((await request(streams, { type: "ping" })).activeChildren, 0);
      } finally {
        connection.socket.destroy();
      }
    });
    await check(
      "full disconnect terminates the owned child and grandchild process group",
      async () => {
        const connection = await readyConnection(streams);
        const pids = await heldProcesses(connection, "hold");
        connection.socket.destroy();
        await assertProcessesGone(pids);
      }
    );
    await check(
      "inherited pipe holders cannot keep a completed session alive indefinitely",
      async () => {
        const connection = await readyConnection(streams);
        const pids = await heldProcesses(connection, "orphan");
        try {
          await assert.rejects(outputUntilExit(connection), /ended|closed/);
          await assertProcessesGone(pids);
        } finally {
          connection.socket.destroy();
        }
      }
    );
  } finally {
    await stop(streamBroker);
  }

  await check("broker SIGTERM cancels sessions and reaps their owned process groups", async () => {
    const fx = fixture();
    const broker = await start(fx);
    const connection = await readyConnection(fx);
    const pids = await heldProcesses(connection, "hold");
    const partial = await openConnection(fx.socket);
    partial.socket.write('{"type":');
    broker.child.kill("SIGTERM");
    await waitFor(() => broker.exited, "broker stopped after cancelling sessions", 3000);
    await assertProcessesGone(pids);
    connection.socket.destroy();
    partial.socket.destroy();
    brokers.delete(broker);
  });

  await check("failed runtime spawn releases pipes and child capacity", async () => {
    const fx = fixture();
    chmodSync(fx.runtime, 0o600);
    const broker = await start(fx);
    try {
      for (let i = 0; i < 20; i++) {
        assert.equal((await request(fx, connectRequest(fx))).code, "spawn_failed");
      }
      assert.equal((await request(fx, { type: "ping" })).activeChildren, 0);
      assert.equal(existsSync(fx.marker), false);
    } finally {
      await stop(broker);
    }
  });

  const mutations = [
    ["sealed broker config", (fx) => appendFileSync(fx.configPath, " ")],
    ["sealed server JavaScript", (fx) => appendFileSync(fx.entry, "// tampered\n")],
    [
      "sealed server settings",
      (fx) =>
        writeFileSync(
          join(fx.resources, "config.json"),
          '{"APPLE_NOTES_MCP_ENABLE_PRIVATE":"1"}\n'
        ),
    ],
    [
      "pinned runtime bytes",
      (fx) => {
        const replacement = `${fx.runtime}.replacement`;
        // Atomic replacement avoids editing an image that may still be mapped.
        writeFileSync(
          replacement,
          Buffer.concat([readFileSync(fx.runtime), Buffer.from("tampered\n")]),
          { mode: 0o755 }
        );
        renameSync(replacement, fx.runtime);
      },
    ],
    [
      "pinned runtime symlink",
      (fx) => {
        rmSync(fx.runtime);
        symlinkSync(compiledRuntime, fx.runtime);
      },
    ],
  ];
  for (const [name, mutate] of mutations) {
    await check(`${name} tampering is refused before startup`, () => {
      const fx = fixture();
      mutate(fx);
      assertRefusedStartup(fx, name);
    });
    await check(`${name} tampering is refused between live connections`, async () => {
      const fx = fixture();
      const broker = await start(fx);
      try {
        assertEnvironment(fx, await request(fx, connectRequest(fx), true));
        mutate(fx);
        await assertNoSpawn(fx, connectRequest(fx), "integrity_failed");
      } finally {
        assertNoUnexpectedExecution();
        await stop(broker);
      }
    });
  }
  assertNoUnexpectedExecution();
  console.log(`PASS: ${checks} isolated native broker security checks.`);
} catch (error) {
  console.error(error.stack ?? error);
  process.exitCode = 1;
  try {
    await reportFailureDiagnostics();
  } catch (diagnosticError) {
    console.error(
      `Failure diagnostics could not complete: ${diagnosticError.stack ?? diagnosticError}`
    );
  }
} finally {
  await cleanup();
}
