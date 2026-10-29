import CLoomPOSIX
import Darwin
import Foundation

public enum OpenCodeTUIRoute: Equatable, Sendable {
    case unavailable, home, plugin, session(String)
}

/// Passive route evidence only; it is never a mutation or input lease.
public struct OpenCodeTUISelection: Equatable, Sendable {
    public let appSessionID: UUID
    public let runID: UUID
    public let instanceID: UUID
    public let generation: Int64?
    public let route: OpenCodeTUIRoute
}

/// One per TUI instance/run. Only the current route and one generation are
/// retained. A kernel-audited peer plus the caller's live owned-TUI validator
/// and invocation-local token are all required before metadata is accepted.
public final class OpenCodeTUIBridge: @unchecked Sendable {
    public typealias Validator = @Sendable (RunScopeMember) async -> Bool
    private final class Peer {
        let fd: Int32
        let identity: RunScopeMember
        var authenticated = false
        var bytes = [UInt8]()
        var source: DispatchSourceRead?
        var timeout: DispatchSourceTimer?
        var validation: Task<Void, Never>?
        init(fd: Int32, identity: RunScopeMember) { self.fd = fd; self.identity = identity }
    }
    private struct Wire: Decodable {
        let version: Int
        let type: String
        let generation: Int64
        let token: String?
        let appSessionID: UUID?
        let runID: UUID?
        let instanceID: UUID?
        let kind: String?
        let nativeSessionID: String?
    }
    private struct SocketWitness {
        let device: dev_t
        let inode: ino_t
        let uid: uid_t
    }

    private static let frameLimit = 4096
    private static let peerLimit = 4
    private static let maxGeneration: Int64 = 9_007_199_254_740_991
    private let queue = DispatchQueue(label: "sphyrna.opencode.tui-observer", qos: .userInitiated)
    private let stateLock = NSLock()
    private let cleanupQueue = DispatchQueue(label: "sphyrna.opencode.tui-observer.subscriber")
    private let socketPath: String
    private let pathWitness: SocketWitness
    private let appSessionID: UUID
    private let runID: UUID
    private let instanceID: UUID
    private let token: String
    private let policy: OpenCodeTUIPolicyProof
    private let validator: Validator
    private var listener: Int32
    private var listenerSource: DispatchSourceRead?
    private var peers: [UUID: Peer] = [:]
    private var outstandingValidations = 0
    private var active: UUID?
    private var highest: Int64 = 0
    private var ended = false
    private var selection: OpenCodeTUISelection
    private var observerID: UUID?
    private var observer: AsyncStream<OpenCodeTUISelection>.Continuation?

    /// The socket's existing parent must be an owner-only app directory.
    /// The validator must recognize the actual currently registered TUI member
    /// for this app/run/instance; it must not infer ownership from a cwd.
    public static func start(socketPath: String, appSessionID: UUID, runID: UUID, instanceID: UUID,
                             policy: OpenCodeTUIPolicyProof,
                             validateOwnedTUI: @escaping Validator) throws -> OpenCodeTUIBridge {
        guard policy.isValid, policy.appSessionID == appSessionID, policy.runID == runID else {
            throw OpenCodeError.unavailable
        }
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        var root = stat()
        guard socketPath.hasPrefix("/"), !socketPath.contains("\0"),
              lstat(parent, &root) == 0, root.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              root.st_uid == geteuid(), root.st_mode & 0o077 == 0 else { throw OpenCodeError.invalidTarget }
        let fd = try LocalSocket.listen(at: socketPath)
        var node = stat()
        guard lstat(socketPath, &node) == 0, node.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              node.st_uid == geteuid() else {
            Darwin.close(fd)
            throw OpenCodeError.unavailable
        }
        var random = [UInt8](repeating: 0, count: 32)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let token = random.map { String(format: "%02x", $0) }.joined()
        let bridge = OpenCodeTUIBridge(socketPath: socketPath, listener: fd,
                                       pathWitness: SocketWitness(device: node.st_dev, inode: node.st_ino, uid: node.st_uid),
                                       appSessionID: appSessionID, runID: runID, instanceID: instanceID,
                                       token: token, policy: policy, validator: validateOwnedTUI)
        guard policy.attach({ [weak bridge] in bridge?.invalidatePolicy() }) else {
            bridge.queue.sync { bridge.finish() }
            throw OpenCodeError.unavailable
        }
        return bridge
    }

