import CLoomPOSIX
import Darwin
import Foundation
import Security
import Synchronization

/// One process in a run scope's resource coalition. `launchdSpawned` members
/// (the run host itself and per-requester XPC service instances) are never
/// signaled by Loom; every other member was forked from managed work.
public struct RunScopeMember: Codable, Equatable, Sendable {
    public let identity: ProcessIdentity
    public let userID: UInt32
    public let zombie: Bool
    public let launchdSpawned: Bool
    public let idVersion: Int32
}

/// Durable recovery handle: coalition IDs are not reused within one boot.
public struct RunScopeRecord: Codable, Equatable, Hashable, Sendable {
    public let coalitionID: UInt64
    public let bootSessionID: String
    public let hostPID: Int32
    public let hostIDVersion: Int32
}

public enum RunScopeError: Error, CustomStringConvertible, Sendable {
    case hostUnavailable(String)
    case handshake(String)
    case lost
    case spawn(Int32)
    case membership(Int32)

    public var description: String {
        switch self {
        case let .hostUnavailable(detail): "Run scope could not be started: \(detail)"
        case let .handshake(detail): "Run scope could not be verified: \(detail)"
        case .lost: "Run scope host connection was lost"
        case let .spawn(code): "Run scope could not start the process: \(String(cString: strerror(code))) (\(code))"
        case let .membership(code): "Run scope membership is unreadable: \(String(cString: strerror(code))) (\(code))"
        }
    }
}

public enum RunScopeTable {
    public static func lineage(pid: Int32) -> RunScopeMember? {
        var raw = loom_scope_member()
        guard loom_process_lineage(pid, &raw) == 0 else { return nil }
        return member(raw)
    }

    /// Every live process of the coalition, or an error when any process that
    /// could belong to it is unreadable.
    public static func members(coalitionID: UInt64) throws -> [RunScopeMember] {
        var pointer: UnsafeMutablePointer<loom_scope_member>?
        var count = 0
        guard loom_scope_members(coalitionID, &pointer, &count) == 0 else {
            throw RunScopeError.membership(errno)
        }
        defer { loom_free_scope_members(pointer) }
        guard let pointer else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).map(member)
    }

    /// One process-table pass for several scopes, keyed by coalition.
    public static func members(coalitionIDs: [UInt64]) throws -> [UInt64: [RunScopeMember]] {
        guard !coalitionIDs.isEmpty else { return [:] }
        var pointer: UnsafeMutablePointer<loom_scope_member>?
        var count = 0
        let status = coalitionIDs.withUnsafeBufferPointer {
            loom_scopes_members($0.baseAddress, $0.count, &pointer, &count)
        }
        guard status == 0 else { throw RunScopeError.membership(errno) }
        defer { loom_free_scope_members(pointer) }
        var result: [UInt64: [RunScopeMember]] = [:]
        guard let pointer else { return result }
        for raw in UnsafeBufferPointer(start: pointer, count: count) {
            result[raw.coalition_id, default: []].append(member(raw))
        }
        return result
    }

    /// Signals only while pid still names the same process in the same scope.
    /// A vanished or reused PID is not an error: that process is gone.
    public static func signal(_ member: RunScopeMember, coalitionID: UInt64, _ signal: Int32) throws {
        guard loom_signal_scope_member(
            member.identity.pid, member.idVersion, coalitionID, signal
        ) == 0 else {
            if errno == ESRCH { return }
            throw LoomError.system("signal \(member.identity.pid)", errno)
        }
    }

    private static func member(_ raw: loom_scope_member) -> RunScopeMember {
        RunScopeMember(
            identity: ProcessIdentity(pid: raw.pid, startSeconds: raw.start_sec,
                                      startMicroseconds: raw.start_usec),
            userID: raw.uid, zombie: raw.zombie != 0,
            launchdSpawned: raw.launchd_spawned != 0, idVersion: raw.id_version
        )
    }
}

/// Starts run hosts through LaunchServices, which gives each instance a fresh
/// resource coalition; Loom itself cannot create one or spawn into one.
public struct RunScopeLauncher: Sendable {
    public static let hostExecutableName = "loom-run-host"
    public let hostBundle: URL
    public let socketDirectory: URL
    public let handshakeTimeout: TimeInterval

