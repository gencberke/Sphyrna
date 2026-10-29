import CryptoKit
import Darwin
import Foundation
import Testing
@testable import LoomCore
@testable import SwiftTerm

// This fixture is prepared for an explicit parent-owned, zero-input native
// acceptance run. Discovery and ordinary checks never start a provider.
private enum NativeOpenCodeAcceptanceGate {
    static let required = [
        "LOOM_ACC_NATIVE_OPENCODE_EXECUTABLE", "LOOM_ACC_NATIVE_OPENCODE_ROOT",
        "LOOM_ACC_NATIVE_OPENCODE_EVIDENCE", "LOOM_ACC_NATIVE_OPENCODE_RESERVATION",
    ]

    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["LOOM_ACC_NATIVE_OPENCODE"] == "1" &&
            required.allSatisfy { !(environment[$0] ?? "").isEmpty }
    }

}

private struct NativeOpenCodeAcceptanceFailure: Error, Equatable {
    // Only fixed fixture labels may escape to a test log or evidence.
    let phase: String
    init(_ phase: String) { self.phase = phase }
}

private func nativeAcceptanceRequire(_ value: Bool, _ phase: String) throws {
    guard value else { throw NativeOpenCodeAcceptanceFailure(phase) }
}

private enum NativeOpenCodeAcceptanceFiles {
    static func privateDirectory(_ url: URL, beneath parent: URL? = nil) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw NativeOpenCodeAcceptanceFailure("directory")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw NativeOpenCodeAcceptanceFailure("directory")
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { throw NativeOpenCodeAcceptanceFailure("directory") }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let resolved = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
        if let parent {
            guard resolved.path.hasPrefix(parent.path + "/") else {
                throw NativeOpenCodeAcceptanceFailure("outside-synthetic-root")
            }
        }
        return resolved
    }

    static func readOwnedFile(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeOpenCodeAcceptanceFailure("reservation") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= off_t(limit) else {
            throw NativeOpenCodeAcceptanceFailure("reservation")
        }
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw NativeOpenCodeAcceptanceFailure("reservation")
            }
            guard result.count + count <= limit else { throw NativeOpenCodeAcceptanceFailure("reservation") }
            result.append(contentsOf: chunk.prefix(count))
        }
        return result
    }

    static func claim(_ reservation: URL) throws {
        let fd = open(reservation.path + ".consumed", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                      mode_t(0o600))
        guard fd >= 0 else { throw NativeOpenCodeAcceptanceFailure("reservation-consumed") }
        defer { close(fd) }
        let data = Data("zero-input route acceptance claimed before native execution\n".utf8)
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        try nativeAcceptanceRequire(count == data.count && fsync(fd) == 0, "reservation-claim")
    }

    static func writeExclusive(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw NativeOpenCodeAcceptanceFailure("owned-file") }
        defer { close(fd) }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NativeOpenCodeAcceptanceFailure("owned-file") }
                offset += count
            }
        }
        try nativeAcceptanceRequire(fsync(fd) == 0 && fchmod(fd, mode) == 0, "owned-file")
    }

    /// Read only the approved executable and bind both its bytes and stat
    /// identity; never follow a retargeted symlink or retain executable bytes.
    static func executableWitness(_ path: String) throws -> NativeExecutableWitness {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeOpenCodeAcceptanceFailure("executable") }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size > 0, before.st_size <= 1_073_741_824,
              before.st_mode & 0o111 != 0 else { throw NativeOpenCodeAcceptanceFailure("executable") }
        var hash = SHA256()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw NativeOpenCodeAcceptanceFailure("executable")
            }
            hash.update(data: Data(chunk.prefix(count)))
        }
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw NativeOpenCodeAcceptanceFailure("executable-changed")
        }
        return NativeExecutableWitness(device: before.st_dev, inode: before.st_ino, size: before.st_size,
            modifiedSeconds: before.st_mtimespec.tv_sec, modifiedNanoseconds: before.st_mtimespec.tv_nsec,
            digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

private struct NativeExecutableWitness: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let digest: String
}

private struct NativeOpenCodeReservation: Decodable {
    let kind: String
    let modelInputs: Int
    let root: String
    let executable: String
    let executableSHA256: String
    let version: String
    let environmentSHA256: String
    let roots: [String: String]
}

private struct NativeOpenCodeAcceptanceInputs {
    let root: URL
    let evidence: URL
    let reservation: URL
    let approval: NativeOpenCodeReservation
    let executable: String
    let executableWitness: NativeExecutableWitness

