import Foundation

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
    private var pendingRequestSequences: Set<UInt64> = []

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
            pendingRequestSequences.insert(sequence)
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
        guard pendingRequestSequences.remove(requestSequence) != nil else { return }
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
        case .threadClosed:
            currentStatus.activity = .sessionEnded("closed")
        case .threadStarted:
            currentStatus.activity = .unknown
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

/// New remote TUI launches are intentionally serialized. The app-server does
/// not include a PTY/run marker in thread/started, so accepting two unmatched
/// starts concurrently would make identity assignment nondeterministic.
public actor CodexLaunchMatcher {
    private struct Pending {
        let reservation: CodexLaunchReservation
        let workingDirectory: String
        let afterSequence: UInt64
        var matchedThreadID: String?
        var matchedSequence: UInt64?
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

    @discardableResult
    public func receive(
        _ inbound: CodexAppServerInbound
    ) -> (CodexLaunchReservation, CodexThreadIdentity, UInt64)? {
        guard var current = pending,
              case let .event(sequence, .threadStarted(identity)) = inbound,
              sequence > current.afterSequence,
              identity.ephemeral != true,
              let directory = identity.workingDirectory,
              URL(fileURLWithPath: directory).standardizedFileURL.path
                == current.workingDirectory else { return nil }
        current.matchedThreadID = identity.id
        current.matchedSequence = sequence
        pending = current
        current.continuation?.resume(returning: identity.id)
        if current.continuation != nil { finishReservation() }
        return (current.reservation, identity, sequence)
    }

    public func waitForMatch(
        _ reservation: CodexLaunchReservation, timeout: TimeInterval = 10
    ) async throws -> String {
        guard var current = pending, current.reservation == reservation else {
            throw CodexLaunchMatchingError.invalidReservation
        }
        if let matched = current.matchedThreadID {
            finishReservation()
            return matched
        }
        return try await withCheckedThrowingContinuation { continuation in
            current.continuation = continuation
            pending = current
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.02, timeout)))
                await self?.expire(reservation)
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
    case ambiguous([CodexRunBinding])
}

/// Routes the shared app-server stream without guessing. `/new` can be tied to
/// an existing TUI when exactly one live binding has the same cwd. If multiple
/// TUI sessions share that cwd, the event is reported as ambiguous and no
/// durable identity is changed.
public actor CodexSessionRouter {
    public let launchMatcher: CodexLaunchMatcher
    private var bindingsByThread: [String: CodexRunBinding] = [:]

    public init(launchMatcher: CodexLaunchMatcher = CodexLaunchMatcher()) {
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
        if let (reservation, identity, sequence) = await launchMatcher.receive(inbound) {
            return .initialLaunchMatched(CodexRunBinding(
                sessionID: reservation.sessionID,
                managedRunID: reservation.managedRunID,
                threadID: identity.id,
                workingDirectory: identity.workingDirectory ?? ""
            ), sequence: sequence)
        }
        let threadID: String?
        switch inbound {
        case let .request(_, request): threadID = request.threadID
        case let .event(_, event): threadID = Self.threadID(event)
        }
        if let threadID, let binding = bindingsByThread[threadID] {
            return .routed(binding)
        }
        guard case let .event(_, .threadStarted(identity)) = inbound,
              let directory = identity.workingDirectory else { return .unmatched }
        let normalized = URL(fileURLWithPath: directory).standardizedFileURL.path
        let candidates = bindingsByThread.values.filter {
            URL(fileURLWithPath: $0.workingDirectory).standardizedFileURL.path == normalized
        }.sorted { $0.threadID < $1.threadID }
        if candidates.count == 1 {
            return .newConversation(previous: candidates[0], identity: identity)
        }
        if candidates.isEmpty { return .unmatched }
        return .ambiguous(candidates)
    }

    private static func threadID(_ event: CodexAppServerEvent) -> String? {
        switch event {
        case let .threadStarted(identity): identity.id
        case let .threadStatusChanged(threadID, _): threadID
        case let .turnStarted(threadID, _): threadID
        case let .turnCompleted(threadID, _, _, _): threadID
        case let .error(threadID, _, _, _): threadID
        case let .threadClosed(threadID): threadID
        case .unknown: nil
        }
    }
}
