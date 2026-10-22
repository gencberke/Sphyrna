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
    /// The server read the message and refused its token (a Loom that is not the one this hook was
    /// started by).
    case rejected

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
        case .rejected:
            "Claude hook message was rejected by Sphyrna"
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
        // The server closes the connection once it has judged the message, and sends one byte first
        // when it refuses the token. A server that is slow or older than this client simply closes
        // or stays silent: that is never a failure of the hook, so the wait is short and its
        // timeout is ignored.
        if readVerdict(descriptor: descriptor, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + verdictWait)) {
            throw ClaudeHookTransportError.rejected
        }
    }

    /// A short, content-free reason for a failed send: what `loom-hook` logs before it exits.
    public static func failureDescription(_ error: any Error) -> String {
        switch error {
        case let ClaudeHookTransportError.timeout(operation): return "\(operation) timed out"
        case ClaudeHookTransportError.rejected: return "token rejected by Sphyrna"
        case let ClaudeHookTransportError.system(operation, code):
            switch code {
            case ECONNREFUSED: return "\(operation) refused (nothing is listening; Sphyrna is not running or restarted)"
            case ENOENT: return "\(operation) failed: the socket does not exist"
            default: return "\(operation) failed (errno \(code))"
            }
        case ClaudeHookTransportError.invalidConfiguration: return "invalid configuration"
        case ClaudeHookTransportError.messageTooLarge: return "message too large"
        default: return LoomLog.category(of: error)
        }
    }

    /// The one byte a server sends for a refused message.
    static let rejectionByte: UInt8 = 0x15
    private static let verdictWait: TimeInterval = 0.1

    private static func readVerdict(descriptor: Int32, deadline: TimeInterval) -> Bool {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.recv(descriptor, &byte, 1, 0)
            if count > 0 { return byte == rejectionByte }
            if count == 0 { return false }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return false }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            // Any event (data, or the server hanging up after its byte) is answered by reading again.
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&item, 1, Int32(max(1, min(remaining * 1_000, 100))))
            if result < 0, errno != EINTR { return false }
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
    private let receiveQueue = DispatchQueue(
        label: "dev.loom.claude-hooks.receive", qos: .userInitiated
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

        let descriptor = try LocalSocket.listen(at: socketPath)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: receiveQueue
        )
        source.setEventHandler { [weak self] in self?.acceptAvailable(descriptor: descriptor) }
        source.setCancelHandler {
            Darwin.close(descriptor)
            unlink(socketPath)
        }
        self.source = source
        source.resume()
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
            guard !stateLock.withLock({ stopped }) else { return }
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection >= 0 {
                guard fcntl(connection, F_SETFL, O_NONBLOCK) == 0,
                      fcntl(connection, F_SETFD, FD_CLOEXEC) == 0 else {
                    Darwin.close(connection)
                    continue
                }
                // Receive on this dedicated serial utility queue. At most one
                // accepted FD is retained; the kernel listen backlog is 16.
                receive(connection: connection)
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
            guard ProcessInfo.processInfo.systemUptime < deadline else { return }
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
        // A connection that sends nothing is a probe (the stale-socket sweep of another Loom), not a message.
        guard !data.isEmpty else { return }
        guard let wire = try? JSONDecoder().decode(ClaudeHookWireMessage.self, from: data),
              wire.envelope.version == ClaudeHookEnvelope.protocolVersion,
              wire.envelope.payload.count <= ClaudeHookClient.maximumPayloadByteCount else {
            HookDiagnostics.note(.malformedMessage)
            LoomLog.error(.claudeHooks, key: "hook-malformed", "A hook connection sent a message this Sphyrna cannot read")
            return
        }
        guard secureEqual(wire.authenticationToken, authenticationToken) else {
            HookDiagnostics.note(.rejectedToken)
            LoomLog.error(.claudeHooks, key: "hook-token", "A hook message with the wrong token was refused")
            // The one byte goes out only with SIGPIPE disabled on this connection. Setting that fails
            // (EINVAL) once the peer has hung up, which also means there is nobody to tell.
            var noSignal: Int32 = 1
            if setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                          socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 {
                var verdict = ClaudeHookClient.rejectionByte
                _ = Darwin.send(connection, &verdict, 1, 0)
            }
            return
        }
        HookDiagnostics.note(.received)
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
        /// A subagent of the run's own conversation started or stopped (`agent_id` names it,
        /// `agent_type` is empty for Claude's internal agents, which Loom ignores).
        case subagentStart(agentType: String)
        case subagentStop(agentType: String)
        case unknown(name: String)
    }

    public let providerSessionID: String
    public let promptID: String?
    public let agentID: String?
    public let transcriptPath: String?
    /// `SubagentStop` only: where Claude keeps that subagent's transcript.
    public let agentTranscriptPath: String?
    public let workingDirectory: String?
    public let lastAssistantMessage: String?
    /// `Stop` only: the background subagents Claude reports as running at the end of the turn.
    public let backgroundSubagents: [BackgroundSubagentTask]
    /// `Stop` only: a workflow is still in flight at the end of the turn; its agents are not listed.
    public let listsRunningWorkflow: Bool
    /// `UserPromptSubmit` only: the harness injects hand-backs of background subagents
    /// (`<agent-message`) and task notifications (`<task-notification`, S0: what Claude starts a turn with
    /// when a background task ends) as prompts. They are not something the user typed: the turn is
    /// automatic, it is not the user's use of the session and it does not start a new turn from the
    /// user's point of view.
    public let promptIsSynthetic: Bool
    /// `Stop` only: what Claude lists as still running (S0: `shell` and `subagent` tasks, plus crons).
    public let work: BackgroundWork
    /// The reason this event states for the session's status, built here so that no payload text is kept
    /// past parsing (`PermissionRequest`, `Stop`, `StopFailure`, an automatic `UserPromptSubmit`, an
    /// MCP elicitation). Nil for events that state none.
    public let reason: StatusReason?
    /// The permission mode the CLI reports (`permission_mode`, 2.1.300's UserPromptSubmit and PermissionRequest), in its own
    /// word (`default`, `acceptEdits`, `plan`, `auto`, `bypassPermissions`, `dontAsk`); nil when the event carries none or a
    /// word Loom does not know.
    public let permissionMode: String?
    /// The effort level the CLI reports (`effort.level`: `low` to `max`); nil when the event carries none or an unknown one.
    public let effort: String?
    public let kind: Kind

    /// The CLI's words for the modes Loom knows.
    static let knownPermissionModes = Set(ClaudePermissionMode.allCases.map(\.cliValue))

    public var isSubagentLifecycle: Bool {
        switch kind {
        case .subagentStart, .subagentStop: true
        default: false
        }
    }

    /// A subagent of the conversation waits on its own permission prompt, which Claude shows in the
    /// session's terminal (FB2-6).
    public var isSubagentPermissionPrompt: Bool {
        guard agentID != nil else { return false }
        if case .permissionRequest = kind { return true }
        return false
    }

    public var name: String {
        switch kind {
        case .sessionStart: "SessionStart"
        case .userPromptSubmit: "UserPromptSubmit"
        case .permissionRequest: "PermissionRequest"
        case .notification: "Notification"
        case .stop: "Stop"
        case .stopFailure: "StopFailure"
        case .sessionEnd: "SessionEnd"
        case .subagentStart: "SubagentStart"
        case .subagentStop: "SubagentStop"
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
        agentID = (object["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        transcriptPath = object["transcript_path"] as? String
        agentTranscriptPath = object["agent_transcript_path"] as? String
        workingDirectory = object["cwd"] as? String
        lastAssistantMessage = object["last_assistant_message"] as? String
        backgroundSubagents = eventName == "Stop" ? BackgroundSubagentTask.parse(object["background_tasks"]) : []
        listsRunningWorkflow = eventName == "Stop" && BackgroundSubagentTask.listsWorkflow(object["background_tasks"])
        let prompt = eventName == "UserPromptSubmit" ? object["prompt"] as? String : nil
        promptIsSynthetic = prompt.map(Self.isSyntheticPrompt) == true
        work = eventName == "Stop"
            ? BackgroundWork.parse(tasks: object["background_tasks"], scheduled: object["session_crons"]) : BackgroundWork()
        permissionMode = (object["permission_mode"] as? String).flatMap { Self.knownPermissionModes.contains($0) ? $0 : nil }
        effort = ((object["effort"] as? [String: Any])?["level"] as? String)
            .flatMap { ClaudeTranscriptEffort.levels.contains($0) ? $0 : nil }
        switch eventName {
        case "PermissionRequest":
            reason = StatusReason.permission(toolName: object["tool_name"] as? String, toolInput: object["tool_input"])
        case "Stop":
            reason = StatusReason.turnDone(lastMessage: object["last_assistant_message"] as? String, work: work)
        case "StopFailure":
            reason = StatusReason.failure(
                error: object["error"] as? String, message: object["last_assistant_message"] as? String,
                details: object["error_details"] as? String)
        case "UserPromptSubmit" where promptIsSynthetic:
            reason = StatusReason.automaticTurn(prompt: prompt)
        case "Notification" where ["agent_needs_input", "elicitation_dialog"].contains(object["notification_type"] as? String):
            reason = StatusReason(.input)
        default:
            reason = nil
        }
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
            kind = .stop(backgroundTaskCount: work.tasks, scheduledTaskCount: work.scheduled)
        case "StopFailure":
            kind = .stopFailure(
                error: object["error"] as? String,
                details: object["error_details"] as? String
            )
        case "SessionEnd":
            kind = .sessionEnd(reason: object["reason"] as? String)
        case "SubagentStart":
            kind = .subagentStart(agentType: (object["agent_type"] as? String) ?? "")
        case "SubagentStop":
            kind = .subagentStop(agentType: (object["agent_type"] as? String) ?? "")
        default:
            kind = .unknown(name: eventName)
        }
    }

    private static func isSyntheticPrompt(_ prompt: String) -> Bool {
        let head = prompt.drop { $0.isWhitespace }
        return head.hasPrefix("<agent-message") || head.hasPrefix("<task-notification")
    }

}

public enum AgentActivity: Equatable, Sendable {
    case unknown
    /// The provider started or resumed and sits at its prompt; no turn ran in this process yet.
    case atPrompt
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
    /// Why the session shows `activity` (see `StatusReason`); nil when nothing states it. Never logged.
    public var reason: StatusReason?

    public init() {
        providerSessionID = nil
        activity = .unknown
        lastUsedAt = nil
        lastEventAt = nil
        lastAssistantMessage = nil
        backgroundTaskCount = 0
        scheduledTaskCount = 0
        reason = nil
    }
}

public enum ClaudeHookDisposition: Equatable, Sendable {
    case applied(ClaudeHookEvent)
    case staleRun
    case wrongSession
    case wrongConversation
    case retiredConversation
    case duplicateSessionStart
    case childAgent
    case unreliable
}

/// Reduces provider events independently from durable lifecycle and process
/// state. A new run must be selected explicitly; late events from an older run
/// are observable but cannot overwrite the active status.
public actor ClaudeHookStateTracker {
    public let sessionID: UUID
    private var managedRunID: UUID
    private var currentStatus = ClaudeSessionStatus()
    private var activeProviderSessionID: String?
    private var retiredSessionIDs: Set<String> = []
    private var inputGeneration: UUID?
    private var inputWatermark: Double?
    private var inputAwaitsApproval = false
    private var hookEmissionWatermark: Double?
    /// The previous hook's emission time: the clock is judged against it, so a wall clock that
    /// stepped back is ambiguous once and the next hook on the new clock is sane again.
    private var lastHookEmission: Double?
    private var inputClockAmbiguous = false
    static let maximumHookReorderMilliseconds = 500.0
    private var registryStartedAt: Double?
    private var registryTimestamp: Double?
    /// An event for a conversation not yet announced was dropped before the first SessionStart
    /// (a prompt typed at once): that start cannot claim the provider is idle at its prompt.
    private var droppedEarlyEvent = false
    /// Whether a PermissionRequest was seen since the last prompt or stop. A `permission_prompt` notification
    /// then belongs to it (and is no signal); without one the notification is the backup for a lost hook.
    private var permissionRequestSeen = false
    /// The subagents of this run's conversation (`SubagentLedger` holds the rules).
    private var subagents = SubagentLedger()
    /// While a subagent's permission prompt is shown: the conversation's state before it, which the
    /// registry's first later sample that no longer says "waiting" returns to.
    private var subagentApprovalReturn: SubagentApprovalReturn?
    /// The `agent_id` of the last subagent permission prompt (V23); it counts only while the session waits for approval.
    private var waitingSubagentID: String?
    private struct SubagentApprovalReturn {
        let activity: AgentActivity
        let generation: UUID?
        let watermark: Double?
        let awaitsApproval: Bool
        let reason: StatusReason?
    }

    func registryGeneration() -> UUID? { inputGeneration }

    /// Millisecond provider metadata is a bounded freshness aid, not a total
    /// order. Ambiguous clocks remain unknown and cannot permit automatic idle.
    func receiveRegistry(_ result: ClaudeRegistryRead, generation: UUID?, now: Date) -> String? {
        let issue = applyRegistry(result, generation: generation, now: now)
        dropStaleReason()
        return issue
    }

    /// An approval cancelled with Esc fires no hook (S0 Q7), so the registry is the second signal that
    /// ends it: its "idle" or "busy" sample moves the activity on, and the reason that described the
    /// approval goes with it.
    private func dropStaleReason() {
        if let reason = currentStatus.reason, !reason.holds(for: currentStatus.activity) { currentStatus.reason = nil }
    }

    private func applyRegistry(_ result: ClaudeRegistryRead, generation: UUID?, now: Date) -> String? {
        guard let generation, generation == inputGeneration else { return nil }
        guard case let .snapshot(snapshot) = result else {
            currentStatus.activity = .unknown
            return "Claude session metadata is unavailable; input state cannot be verified."
        }
        guard snapshot.sessionID.caseInsensitiveCompare(activeProviderSessionID ?? "") == .orderedSame else { return nil }
        if let previous = registryStartedAt, previous != snapshot.startedAt { return nil }
        registryStartedAt = snapshot.startedAt
        guard let timestamp = snapshot.statusUpdatedAt, let status = snapshot.status,
              let watermark = inputWatermark else {
            currentStatus.activity = .unknown
            return "Claude session metadata is incomplete; input state cannot be verified."
        }
        let nowMS = now.timeIntervalSince1970 * 1_000
        // Only a clock that really jumped (a large rollback between hooks, or
        // stamps in the future) makes the order unknowable.
        if inputClockAmbiguous || timestamp > nowMS || watermark > nowMS {
            currentStatus.activity = .unknown
            return "Claude session metadata clock is ambiguous; input state cannot be verified."
        }
        // Real Claude writes the registry a few ms before the matching hook,
        // stamps its first record before `startedAt`, and runs hook helpers as
        // concurrent processes. A sample that is not strictly newer than every
        // hook seen, or older than an earlier sample, or tied to the
        // millisecond, is stale: keep the hook state and wait for a later write.
        let newest = max(watermark, hookEmissionWatermark ?? watermark)
        if let previous = registryTimestamp, timestamp < previous { return nil }
        if timestamp == floor(newest) { return nil }
        registryTimestamp = timestamp
        guard timestamp > newest else { return nil }
        if let previous = subagentApprovalReturn, status == "idle" || status == "busy" {
            // The subagent's prompt was answered. A conversation that was at rest still is (Claude reports
            // "busy" while a background subagent runs); one that was working follows the sample.
            subagentApprovalReturn = nil
            waitingSubagentID = nil
            inputGeneration = previous.generation; inputWatermark = previous.watermark
            inputAwaitsApproval = previous.awaitsApproval
            currentStatus.reason = previous.reason
            switch previous.activity {
            case .atPrompt, .turnComplete, .waitingForInput: currentStatus.activity = previous.activity
            default: currentStatus.activity = status == "idle" ? .waitingForInput : .working
            }
            return nil
        }
        switch status {
        case "idle": currentStatus.activity = .waitingForInput
        case "busy": currentStatus.activity = .working
        case "waiting":
            // Backup for a PermissionRequest hook that never arrived: Claude itself says it waits.
            if inputAwaitsApproval || currentStatus.activity == .working {
                currentStatus.activity = .waitingForApproval
                inputAwaitsApproval = true
            }
        // A status this build does not know says nothing against the hook state.
        default: break
        }
        return nil
    }

    public init(sessionID: UUID, managedRunID: UUID, providerSessionID: String? = nil) {
        self.sessionID = sessionID
        self.managedRunID = managedRunID
        activeProviderSessionID = providerSessionID
    }

    public func beginRun(_ runID: UUID) {
        managedRunID = runID
        currentStatus = ClaudeSessionStatus()
        activeProviderSessionID = nil
        retiredSessionIDs.removeAll()
        inputGeneration = nil; inputWatermark = nil
        registryStartedAt = nil; registryTimestamp = nil
        hookEmissionWatermark = nil; lastHookEmission = nil; inputClockAmbiguous = false
        droppedEarlyEvent = false
        permissionRequestSeen = false
        subagents = SubagentLedger()
        subagentApprovalReturn = nil
        waitingSubagentID = nil
    }

    public func status() -> ClaudeSessionStatus { currentStatus }

    /// The run's subagents, the ledger's order. The one whose permission prompt is up (the `PermissionRequest` hook named it) is
    /// marked while the session still waits for approval; the registry's later sample, or the next event of the conversation,
    /// moves the activity on and takes the mark with it.
    public func subagentRecords() -> [SubagentRecord] {
        guard let waiting = waitingSubagentID, currentStatus.activity == .waitingForApproval else { return subagents.records }
        return subagents.records.map { record in
            var marked = record
            marked.awaitsApproval = record.id == waiting && record.isRunning
            return marked
        }
    }

    /// Details read later from the subagent's `meta.json`; true when the list changed.
    func applySubagentMeta(id: String, _ meta: SubagentMeta) -> Bool { subagents.apply(meta, to: id) }

    /// Classification runs before durable adoption. Native identity, never
    /// helper timestamps, fences late events from a previous conversation.
    public func disposition(for envelope: ClaudeHookEnvelope) throws -> ClaudeHookDisposition {
        guard envelope.sessionID == sessionID else { return .wrongSession }
        guard envelope.managedRunID == managedRunID else { return .staleRun }
        let event = try ClaudeHookEvent(payload: envelope.payload)
        // The two subagent lifecycle events and a subagent's permission prompt of the run's own
        // conversation are the only payloads with an agent_id that are used: the first two feed the
        // subagent list, the prompt only shows Needs approval until the registry says it was answered.
        if event.isSubagentLifecycle || event.isSubagentPermissionPrompt {
            guard activeProviderSessionID == event.providerSessionID else { return .wrongConversation }
            return .applied(event)
        }
        // Child hook payloads share launch credentials; agent_id identifies a
        // different execution context and has no parent-conversation authority.
        guard event.agentID == nil else { return .childAgent }
        if case let .sessionStart(source) = event.kind {
            if currentStatus.providerSessionID == event.providerSessionID { return .duplicateSessionStart }
            if retiredSessionIDs.contains(event.providerSessionID), source != "resume" { return .retiredConversation }
        } else if activeProviderSessionID != event.providerSessionID {
            if currentStatus.providerSessionID == nil { droppedEarlyEvent = true }
            return .wrongConversation
        }
        return .applied(event)
    }

    @discardableResult
    public func receive(
        _ envelope: ClaudeHookEnvelope,
        receivedAt: Date = Date()
    ) throws -> ClaudeHookDisposition {
        let disposition = try disposition(for: envelope)
        guard case let .applied(event) = disposition else { return disposition }
        if event.isSubagentLifecycle {
            subagents.apply(event, at: min(receivedAt, envelope.sentAt))
            return disposition
        }
        if event.isSubagentPermissionPrompt {
            waitingSubagentID = event.agentID
            if subagentApprovalReturn == nil, currentStatus.activity != .waitingForApproval {
                subagentApprovalReturn = SubagentApprovalReturn(
                    activity: currentStatus.activity, generation: inputGeneration,
                    watermark: inputWatermark, awaitsApproval: inputAwaitsApproval, reason: currentStatus.reason)
            }
            inputGeneration = UUID(); inputWatermark = envelope.sentAt.timeIntervalSince1970 * 1_000
            inputAwaitsApproval = true; registryTimestamp = nil
            permissionRequestSeen = true
            noteEmission(envelope.sentAt)
            currentStatus.lastEventAt = receivedAt
            currentStatus.activity = .waitingForApproval
            currentStatus.reason = event.reason
            return disposition
        }
        let promotesLostApproval = event.kind == .notification(type: "permission_prompt")
            && currentStatus.activity == .working && !permissionRequestSeen
        if case let .notification(type) = event.kind, !promotesLostApproval,
           Self.notificationActivity(type) == nil
            || (type == "idle_prompt" && !acceptsIdleReminder(sentAt: envelope.sentAt)) {
            // Informational notifications (auth_success, types newer than this build) say
            // nothing about the turn: the state and the pending registry check stay. So does a
            // `permission_prompt`, which comes about 6 s after the PermissionRequest that already said
            // it (or never, when the dialog was answered first), and an `idle_prompt` where the session
            // is not at rest: it is a reminder 60 s after a Stop, not a state.
            noteEmission(envelope.sentAt)
            currentStatus.lastEventAt = receivedAt
            return disposition
        }
        if case .sessionStart = event.kind {
            // The run's own conversation announcing itself after its first prompt hook won the
            // race (a resume typed into at once) keeps what that prompt established.
            let continues = event.providerSessionID == activeProviderSessionID && currentStatus.activity != .unknown
            if let previous = activeProviderSessionID, previous != event.providerSessionID { retiredSessionIDs.insert(previous) }
            retiredSessionIDs.remove(event.providerSessionID)
            activeProviderSessionID = event.providerSessionID
            if continues {
                currentStatus.providerSessionID = event.providerSessionID
                noteEmission(envelope.sentAt)
                currentStatus.lastEventAt = receivedAt
                return disposition
            }
            currentStatus = ClaudeSessionStatus()
            subagents = SubagentLedger()
        }
        inputGeneration = nil
        inputWatermark = nil
        inputAwaitsApproval = false
        registryTimestamp = nil
        subagentApprovalReturn = nil
        waitingSubagentID = nil
        if case .sessionStart = event.kind { registryStartedAt = nil }
        switch event.kind {
        case .permissionRequest:
            inputGeneration = UUID(); inputWatermark = envelope.sentAt.timeIntervalSince1970 * 1_000; inputAwaitsApproval = true
            permissionRequestSeen = true
        case .userPromptSubmit:
            inputGeneration = UUID(); inputWatermark = envelope.sentAt.timeIntervalSince1970 * 1_000
            permissionRequestSeen = false
        case .stop, .stopFailure, .sessionStart:
            permissionRequestSeen = false
        default: break
        }
        // An MCP elicitation is answered in the terminal without a prompt hook: the registry's
        // later "busy" sample moves the card back to Working.
        if promotesLostApproval {
            inputGeneration = UUID(); inputWatermark = envelope.sentAt.timeIntervalSince1970 * 1_000; inputAwaitsApproval = true
        }
        if case .notification("elicitation_dialog") = event.kind {
            inputGeneration = UUID(); inputWatermark = envelope.sentAt.timeIntervalSince1970 * 1_000
        }
        noteEmission(envelope.sentAt)
        currentStatus.lastEventAt = receivedAt
        switch event.kind {
        case .sessionStart:
            // A provider that just started or resumed is at its prompt until a prompt arrives,
            // unless a prompt for it was already dropped before this start was known.
            currentStatus.providerSessionID = event.providerSessionID
            currentStatus.activity = droppedEarlyEvent ? .unknown : .atPrompt
            droppedEarlyEvent = false
        case .userPromptSubmit:
            currentStatus.activity = .working
            currentStatus.reason = event.reason
            // The next turn of the user ends the finished subagents of the last one; a hand-back
            // of a background subagent or a task notification is not that turn, and not the user's use.
            if !event.promptIsSynthetic {
                currentStatus.lastUsedAt = receivedAt
                subagents.clearFinished()
            }
        case .permissionRequest:
            currentStatus.activity = .waitingForApproval
            currentStatus.reason = event.reason
        case let .notification(type):
            if promotesLostApproval {
                currentStatus.activity = .waitingForApproval
            } else if let activity = Self.notificationActivity(type) {
                currentStatus.activity = activity
                if let reason = event.reason { currentStatus.reason = reason }
            }
        case let .stop(backgroundTaskCount, scheduledTaskCount):
            currentStatus.activity = .turnComplete
            currentStatus.reason = event.reason
            currentStatus.lastAssistantMessage = event.lastAssistantMessage
            currentStatus.backgroundTaskCount = backgroundTaskCount
            currentStatus.scheduledTaskCount = scheduledTaskCount
            subagents.turnEnded(
                listing: event.backgroundSubagents, workflowRunning: event.listsRunningWorkflow,
                at: min(receivedAt, envelope.sentAt))
        case let .stopFailure(error, _):
            currentStatus.activity = .failed(error)
            currentStatus.reason = event.reason
            currentStatus.lastAssistantMessage = event.lastAssistantMessage
        case let .sessionEnd(reason):
            currentStatus.activity = .sessionEnded(reason)
        case .unknown:
            currentStatus.activity = .unknown
        case .subagentStart, .subagentStop:
            break // handled before the status; not reachable here
        }
        dropStaleReason()
        return .applied(event)
    }

    /// The activity a notification type establishes; nil for informational types.
    /// `permission_prompt` is not one: "needs you" comes from `PermissionRequest` (S0).
    static func notificationActivity(_ type: String?) -> AgentActivity? {
        switch type {
        case "idle_prompt", "agent_needs_input", "elicitation_dialog": .waitingForInput
        default: nil
        }
    }

    /// An `idle_prompt` only reminds that Claude has waited a minute: it applies where the session is at
    /// rest, never over an approval, a failure (which stays until the next prompt) or an ended session.
    /// Over `.working` it applies only when it is clearly later than the last hook: a user interrupt runs
    /// no Stop, and when the registry's "idle" sample is then lost as stale nothing else ends the turn.
    /// A reminder within the reorder window of a hook may simply be older than the prompt that followed it.
    func acceptsIdleReminder(sentAt: Date) -> Bool {
        switch currentStatus.activity {
        case .turnComplete, .waitingForInput, .atPrompt, .unknown: return true
        case .waitingForApproval, .failed, .sessionEnded: return false
        case .working:
            guard !inputClockAmbiguous, let last = hookEmissionWatermark else { return false }
            return sentAt.timeIntervalSince1970 * 1_000 > last + Self.maximumHookReorderMilliseconds
        }
    }

    private func noteEmission(_ sentAt: Date) {
        let emission = sentAt.timeIntervalSince1970 * 1_000
        guard emission.isFinite else { inputClockAmbiguous = true; return }
        // Helpers for concurrent hooks may deliver slightly out of order; only a larger step back
        // from the hook before means the clock itself moved. That hook is ambiguous; the next one
        // on the new clock is not, and later registry samples are measured against the new clock.
        let steppedBack = lastHookEmission.map { emission < $0 - Self.maximumHookReorderMilliseconds } ?? false
        inputClockAmbiguous = steppedBack
        hookEmissionWatermark = steppedBack ? emission : max(hookEmissionWatermark ?? emission, emission)
        lastHookEmission = emission
    }
}

func unixAddress(path: String) throws -> sockaddr_un {
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

func secureEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
}
