import Darwin
import Foundation

public struct ClaudeHookEnvelope: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public let version: Int
    public let sessionID: UUID
    public let managedRunID: UUID
    public let payload: Data
    public let sentAt: Date

    public init(sessionID: UUID, managedRunID: UUID, payload: Data,
                sentAt: Date = Date()) {
        version = Self.protocolVersion
        self.sessionID = sessionID
        self.managedRunID = managedRunID
        self.payload = payload
        self.sentAt = sentAt
    }
}

public enum ClaudeHookTransportError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidConfiguration(String)
    case system(operation: String, code: Int32)
    case timeout(String)
    case messageTooLarge
    case malformedMessage

    public var description: String {
        switch self {
        case let .invalidConfiguration(reason):
            "Claude hook configuration is invalid: \(reason)"
        case let .system(operation, code):
            "Claude hook \(operation) failed: \(String(cString: strerror(code)))"
        case let .timeout(operation):
            "Claude hook timed out during \(operation)"
        case .messageTooLarge:
            "Claude hook message exceeds 1 MiB"
        case .malformedMessage:
            "Claude hook message is malformed"
        }
    }
}

private struct ClaudeHookWireMessage: Codable {
    let authenticationToken: String
    let envelope: ClaudeHookEnvelope
}

public enum ClaudeHookClient {
    public static let maximumPayloadByteCount = 1024 * 1024
    fileprivate static let maximumWireByteCount = 2 * 1024 * 1024

    /// A hook process sends exactly one authenticated message and disconnects.
    /// The bounded deadline keeps the synchronous SessionEnd hook inside
    /// Claude's short shutdown budget.
    public static func send(
        _ envelope: ClaudeHookEnvelope,
        socketPath: String,
        authenticationToken: String,
        timeout: TimeInterval = 0.5
    ) throws {
        guard envelope.version == ClaudeHookEnvelope.protocolVersion,
              envelope.payload.count <= maximumPayloadByteCount,
              !authenticationToken.isEmpty else {
            throw ClaudeHookTransportError.invalidConfiguration("missing token or unsupported envelope")
        }
        let data = try JSONEncoder().encode(ClaudeHookWireMessage(
            authenticationToken: authenticationToken, envelope: envelope
        ))
        guard data.count <= maximumWireByteCount else {
            throw ClaudeHookTransportError.messageTooLarge
        }

        let descriptor = try connectedSocket(path: socketPath, timeout: timeout)
        defer { Darwin.close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.send(
                    descriptor, bytes.baseAddress!.advanced(by: offset),
                    data.count - offset, 0
                )
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try wait(
                    descriptor: descriptor, events: Int16(POLLOUT),
                    deadline: deadline, operation: "write"
                )
            } else {
                throw ClaudeHookTransportError.system(operation: "write", code: errno)
            }
        }
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
            throw ClaudeHookTransportError.system(operation: "shutdown", code: errno)
        }
    }

    private static func connectedSocket(path: String, timeout: TimeInterval) throws -> Int32 {
        var address = try unixAddress(path: path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ClaudeHookTransportError.system(operation: "socket", code: errno)
        }
        do {
            var noSignal: Int32 = 1
            guard setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))
            ) == 0 else {
                throw ClaudeHookTransportError.system(operation: "SO_NOSIGPIPE", code: errno)
            }
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw ClaudeHookTransportError.system(operation: "fcntl", code: errno)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor, $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            if result < 0 {
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else {
                    throw ClaudeHookTransportError.system(operation: "connect", code: errno)
                }
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                try wait(
                    descriptor: descriptor, events: Int16(POLLOUT),
                    deadline: deadline, operation: "connect"
                )
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard getsockopt(
                    descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length
                ) == 0 else {
                    throw ClaudeHookTransportError.system(operation: "connect status", code: errno)
                }
                guard socketError == 0 else {
                    throw ClaudeHookTransportError.system(operation: "connect", code: socketError)
                }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func wait(descriptor: Int32, events: Int16,
                             deadline: TimeInterval, operation: String) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ClaudeHookTransportError.timeout(operation) }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(min(remaining * 1_000, 500)))
            if result > 0 {
                guard item.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) == 0 else {
                    throw ClaudeHookTransportError.system(operation: operation, code: ECONNRESET)
                }
                if item.revents & events != 0 { return }
            } else if result == 0 {
                continue
            } else if errno != EINTR {
                throw ClaudeHookTransportError.system(operation: operation, code: errno)
            }
        }
    }
}