    static func read() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        func input(_ key: String) throws -> URL {
            guard let value = environment[key], value.hasPrefix("/"), !value.contains("\0") else {
                throw NativeOpenCodeAcceptanceFailure("input")
            }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        let root = try NativeOpenCodeAcceptanceFiles.privateDirectory(input("LOOM_ACC_NATIVE_OPENCODE_ROOT"))
        try nativeAcceptanceRequire(root.path.hasPrefix("/private/tmp/loom-real/") &&
            root.path.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (65...90).contains(scalar.value) ||
                (97...122).contains(scalar.value) || "/-_.".unicodeScalars.contains(scalar)
            }, "synthetic-root")
        let evidence = try NativeOpenCodeAcceptanceFiles.privateDirectory(input("LOOM_ACC_NATIVE_OPENCODE_EVIDENCE"))
        try nativeAcceptanceRequire(evidence.path ==
            "/Users/gencberke/Library/Caches/loom-v2/evidence/r9/e1/native-acceptance", "evidence")
        let reservation = try input("LOOM_ACC_NATIVE_OPENCODE_RESERVATION")
        try nativeAcceptanceRequire(reservation.deletingLastPathComponent().resolvingSymlinksInPath().path == evidence.path,
                                    "reservation-location")
        let bytes = try NativeOpenCodeAcceptanceFiles.readOwnedFile(reservation, limit: 8 * 1024)
        guard let approval = try? JSONDecoder().decode(NativeOpenCodeReservation.self, from: bytes) else {
            throw NativeOpenCodeAcceptanceFailure("reservation-format")
        }
        let executable = try input("LOOM_ACC_NATIVE_OPENCODE_EXECUTABLE").path
        // The only permitted native file is the installed binary named by the
        // parent-owned P1 metadata evidence, never a profile/config/data path.
        try nativeAcceptanceRequire(executable == "/Users/gencberke/.opencode/bin/opencode" &&
            approval.kind == "opencode-native-tui-zero-input-v1" && approval.modelInputs == 0 &&
            approval.root == root.path && approval.executable == executable && approval.version == "2.2.0",
            "reservation-mismatch")
        try nativeAcceptanceRequire(executable.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (65...90).contains(scalar.value) ||
            (97...122).contains(scalar.value) || "/-_.".unicodeScalars.contains(scalar)
        }, "executable-path")
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        try nativeAcceptanceRequire(realpath(executable, &resolved) != nil, "executable-path")
        let resolvedBytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        try nativeAcceptanceRequire(String(decoding: resolvedBytes, as: UTF8.self) == executable, "executable-path")
        let witness = try NativeOpenCodeAcceptanceFiles.executableWitness(executable)
        try nativeAcceptanceRequire(approval.executableSHA256 == witness.digest, "reservation-mismatch")
        var info = stat()
        try nativeAcceptanceRequire(lstat(reservation.path + ".result.json", &info) != 0 && errno == ENOENT,
                                    "result-preexists")
        try nativeAcceptanceRequire(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                                    "synthetic-root-not-empty")
        return Self(root: root, evidence: evidence, reservation: reservation, approval: approval,
                    executable: executable, executableWitness: witness)
    }
}

private struct NativeOpenCodeLayout {
    let root: URL
    var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    var app: URL { root.appendingPathComponent("app", isDirectory: true) }
    var plugin: URL { app.appendingPathComponent("plugin", isDirectory: true) }
    var host: URL { root.appendingPathComponent("host", isDirectory: true) }
    var sockets: URL { root.appendingPathComponent("s", isDirectory: true) }
    var bridge: String { app.appendingPathComponent("tui.sock").path }
    var serverPolicy: URL { app.appendingPathComponent("server.sb") }
    var terminalPolicy: URL { app.appendingPathComponent("terminal.sb") }
    var wrapper: URL { app.appendingPathComponent("native-wrapper") }

    var roots: [String: String] {
        let data = root.appendingPathComponent("xdg/data/opencode").path
        let cache = root.appendingPathComponent("xdg/cache/opencode").path
        return ["home": root.appendingPathComponent("home").path, "data": data, "cache": cache,
                "config": root.appendingPathComponent("xdg/config/opencode").path,
                "state": root.appendingPathComponent("xdg/state/opencode").path,
                "tmp": root.appendingPathComponent("tmp/opencode").path,
                "bin": cache + "/bin", "log": data + "/log", "repos": data + "/repos",
                "db": data + "/opencode.db"]
    }

    var profileRoots: OpenCodeProfileRoots {
        let value = roots
        return OpenCodeProfileRoots(home: value["home"]!, data: value["data"]!, cache: value["cache"]!,
                                    config: value["config"]!, state: value["state"]!, tmp: value["tmp"]!,
                                    bin: value["bin"]!, log: value["log"]!, repos: value["repos"]!, db: value["db"]!)
    }

