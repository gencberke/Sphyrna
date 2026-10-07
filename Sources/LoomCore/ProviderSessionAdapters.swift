import Foundation

/// Claude owns hook authentication/reduction and translates it into the common
/// work state and conversation operations exposed by the process owner.
public actor ClaudeSessionAdapter {
    private let supervisor: ProcessSupervisor
    private var trackers: [UUID: ClaudeHookStateTracker] = [:]
    private var lastStatuses: [UUID: ClaudeSessionStatus] = [:]
    private var transitioningRuns: Set<UUID> = []
    private struct RegistryObservation {
        let watch: ClaudeRegistryWatch
        let continuation: AsyncStream<(UUID, UUID?, ClaudeRegistryRead)>.Continuation
        let consumer: Task<Void, Never>
    }
    private var registryWatches: [UUID: RegistryObservation] = [:]
    private var registryIssues: [UUID: String] = [:]

    func observeRegistry(runID: UUID, reader: ClaudeRegistryReader) async {
        stopRegistry(runID: runID, discardTracker: false)
        // These are replaceable full snapshots, not identity/permission deltas.
        let pair = AsyncStream<(UUID, UUID?, ClaudeRegistryRead)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let watch = ClaudeRegistryWatch(reader: reader) { watchID, generation, result in
            pair.continuation.yield((watchID, generation, result))
        }
        let consumer = Task { [weak self] in
            for await (watchID, generation, result) in pair.stream {
                guard !Task.isCancelled else { break }
                await self?.receiveRegistry(runID: runID, watchID: watchID, generation: generation, result: result)
            }
        }
        registryWatches[runID] = RegistryObservation(watch: watch, continuation: pair.continuation, consumer: consumer)
        watch.request(generation: await trackers[runID]?.registryGeneration())
    }

    func stopRegistry(runID: UUID, discardTracker: Bool = true) {
        if let observation = registryWatches.removeValue(forKey: runID) {
            observation.watch.stop(); observation.continuation.finish(); observation.consumer.cancel()
        }
        registryIssues[runID] = nil
        if discardTracker { trackers[runID] = nil }
    }

    private func receiveRegistry(runID: UUID, watchID: UUID, generation: UUID?, result: ClaudeRegistryRead) async {
        while transitioningRuns.contains(runID) {
            guard !Task.isCancelled, registryWatches[runID]?.watch.id == watchID else { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard !Task.isCancelled, registryWatches[runID]?.watch.id == watchID,
              supervisor.providerWorkStateIsReliable(runID: runID),
              let context = await supervisor.runContext(runID: runID),
              let tracker = trackers[runID] else { return }
        transitioningRuns.insert(runID)
        defer { transitioningRuns.remove(runID) }
        let issue = await tracker.receiveRegistry(result, generation: generation, now: Date())
        guard registryWatches[runID]?.watch.id == watchID,
              supervisor.providerWorkStateIsReliable(runID: runID),
              let latest = await supervisor.runContext(runID: runID),
              latest.activeSessionID == context.activeSessionID else { return }
        let status = await tracker.status()
        lastStatuses[latest.activeSessionID] = status
        try? await supervisor.updateProviderWorkState(runID: runID, state: ProviderWorkState(
            activity: status.activity, pendingProviderWorkCount: status.backgroundTaskCount + status.scheduledTaskCount))
        if let issue {
            registryIssues[runID] = issue
            await supervisor.events.publish(sessionID: latest.activeSessionID, change: .issue(issue))
        } else if let previous = registryIssues[runID], status.activity == .waitingForInput {
            registryIssues[runID] = nil
            if await supervisor.events.snapshot().sessions[latest.activeSessionID]?.issue == previous {
                await supervisor.events.publish(sessionID: latest.activeSessionID, change: .issue(nil))
            }
        }
    }

    public init(supervisor: ProcessSupervisor) { self.supervisor = supervisor }

    /// Called synchronously by bounded ingress, outside the lossy delta queue.
    nonisolated func noteHookLoss(runID: UUID) {
        guard supervisor.invalidateProviderWorkState(runID: runID) else { return }
        Task { await publishHookLoss(runID: runID) }
    }

    private func publishHookLoss(runID: UUID) async {
        guard let context = await supervisor.runContext(runID: runID) else {
            supervisor.clearProviderWorkInvalidation(runID: runID)
            return
        }
        try? await supervisor.updateProviderWorkState(runID: runID, state: ProviderWorkState(activity: .unknown))
        await supervisor.events.publish(sessionID: context.activeSessionID,
            change: .issue("Claude hook events were lost; state is unknown. Stop and resume this conversation to restore reliable tracking."))
    }

    /// Drops what the adapter kept for a deleted conversation (its last status). Per-run state
    /// (tracker, registry watch) already went with the run's end.
    func forget(sessionID: UUID) {
        lastStatuses[sessionID] = nil
    }

    public func status(sessionID: UUID) async -> ClaudeSessionStatus? {
        if let runID = await supervisor.session(id: sessionID)?.currentRun?.id {
            var status = await trackers[runID]?.status() ?? ClaudeSessionStatus()
            if !supervisor.providerWorkStateIsReliable(runID: runID) { status.activity = .unknown }
            return status
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
        guard supervisor.providerWorkStateIsReliable(runID: envelope.managedRunID) else { return .unreliable }
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
        guard supervisor.providerWorkStateIsReliable(runID: envelope.managedRunID) else { return .unreliable }
        let tracker: ClaudeHookStateTracker
        if let existing = trackers[envelope.managedRunID] { tracker = existing }
        else {
            tracker = ClaudeHookStateTracker(
                sessionID: envelope.sessionID, managedRunID: envelope.managedRunID,
                providerSessionID: context.session.providerConversationID
            )
            trackers[envelope.managedRunID] = tracker
        }
        let accepted = try await tracker.disposition(for: envelope)
        guard case .applied = accepted else { return accepted }
        if case let .sessionStart(source) = event.kind {
            let transition: ConversationTransition
            switch source {
            case "clear", "fork": transition = .new
            case "resume": transition = .resume
            default: transition = .automatic
            }
            do {
                _ = try await supervisor.adoptConversation(
                    runID: envelope.managedRunID,
                    conversationID: event.providerSessionID,
                    transition: transition, at: receivedAt
                )
            } catch SessionManagementError.conversationBeingDeleted {
                // A deleted conversation never comes back; this is not an error to show.
                return .staleRun
            }
        }
        guard supervisor.providerWorkStateIsReliable(runID: envelope.managedRunID) else {
            await publishHookLoss(runID: envelope.managedRunID)
            return .unreliable
        }
        let disposition = try await tracker.receive(envelope, receivedAt: receivedAt)
        guard case .applied = disposition else { return disposition }
        if case .userPromptSubmit = event.kind {
            // This is a usage timestamp only. An asynchronous helper may run
            // after user work starts, so it cannot establish a process baseline.
            try await supervisor.markProviderUsed(
                runID: envelope.managedRunID, at: min(receivedAt, envelope.sentAt)
            )
        }
        registryWatches[envelope.managedRunID]?.watch.request(generation: await tracker.registryGeneration())
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
