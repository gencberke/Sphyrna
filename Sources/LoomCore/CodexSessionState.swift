import Foundation

/// Provider-reported settings at the last successful, identity-checked resume.
/// Native changes after that response are not reflected until the next resume.
public struct CodexResumeSettings: Equatable, Sendable {
    public let model: String?
    public let effort: String?
    public let mode: HarnessMode
}

extension CodexResumeSettings {
    /// Validate native permission evidence without consulting stored app launch choices.
    static func decodeNative(_ result: JSONValue, threadID: String, workingDirectory: String) throws -> Self {
        let response = result.object ?? [:]
        let thread = response["thread"]?.object ?? [:]
        guard thread["id"]?.string == threadID else {
            throw CodexAppServerError.protocolViolation("thread/resume returned a missing or different thread identity")
        }
        guard let cwd = response["cwd"]?.string, cwd.hasPrefix("/"), workingDirectory.hasPrefix("/"),
              URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
                == URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CodexAppServerError.protocolViolation("thread/resume returned a different working directory")
        }
        let sandbox = response["sandbox"]?.object ?? [:]
        // The native schema defaults absent network and writable-root fields
        // to false/empty; null or a different type is not that default.
        let network = sandbox["networkAccess"] ?? .bool(false)
        let writableRoots = sandbox["writableRoots"] ?? .array([])
        let mode: HarnessMode
        switch sandbox["type"]?.string {
        case "readOnly": mode = .askBeforeEdits
        case "workspaceWrite" where writableRoots == .array([]): mode = .acceptEdits
        default: throw CodexAppServerError.protocolViolation("thread/resume returned unverified permissions")
        }
        let runtimeRoots = (response["runtimeWorkspaceRoots"] ?? .array([])).array
        let expectedRoot = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path
        // A native TUI normally records its own cwd as :workspace_roots. It
        // adds no directory beyond the already identity-checked workspace.
        let rootsMatch = runtimeRoots.map { roots in
            roots.count <= 1 && roots.allSatisfy { value in
                guard let path = value.string, path.hasPrefix("/") else { return false }
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == expectedRoot
            }
        } ?? false
        guard network == .bool(false),
              response["approvalPolicy"]?.string == "on-request",
              response["approvalsReviewer"]?.string == "user",
              response["activePermissionProfile"] == nil || response["activePermissionProfile"] == .null,
              rootsMatch else {
            throw CodexAppServerError.protocolViolation("thread/resume returned unverified permissions")
        }
        return CodexResumeSettings(model: response["model"]?.string,
                                   effort: response["reasoningEffort"]?.string, mode: mode)
    }
}

public struct CodexSessionStatus: Equatable, Sendable {
    public var providerThreadID: String
    public var activity: AgentActivity
    public var lastUsedAt: Date?
    public var lastEventAt: Date?
    public var lastAssistantMessage: String?
    public var pendingRequestCount: Int
    public var backgroundTerminalCount: Int

    public init(providerThreadID: String) {
        self.providerThreadID = providerThreadID
        activity = .unknown
        lastUsedAt = nil
        lastEventAt = nil
        lastAssistantMessage = nil
        pendingRequestCount = 0
        backgroundTerminalCount = 0
    }
}

public enum CodexEventDisposition: Equatable, Sendable {
    case applied
    case differentThread
    case staleSequence
    case staleRun
    case unbound
}