    public init(hostBundle: URL, socketDirectory: URL, handshakeTimeout: TimeInterval = 10) {
        self.hostBundle = hostBundle
        self.socketDirectory = socketDirectory
        self.handshakeTimeout = handshakeTimeout
    }

    public func launch() async throws -> RunScope {
        try await Task.detached { try self.launchBlocking() }.value
    }

    /// Writes a minimal background-only bundle around a built host executable.
    /// Packaging uses the same layout; tests use it to run real scopes.
    public static func assembleBundle(executable: URL, at bundle: URL, ownerRequirement: String) throws {
        let fileManager = FileManager.default
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try? fileManager.removeItem(at: bundle)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.copyItem(at: executable, to: macOS.appendingPathComponent(hostExecutableName))
        let plist: [String: Any] = [
            "CFBundleExecutable": hostExecutableName,
            "CFBundleIdentifier": "local.loom.run-host",
            "CFBundleName": "LoomRunHost",
            "CFBundlePackageType": "APPL",
            "LSBackgroundOnly": true,
            "LSMultipleInstancesProhibited": false,
            // Sealed by the signature below: the only code this host serves.
            "LoomOwnerRequirement": ownerRequirement,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let status = try runTool("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path], timeout: 30)
        guard status == 0 else { throw RunScopeError.hostUnavailable("codesign exited \(status)") }
    }

    /// Test/probe layout: a host whose owner is `owner` (default: the calling
    /// process's own executable), identified by that code's designated
    /// requirement. Returns the host bundle to pass to the launcher.
    public static func assembleOwnedBundle(executable: URL, in root: URL,
                                           owner: URL? = nil) throws -> URL {
        guard let path = owner?.path ?? ProcessTable.executablePath(pid: getpid()) else {
            throw RunScopeError.hostUnavailable("caller executable is unknown")
        }
        let host = root.appendingPathComponent("LoomRunHost.app")
        try assembleBundle(executable: executable, at: host,
                           ownerRequirement: try designatedRequirement(of: URL(fileURLWithPath: path)))
        return host
    }

    /// Removes `root`, a folder that `assembleOwnedBundle` may have assembled a host in. `open`
    /// registers every host it launches with LaunchServices, and that record outlives the folder, so
    /// the host is unregistered first.
    public static func removeOwnedBundle(in root: URL) {
        let host = root.appendingPathComponent("LoomRunHost.app")
        if FileManager.default.fileExists(atPath: host.path) {
            _ = try? runTool(lsregisterPath, ["-u", host.path], timeout: 10)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func designatedRequirement(of code: URL) throws -> String {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(code as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw RunScopeError.hostUnavailable("cannot read the code requirement of \(code.lastPathComponent)")
        }
        return text as String
    }

    private func launchBlocking() throws -> RunScope {
        let expected = hostBundle.appendingPathComponent("Contents/MacOS/\(Self.hostExecutableName)")
        guard FileManager.default.isExecutableFile(atPath: expected.path) else {
            throw RunScopeError.hostUnavailable("host executable is missing")
        }
        try FileManager.default.createDirectory(
            at: socketDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let token = (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
        let path = socketDirectory.appendingPathComponent("h-\(token.prefix(12)).sock").path
        let listener = try Self.listen(at: path)
        defer { Darwin.close(listener); unlink(path) }
        let deadline = ProcessInfo.processInfo.systemUptime + handshakeTimeout
        let status = try Self.runTool("/usr/bin/open", [
            "-n", "-g", "-j", hostBundle.path, "--args", "--socket", path, "--token", token,
        ], timeout: handshakeTimeout)
        guard status == 0 else { throw RunScopeError.hostUnavailable("LaunchServices open exited \(status)") }
        let connection = try Self.accept(listener, until: deadline)
        do {
            return try verify(connection, token: token, expected: expected, deadline: deadline)
        } catch {
            // Closing without EXIT makes a genuine host clean up and exit.
            Darwin.close(connection)
            throw error
        }
    }

    private func verify(_ connection: Int32, token: String, expected: URL,
                        deadline: TimeInterval) throws -> RunScope {
        let remaining = max(0.01, deadline - ProcessInfo.processInfo.systemUptime)
        var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var type: UInt8 = 0
        var length: UInt32 = 0
        var payload = [UInt8](repeating: 0, count: 256)
        var fds = [Int32](repeating: -1, count: 3)
        var fdCount: Int32 = 0
        guard loom_receive_frame(connection, &type, &payload, UInt32(payload.count),
                                 &length, &fds, &fdCount) == 0 else {
            throw RunScopeError.handshake("no hello (\(String(cString: strerror(errno))))")
        }
        for index in 0..<Int(fdCount) { Darwin.close(fds[index]) }
        guard type == RunScope.Frame.hello.rawValue, fdCount == 0,
              String(decoding: payload.prefix(Int(length)), as: UTF8.self) == token else {
            throw RunScopeError.handshake("unexpected hello")
        }
        var cleared = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &cleared, socklen_t(MemoryLayout<timeval>.size))
        var peerPID: pid_t = 0
        var peerVersion: Int32 = 0
        var peerUID: uid_t = 0
        guard loom_socket_peer_version(connection, &peerPID, &peerVersion, &peerUID) == 0,
              peerUID == getuid() else {
            throw RunScopeError.handshake("peer is not this user")
        }
        // The audit token's pid version binds every check below to the
        // connected process itself, not to whatever later reuses its PID.
        guard let host = RunScopeTable.lineage(pid: peerPID), host.idVersion == peerVersion,
              host.launchdSpawned,
              let path = ProcessTable.executablePath(pid: peerPID),
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                == expected.resolvingSymlinksInPath().path else {
            throw RunScopeError.handshake("peer is not a LaunchServices run host")
        }
        guard let coalition = ProcessTable.resourceCoalition(pid: peerPID),
              coalition != ProcessTable.resourceCoalition(pid: getpid()) else {
            throw RunScopeError.handshake("host does not have its own coalition")
        }
        let members = try RunScopeTable.members(coalitionID: coalition)
        guard members.filter({ !$0.zombie }).map(\.identity) == [host.identity] else {
            throw RunScopeError.handshake("host coalition is not exclusive")
        }
        return RunScope(connection: connection, coalitionID: coalition, host: host)
    }

    private static func listen(at path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw RunScopeError.hostUnavailable("socket path too long") }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoomError.system("run scope socket", errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 1) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw LoomError.system("run scope listen", code)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        return descriptor
    }

    private static func accept(_ listener: Int32, until deadline: TimeInterval) throws -> Int32 {
        while true {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw RunScopeError.handshake("host did not connect in time") }
            var watched = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watched, 1, Int32(min(left, 1) * 1000))
            if ready < 0 && errno != EINTR { throw LoomError.system("run scope accept", errno) }
            guard ready > 0 else { continue }
            let connection = Darwin.accept(listener, nil, nil)
            if connection < 0 {
                if errno == EAGAIN || errno == EINTR || errno == ECONNABORTED { continue }
                throw LoomError.system("run scope accept", errno)
            }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
            var noSigpipe: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            return connection
        }
    }

    /// Short-lived tool children (open, codesign) are reaped before returning.
    @discardableResult
    static func runTool(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null",
                                             descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { environment.forEach { free($0) } }
        var pid: pid_t = 0
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the tool: never a host
        // connection, listener or capture pipe opened concurrently.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environment)
        guard spawned == 0 else { throw LoomError.system("spawn \(executable)", spawned) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result < 0 && errno != EINTR { throw LoomError.system("wait \(executable)", errno) }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw RunScopeError.hostUnavailable("\(executable) timed out")
            }
            usleep(2_000)
        }
        return status
    }
}

/// Connection to one verified run host. Loom keeps run ownership: the host
/// only spawns into its coalition and reports exit statuses of its children.
public final class RunScope: @unchecked Sendable {
    enum Frame: UInt8 { case hello = 1, spawn = 2, spawned = 3, exited = 4, exit = 5 }

