import CLoomPOSIX
import Darwin
import Foundation

/// Ordered, bounded ingress. Loss invalidates provider work state rather than
/// presenting an old completion as current.
final class AgyHookIngress: Sendable {
    let stream: AsyncStream<AgyHookEvent>
    private let continuation: AsyncStream<AgyHookEvent>.Continuation
    private let supervisor: ProcessSupervisor
    private let runID: UUID

    init(supervisor: ProcessSupervisor, runID: UUID) {
        self.supervisor = supervisor
        self.runID = runID
        let pair = AsyncStream<AgyHookEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
        stream = pair.stream
        continuation = pair.continuation
    }

    func receive(_ event: AgyHookEvent) {
        switch continuation.yield(event) {
        case .enqueued: break
        case .dropped, .terminated: _ = supervisor.invalidateProviderWorkState(runID: runID)
        @unknown default: _ = supervisor.invalidateProviderWorkState(runID: runID)
        }
    }

    func finish() { continuation.finish() }
}

/// One private hook route per owned AGY run. The bearer alone is not enough:
/// the kernel peer must still be a live member of that exact run's coalition.
final class AgyHookServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sphyrna.agy.hook", qos: .userInitiated)
    private let lock = NSLock()
    private let closed = AgySocketClosure()
    private let path: String
    private let device: dev_t
    private let inode: ino_t
    private let token: String
    private let sessionID: UUID
    private let runID: UUID
    private let coalition: UInt64
    private let helperPath: String
    private let ingress: AgyHookIngress
    private var source: DispatchSourceRead?
    private var stopped = false

    init(path: String, token: String, sessionID: UUID, runID: UUID, scope: RunScope, helperPath: String,
         ingress: AgyHookIngress) throws {
        self.path = path; self.token = token; self.sessionID = sessionID; self.runID = runID
        coalition = scope.coalitionID; self.ingress = ingress
        self.helperPath = URL(fileURLWithPath: helperPath).standardizedFileURL.resolvingSymlinksInPath().path
        let fd = try LocalSocket.listen(at: path)
        var node = stat()
        guard lstat(path, &node) == 0, node.st_uid == geteuid(),
              node.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            Darwin.close(fd)
            throw AgyLaunchError.invalidTarget
        }
        device = node.st_dev; inode = node.st_ino
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let closed = self.closed, device = node.st_dev, inode = node.st_ino
        source.setEventHandler { [weak self] in self?.acceptAvailable(fd) }
        source.setCancelHandler {
            Darwin.close(fd)
            var current = stat()
            let result: Bool
            if lstat(path, &current) != 0 { result = errno == ENOENT }
            else if current.st_uid == geteuid(), current.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
                    current.st_dev == device, current.st_ino == inode { result = unlink(path) == 0 }
            else { result = false }
            closed.finish(result)
        }
        self.source = source
        source.resume()
    }

    deinit { stop() }

    func stop() {
        let source = lock.withLock { () -> DispatchSourceRead? in
            guard !stopped else { return nil }
            stopped = true
            let value = self.source; self.source = nil
            return value
        }
        source?.cancel()
    }

    func stopAndWait() async -> Bool { stop(); return await closed.wait() }

    private func acceptAvailable(_ fd: Int32) {
        while !lock.withLock({ stopped }) {
            let connection = Darwin.accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            defer { Darwin.close(connection) }
            guard (try? LocalSocket.prepare(connection)) != nil, let peer = Self.peer(connection),
                  owns(peer) else { continue }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            guard let data = try? LocalSocket.readToEnd(from: connection, limit: 72 * 1024, deadline: deadline),
                  let wire = try? JSONDecoder().decode(AgyHookWire.self, from: data),
                  wire.sessionID == sessionID, wire.runID == runID, secureEqual(wire.token, token),
                  wire.event.isWellFormed, Self.peer(connection) == peer, owns(peer),
                  !lock.withLock({ stopped }) else { continue }
            ingress.receive(wire.event)
            try? LocalSocket.writeAll(Data("ok".utf8), to: connection, deadline: deadline)
        }
    }

    private func owns(_ peer: RunScopeMember) -> Bool {
        guard ProcessTable.resourceCoalition(pid: peer.identity.pid) == coalition,
              let path = ProcessTable.executablePath(pid: peer.identity.pid) else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == helperPath
    }

    private static func peer(_ fd: Int32) -> RunScopeMember? {
        var pid: pid_t = 0, version: Int32 = 0
        var uid: uid_t = 0
        guard loom_socket_peer_version(fd, &pid, &version, &uid) == 0, uid == geteuid(),
              let member = RunScopeTable.lineage(pid: pid), member.idVersion == version,
              member.userID == uid, !member.zombie, !member.launchdSpawned else { return nil }
        return member
    }
}

private final class AgySocketClosure: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    func finish(_ value: Bool) {
        let pending = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            result = value
            let value = waiters; waiters.removeAll(); return value
        }
        for waiter in pending { waiter.resume(returning: value) }
    }
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let value = lock.withLock { () -> Bool? in
                if let result { return result }
                waiters.append(continuation); return nil
            }
            if let value { continuation.resume(returning: value) }
        }
    }
}
