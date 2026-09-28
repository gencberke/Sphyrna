import Foundation

/// Claude owns hook authentication/reduction and translates it into the common
/// work state and conversation operations exposed by the process owner.
public actor ClaudeSessionAdapter {
    private let supervisor: ProcessSupervisor
    private var trackers: [UUID: ClaudeHookStateTracker] = [:]
    private var lastStatuses: [UUID: ClaudeSessionStatus] = [:]
    private var transitioningRuns: Set<UUID> = []

    public init(supervisor: ProcessSupervisor) { self.supervisor = supervisor }

    public func status(sessionID: UUID) async -> ClaudeSessionStatus? {
        if let runID = await supervisor.session(id: sessionID)?.currentRun?.id {
            return await trackers[runID]?.status() ?? ClaudeSessionStatus()
        }
        guard var status = lastStatuses[sessionID] else {
            guard await supervisor.session(id: sessionID) != nil else { return nil }
            var empty = ClaudeSessionStatus()
            empty.activity = .unknown
            return empty
        }
        switch status.activity {
        case .failed, .sessionEnded: break
        default: status.activity = .unknown
        }
        return status
    }

    @discardableResult
    public func receive(
        _ envelope: ClaudeHookEnvelope, receivedAt: Date = Date()
    ) async throws -> ClaudeHookDisposition {
        guard let initial = await supervisor.runContext(runID: envelope.managedRunID) else {
            return .staleRun
        }
        guard initial.launchSessionID == envelope.sessionID else { return .wrongSession }
        let event = try ClaudeHookEvent(payload: envelope.payload)
        while transitioningRuns.contains(envelope.managedRunID) {
            try await Task.sleep(for: .milliseconds(1))
            guard await supervisor.runContext(runID: envelope.managedRunID) != nil else {
                return .staleRun
            }
        }
        transitioningRuns.insert(envelope.managedRunID)
        defer { transitioningRuns.remove(envelope.managedRunID) }
        guard let context = await supervisor.runContext(runID: envelope.managedRunID),
              context.launchSessionID == envelope.sessionID else { return .staleRun }
        let tracker: ClaudeHookStateTracker
        if let existing = trackers[envelope.managedRunID] { tracker = existing }
        else {
            tracker = ClaudeHookStateTracker(
                sessionID: envelope.sessionID, managedRunID: envelope.managedRunID
            )
            trackers[envelope.managedRunID] = tracker
        }
        if case let .sessionStart(source) = event.kind {
            let transition: ConversationTransition
            switch source {
            case "clear", "fork": transition = .new
            case "resume": transition = .resume
            default: transition = .automatic
            }
            _ = try await supervisor.adoptConversation(
                runID: envelope.managedRunID,
                conversationID: event.providerSessionID,
                transition: transition, at: receivedAt
            )
        }
        let disposition = try await tracker.receive(envelope, receivedAt: receivedAt)
        guard case .applied = disposition else { return disposition }
        if case .userPromptSubmit = event.kind {
            try await supervisor.markProviderUsed(
                runID: envelope.managedRunID, at: receivedAt
            )
        }
        let status = await tracker.status()
        let activeSessionID = await supervisor.activeSessionID(runID: envelope.managedRunID)
            ?? context.activeSessionID
        lastStatuses[activeSessionID] = status
        try await supervisor.updateProviderWorkState(
            runID: envelope.managedRunID,
            state: ProviderWorkState(
                activity: status.activity,
                pendingProviderWorkCount:
                    status.backgroundTaskCount + status.scheduledTaskCount
            )
        )
        return disposition
    }
}