/// Run-scoped reducer for one Codex conversation. A sequence barrier is taken
/// immediately before a remote TUI is launched/resumed; messages already
/// queued from its previous run cannot mutate the new run's state.
public actor CodexEventStateTracker {
    public let threadID: String
    private var managedRunID: UUID
    private var minimumSequence: UInt64
    private var currentStatus: CodexSessionStatus
    private var pendingRequestSequences: [UInt64: JSONValue] = [:]

    public init(threadID: String, managedRunID: UUID, after sequence: UInt64) {
        self.threadID = threadID
        self.managedRunID = managedRunID
        minimumSequence = sequence
        currentStatus = CodexSessionStatus(providerThreadID: threadID)
    }

    public func beginRun(_ runID: UUID, after sequence: UInt64) {
        managedRunID = runID
        minimumSequence = sequence
        currentStatus = CodexSessionStatus(providerThreadID: threadID)
        pendingRequestSequences.removeAll()
    }

    public func status() -> CodexSessionStatus { currentStatus }

    public func setBackgroundTerminalCount(_ count: Int) {
        currentStatus.backgroundTerminalCount = max(0, count)
    }

    public func refresh(
        _ snapshot: CodexThreadSnapshot, after sequence: UInt64,
        receivedAt: Date = Date()
    ) -> CodexEventDisposition {
        guard snapshot.threadID == threadID else { return .differentThread }
        guard sequence >= minimumSequence else { return .staleSequence }
        minimumSequence = sequence
        currentStatus.lastEventAt = receivedAt
        currentStatus.lastUsedAt = snapshot.lastTurnStartedAt ?? currentStatus.lastUsedAt
        currentStatus.lastAssistantMessage = snapshot.lastAssistantMessage
        guard let outcome = snapshot.lastTurnOutcome else {
            currentStatus.activity = .turnComplete
            return .applied
        }
        switch outcome {
        case .completed: currentStatus.activity = .turnComplete
        case .interrupted: currentStatus.activity = .failed("interrupted")
        case let .failed(message): currentStatus.activity = .failed(message)
        case .unknown: currentStatus.activity = .unknown
        }
        return .applied
    }

    @discardableResult
    public func receive(
        _ inbound: CodexAppServerInbound, for runID: UUID,
        receivedAt: Date = Date()
    ) -> CodexEventDisposition {
        let sequence: UInt64
        switch inbound {
        case let .event(value, _), let .request(value, _): sequence = value
        }
        guard runID == managedRunID else { return .staleRun }
        guard sequence > minimumSequence else { return .staleSequence }
        switch inbound {
        case let .event(_, event):
            guard Self.threadID(event) == nil || Self.threadID(event) == threadID else {
                return .differentThread
            }
            currentStatus.lastEventAt = receivedAt
            reduce(event, receivedAt: receivedAt)
        case let .request(_, request):
            guard request.threadID == nil || request.threadID == threadID else {
                return .differentThread
            }
            currentStatus.lastEventAt = receivedAt
            pendingRequestSequences = pendingRequestSequences.filter { $0.value != request.id }
            pendingRequestSequences[sequence] = request.id
            currentStatus.pendingRequestCount = pendingRequestSequences.count
            switch request.kind {
            case .userInput: currentStatus.activity = .waitingForInput
            case .commandExecution, .fileChange, .permissions:
                currentStatus.activity = .waitingForApproval
            case .other: currentStatus.activity = .unknown
            }
        }
        minimumSequence = sequence
        return .applied
    }

    public func requestResolved(requestSequence: UInt64, receivedAt: Date = Date()) {
        guard pendingRequestSequences.removeValue(forKey: requestSequence) != nil else { return }
        currentStatus.lastEventAt = receivedAt
        currentStatus.pendingRequestCount = pendingRequestSequences.count
        if pendingRequestSequences.isEmpty,
           currentStatus.activity == .waitingForApproval
               || currentStatus.activity == .waitingForInput {
            currentStatus.activity = .working
        }
    }

    private func reduce(_ event: CodexAppServerEvent, receivedAt: Date) {
        switch event {
        case let .threadStatusChanged(_, status):
            switch status {
            case .notLoaded: currentStatus.activity = .unknown
            case .idle: currentStatus.activity = .turnComplete
            case .systemError: currentStatus.activity = .failed("systemError")
            case let .active(flags):
                if flags.contains(.waitingOnApproval) {
                    currentStatus.activity = .waitingForApproval
                } else if flags.contains(.waitingOnUserInput) {
                    currentStatus.activity = .waitingForInput
                } else {
                    currentStatus.activity = .working
                }
            case .unknown: currentStatus.activity = .unknown
            }
        case .turnStarted:
            currentStatus.activity = .working
            currentStatus.lastUsedAt = receivedAt
        case let .turnCompleted(_, _, outcome, message):
            currentStatus.lastAssistantMessage = message
            switch outcome {
            case .completed: currentStatus.activity = .turnComplete
            case .interrupted: currentStatus.activity = .failed("interrupted")
            case let .failed(message): currentStatus.activity = .failed(message)
            case .unknown: currentStatus.activity = .unknown
            }
        case let .error(_, _, message, willRetry):
            currentStatus.activity = willRetry ? .working : .failed(message)
        case let .serverRequestResolved(_, requestID):
            for sequence in pendingRequestSequences.filter({ $0.value == requestID }).keys {
                requestResolved(requestSequence: sequence, receivedAt: receivedAt)
            }
        case .threadClosed:
            currentStatus.activity = .sessionEnded("closed")
        case .threadStarted:
            // A resume can announce the already bound thread again.
            break
        case .unknown:
            currentStatus.activity = .unknown
        }
    }

    private static func threadID(_ event: CodexAppServerEvent) -> String? {
        switch event {
        case let .threadStarted(identity): identity.id
        case let .threadStatusChanged(threadID, _): threadID
        case let .turnStarted(threadID, _): threadID
        case let .turnCompleted(threadID, _, _, _): threadID
        case let .error(threadID, _, _, _): threadID
        case let .serverRequestResolved(threadID, _): threadID
        case let .threadClosed(threadID): threadID
        case .unknown: nil
        }
    }
}

