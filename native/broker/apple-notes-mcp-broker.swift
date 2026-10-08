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
//     -> {"type": "pong", "protocolVersion": 2, "sourceSha256": "...", ...}
//   {"type": "connect", "protocolVersion": 2, "packageVersion": "...",
//    "entrySha256": "...", "env": {"APPLE_NOTES_MCP_TIMEOUT_MS": "30000"}}
//     -> {"type": "ready", "protocolVersion": 2, "pid": <child>, ...}, then the
//        connection carries the MCP stdio stream until either side closes.
//   anything else -> {"type": "error", "code": "...", "message": "..."}
// Only the numeric limits in passedEnvironmentKeys pass through. Paths,
// helpers, shortcuts, safety overrides, and loader settings are never trusted.
//
// Modes:
//   (no arguments)  read {"type": "hello"} on stdin, answer with the protocol
//                   version and source digest, and exit (build handshake)
//   serve --socket <path>
// Code paths come exclusively from the signed app bundle. The sealed config
// pins Node by canonical path and SHA-256; the server entry is bundled.
//
// Build (done by `apple-notes-mcp setup --broker`, which also generates the
// one-line source-digest file that defines helperSourceSHA256):
//   xcrun swiftc -O -parse-as-library apple-notes-mcp-broker.swift source-digest.swift -o apple-notes-mcp-broker

import Darwin
import Foundation
import CryptoKit
import Security

let protocolVersion = 2
let maxRequestBytes = 65_536
let maxChildren = 16
let maxVariableBytes = 8_192

// Keep in sync with BROKER_PASSED_ENV_KEYS in brokerProxy.ts. This is also
// enforced here because any same-user process can speak the socket protocol.
let passedEnvironmentKeys: Set<String> = [
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
]

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

func runHello(trust: TrustedServer) -> Never {
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
        "packageVersion": trust.config.packageVersion,
        "entrySha256": trust.config.entrySha256,
    ])
    exit(0)
}

// MARK: - Serving

struct ServeOptions {
    let socketPath: String
}

func parseServeOptions(_ args: [String]) -> ServeOptions? {
    var values: [String: String] = [:]
    var index = 0
    while index < args.count {
        let key = args[index]
        guard key == "--socket", values[key] == nil,
              index + 1 < args.count, !args[index + 1].contains("\0") else {
            return nil
        }
        values[key] = args[index + 1]
        index += 2
    }
    guard let socket = values["--socket"], socket.hasPrefix("/") else {
        return nil
    }
    return ServeOptions(socketPath: socket)
}

// MARK: - Signed code and configuration

struct IntegrityError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ServerConfiguration: Decodable {
    let schemaVersion: Int
    let nodePath: String
    let nodeSha256: String
    let packageVersion: String
    let entrySha256: String
}