    public enum Stdio: Sendable {
        /// The PTY slave becomes the child's controlling terminal.
        case terminal(slave: Int32)
        case descriptors(input: Int32, output: Int32, error: Int32)
    }

    public let coalitionID: UInt64
    public let host: RunScopeMember
    public let record: RunScopeRecord

    private let connection: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var nextRequest: UInt32 = 1
    private var pending: [UInt32: @Sendable (Result<Int32, any Error>) -> Void] = [:]
    private var statuses: [Int32: Int32] = [:]
    private var versions: [Int32: Int32] = [:]
    private let spawnReplyTimeout: DispatchTimeInterval = .seconds(30)
    private var lost = false
    private var exitSent = false
    private var closed = false
    private var readSource: DispatchSourceRead?

    init(connection: Int32, coalitionID: UInt64, host: RunScopeMember) {
        self.connection = connection
        self.coalitionID = coalitionID
        self.host = host
        record = RunScopeRecord(
            coalitionID: coalitionID, bootSessionID: ProcessTable.bootSessionID() ?? "",
            hostPID: host.identity.pid, hostIDVersion: host.idVersion
        )
        queue = DispatchQueue(label: "dev.loom.run-scope.\(coalitionID)")
        let source = DispatchSource.makeReadSource(fileDescriptor: connection, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.setCancelHandler { Darwin.close(connection) }
        readSource = source
        source.activate()
    }

    deinit { readSource?.cancel() }

    /// Starts one process in this scope. Descriptors are duplicated into the
    /// host; the caller keeps and closes its own copies.
    public func spawn(executable: String, arguments: [String], environment: [String: String],
                      directory: String, stdio: Stdio) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            send(executable: executable, arguments: arguments, environment: environment,
                 directory: directory, stdio: stdio) { continuation.resume(with: $0) }
        }
    }