    private init(socketPath: String, listener: Int32, pathWitness: SocketWitness,
                 appSessionID: UUID, runID: UUID, instanceID: UUID, token: String,
                 policy: OpenCodeTUIPolicyProof, validator: @escaping Validator) {
        self.socketPath = socketPath; self.listener = listener; self.pathWitness = pathWitness
        self.appSessionID = appSessionID; self.runID = runID; self.instanceID = instanceID
        self.token = token; self.policy = policy; self.validator = validator
        selection = OpenCodeTUISelection(appSessionID: appSessionID, runID: runID, instanceID: instanceID,
                                         generation: nil, route: .unavailable)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReady() }
        listenerSource = source
        source.resume()
    }

    /// The capability is injected only after the verified terminal profile was
    /// built. The owned server profile strips this reserved namespace.
    public func applyingToTerminal(_ profile: ProviderLaunchProfile) throws -> ProviderLaunchProfile {
        try stateLock.withLock {
            guard !ended, policy.isValid else { throw OpenCodeError.closed }
            let args = profile.arguments
            guard args.count == 5, args[0] == "--server",
                  let url = URL(string: args[1]), OpenCodeLaunchProfile.validServerURL(url), url == policy.serverURL,
                  args[2] == "--session", OpenCodeLaunchProfile.validID(args[3], prefix: "ses"),
                  args[4] == policy.directory, profile.trailingArguments.isEmpty else {
                throw OpenCodeError.invalidTarget
            }
            var environment = profile.environment.filter { !$0.key.hasPrefix("SPHYRNA_OPENCODE_TUI_") }
            environment["SPHYRNA_OPENCODE_TUI_SOCKET"] = socketPath
            environment["SPHYRNA_OPENCODE_TUI_TOKEN"] = token
            environment["SPHYRNA_OPENCODE_TUI_APP_SESSION_ID"] = appSessionID.uuidString
            environment["SPHYRNA_OPENCODE_TUI_RUN_ID"] = runID.uuidString
            environment["SPHYRNA_OPENCODE_TUI_INSTANCE_ID"] = instanceID.uuidString
            return ProviderLaunchProfile(arguments: profile.arguments, environment: environment,
                                         trailingArguments: profile.trailingArguments, replacedAsk: profile.replacedAsk)
        }
    }

    public var snapshot: OpenCodeTUISelection {
        stateLock.withLock {
            policy.isValid ? selection : OpenCodeTUISelection(appSessionID: appSessionID, runID: runID,
                                                               instanceID: instanceID, generation: nil, route: .unavailable)
        }
    }

    public func updates() -> AsyncStream<OpenCodeTUISelection> {
        let pair = AsyncStream<OpenCodeTUISelection>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        pair.continuation.onTermination = { [weak self] _ in
            self?.cleanupQueue.async { [weak self] in
                self?.stateLock.withLock {
                    if self?.observerID == id { self?.observerID = nil; self?.observer = nil }
                }
            }
        }
        let (previous, finished) = stateLock.withLock {
            let previous = observer
            observer = nil
            observerID = nil
            let value = policy.isValid ? selection : OpenCodeTUISelection(appSessionID: appSessionID, runID: runID,
                                                                          instanceID: instanceID, generation: nil, route: .unavailable)
            _ = pair.continuation.yield(value)
            if ended || !policy.isValid { return (previous, true) }
            observer = pair.continuation
            observerID = id
            return (previous, false)
        }
        previous?.finish()
        if finished { pair.continuation.finish() }
        return pair.stream
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finish()
                continuation.resume()
            }
        }
    }

    private func invalidatePolicy() {
        publish(.unavailable, generation: nil)
        queue.async { [weak self] in self?.finish() }
    }

    private func acceptReady() {
        guard !stateLock.withLock({ ended }), listener >= 0 else { return }
        for _ in 0..<16 {
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(); return
            }
            guard peers.count < Self.peerLimit, outstandingValidations < Self.peerLimit,
                  (try? LocalSocket.prepare(fd)) != nil, let member = Self.peer(fd) else {
                Darwin.close(fd); continue
            }
            let id = UUID()
            let value = Peer(fd: fd, identity: member)
            peers[id] = value
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5)
            timer.setEventHandler { [weak self] in self?.closePeer(id) }
            value.timeout = timer
            timer.resume()
            let validator = validator
            outstandingValidations += 1
            value.validation = Task { [weak self] in
                let accepted = await validator(member)
                self?.queue.async { [weak self] in self?.validated(id, accepted: accepted) }
            }
        }
    }

    private func validated(_ id: UUID, accepted: Bool) {
        outstandingValidations -= 1
        guard let peer = peers[id] else { return }
        peer.validation = nil
        guard accepted, Self.peer(peer.fd) == peer.identity else { closePeer(id); return }
        let source = DispatchSource.makeReadSource(fileDescriptor: peer.fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readReady(id) }
        peer.source = source
        source.resume()
    }

    private func readReady(_ id: UUID) {
        guard let peer = peers[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<16 {
            let count = Darwin.recv(peer.fd, &buffer, buffer.count, 0)
            if count == 0 { closePeer(id); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                closePeer(id); return
            }
            for byte in buffer.prefix(count) {
                if byte == 10 {
                    guard !peer.bytes.isEmpty else { closePeer(id); return }
                    let data = Data(peer.bytes)
                    peer.bytes.removeAll(keepingCapacity: true)
                    guard handle(data, peerID: id, peer: peer) else { closePeer(id); return }
                } else {
                    peer.bytes.append(byte)
                    guard peer.bytes.count <= Self.frameLimit else { closePeer(id); return }
                }
            }
        }
    }

    private func handle(_ bytes: Data, peerID: UUID, peer: Peer) -> Bool {
        guard policy.isValid, Self.peer(peer.fd) == peer.identity,
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let message = try? JSONDecoder().decode(Wire.self, from: bytes),
              message.version == 1, message.generation > 0, message.generation <= Self.maxGeneration else { return false }
        let keys = Set(object.keys)
        if !peer.authenticated {
            guard keys == Set(["version", "type", "generation", "token", "appSessionID", "runID", "instanceID"]),
                  message.type == "hello", let supplied = message.token, secureEqual(supplied, token),
                  message.appSessionID == appSessionID, message.runID == runID, message.instanceID == instanceID else {
                return false
            }
            guard message.generation > highest else {
                if let active { closePeer(active) }
                return false
            }
            if let active { closePeer(active) }
            highest = message.generation
            peer.authenticated = true
            peer.timeout?.cancel()
            peer.timeout = nil
            active = peerID
            publish(.unavailable, generation: nil)
            return true
        }
        guard active == peerID, message.type == "route", message.generation > highest,
              let kind = message.kind else { return false }
        let route: OpenCodeTUIRoute
        switch kind {
        case "home":
            guard keys == Set(["version", "type", "generation", "kind"]) else { return false }
            route = .home
        case "plugin":
            guard keys == Set(["version", "type", "generation", "kind"]) else { return false }
            route = .plugin
        case "session":
            guard keys == Set(["version", "type", "generation", "kind", "nativeSessionID"]),
                  let native = message.nativeSessionID,
                  OpenCodeLaunchProfile.validID(native, prefix: "ses") else { return false }
            route = .session(native)
        default: return false
        }
        highest = message.generation
        publish(route, generation: message.generation)
        return true
    }

    private static func peer(_ fd: Int32) -> RunScopeMember? {
        var pid: pid_t = 0
        var version: Int32 = 0
        var uid: uid_t = 0
        guard loom_socket_peer_version(fd, &pid, &version, &uid) == 0, uid == geteuid(),
              let member = RunScopeTable.lineage(pid: pid), member.idVersion == version,
              member.userID == uid, !member.zombie else { return nil }
        return member
    }

    private func closePeer(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.validation?.cancel()
        peer.timeout?.cancel()
        peer.source?.cancel()
        Darwin.close(peer.fd)
        if active == id {
            active = nil
            publish(.unavailable, generation: nil)
        }
    }

    private func publish(_ route: OpenCodeTUIRoute, generation: Int64?) {
        stateLock.withLock {
            let route = policy.isValid ? route : .unavailable
            let generation = policy.isValid ? generation : nil
            let next = OpenCodeTUISelection(appSessionID: appSessionID, runID: runID, instanceID: instanceID,
                                            generation: generation, route: route)
            guard next != selection else { return }
            selection = next
            _ = observer?.yield(next)
        }
    }

    private func finish() {
        let alreadyEnded = stateLock.withLock { () -> Bool in
            if ended { return true }
            ended = true
            return false
        }
        guard !alreadyEnded else { return }
        listenerSource?.cancel()
        listenerSource = nil
        if listener >= 0 { Darwin.close(listener); listener = -1 }
        for id in Array(peers.keys) { closePeer(id) }
        publish(.unavailable, generation: nil)
        var current = stat()
        if lstat(socketPath, &current) == 0, current.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
           current.st_dev == pathWitness.device, current.st_ino == pathWitness.inode, current.st_uid == pathWitness.uid {
            unlink(socketPath)
        }
        let previous = stateLock.withLock {
            let previous = observer
            observer = nil
            observerID = nil
            return previous
        }
        previous?.finish()
    }

    deinit {
        listenerSource?.cancel()
        if listener >= 0 { Darwin.close(listener) }
        for peer in peers.values {
            peer.validation?.cancel()
            peer.timeout?.cancel()
            peer.source?.cancel()
            Darwin.close(peer.fd)
        }
        var current = stat()
        if lstat(socketPath, &current) == 0, current.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
           current.st_dev == pathWitness.device, current.st_ino == pathWitness.inode, current.st_uid == pathWitness.uid {
            unlink(socketPath)
        }
        observer?.finish()
    }
}