func sha256File(_ path: String) throws -> String {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    var digest = SHA256()
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
        digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

func canonicalPath(_ path: String) throws -> String {
    guard !path.contains("\0"), let resolved = realpath(path, nil) else {
        throw IntegrityError("Cannot resolve path: \(path)")
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Returns only existing regular files whose path has no symlink components.
func requireCanonicalFile(_ path: String) throws {
    var info = stat()
    guard path.hasPrefix("/"), !path.contains("\0"),
          try canonicalPath(path) == path,
          lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
        throw IntegrityError("Code path is missing, noncanonical, or not a regular file: \(path)")
    }
}

/// The running image supplies the requirement, never a mutable external
/// manifest. Strict validation seals resources as well as the executable.
/// Revalidate at each spawn to detect replacement since startup. This does not
/// make file checks atomic with Node's later reads or isolate an unsandboxed
/// same-user process actively racing writes to the installation.
final class TrustedServer {
    let bundlePath: String
    let resourcesPath: String
    let entryPath: String
    let config: ServerConfiguration
    private let requirement: SecRequirement

    init() throws {
        bundlePath = try canonicalPath(Bundle.main.bundleURL.path)
        resourcesPath = bundlePath + "/Contents/Resources"
        entryPath = resourcesPath + "/server/build/index.js"
        guard bundlePath.hasSuffix(".app"), let executable = Bundle.main.executableURL,
              try canonicalPath(executable.path) ==
                bundlePath + "/Contents/MacOS/apple-notes-mcp-broker" else {
            throw IntegrityError("The broker must run from its signed app bundle.")
        }
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var ownRequirement: SecRequirement?
        guard SecCodeCopySelf(SecCSFlags(), &running) == errSecSuccess,
              let running,
              SecCodeCheckValidity(running, SecCSFlags(), nil) == errSecSuccess,
              SecCodeCopyStaticCode(running, SecCSFlags(), &runningStatic) == errSecSuccess,
              let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, SecCSFlags(), &ownRequirement) == errSecSuccess,
              let ownRequirement else {
            throw IntegrityError("Cannot verify the running broker's code signature.")
        }
        requirement = ownRequirement
        try Self.verifyBundle(bundlePath, requirement: ownRequirement)
        let configPath = resourcesPath + "/broker-config.json"
        try requireCanonicalFile(configPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        guard data.count <= maxRequestBytes else { throw IntegrityError("The sealed broker config is too large.") }
        config = try JSONDecoder().decode(ServerConfiguration.self, from: data)
        guard config.schemaVersion == 1, isSHA256(config.nodeSha256), isSHA256(config.entrySha256),
              !config.packageVersion.isEmpty, config.packageVersion.utf8.count <= 256 else {
            throw IntegrityError("The sealed broker config is invalid. Run setup --broker again.")
        }
        try validate()
    }

    private static func verifyBundle(_ path: String, requirement: SecRequirement) throws {
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw IntegrityError("The broker app's signature or sealed resources changed. Run setup --broker again.")
        }
        var signing: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
              let info = signing as? [String: Any],
              let signedFlags = info[kSecCodeInfoFlags as String] as? NSNumber,
              signedFlags.uint32Value & 0x10000 != 0 else { // CS_RUNTIME
            throw IntegrityError("The broker must be signed with the hardened runtime enabled.")
        }
        // These entitlements would defeat the broker's loader boundary.
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for key in ["com.apple.security.cs.allow-dyld-environment-variables",
                    "com.apple.security.cs.disable-library-validation",
                    "com.apple.security.get-task-allow"] {
            if (entitlements[key] as? NSNumber)?.boolValue == true {
                throw IntegrityError("The broker has an unsafe code-signing entitlement: \(key)")
            }
        }
    }

    func validate() throws {
        try Self.verifyBundle(bundlePath, requirement: requirement)
        try requireCanonicalFile(entryPath)
        try requireCanonicalFile(config.nodePath)
        guard try sha256File(entryPath) == config.entrySha256,
              try sha256File(config.nodePath) == config.nodeSha256 else {
            throw IntegrityError("The server entry or pinned Node runtime changed. Run setup --broker again.")
        }
        try requireCanonicalFile(resourcesPath + "/config.json")
    }
}

final class Broker {
    let options: ServeOptions
    let trust: TrustedServer
    let bundlePath: String
    private let lock = NSLock()
    private var active = 0

    init(options: ServeOptions, trust: TrustedServer) {
        self.options = options
        self.trust = trust
        bundlePath = trust.bundlePath
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
        log("listening on \(options.socketPath) (bundle \(bundlePath), node \(trust.config.nodePath))")
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
                "nodePath": trust.config.nodePath,
                "entryPath": trust.entryPath,
                "packageVersion": trust.config.packageVersion,
                "entrySha256": trust.config.entrySha256,
                "activeChildren": activeChildren,
            ])
            close(connection)
        case "connect":
            guard request["protocolVersion"] as? Int == protocolVersion else {
                refuse(connection, "protocol_mismatch",
                       "The broker speaks protocol \(protocolVersion). Run `apple-notes-mcp setup --broker` again.")
                return
            }
            guard request["packageVersion"] as? String == trust.config.packageVersion,
                  request["entrySha256"] as? String == trust.config.entrySha256 else {
                refuse(connection, "version_mismatch",
                       "This client does not match the broker's sealed server. Run `apple-notes-mcp setup --broker` again.")
                return
            }
            connect(connection, passed: request["env"] as? [String: Any] ?? [:])
        default:
            refuse(connection, "bad_request", "Unknown request type.")
        }
    }

    /// Never inherit the LaunchAgent's environment. HOME and TMPDIR also
    /// influence file/config discovery, so derive them from the OS account.
    private func childEnvironment(passed: [String: Any]) -> [String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "SHELL": "/bin/sh",
        ]
        // getpwuid_r is safe across concurrent connection threads.
        var account = passwd()
        var accountPointer: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        if getpwuid_r(getuid(), &account, &buffer, buffer.count, &accountPointer) == 0,
           accountPointer != nil {
            env["HOME"] = String(cString: account.pw_dir)
            env["USER"] = String(cString: account.pw_name)
            env["LOGNAME"] = env["USER"]
        } else {
            // Fail closed rather than letting Node consult inherited values.
            env["HOME"] = "/var/empty"
        }
        var temporary = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &temporary, temporary.count)
        env["TMPDIR"] = length > 0 && length <= temporary.count ? String(cString: temporary) : "/tmp"
        for key in passedEnvironmentKeys {
            guard let raw = passed[key],
                  let value = raw as? String, value.utf8.count <= maxVariableBytes,
                  !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) })
            else { continue }
            // Match the proxy's positive Int32 range, including leading zeros.
            let digits = value.drop(while: { $0 == "0" })
            guard let number = Int64(digits), number > 0, number <= Int64(Int32.max) else { continue }
            env[key] = value
        }
        env["APPLE_NOTES_MCP_BROKERED"] = "1"
        env["APPLE_NOTES_MCP_BROKER_APP"] = bundlePath
        env["APPLE_NOTES_MCP_CONFIG_FILE"] = trust.resourcesPath + "/config.json"
        // Mutable helper manifests only hash their mutable binaries; they are
        // not a trust anchor. Helpers require a separately sealed integration.
        // /dev/null is a root-owned non-directory, so even an already-running
        // child cannot discover a helper added after bundle verification.
        env["APPLE_NOTES_MCP_PUBLIC_HELPER_DIR"] = "/dev/null"
        env["APPLE_NOTES_MCP_PRIVATE_HELPER_DIR"] = "/dev/null"
        env["APPLE_NOTES_MCP_ENABLE_PRIVATE"] = "0"
        env["APPLE_NOTES_MCP_ALLOW_PRIVATE_CONTENT_PATHS"] = "0"
        env["APPLE_NOTES_MCP_ALLOW_UNVERIFIED"] = "0"
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func connect(_ connection: Int32, passed: [String: Any]) {
        guard reserveChild() else {
            log("refused a connection: child limit \(maxChildren) reached")
            refuse(connection, "busy", "The broker is already serving \(maxChildren) clients.")
            return
        }
        defer { releaseChild() }
        do {
            try trust.validate()
        } catch {
            log("refused spawn: \(error)")
            refuse(connection, "integrity_failed", "The broker's sealed server or pinned runtime changed. Run setup --broker again.")
            return
        }
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, connection, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, connection, STDOUT_FILENO)
        // Inherit the descriptor opened by launchd/the caller, not a writable
        // command-line path that could make the broker append to a TCC file.
        posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every descriptor not named above, including the listening socket.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        // Ignore LaunchAgent WorkingDirectory as well as its environment.
        posix_spawn_file_actions_addchdir_np(&actions, trust.resourcesPath + "/server")
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(trust.config.nodePath), strdup(trust.entryPath), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = childEnvironment(passed: passed).map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, trust.config.nodePath, &actions, &attributes, argv, envp)
        guard status == 0 else {
            log("could not start \(trust.config.nodePath): \(String(cString: strerror(status)))")
            refuse(connection, "spawn_failed", "The broker could not start Node at \(trust.config.nodePath).")
            return
        }
        // The child only writes after a request, and the client sends none
        // until it reads this line, so the two never interleave.
        sendLine(connection, ["type": "ready", "protocolVersion": protocolVersion, "pid": Int(pid),
                              "packageVersion": trust.config.packageVersion, "entrySha256": trust.config.entrySha256])
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
        do {
            if arguments.isEmpty {
                runHello(trust: try TrustedServer())
            }
            if arguments.first == "serve", let options = parseServeOptions(Array(arguments.dropFirst())) {
                Broker(options: options, trust: try TrustedServer()).serve()
            }
        } catch {
            log("integrity check failed: \(error)")
            exit(78)
        }
        FileHandle.standardError.write(Data(
            "usage: apple-notes-mcp-broker serve --socket <path>\n".utf8))
        exit(64)
    }
}