    /// Blocking variant for the synchronous environment/helper capture. The
    /// reply arrives on this scope's own queue, never the caller's thread.
    func spawnBlocking(executable: String, arguments: [String], environment: [String: String],
                       directory: String, stdio: Stdio) throws -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<Result<Int32, any Error>?>(nil)
        send(executable: executable, arguments: arguments, environment: environment,
             directory: directory, stdio: stdio) { reply in
            result.withLock { $0 = reply }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.withLock { $0! }.get()
    }

    /// The child's waitpid status once the host reported its exit.
    func exitStatus(of pid: Int32) -> Int32? { lock.withLock { statuses[pid] } }

    private func send(executable: String, arguments: [String], environment: [String: String],
                      directory: String, stdio: Stdio,
                      reply: @escaping @Sendable (Result<Int32, any Error>) -> Void) {
        let strings = [executable, directory, executable] + arguments
            + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        guard strings.allSatisfy({ !$0.utf8.contains(0) }) else {
            reply(.failure(LoomError.message("Invalid launch argument")))
            return
        }
        let descriptors: [Int32]
        let mode: UInt8
        switch stdio {
        case let .terminal(slave): descriptors = [slave]; mode = 1
        case let .descriptors(input, output, error): descriptors = [input, output, error]; mode = 2
        }
        lock.lock()
        guard !lost, !exitSent else {
            lock.unlock()
            reply(.failure(RunScopeError.lost))
            return
        }
        let request = nextRequest
        nextRequest &+= 1
        pending[request] = reply
        lock.unlock()
        // A host stuck before replying must not hang a launch forever.
        queue.asyncAfter(deadline: .now() + spawnReplyTimeout) { [weak self] in
            guard let self, lock.withLock({ pending[request] != nil }) else { return }
            connectionLost()
        }
        var payload = [UInt8]()
        payload += Self.u32(request)
        payload.append(mode)
        payload += Self.u32(UInt32(1 + arguments.count))
        payload += Self.u32(UInt32(environment.count))
        for string in strings { payload += Array(string.utf8) + [0] }
        // The caller's descriptors must stay open until this send completes;
        // both callers wait for the reply, which can only follow the send.
        queue.async { [self] in
            // The descriptor may already be closed (and its number reused);
            // connectionLost has then failed this request.
            guard !lock.withLock({ closed }) else { return }
            let sent = payload.withUnsafeBytes { bytes in
                descriptors.withUnsafeBufferPointer { fds in
                    loom_send_frame(connection, Frame.spawn.rawValue, bytes.baseAddress,
                                    UInt32(bytes.count), fds.baseAddress, Int32(fds.count))
                }
            }
            if sent != 0 { connectionLost() }
        }
    }