/// Receives short-lived hook connections on a private local socket. Socket
/// permissions reject other users; the per-app-run token rejects unrelated local
/// processes that discover the path.
public final class ClaudeHookServer: @unchecked Sendable {
    private let socketPath: String
    private let authenticationToken: String
    private let handler: @Sendable (ClaudeHookEnvelope) -> Void
    private let workerQueue = DispatchQueue(
        label: "dev.loom.claude-hooks.receive", qos: .utility,
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var source: DispatchSourceRead?
    private var stopped = false

    public init(
        socketPath: String,
        authenticationToken: String,
        handler: @escaping @Sendable (ClaudeHookEnvelope) -> Void
    ) throws {
        guard !authenticationToken.isEmpty else {
            throw ClaudeHookTransportError.invalidConfiguration("empty authentication token")
        }
        self.socketPath = socketPath
        self.authenticationToken = authenticationToken
        self.handler = handler

        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  let permissions = try FileManager.default.attributesOfItem(
                    atPath: parent.path
                  )[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else {
                throw ClaudeHookTransportError.invalidConfiguration(
                    "socket directory must exist with owner-only permissions"
                )
            }
        } else {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var existing = stat()
        guard lstat(socketPath, &existing) != 0, errno == ENOENT else {
            throw ClaudeHookTransportError.invalidConfiguration("socket path already exists")
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ClaudeHookTransportError.system(operation: "socket", code: errno)
        }
        do {
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw ClaudeHookTransportError.system(operation: "fcntl", code: errno)
            }
            var address = try unixAddress(path: socketPath)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor, $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bound == 0 else {
                throw ClaudeHookTransportError.system(operation: "bind", code: errno)
            }
            guard chmod(socketPath, 0o600) == 0 else {
                throw ClaudeHookTransportError.system(operation: "chmod", code: errno)
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                throw ClaudeHookTransportError.system(operation: "listen", code: errno)
            }

            let source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue(label: "dev.loom.claude-hooks.accept", qos: .utility)
            )
            source.setEventHandler { [weak self] in self?.acceptAvailable(descriptor: descriptor) }
            source.setCancelHandler {
                Darwin.close(descriptor)
                unlink(socketPath)
            }
            self.source = source
            source.resume()
        } catch {
            Darwin.close(descriptor)
            unlink(socketPath)
            throw error
        }
    }

    deinit { stop() }

    public func stop() {
        let source: DispatchSourceRead? = stateLock.withLock {
            guard !stopped else { return nil }
            stopped = true
            let value = self.source
            self.source = nil
            return value
        }
        source?.cancel()
    }

    private func acceptAvailable(descriptor: Int32) {
        while true {
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection >= 0 {
                guard fcntl(connection, F_SETFL, O_NONBLOCK) == 0,
                      fcntl(connection, F_SETFD, FD_CLOEXEC) == 0 else {
                    Darwin.close(connection)
                    continue
                }
                workerQueue.async { [weak self] in
                    guard let self else {
                        Darwin.close(connection)
                        return
                    }
                    self.receive(connection: connection)
                }
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                return
            }
        }
    }

    private func receive(connection: Int32) {
        defer { Darwin.close(connection) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var data = Data()
        while true {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.recv(connection, &buffer, buffer.count, 0)
            if count > 0 {
                guard data.count + count <= ClaudeHookClient.maximumWireByteCount else { return }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return }
                var item = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                let result = Darwin.poll(&item, 1, Int32(min(remaining * 1_000, 1_000)))
                if result > 0 {
                    guard item.revents & (Int16(POLLERR) | Int16(POLLNVAL)) == 0 else { return }
                    if item.revents & Int16(POLLIN) != 0 { continue }
                    if item.revents & Int16(POLLHUP) != 0 { break }
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            } else {
                return
            }
        }
        guard let wire = try? JSONDecoder().decode(ClaudeHookWireMessage.self, from: data),
              wire.envelope.version == ClaudeHookEnvelope.protocolVersion,
              secureEqual(wire.authenticationToken, authenticationToken),
              wire.envelope.payload.count <= ClaudeHookClient.maximumPayloadByteCount else { return }
        handler(wire.envelope)
    }
}

public struct ClaudeHookEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sessionStart(source: String?)
        case userPromptSubmit
        case permissionRequest(toolName: String?)
        case notification(type: String?)
        case stop(backgroundTaskCount: Int, scheduledTaskCount: Int)
        case stopFailure(error: String?, details: String?)
        case sessionEnd(reason: String?)
        case unknown(name: String)
    }

    public let providerSessionID: String
    public let promptID: String?
    public let transcriptPath: String?
    public let workingDirectory: String?
    public let lastAssistantMessage: String?
    public let kind: Kind

    public var name: String {
        switch kind {
        case .sessionStart: "SessionStart"
        case .userPromptSubmit: "UserPromptSubmit"
        case .permissionRequest: "PermissionRequest"
        case .notification: "Notification"
        case .stop: "Stop"
        case .stopFailure: "StopFailure"
        case .sessionEnd: "SessionEnd"
        case let .unknown(name): name
        }
    }

    public init(payload: Data) throws {
        guard payload.count <= ClaudeHookClient.maximumPayloadByteCount,
              let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let providerSessionID = object["session_id"] as? String,
              !providerSessionID.isEmpty,
              let eventName = object["hook_event_name"] as? String,
              !eventName.isEmpty else {
            throw ClaudeHookTransportError.malformedMessage
        }
        self.providerSessionID = providerSessionID
        promptID = object["prompt_id"] as? String
        transcriptPath = object["transcript_path"] as? String
        workingDirectory = object["cwd"] as? String
        lastAssistantMessage = object["last_assistant_message"] as? String
        switch eventName {
        case "SessionStart":
            kind = .sessionStart(source: object["source"] as? String)
        case "UserPromptSubmit":
            kind = .userPromptSubmit
        case "PermissionRequest":
            kind = .permissionRequest(toolName: object["tool_name"] as? String)
        case "Notification":
            kind = .notification(type: object["notification_type"] as? String)
        case "Stop":
            kind = .stop(
                backgroundTaskCount: Self.collectionCount(object["background_tasks"]),
                scheduledTaskCount: Self.collectionCount(object["session_crons"])
            )
        case "StopFailure":
            kind = .stopFailure(
                error: object["error"] as? String,
                details: object["error_details"] as? String
            )
        case "SessionEnd":
            kind = .sessionEnd(reason: object["reason"] as? String)
        default:
            kind = .unknown(name: eventName)
        }
    }

    private static func collectionCount(_ value: Any?) -> Int {
        if let values = value as? [Any] { return values.count }
        if let values = value as? [String: Any] { return values.count }
        return 0
    }
}

