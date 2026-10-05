// apple-notes-mcp-broker
//
// An optional, per-user permission broker for apple-notes-mcp. It runs as a
// LaunchAgent inside a signed app bundle, so macOS holds the bundle (not the
// MCP host app, and not whichever Node binary the host launched) responsible
// for Full Disk Access and Notes Automation. Grants survive Node updates and
// work under hosts that disclaim responsibility for their children.
//
// It does not read the Notes database or talk to Notes itself. For each
// accepted connection it starts the server's own Node entry point as a child,
// with the connection as the child's stdin and stdout. Children inherit the
// bundle as their responsible process.
//
// Listening socket: a Unix socket created 0600 inside a 0700 directory. Every
// connection is checked with getpeereid() and refused unless the peer runs as
// this user. The first line on a connection is a JSON request:
//   {"type": "ping"}
//     -> {"type": "pong", "protocolVersion": 1, "sourceSha256": "...", ...}
//   {"type": "connect", "protocolVersion": 1, "env": {"APPLE_NOTES_MCP_...": "..."}}
//     -> {"type": "ready", "protocolVersion": 1, "pid": <child>}, then the
//        connection carries the MCP stdio stream until either side closes.
//   anything else -> {"type": "error", "code": "...", "message": "..."}
// Only APPLE_NOTES_MCP_* variables are passed through from a connect request,
// so a client's configuration reaches the child but its PATH, NODE_OPTIONS and
// the like do not.
//
// Modes:
//   (no arguments)  read {"type": "hello"} on stdin, answer with the protocol
//                   version and source digest, and exit (build handshake)
//   serve --socket <path> --node <node> --entry <build/index.js> [--log <file>]
//
// Build (done by `apple-notes-mcp setup --broker`, which also generates the
// one-line source-digest file that defines helperSourceSHA256):
//   xcrun swiftc -O -parse-as-library apple-notes-mcp-broker.swift source-digest.swift -o apple-notes-mcp-broker

import Darwin
import Foundation

let protocolVersion = 1
let maxRequestBytes = 65_536
let maxChildren = 16
let maxPassedVariables = 64
let maxVariableBytes = 8_192

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard var pointer = raw.baseAddress else { return true }
        var remaining = raw.count
        while remaining > 0 {
            let written = Darwin.write(fd, pointer, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            remaining -= written
            pointer = pointer.advanced(by: written)
        }
        return true
    }
}

@discardableResult
func sendLine(_ fd: Int32, _ object: [String: Any]) -> Bool {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return false
    }
    data.append(0x0A)
    return writeAll(fd, data)
}

/// Reads one newline-terminated line a byte at a time, so nothing past the
/// newline is consumed: the rest of the stream belongs to the child.
func readRequestLine(_ fd: Int32) -> Data? {
    var line = Data()
    var byte: UInt8 = 0
    while line.count < maxRequestBytes {
        let count = Darwin.read(fd, &byte, 1)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return nil }
        if byte == 0x0A { return line }
        line.append(byte)
    }
    return nil
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

// MARK: - Build handshake

func runHello() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let firstLine = input.split(separator: 0x0A).first.map { Data($0) } ?? Data()
    guard
        let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
        object["type"] as? String == "hello"
    else {
        FileHandle.standardError.write(Data("expected {\"type\":\"hello\"} on stdin\n".utf8))
        exit(64)
    }
    sendLine(STDOUT_FILENO, [
        "type": "hello",
        "protocolVersion": protocolVersion,
        "sourceSha256": helperSourceSHA256,
    ])
    exit(0)
}

// MARK: - Serving

struct ServeOptions {
    let socketPath: String
    let nodePath: String
    let entryPath: String
    let logPath: String?
}

func parseServeOptions(_ args: [String]) -> ServeOptions? {
    var values: [String: String] = [:]
    var index = 0
    while index < args.count {
        let key = args[index]
        guard ["--socket", "--node", "--entry", "--log"].contains(key), index + 1 < args.count else {
            return nil
        }
        values[key] = args[index + 1]
        index += 2
    }
    guard let socket = values["--socket"], let node = values["--node"], let entry = values["--entry"] else {
        return nil
    }
    return ServeOptions(socketPath: socket, nodePath: node, entryPath: entry, logPath: values["--log"])
}

final class Broker {
    let options: ServeOptions
    let bundlePath: String
    private let lock = NSLock()
    private var active = 0

    init(options: ServeOptions) {
        self.options = options
        bundlePath = Bundle.main.bundlePath
    }