    /// waitpid-shaped reaper for EventDrivenPTYProcess: pid with status when
    /// the host reported the exit; 0 while running; -2 when the host is gone
    /// and the process no longer exists, so its status cannot be known.
    func reap(_ pid: Int32, _ status: UnsafeMutablePointer<Int32>) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if let known = statuses[pid] {
            status.pointee = known
            return pid
        }
        if lost {
            // Bare PIDs can be reused: the spawned process is gone when its
            // recorded pid version no longer names a live process.
            guard let version = versions[pid] else { return -2 }
            if RunScopeTable.lineage(pid: pid)?.idVersion != version { return -2 }
        }
        return 0
    }

    public func members() throws -> [RunScopeMember] {
        try RunScopeTable.members(coalitionID: coalitionID)
    }

    /// Forked work still alive in the scope; launchd-spawned members excluded.
    public func forkedMembers() throws -> [RunScopeMember] {
        try members().filter { !$0.launchdSpawned && !$0.zombie }
    }

    /// Ends the scope after its runs were stopped: asks the host to exit, then
    /// requires the coalition to become empty. Launchd-spawned service
    /// instances are left to launchd. Idempotent; returns errors, not success.
    public func release(timeout: TimeInterval = 10) async -> [String] {
        // EXIT ends the host without cleanup; forked work must already be gone
        // or it would survive hostless.
        do {
            let forked = try forkedMembers()
            guard forked.isEmpty else {
                return ["Run scope \(coalitionID) still has \(forked.count) forked process(es); the run host was kept"]
            }
        } catch { return [String(describing: error)] }
        let shouldSend = lock.withLock {
            let send = !exitSent && !lost
            exitSent = true
            return send
        }
        if shouldSend {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { [self] in
                    if !lock.withLock({ closed }) {
                        _ = loom_send_frame(connection, Frame.exit.rawValue, nil, 0, nil, 0)
                    }
                    continuation.resume()
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
        var live: [RunScopeMember] = []
        repeat {
            do { live = try members().filter { !$0.zombie } }
            catch { return [String(describing: error)] }
            if live.isEmpty {
                closeConnection()
                return []
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        let services = live.filter { $0.launchdSpawned && $0.identity.pid != host.identity.pid }.count
        let forked = live.filter { !$0.launchdSpawned }.count
        let hostAlive = live.contains { $0.identity.pid == host.identity.pid }
        var parts: [String] = []
        if forked > 0 { parts.append("\(forked) forked process(es)") }
        if services > 0 { parts.append("\(services) launchd-started service instance(s)") }
        if hostAlive { parts.append("the run host") }
        return ["Run scope \(coalitionID) is not empty: " + parts.joined(separator: ", ")]
    }

    /// Simulates Loom disappearing: the connection closes without EXIT.
    func dropConnectionForTesting() {
        lock.withLock { lost = true }
        closeConnection()
    }

    private func receive() {
        var type: UInt8 = 0
        var length: UInt32 = 0
        var payload = [UInt8](repeating: 0, count: 64)
        var fds = [Int32](repeating: -1, count: 3)
        var fdCount: Int32 = 0
        guard loom_receive_frame(connection, &type, &payload, UInt32(payload.count),
                                 &length, &fds, &fdCount) == 0 else {
            connectionLost()
            return
        }
        for index in 0..<Int(fdCount) { Darwin.close(fds[index]) }
        switch (Frame(rawValue: type), length) {
        case (.spawned, 12):
            let request = Self.u32(payload, 0)
            let pid = Int32(bitPattern: Self.u32(payload, 4))
            let code = Int32(bitPattern: Self.u32(payload, 8))
            if pid > 0, let version = RunScopeTable.lineage(pid: pid)?.idVersion {
                lock.withLock { versions[pid] = version }
            }
            let reply = lock.withLock { pending.removeValue(forKey: request) }
            if pid > 0 { reply?(.success(pid)) }
            else { reply?(.failure(RunScopeError.spawn(code == 0 ? EIO : code))) }
        case (.exited, 8):
            let pid = Int32(bitPattern: Self.u32(payload, 0))
            let status = Int32(bitPattern: Self.u32(payload, 4))
            lock.lock()
            statuses[pid] = status
            lock.unlock()
        default:
            connectionLost()
        }
    }

    private func connectionLost() {
        lock.lock()
        lost = true
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        closeConnection()
        for reply in waiting.values { reply(.failure(RunScopeError.lost)) }
    }

    /// The read source's cancel handler closes the descriptor exactly once.
    private func closeConnection() {
        lock.lock()
        let shouldClose = !closed
        closed = true
        lock.unlock()
        if shouldClose { readSource?.cancel() }
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