    func prepare() throws {
        let names = ["work", "app/plugin", "host", "s", "home", "tmp", "xdg/config/opencode",
                     "xdg/data/opencode/log", "xdg/data/opencode/repos", "xdg/cache/opencode/bin",
                     "xdg/state/opencode", "tmp/opencode", "gcloud"]
        for name in names {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try nativeAcceptanceRequire(bridge.utf8.count < 104 &&
            sockets.appendingPathComponent("r/h-000000000000.sock").path.utf8.count < 104, "socket-path")
    }

    func environment() throws -> [String: String] {
        let tmp = root.appendingPathComponent("tmp").path
        var result = ["HOME": roots["home"]!, "TMPDIR": tmp, "TMP": tmp, "TEMP": tmp,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "TERM": "xterm-256color",
            "CLOUDSDK_CONFIG": root.appendingPathComponent("gcloud").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("xdg/config").path,
            "XDG_DATA_HOME": root.appendingPathComponent("xdg/data").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("xdg/cache").path,
            "XDG_STATE_HOME": root.appendingPathComponent("xdg/state").path,
            "OPENCODE_CONFIG_DIR": roots["config"]!, "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_CONFIG_PROJECT_DISABLE": "1",
            "OPENCODE_DISABLE_PROJECT_CONFIG": "1", "OPENCODE_DISABLE_CLAUDE_CODE": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS": "1",
            "OPENCODE_CONFIG_CONTENT": #"{"plugins":["-opencode.provider.*"],"enabled_providers":["opencode"],"warming":false}"#]
        result = try OpenCodeTUIPlugin.addingOwnedPlugin(to: result, directory: plugin)
        guard let content = result["OPENCODE_CONFIG_CONTENT"],
              let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: canonical, encoding: .utf8) else {
            throw NativeOpenCodeAcceptanceFailure("environment")
        }
        result["OPENCODE_CONFIG_CONTENT"] = text
        return result
    }

    static func environmentDigest(_ values: [String: String]) -> String {
        var hash = SHA256()
        for key in values.keys.sorted() {
            let value = values[key]!
            hash.update(data: Data("\(key.utf8.count):".utf8)); hash.update(data: Data(key.utf8))
            hash.update(data: Data("\(value.utf8.count):".utf8)); hash.update(data: Data(value.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The run host is started by LaunchServices, so the wrapper applies the
/// profile inside each child rather than assuming its parent inherited it.
private struct NativeOpenCodeBoundary {
    let layout: NativeOpenCodeLayout
    let nativeExecutable: String
    let wrapperWitness: NativeExecutableWitness
    let serverPolicy: Data

    private static func quote(_ value: String) -> String { "\"" + value + "\"" }

    private static func policy(layout: NativeOpenCodeLayout, executable: String, port: UInt16?) -> Data {
        var text = "(version 1)\n(deny default)\n(allow process*)\n(allow sysctl-read)\n(allow file-read-metadata)\n"
        text += "(allow file-read* file-test-existence (literal \"/\"))\n"
        for path in ["/System", "/usr/lib", "/usr/share", "/usr/bin", "/bin", "/sbin", "/Library/Apple", layout.root.path] {
            text += "(allow file-read* file-map-executable (subpath \(quote(path))))\n"
        }
        for path in [executable, "/dev/null", "/dev/random", "/dev/urandom", "/private/etc/localtime",
                     "/etc/localtime", "/private/etc/hosts", "/etc/hosts"] {
            text += "(allow file-read* file-map-executable (literal \(quote(path))))\n"
        }
        // The child cannot rewrite the wrapper, either sandbox profile, or
        // the generated plugin. Writable native paths are narrowly scoped.
        for name in ["home", "tmp", "xdg", "work", "gcloud"] {
            text += "(allow file-write* (subpath \(quote(layout.root.appendingPathComponent(name).path))))\n"
        }
        text += "(allow file-write* (literal \"/dev/null\"))\n"
        if let port {
            text += "(allow network-outbound (remote ip \"localhost:\(port)\"))\n"
            text += "(allow network-outbound (literal \(quote(layout.bridge))))\n"
        } else {
            text += "(allow network-bind network-inbound (local ip \"localhost:*\"))\n"
        }
        return Data(text.utf8)
    }

    static func install(layout: NativeOpenCodeLayout, executable: String) throws -> Self {
        let server = policy(layout: layout, executable: executable, port: nil)
        try NativeOpenCodeAcceptanceFiles.writeExclusive(server, to: layout.serverPolicy, mode: 0o400)
        // Only the explicit native entry points are executable through this
        // wrapper. No shell eval and no credentials appear in these files.
        let script = """
            #!/bin/sh
            case "${1-}" in
              debug) [ "${2-}" = paths ] || exit 64; profile="\(layout.serverPolicy.path)" ;;
              serve) profile="\(layout.serverPolicy.path)" ;;
              --server) profile="\(layout.terminalPolicy.path)" ;;
              *) exit 64 ;;
            esac
            exec /usr/bin/sandbox-exec -f "$profile" "\(executable)" "$@"

            """
        try NativeOpenCodeAcceptanceFiles.writeExclusive(Data(script.utf8), to: layout.wrapper, mode: 0o500)
        let witness = try NativeOpenCodeAcceptanceFiles.executableWitness(layout.wrapper.path)
        return Self(layout: layout, nativeExecutable: executable, wrapperWitness: witness, serverPolicy: server)
    }

    func installTerminal(port: UInt16) throws -> Data {
        let policy = Self.policy(layout: layout, executable: nativeExecutable, port: port)
        try NativeOpenCodeAcceptanceFiles.writeExclusive(policy, to: layout.terminalPolicy, mode: 0o400)
        return policy
    }

    func validate(terminalPolicy: Data? = nil) throws {
        try nativeAcceptanceRequire(try NativeOpenCodeAcceptanceFiles.executableWitness(layout.wrapper.path) == wrapperWitness,
                                    "wrapper-changed")
        try nativeAcceptanceRequire(try NativeOpenCodeAcceptanceFiles.readOwnedFile(layout.serverPolicy, limit: 16 * 1024) == serverPolicy,
                                    "boundary-changed")
        if let terminalPolicy {
            try nativeAcceptanceRequire(try NativeOpenCodeAcceptanceFiles.readOwnedFile(layout.terminalPolicy, limit: 16 * 1024) == terminalPolicy,
                                        "boundary-changed")
        }
    }
}

private final class NativeOpenCodeScreen: TerminalOutputSink, TerminalDelegate, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private lazy var terminal: SwiftTerm.Terminal = {
        let value = SwiftTerm.Terminal(delegate: self,
            options: TerminalOptions(cols: 120, rows: 40, scrollback: 0))
        // SwiftTerm's debug default may print parser data. This fixture never
        // emits native terminal content, including on malformed sequences.
        value.silentLog = true
        return value
    }()
    private var queue: TerminalInputQueue?
    private var pending = Data()
    private var totalBytes = 0
    private var failed = false
    private var interaction = false
    private var responseCount = 0
    private var closed = false

    func attach(_ endpoint: TerminalEndpoint) {
        lock.withLock {
            guard !closed else { return }
            queue = TerminalInputQueue(endpoint: endpoint, capacity: 32 * 1024) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { if !self.closed { self.failed = true } }
            }
            if !pending.isEmpty {
                if queue?.enqueueTerminalResponse(pending) != true { failed = true }
                pending.removeAll(keepingCapacity: false)
            }
        }
    }

    func receive(_ data: Data) {
        lock.withLock {
            guard !closed, !failed else { return }
            totalBytes += data.count
            guard totalBytes <= 1024 * 1024 else { failed = true; return }
            terminal.terminalLock.withLock { terminal.feed(byteArray: Array(data)) }
            let text = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
                .joined(separator: "\n").lowercased()
            // A false positive fails closed. The content itself is never logged.
            if ["trust this", "trust the", "approve", "permission required", "permission request",
                "sign in", "log in", "authorize"].contains(where: text.contains) { interaction = true }
        }
    }

    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        // Any reply that lost its origin is refused, never treated as a key.
        lock.withLock { if !closed { failed = true } }
    }

    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>, origin: TerminalInputOrigin) {
        lock.withLock {
            guard !closed else { return }
            guard origin == .protocolResponse, !data.isEmpty else { failed = true; return }
            responseCount += 1
            if let queue {
                if !queue.enqueueTerminalResponse(data) { failed = true }
            } else if pending.count + data.count <= 32 * 1024 {
                pending.append(contentsOf: data)
            } else { failed = true }
        }
    }

    var state: (failed: Bool, needsInteraction: Bool, replies: Int, bytes: Int) {
        lock.withLock { (failed, interaction, responseCount, totalBytes) }
    }

    /// Freeze the final observation and retire input under the same lock, so
    /// late native output cannot alter the acceptance decision.
    @discardableResult
    func close() -> (failed: Bool, needsInteraction: Bool, replies: Int, bytes: Int) {
        lock.withLock {
            closed = true
            queue?.close(reason: "Native acceptance finished")
            queue = nil
            pending.removeAll(keepingCapacity: false)
            return (failed, interaction, responseCount, totalBytes)
        }
    }
}

/// A held owned listener makes an unsuccessful connection meaningful: it
/// cannot be confused with an unbound port or an external network request.
private final class NativeControlListener {
    let fd: Int32
    let port: UInt16
    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeOpenCodeAcceptanceFailure("control-socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd); throw NativeOpenCodeAcceptanceFailure("control-socket")
        }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
    }
    deinit { Darwin.close(fd) }
}

private enum NativeOpenCodeControls {
    private struct Capture: Sendable {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    private static func capture(supervisor: ProcessSupervisor, policy: URL, executable: String, arguments: [String],
                                environment: [String: String], work: String) async throws -> Capture {
        try await supervisor.runOwnedJob(scope: .perCall) { _, job, spawner in
            let result = try LaunchEnvironment.capture("/usr/bin/sandbox-exec", ["-f", policy.path, executable] + arguments,
                environment: environment, directory: work, timeout: 5, outputLimit: 16 * 1024, spawner: spawner,
                onSpawn: job.register, onPoll: job.sample)
            defer { spawner.abort(result.pid) }
            return Capture(stdout: result.stdout, stderr: result.stderr, status: result.status)
        }
    }