public enum AgentActivity: Equatable, Sendable {
    case unknown
    case working
    case waitingForApproval
    case waitingForInput
    case turnComplete
    case failed(String?)
    case sessionEnded(String?)
}

public struct ClaudeSessionStatus: Equatable, Sendable {
    public var providerSessionID: String?
    public var activity: AgentActivity
    public var lastUsedAt: Date?
    public var lastEventAt: Date?
    public var lastAssistantMessage: String?
    public var backgroundTaskCount: Int
    public var scheduledTaskCount: Int

    public init() {
        providerSessionID = nil
        activity = .unknown
        lastUsedAt = nil
        lastEventAt = nil
        lastAssistantMessage = nil
        backgroundTaskCount = 0
        scheduledTaskCount = 0
    }
}

public enum ClaudeHookDisposition: Equatable, Sendable {
    case applied(ClaudeHookEvent)
    case staleRun
    case wrongSession
}

/// Reduces provider events independently from durable lifecycle and process
/// state. A new run must be selected explicitly; late events from an older run
/// are observable but cannot overwrite the active status.
public actor ClaudeHookStateTracker {
    public let sessionID: UUID
    private var managedRunID: UUID
    private var currentStatus = ClaudeSessionStatus()

    public init(sessionID: UUID, managedRunID: UUID) {
        self.sessionID = sessionID
        self.managedRunID = managedRunID
    }

    public func beginRun(_ runID: UUID) {
        managedRunID = runID
        currentStatus = ClaudeSessionStatus()
    }

    public func status() -> ClaudeSessionStatus { currentStatus }

    @discardableResult
    public func receive(
        _ envelope: ClaudeHookEnvelope,
        receivedAt: Date = Date()
    ) throws -> ClaudeHookDisposition {
        guard envelope.sessionID == sessionID else { return .wrongSession }
        guard envelope.managedRunID == managedRunID else { return .staleRun }
        let event = try ClaudeHookEvent(payload: envelope.payload)
        currentStatus.lastEventAt = receivedAt
        switch event.kind {
        case .sessionStart:
            currentStatus.providerSessionID = event.providerSessionID
            currentStatus.activity = .unknown
        case .userPromptSubmit:
            currentStatus.activity = .working
            currentStatus.lastUsedAt = receivedAt
        case .permissionRequest:
            currentStatus.activity = .waitingForApproval
        case let .notification(type):
            switch type {
            case "permission_prompt": currentStatus.activity = .waitingForApproval
            case "idle_prompt", "agent_needs_input": currentStatus.activity = .waitingForInput
            default: currentStatus.activity = .unknown
            }
        case let .stop(backgroundTaskCount, scheduledTaskCount):
            currentStatus.activity = .turnComplete
            currentStatus.lastAssistantMessage = event.lastAssistantMessage
            currentStatus.backgroundTaskCount = backgroundTaskCount
            currentStatus.scheduledTaskCount = scheduledTaskCount
        case let .stopFailure(error, _):
            currentStatus.activity = .failed(error)
            currentStatus.lastAssistantMessage = event.lastAssistantMessage
        case let .sessionEnd(reason):
            currentStatus.activity = .sessionEnded(reason)
        case .unknown:
            currentStatus.activity = .unknown
        }
        return .applied(event)
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw ClaudeHookTransportError.invalidConfiguration("Unix socket path is too long or contains NUL")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.copyBytes(from: bytes)
    }
    return address
}

private func secureEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
}