public struct CodexLaunchReservation: Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let managedRunID: UUID
}

public enum CodexLaunchMatchingError: Error, Equatable, Sendable {
    case invalidReservation
    case cancelled
    case timeout
}

/// Matches a new TUI's `thread/started` to its launch by cwd. The runtime
/// gives every TUI its own app-server and coordinator, so one reservation is
/// pending per matcher; concurrent reservations on one matcher are still
/// serialized because thread/started carries no PTY/run marker.
public actor CodexLaunchMatcher {
    private struct Pending {
        let reservation: CodexLaunchReservation
        let workingDirectory: String
        let afterSequence: UInt64
        var matchedThreadID: String?
        var matchedSequence: UInt64?
        var committed = false
        var continuation: CheckedContinuation<String, any Error>?
    }

    private var pending: Pending?
    private var reservationWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func reserveNewLaunch(
        sessionID: UUID, managedRunID: UUID, workingDirectory: String,
        after sequence: UInt64
    ) async -> CodexLaunchReservation {
        while pending != nil {
            await withCheckedContinuation { continuation in
                reservationWaiters.append(continuation)
            }
        }
        let reservation = CodexLaunchReservation(
            id: UUID(), sessionID: sessionID, managedRunID: managedRunID
        )
        pending = Pending(
            reservation: reservation,
            workingDirectory: URL(fileURLWithPath: workingDirectory).standardizedFileURL.path,
            afterSequence: sequence, matchedThreadID: nil, matchedSequence: nil,
            continuation: nil
        )
        return reservation
    }

    func pendingBinding() -> CodexRunBinding? {
        guard let pending else { return nil }
        return CodexRunBinding(sessionID: pending.reservation.sessionID,
                               managedRunID: pending.reservation.managedRunID,
                               threadID: "", workingDirectory: pending.workingDirectory)
    }

    @discardableResult
    public func receive(
        _ inbound: CodexAppServerInbound
    ) -> (CodexLaunchReservation, CodexThreadIdentity, UInt64)? {
        guard var current = pending,
              current.matchedThreadID == nil,
              case let .event(sequence, .threadStarted(identity)) = inbound,
              sequence > current.afterSequence,
              identity.isInteractiveConversation,
              let directory = identity.workingDirectory,
              URL(fileURLWithPath: directory).standardizedFileURL.path
                == current.workingDirectory else { return nil }
        current.matchedThreadID = identity.id
        current.matchedSequence = sequence
        pending = current
        return (current.reservation, identity, sequence)
    }

    /// Matching is provisional until the runtime has adopted the native ID
    /// durably and installed its run binding. A cancelled owner cannot commit.
    func commitMatched(_ binding: CodexRunBinding) -> Bool {
        guard var current = pending,
              current.reservation.sessionID == binding.sessionID,
              current.reservation.managedRunID == binding.managedRunID,
              current.matchedThreadID == binding.threadID else { return false }
        current.committed = true
        pending = current
        if let continuation = current.continuation {
            continuation.resume(returning: binding.threadID)
            finishReservation()
        }
        return true
    }

    func rejectMatched(runID: UUID) {
        guard let current = pending, current.reservation.managedRunID == runID else { return }
        cancel(current.reservation)
    }

    public func waitForMatch(
        _ reservation: CodexLaunchReservation, timeout: TimeInterval? = 10
    ) async throws -> String {
        guard var current = pending, current.reservation == reservation else {
            throw CodexLaunchMatchingError.invalidReservation
        }
        if current.committed, let matched = current.matchedThreadID {
            finishReservation()
            return matched
        }
        return try await withCheckedThrowingContinuation { continuation in
            current.continuation = continuation
            pending = current
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0.02, timeout)))
                    await self?.expire(reservation)
                }
            }
        }
    }

    public func cancel(_ reservation: CodexLaunchReservation) {
        guard pending?.reservation == reservation else { return }
        pending?.continuation?.resume(throwing: CodexLaunchMatchingError.cancelled)
        finishReservation()
    }

    private func expire(_ reservation: CodexLaunchReservation) {
        guard pending?.reservation == reservation else { return }
        pending?.continuation?.resume(throwing: CodexLaunchMatchingError.timeout)
        finishReservation()
    }

    private func finishReservation() {
        pending = nil
        if !reservationWaiters.isEmpty {
            reservationWaiters.removeFirst().resume()
        }
    }
}