    var activeChildren: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    private func reserveChild() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if active >= maxChildren { return false }
        active += 1
        return true
    }

    private func releaseChild() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    func listen() -> Int32 {
        let path = options.socketPath
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            log("cannot create socket directory \(directory): \(error)")
            exit(73)
        }
        // The directory is the first fence: owned by this user and closed to everyone else.
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            log("socket directory \(directory) is not a directory owned by this user")
            exit(73)
        }
        chmod(directory, 0o700)
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                log("refusing to replace \(path): it exists and is not a socket")
                exit(73)
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("socket() failed: \(String(cString: strerror(errno)))")
            exit(71)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < capacity else {
            log("socket path is too long (\(pathBytes.count) bytes, limit \(capacity - 1)): \(path)")
            exit(64)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // Created 0600 from the start, so there is no window where it is open to others.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            log("bind(\(path)) failed: \(String(cString: strerror(errno)))")
            exit(71)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            log("listen() failed: \(String(cString: strerror(errno)))")
            exit(71)
        }
        return fd
    }

    func serve() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let listener = listen()
        log("listening on \(options.socketPath) (bundle \(bundlePath), node \(options.nodePath))")
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                log("accept() failed: \(String(cString: strerror(errno)))")
                continue
            }
            Thread.detachNewThread { [self] in
                handle(connection)
            }
        }
    }

    private func refuse(_ fd: Int32, _ code: String, _ message: String) {
        sendLine(fd, ["type": "error", "code": code, "message": message])
        close(fd)
    }

    private func handle(_ connection: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(connection, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            log("refused a connection from uid \(peerUID)")
            refuse(connection, "peer_refused", "Only the user who installed the broker may connect.")
            return
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard
            let line = readRequestLine(connection),
            let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = request["type"] as? String
        else {
            refuse(connection, "bad_request", "Expected one JSON request line.")
            return
        }
        switch type {
        case "ping":
            sendLine(connection, [
                "type": "pong",
                "protocolVersion": protocolVersion,
                "sourceSha256": helperSourceSHA256,
                "pid": Int(getpid()),
                "bundlePath": bundlePath,
                "nodePath": options.nodePath,
                "entryPath": options.entryPath,
                "activeChildren": activeChildren,
            ])
            close(connection)
        case "connect":
            guard request["protocolVersion"] as? Int == protocolVersion else {
                refuse(connection, "protocol_mismatch",
                       "The broker speaks protocol \(protocolVersion). Run `apple-notes-mcp setup --broker` again.")
                return
            }
            connect(connection, passed: request["env"] as? [String: Any] ?? [:])
        default:
            refuse(connection, "bad_request", "Unknown request type.")
        }
    }

    /// The child's environment: a small fixed base plus the client's
    /// APPLE_NOTES_MCP_* settings. Broker control variables are never taken
    /// from the client.
    private func childEnvironment(passed: [String: Any]) -> [String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "__CFBundleIdentifier"] {
            if let value = inherited[key] { env[key] = value }
        }
        for (key, value) in inherited where key.hasPrefix("LC_") {
            env[key] = value
        }
        var count = 0
        for (key, raw) in passed {
            guard count < maxPassedVariables,
                  key.hasPrefix("APPLE_NOTES_MCP_"), !key.hasPrefix("APPLE_NOTES_MCP_BROKER"),
                  key.utf8.count <= 128,
                  let value = raw as? String, value.utf8.count <= maxVariableBytes,
                  !value.contains("\0")
            else { continue }
            env[key] = value
            count += 1
        }
        env["APPLE_NOTES_MCP_BROKERED"] = "1"
        env["APPLE_NOTES_MCP_BROKER_APP"] = bundlePath
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func connect(_ connection: Int32, passed: [String: Any]) {
        guard reserveChild() else {
            refuse(connection, "busy", "The broker is already serving \(maxChildren) clients.")
            return
        }
        defer { releaseChild() }
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, connection, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, connection, STDOUT_FILENO)
        if let logPath = options.logPath {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every descriptor not named above, including the listening socket.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(options.nodePath), strdup(options.entryPath), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = childEnvironment(passed: passed).map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, options.nodePath, &actions, &attributes, argv, envp)
        guard status == 0 else {
            log("could not start \(options.nodePath): \(String(cString: strerror(status)))")
            refuse(connection, "spawn_failed", "The broker could not start Node at \(options.nodePath).")
            return
        }
        // The child only writes after a request, and the client sends none
        // until it reads this line, so the two never interleave.
        sendLine(connection, ["type": "ready", "protocolVersion": protocolVersion, "pid": Int(pid)])
        close(connection)
        var exitStatus: Int32 = 0
        while waitpid(pid, &exitStatus, 0) < 0 && errno == EINTR {}
    }
}

// MARK: - Entry

@main
enum BrokerMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            runHello()
        }
        if arguments.first == "serve", let options = parseServeOptions(Array(arguments.dropFirst())) {
            Broker(options: options).serve()
        }
        FileHandle.standardError.write(Data(
            "usage: apple-notes-mcp-broker serve --socket <path> --node <node> --entry <build/index.js> [--log <file>]\n".utf8))
        exit(64)
    }
}