    static func check(supervisor: ProcessSupervisor, policy: URL, environment: [String: String],
                      layout: NativeOpenCodeLayout, permittedPort: UInt16?) async throws {
        let inside = layout.root.appendingPathComponent("inside-\(UUID().uuidString)")
        let outside = layout.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        let marker = Data("OWNED-NATIVE-BOUNDARY\n".utf8)
        try NativeOpenCodeAcceptanceFiles.writeExclusive(marker, to: inside)
        defer { unlink(inside.path) }
        try NativeOpenCodeAcceptanceFiles.writeExclusive(marker, to: outside)
        defer { unlink(outside.path) }
        let yes = try await capture(supervisor: supervisor, policy: policy, executable: "/bin/cat",
                                    arguments: [inside.path], environment: environment, work: layout.work.path)
        try nativeAcceptanceRequire(yes.status == 0 && yes.stdout == marker, "boundary-inside")
        let no = try await capture(supervisor: supervisor, policy: policy, executable: "/bin/cat",
                                   arguments: [outside.path], environment: environment, work: layout.work.path)
        let error = String(decoding: no.stderr, as: UTF8.self)
        try nativeAcceptanceRequire(no.status == 256 && no.stdout.isEmpty &&
            (error.contains("Operation not permitted") || error.contains("Permission denied")), "boundary-outside")
        let protected = try NativeOpenCodeAcceptanceFiles.readOwnedFile(policy, limit: 16 * 1024)
        let mutation = try await capture(supervisor: supervisor, policy: policy, executable: "/bin/chmod",
            arguments: ["600", policy.path], environment: environment, work: layout.work.path)
        let mutationError = String(decoding: mutation.stderr, as: UTF8.self)
        var policyInfo = stat()
        try nativeAcceptanceRequire(mutation.status == 256 &&
            (mutationError.contains("Operation not permitted") || mutationError.contains("Permission denied")) &&
            mutationError.contains(policy.path) && lstat(policy.path, &policyInfo) == 0 &&
            policyInfo.st_mode & 0o777 == 0o400 &&
            (try NativeOpenCodeAcceptanceFiles.readOwnedFile(policy, limit: 16 * 1024)) == protected,
            "boundary-policy-write")
        let denied = try NativeControlListener()
        if let permittedPort {
            try nativeAcceptanceRequire(permittedPort != denied.port, "boundary-control-port")
            let accepted = try await capture(supervisor: supervisor, policy: policy, executable: "/usr/bin/nc",
                arguments: ["-z", "-G", "1", "127.0.0.1", String(permittedPort)],
                environment: environment, work: layout.work.path)
            try nativeAcceptanceRequire(accepted.status == 0, "boundary-allowed-port")
        }
        let rejected = try await capture(supervisor: supervisor, policy: policy, executable: "/usr/bin/nc",
            arguments: ["-z", "-G", "1", "127.0.0.1", String(denied.port)],
            environment: environment, work: layout.work.path)
        try nativeAcceptanceRequire(rejected.status != 0 && rejected.status & 0x7f == 0, "boundary-denied-port")
    }
}

private actor NativeOpenCodeTUIIdentity {
    private var leader: ProcessIdentity?
    func register(_ identity: ProcessIdentity) { leader = identity }
    func admits(_ member: RunScopeMember, scope: RunScope, executable: String) async -> Bool {
        // The peer may connect before launch() returns its leader. Wait only
        // for that exact registered leader, never for a cwd or created ID.
        for _ in 0..<200 {
            guard !Task.isCancelled else { return false }
            if let leader {
                return member.identity == leader && member.userID == geteuid() && !member.zombie &&
                    !member.launchdSpawned && ProcessTable.record(pid: leader.pid)?.identity == leader &&
                    ProcessTable.executablePath(pid: leader.pid) == executable &&
                    ((try? scope.members())?.contains(member) == true)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private final class NativeOpenCodeBundleAnchor: NSObject {}

private struct NativeOpenCodeResult: Encodable {
    var result = "FAIL"
    var phase = "setup"
    let modelInputs = 0
    var createAttempts = 0
    var serverBoundaryControls = false
    var tuiBoundaryControls = false
    var profileProof = false
    var bornListener = false
    var eventFeed = false
    var pluginPolicy = false
    var authenticatedExactRoute = false
    var nativeAndBoundaryUnchanged = false
    var interactionRequired = false
    var protocolReplies = 0
    var terminalBytes = 0
    var cleanupVerified = false
}

@Suite(.serialized)
struct NativeOpenCodeTUIAcceptanceTests {
    @Test func syntheticRootAndReservationGuardsDoNotFollowAReplacement() throws {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("sphyrna-native-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("owned", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        for directory in [root, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let resolvedRoot = try NativeOpenCodeAcceptanceFiles.privateDirectory(root)
        #expect(try NativeOpenCodeAcceptanceFiles.privateDirectory(child, beneath: resolvedRoot).path == child.path)
        #expect(throws: NativeOpenCodeAcceptanceFailure.self) {
            try NativeOpenCodeAcceptanceFiles.privateDirectory(outside, beneath: resolvedRoot)
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: NativeOpenCodeAcceptanceFailure.self) {
            try NativeOpenCodeAcceptanceFiles.privateDirectory(link, beneath: resolvedRoot)
        }

        let reservation = root.appendingPathComponent("reservation.json")
        try Data("{}\n".utf8).write(to: reservation)
        #expect(chmod(reservation.path, 0o600) == 0)
        #expect(try NativeOpenCodeAcceptanceFiles.readOwnedFile(reservation, limit: 100) == Data("{}\n".utf8))
        try NativeOpenCodeAcceptanceFiles.claim(reservation)
        #expect(throws: NativeOpenCodeAcceptanceFailure.self) { try NativeOpenCodeAcceptanceFiles.claim(reservation) }
        let substituted = root.appendingPathComponent("substituted.json")
        try FileManager.default.createSymbolicLink(at: substituted, withDestinationURL: reservation)
        #expect(throws: NativeOpenCodeAcceptanceFailure.self) {
            try NativeOpenCodeAcceptanceFiles.readOwnedFile(substituted, limit: 100)
        }
    }

    @Test func terminalRepliesKeepTheirParserOriginAndUnclassifiedInputIsRefused() {
        let screen = NativeOpenCodeScreen()
        screen.receive(Data("\u{1b}[6n".utf8))
        #expect(screen.state.replies == 1)
        #expect(!screen.state.failed)
        let terminal = SwiftTerm.Terminal(delegate: screen, options: TerminalOptions(cols: 80, rows: 24))
        screen.send(source: terminal, data: Array("x".utf8)[...], origin: .unclassified)
        #expect(screen.state.failed)
        screen.close()
    }

    @Test func publishedReservationRecipeBindsTheActualLaunchEnvironment() throws {
        let layout = NativeOpenCodeLayout(root: URL(fileURLWithPath: "/private/tmp/loom-real/e1tui-synthetic"))
        #expect(NativeOpenCodeLayout.environmentDigest(try layout.environment()) ==
                "d16bdac6fd81d258c2e6bb8476d866307a647339c4d1c2ade300cd988c157184")
    }

    @Test func terminalCloseFreezesTheFinalAcceptanceObservation() {
        let screen = NativeOpenCodeScreen()
        screen.receive(Data("Ready".utf8))
        let before = screen.state
        screen.close()
        screen.receive(Data("Permission required\u{1b}[6n".utf8))
        let after = screen.state
        #expect(after.bytes == before.bytes)
        #expect(after.replies == before.replies)
        #expect(after.needsInteraction == before.needsInteraction)
        #expect(after.failed == before.failed)
    }

    @Test(.enabled(if: NativeOpenCodeAcceptanceGate.enabled,
                   "Explicit isolated zero-input native acceptance inputs are required"),
          .timeLimit(.minutes(6)))
    func ownedNativeTUIObservesItsExactNewSessionWithoutInput() async {
        var result = NativeOpenCodeResult()
        var input: NativeOpenCodeAcceptanceInputs?
        var supervisor: ProcessSupervisor?
        var scope: RunScope?
        var manager: OpenCodeServerManager?
        var bridge: OpenCodeTUIBridge?
        var terminalID: UUID?
        var serverIdentity: ProcessIdentity?
        var serverPort: UInt16?
        var observed = Set<ProcessIdentity>()
        var claimed = false
        var failure: String?
        let screen = NativeOpenCodeScreen()
        do {
            let value = try NativeOpenCodeAcceptanceInputs.read()
            input = value
            let layout = NativeOpenCodeLayout(root: value.root)
            let environment = try layout.environment()
            try nativeAcceptanceRequire(value.approval.roots == layout.roots &&
                value.approval.environmentSHA256 == NativeOpenCodeLayout.environmentDigest(environment), "approval-layout")
            try NativeOpenCodeAcceptanceFiles.claim(value.reservation)
            claimed = true
            try layout.prepare()
            let boundary = try NativeOpenCodeBoundary.install(layout: layout, executable: value.executable)
            _ = try OpenCodeTUIPlugin.install(in: layout.plugin)
            try boundary.validate()

            let binaries = Bundle(for: NativeOpenCodeBundleAnchor.self).bundleURL.deletingLastPathComponent()
            let bundle = try RunScopeLauncher.assembleOwnedBundle(
                executable: binaries.appendingPathComponent("loom-run-host"), in: layout.host)
            let catalog = try SessionCatalog(url: layout.root.appendingPathComponent("acceptance.sqlite3"))
            let owner = try await ProcessSupervisor.restoring(catalog: catalog,
                scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: layout.sockets.appendingPathComponent("r")))
            supervisor = owner
            result.phase = "server-boundary-controls"
            try await NativeOpenCodeControls.check(supervisor: owner, policy: layout.serverPolicy,
                                                    environment: environment, layout: layout, permittedPort: nil)
            result.serverBoundaryControls = true
            try boundary.validate()
            try nativeAcceptanceRequire(try NativeOpenCodeAcceptanceFiles.executableWitness(value.executable) == value.executableWitness,
                                        "native-executable-changed")
            result.phase = "native-profile"
            let proof = try await OpenCodeProfileProof.acquire(supervisor: owner, executable: layout.wrapper.path,
                environment: environment, workingDirectory: layout.work.path, expected: layout.profileRoots,
                expectedResolved: layout.profileRoots, timeout: 10)
            result.profileProof = true
            try boundary.validate()
            try nativeAcceptanceRequire(try NativeOpenCodeAcceptanceFiles.executableWitness(value.executable) == value.executableWitness,
                                        "native-executable-changed")
            let ownedScope = try await owner.openScope()
            scope = ownedScope
            observed.formUnion(try ownedScope.members().map(\.identity))
            result.phase = "server"
            let server = OpenCodeServerManager(supervisor: owner, configuration: OpenCodeServerConfiguration(
                executable: layout.wrapper.path, workingDirectory: layout.work.path, environment: environment,
                expectedVersion: value.approval.version, profileProof: proof, startupTimeout: 30, scope: ownedScope))
            manager = server
            let client = try await server.start()
            guard let portValue = client.serverURL.port, let port = UInt16(exactly: portValue) else {
                throw NativeOpenCodeAcceptanceFailure("listener")
            }
            serverPort = port
            let members = try ownedScope.members()
            observed.formUnion(members.map(\.identity))
            let listeners = members.filter {
                $0.userID == geteuid() && !$0.zombie && !$0.launchdSpawned &&
                ProcessTable.executablePath(pid: $0.identity.pid) == value.executable &&
                OpenCodeListenerOwnership.owns(leader: $0.identity, port: port)
            }
            guard listeners.count == 1 else { throw NativeOpenCodeAcceptanceFailure("listener") }
            serverIdentity = listeners[0].identity
            result.bornListener = true
            result.phase = "terminal-boundary-controls"
            let terminalPolicy = try boundary.installTerminal(port: port)
            try await NativeOpenCodeControls.check(supervisor: owner, policy: layout.terminalPolicy,
                                                    environment: environment, layout: layout, permittedPort: port)
            result.tuiBoundaryControls = true
            try boundary.validate(terminalPolicy: terminalPolicy)
            try nativeAcceptanceRequire(try NativeOpenCodeAcceptanceFiles.executableWitness(value.executable) == value.executableWitness,
                                        "native-executable-changed")
            let appID = UUID(), runID = UUID(), instanceID = UUID()
            result.phase = "live-feed"
            let feed = try await client.openLive(appSessionID: appID, runID: runID, timeout: 10)
            result.eventFeed = feed.isConnected
            try nativeAcceptanceRequire(result.eventFeed, "live-feed")
            result.phase = "create-empty-session"
            result.createAttempts = 1
            let session = try await client.create(directory: layout.work.path, model: nil)
            result.phase = "plugin-policy"
            let policy = try await client.validateTUIPluginPolicy(pluginDirectory: layout.plugin)
            result.pluginPolicy = policy.isValid
            try nativeAcceptanceRequire(result.pluginPolicy, "plugin-policy")
            let creationDeadline = ProcessInfo.processInfo.systemUptime + 5
            while feed.snapshot?.creationSequence == nil && feed.isConnected &&
                    ProcessInfo.processInfo.systemUptime < creationDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try nativeAcceptanceRequire(feed.snapshot?.creationSequence != nil, "creation-event")
            let identity = NativeOpenCodeTUIIdentity()
            let observer = try OpenCodeTUIBridge.start(socketPath: layout.bridge, appSessionID: appID,
                runID: runID, instanceID: instanceID, policy: policy) { member in
                    await identity.admits(member, scope: ownedScope, executable: value.executable)
                }
            bridge = observer
            let base = try await client.terminalProfile(directory: layout.work.path, environment: environment)
            let profile = try observer.applyingToTerminal(base)
            let launchEnvironment = LaunchEnvironment.make(base: profile.environment,
                runID: owner.ownershipRunID, sessionID: appID)
            let managed = ManagedSession(id: appID, provider: .synthetic, workingDirectory: layout.work.path)
            try await owner.createInternalSession(managed)
            terminalID = appID
            result.phase = "native-tui"
            let launch = try await owner.launch(sessionID: appID, executable: layout.wrapper.path,
                arguments: profile.arguments, environment: launchEnvironment, rows: 40, columns: 120,
                outputSink: screen, managedRunID: runID, scope: ownedScope)
            guard let leader = launch.session.currentRun?.leader else { throw NativeOpenCodeAcceptanceFailure("tui-leader") }
            await identity.register(leader)
            observed.insert(leader)
            screen.attach(launch.terminal)
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            repeat {
                let state = screen.state
                if state.failed { throw NativeOpenCodeAcceptanceFailure("terminal-output") }
                if state.needsInteraction { throw NativeOpenCodeAcceptanceFailure("interaction-required") }
                let selection = observer.snapshot
                if selection.appSessionID == appID && selection.runID == runID && selection.instanceID == instanceID &&
                    selection.generation != nil && selection.route == .session(session.id) {
                    result.authenticatedExactRoute = true
                    break
                }
                if await launch.terminal.exitStatus() != nil { throw NativeOpenCodeAcceptanceFailure("tui-exited") }
                try await Task.sleep(for: .milliseconds(50))
            } while ProcessInfo.processInfo.systemUptime < deadline
            try nativeAcceptanceRequire(result.authenticatedExactRoute, "route-unavailable")
            try boundary.validate(terminalPolicy: terminalPolicy)
            try nativeAcceptanceRequire(try NativeOpenCodeAcceptanceFiles.executableWitness(value.executable) == value.executableWitness,
                                        "native-executable-changed")
            result.nativeAndBoundaryUnchanged = true
            observed.formUnion(try ownedScope.members().map(\.identity))
            result.phase = "cleanup"
        } catch {
            failure = (error as? NativeOpenCodeAcceptanceFailure)?.phase ?? result.phase
        }

        let screenState = screen.close()
        result.protocolReplies = screenState.replies
        result.terminalBytes = screenState.bytes
        result.interactionRequired = screenState.needsInteraction
        if screenState.failed { failure = failure ?? "terminal-output" }
        if screenState.needsInteraction { failure = failure ?? "interaction-required" }
        if let bridge { await bridge.stop() }
        var cleanup = true
        if let scope {
            if let members = try? scope.members() { observed.formUnion(members.map(\.identity)) }
            else { cleanup = false }
        }
        if let supervisor, let terminalID, await supervisor.session(id: terminalID)?.currentRun != nil {
            do { if try await supervisor.stop(sessionID: terminalID, graceSeconds: 0.05).succeeded == false { cleanup = false } }
            catch { cleanup = false }
        }
        if let manager {
            let stopped = await manager.stop()
            if !stopped.errors.isEmpty || stopped.report?.succeeded == false { cleanup = false }
        }
        if let supervisor, let scope {
            if (try? scope.forkedMembers().isEmpty) != true { cleanup = false }
            if !(await supervisor.releaseScope(scope)).isEmpty { cleanup = false }
        }
        if let supervisor, !(await supervisor.shutdown()).succeeded { cleanup = false }
        if let living = try? ProcessTable.snapshot() {
            if !observed.isDisjoint(with: Set(living.map(\.identity))) { cleanup = false }
        } else { cleanup = false }
        if let serverIdentity, let serverPort, OpenCodeListenerOwnership.owns(leader: serverIdentity, port: serverPort) {
            cleanup = false
        }
        if let input {
            var info = stat()
            let layout = NativeOpenCodeLayout(root: input.root)
            let socketPath = layout.bridge
            if lstat(socketPath, &info) == 0 || errno != ENOENT { cleanup = false }
            let hostSockets = layout.sockets.appendingPathComponent("r")
            if lstat(hostSockets.path, &info) == 0 {
                if (try? FileManager.default.contentsOfDirectory(atPath: hostSockets.path).isEmpty) != true { cleanup = false }
            } else if errno != ENOENT { cleanup = false }
        }
        result.cleanupVerified = cleanup
        if cleanup && failure == nil && result.authenticatedExactRoute {
            result.result = "PASS"
            result.phase = "complete"
        } else {
            result.phase = failure ?? "cleanup-unverified"
        }
        if let input, claimed {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                var bytes = try encoder.encode(result); bytes.append(10)
                try NativeOpenCodeAcceptanceFiles.writeExclusive(bytes,
                    to: URL(fileURLWithPath: input.reservation.path + ".result.json"))
            } catch { Issue.record("Could not write bounded native acceptance result") }
        }
        if cleanup, let input { RunScopeLauncher.removeOwnedBundle(in: NativeOpenCodeLayout(root: input.root).host) }
        if result.result != "PASS" { Issue.record("Native zero-input acceptance failed: \(result.phase)") }
    }
}