/// Codex owns app-server events and the run-scoped reducer. The supervisor sees
/// only generic conversation, usage, work-state and stop-hook operations.
public actor CodexSessionAdapter {
    private let supervisor: ProcessSupervisor
    private var trackers: [UUID: CodexEventStateTracker] = [:]
    private var lastStatuses: [UUID: CodexSessionStatus] = [:]
    private var ambiguousThreads: [UUID: Set<String>] = [:]

    public init(supervisor: ProcessSupervisor) { self.supervisor = supervisor }

    public func markAmbiguous(_ candidates: [CodexRunBinding], threadID: String) async throws {
        for candidate in candidates {
            ambiguousThreads[candidate.managedRunID, default: []].insert(threadID)
            try await supervisor.setIdentityState(
                .ambiguous, runID: candidate.managedRunID
            )
        }
    }

    public func clearAmbiguousThreads(runID: UUID) {
        ambiguousThreads[runID] = nil
    }

    public func verifyAmbiguousStop(
        runID: UUID,
        read: @Sendable (String) async throws -> CodexThreadSnapshot
    ) async throws {
        for threadID in (ambiguousThreads[runID] ?? []).sorted() {
            let snapshot = try await read(threadID)
            if snapshot.isActive {
                throw CodexAppServerError.protocolViolation(
                    "Ambiguous new conversation \(threadID) may belong to another session and is still running"
                )
            }
        }
    }

    public func status(sessionID: UUID) async -> CodexSessionStatus? {
        if let runID = await supervisor.session(id: sessionID)?.currentRun?.id,
           let tracker = trackers[runID] {
            return await tracker.status()
        }
        guard var status = lastStatuses[sessionID] else { return nil }
        if await supervisor.session(id: sessionID)?.currentRun == nil {
            switch status.activity {
            case .failed, .sessionEnded: break
            default: status.activity = .unknown
            }
        }
        return status
    }

    public func bind(
        sessionID: UUID, runID: UUID, threadID: String,
        after sequence: UInt64, at date: Date = Date()
    ) async throws {
        guard let context = await supervisor.runContext(runID: runID),
              context.activeSessionID == sessionID else {
            throw SessionManagementError.runNotFound(runID)
        }
        _ = try await supervisor.adoptConversation(
            runID: runID, conversationID: threadID,
            transition: .bind, at: date
        )
        ambiguousThreads[runID] = nil
        trackers[runID] = CodexEventStateTracker(
            threadID: threadID, managedRunID: runID, after: sequence
        )
        lastStatuses[sessionID] = nil
    }

    @discardableResult
    public func transition(
        runID: UUID, to threadID: String, after sequence: UInt64,
        at date: Date = Date()
    ) async throws -> UUID {
        let sessionID = try await supervisor.adoptConversation(
            runID: runID, conversationID: threadID,
            transition: .new, at: date
        )
        ambiguousThreads[runID] = nil
        trackers[runID] = CodexEventStateTracker(
            threadID: threadID, managedRunID: runID, after: sequence
        )
        lastStatuses[sessionID] = nil
        return sessionID
    }

    @discardableResult
    public func receive(
        _ inbound: CodexAppServerInbound, runID: UUID,
        receivedAt: Date = Date()
    ) async throws -> CodexEventDisposition {
        guard await supervisor.runContext(runID: runID) != nil else { return .staleRun }
        guard let tracker = trackers[runID] else { return .unbound }
        let disposition = await tracker.receive(
            inbound, for: runID, receivedAt: receivedAt
        )
        guard disposition == .applied else { return disposition }
        if case .event(_, .turnStarted) = inbound {
            try await supervisor.markProviderUsed(runID: runID, at: receivedAt)
        }
        try await publish(runID: runID, tracker: tracker)
        return disposition
    }

    @discardableResult
    public func resolveRequest(
        runID: UUID, requestSequence: UInt64, receivedAt: Date = Date()
    ) async -> CodexEventDisposition {
        guard await supervisor.runContext(runID: runID) != nil else { return .staleRun }
        guard let tracker = trackers[runID] else { return .unbound }
        await tracker.requestResolved(
            requestSequence: requestSequence, receivedAt: receivedAt
        )
        try? await publish(runID: runID, tracker: tracker)
        return .applied
    }

    @discardableResult
    public func refresh(
        _ snapshot: CodexThreadSnapshot, runID: UUID, after sequence: UInt64,
        backgroundTerminalCount: Int, receivedAt: Date = Date()
    ) async throws -> CodexEventDisposition {
        guard await supervisor.runContext(runID: runID) != nil else { return .staleRun }
        guard let tracker = trackers[runID] else { return .unbound }
        let disposition = await tracker.refresh(
            snapshot, after: sequence, receivedAt: receivedAt
        )
        guard disposition == .applied else { return disposition }
        await tracker.setBackgroundTerminalCount(backgroundTerminalCount)
        if let used = snapshot.lastTurnStartedAt {
            try await supervisor.markProviderUsed(runID: runID, at: used)
        }
        try await publish(runID: runID, tracker: tracker)
        return disposition
    }

    private func publish(
        runID: UUID, tracker: CodexEventStateTracker
    ) async throws {
        guard let sessionID = await supervisor.activeSessionID(runID: runID) else { return }
        let status = await tracker.status()
        lastStatuses[sessionID] = status
        try await supervisor.updateProviderWorkState(
            runID: runID,
            state: ProviderWorkState(
                activity: status.activity,
                pendingProviderWorkCount:
                    status.pendingRequestCount + status.backgroundTerminalCount
            )
        )
    }
}