public struct CodexRunBinding: Equatable, Sendable {
    public let sessionID: UUID
    public let managedRunID: UUID
    public let threadID: String
    public let workingDirectory: String
}

public enum CodexRouteDecision: Equatable, Sendable {
    case initialLaunchMatched(CodexRunBinding, sequence: UInt64)
    case routed(CodexRunBinding)
    case newConversation(previous: CodexRunBinding, identity: CodexThreadIdentity)
    case unmatched
    case ambiguous([CodexRunBinding], threadID: String)
}

/// Routes one app-server's stream without guessing. `/new` can be tied to an
/// existing TUI when exactly one live binding has the same cwd. If several
/// bindings could own it (not reachable through the runtime, which binds one
/// run per server), the event is reported as ambiguous and no durable identity
/// is changed.
public actor CodexSessionRouter {
    public let launchMatcher: CodexLaunchMatcher
    public nonisolated let diagnostics: CodexRoutingDiagnostics
    private var bindingsByThread: [String: CodexRunBinding] = [:]

    public init(launchMatcher: CodexLaunchMatcher = CodexLaunchMatcher(),
                diagnostics: CodexRoutingDiagnostics = CodexRoutingDiagnostics()) {
        self.diagnostics = diagnostics
        self.launchMatcher = launchMatcher
    }

    public func register(_ binding: CodexRunBinding) {
        for (threadID, value) in bindingsByThread
            where value.managedRunID == binding.managedRunID {
            bindingsByThread[threadID] = nil
        }
        bindingsByThread[binding.threadID] = binding
    }

    public func remove(runID: UUID) {
        bindingsByThread = bindingsByThread.filter { $0.value.managedRunID != runID }
    }

    public func route(_ inbound: CodexAppServerInbound) async -> CodexRouteDecision {
        let pending = await launchMatcher.pendingBinding()
        let decision = await decide(inbound, pending: pending)
        let sequence: UInt64
        let eventName: String
        let threadID: String?
        var identity: CodexThreadIdentity?
        switch inbound {
        case let .request(value, request):
            sequence = value; eventName = "request"; threadID = request.threadID
        case let .event(value, event):
            sequence = value; threadID = Self.threadID(event)
            switch event {
            case let .threadStarted(value): eventName = "threadStarted"; identity = value
            case .threadStatusChanged: eventName = "threadStatusChanged"
            case .turnStarted: eventName = "turnStarted"
            case .turnCompleted: eventName = "turnCompleted"
            case .error: eventName = "error"
            case .threadClosed: eventName = "threadClosed"
            case .serverRequestResolved: eventName = "serverRequestResolved"
            case .unknown: eventName = "unknown"
            }
        }
        var candidates = identity.map { cwdCandidates($0) } ?? []
        if let pending, let cwd = identity?.workingDirectory,
           Self.normalized(cwd) == Self.normalized(pending.workingDirectory) {
            candidates.append(pending)
        }
        let cwdMatch = identity?.workingDirectory == nil ? nil : !candidates.isEmpty
        let label: String
        switch decision {
        case let .initialLaunchMatched(binding, _): label = "initialLaunchMatched"; candidates = [binding]
        case let .routed(binding): label = "routed"; candidates = [binding]
        case .newConversation: label = "newConversation"
        case .ambiguous: label = "ambiguous"
        case .unmatched: label = identity?.ephemeral == true ? "ignoredEphemeral" : "unmatched"
        }
        await diagnostics.record(CodexRoutingDiagnostic(
            sequence: sequence, event: eventName, threadID: threadID,
            sessionIDs: candidates.map(\.sessionID), runIDs: candidates.map(\.managedRunID),
            cwdMatch: cwdMatch,
            ephemeral: identity?.ephemeral, source: identity?.sourceClass ?? "missing",
            originator: identity?.originatorClass ?? "missing", decision: label
        ))
        return decision
    }

    private func decide(_ inbound: CodexAppServerInbound, pending: CodexRunBinding?) async -> CodexRouteDecision {
        if case let .event(_, .threadStarted(identity)) = inbound,
           identity.ephemeral == true || identity.source == "exec" { return .unmatched }
        let threadID: String?
        switch inbound {
        case let .request(_, request): threadID = request.threadID
        case let .event(_, event): threadID = Self.threadID(event)
        }
        if let threadID, let binding = bindingsByThread[threadID] {
            return .routed(binding)
        }
        if let (reservation, identity, sequence) = await launchMatcher.receive(inbound) {
            return .initialLaunchMatched(CodexRunBinding(
                sessionID: reservation.sessionID,
                managedRunID: reservation.managedRunID,
                threadID: identity.id,
                workingDirectory: identity.workingDirectory ?? ""
            ), sequence: sequence)
        }
        guard case let .event(_, .threadStarted(identity)) = inbound,
              let directory = identity.workingDirectory else { return .unmatched }
        var candidates = cwdCandidates(identity)
        if !identity.isInteractiveConversation {
            if let pending, Self.normalized(directory) == Self.normalized(pending.workingDirectory) {
                candidates.append(pending)
            }
            return candidates.isEmpty ? .unmatched : .ambiguous(candidates, threadID: identity.id)
        }
        if candidates.count == 1 {
            return .newConversation(previous: candidates[0], identity: identity)
        }
        if candidates.isEmpty { return .unmatched }
        return .ambiguous(candidates, threadID: identity.id)
    }

    private static func normalized(_ directory: String) -> String {
        URL(fileURLWithPath: directory).standardizedFileURL.path
    }

    private func cwdCandidates(_ identity: CodexThreadIdentity) -> [CodexRunBinding] {
        guard let directory = identity.workingDirectory else { return [] }
        return bindingsByThread.values.filter {
            Self.normalized($0.workingDirectory) == Self.normalized(directory)
        }.sorted { $0.threadID < $1.threadID }
    }

    private static func threadID(_ event: CodexAppServerEvent) -> String? {
        switch event {
        case let .threadStarted(identity): identity.id
        case let .threadStatusChanged(threadID, _): threadID
        case let .turnStarted(threadID, _): threadID
        case let .turnCompleted(threadID, _, _, _): threadID
        case let .error(threadID, _, _, _): threadID
        case let .serverRequestResolved(threadID, _): threadID
        case let .threadClosed(threadID): threadID
        case .unknown: nil
        }
    }
}
