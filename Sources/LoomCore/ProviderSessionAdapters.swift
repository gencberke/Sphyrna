import Foundation
import Synchronization

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
    /// Chat-face runs (V16). Their driver reads the child's own stream and is the one authority for the work
    /// state: hooks still fire for a stream child (S1 §D7) and keep everything else they do here (the
    /// conversation's identity, use and activity times, subagents, the reason line), but their activity is not
    /// published, so the two never contradict each other. Such a run has no registry watch either.
    /// Read from the ingress thread too (a lost hook does not make a driver's state unknown).
    private let driverRuns = Mutex<Set<UUID>>([])

    /// From now on this run's work state comes from its driver alone (`SessionRuntime+Chat`).
    func handOverWorkState(runID: UUID) {
        _ = driverRuns.withLock { $0.insert(runID) }
    }

    private func isDriverRun(_ runID: UUID) -> Bool { driverRuns.withLock { $0.contains(runID) } }

    /// Runs started with the fork route (a side chat's first launch, V22). The fork's own `SessionStart` has source `"fork"`
    /// (S6b); for these runs the id it names is already on the card, so the event never moves the run or makes a card.
    private let forkRuns = Mutex<Set<UUID>>([])

    /// Before the spawn of a fork-route run (`SessionRuntime.startSideChat`).
    func markForkRun(runID: UUID) {
        _ = forkRuns.withLock { $0.insert(runID) }
    }
    /// Runs for which at least one hook message reached Loom, whatever became of it. Set from the
    /// ingress thread, so it lives outside the actor's state.
    private let hookArrivals = Mutex<Set<UUID>>([])
    /// Runs whose hook watchdog is waiting, and the issue text it published for a run.
    private var silenceWatchdogs: [UUID: Task<Void, Never>] = [:]
    private var silenceIssues: [UUID: String] = [:]
    /// How long Claude may report a running turn before the missing hooks are reported. A hook
    /// message trails the registry write by a few milliseconds; this only has to outlast that.
    let hookSilenceGrace: TimeInterval
    static let hookSilenceIssue =
        "Sphyrna is not receiving events from Claude, so this session's status may be wrong. The session itself is not affected."

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
        if discardTracker {
            trackers[runID] = nil
            _ = driverRuns.withLock { $0.remove(runID) }
            _ = forkRuns.withLock { $0.remove(runID) }
            silenceWatchdogs.removeValue(forKey: runID)?.cancel()
            silenceIssues[runID] = nil
            _ = hookArrivals.withLock { $0.remove(runID) }
        }
    }

    private func receiveRegistry(runID: UUID, watchID: UUID, generation: UUID?, result: ClaudeRegistryRead) async {
        // A stream child's entry (`entrypoint: sdk-cli`) says nothing its driver does not know first.
        if isDriverRun(runID) { return }
        if case let .snapshot(snapshot) = result, snapshot.isStreamChild { return }
        while transitioningRuns.contains(runID) {
            guard !Task.isCancelled, registryWatches[runID]?.watch.id == watchID else { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        if registryWatches[runID]?.watch.id == watchID, case let .snapshot(snapshot) = result {
            if snapshot.hasUnknownStatus, let status = snapshot.status { noteUnknownRegistryStatus(status) }
            // A turn is running in Claude's own words; every turn begins with a hook.
            if snapshot.status == "busy" { armSilenceWatchdog(runID: runID) }
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
        // An approval cancelled in the terminal fires no hook: the registry's sample is what moves the
        // activity on, and the reason that described the approval goes with it.
        await supervisor.events.publish(sessionID: latest.activeSessionID, change: .reason(status.reason))
        // The sample that ends an approval takes the mark of the subagent that asked with it (V23); an unchanged list is ignored.
        await publishSubagents(runID: runID, tracker: tracker, fallback: latest.activeSessionID)
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

    public init(supervisor: ProcessSupervisor, hookSilenceGrace: TimeInterval = 3) {
        self.supervisor = supervisor
        self.hookSilenceGrace = hookSilenceGrace
    }

    /// Called synchronously by bounded ingress, outside the lossy delta queue.
    nonisolated func noteHookLoss(runID: UUID) {
        HookDiagnostics.note(.lostToOverflow)
        // A Chat-face run's state does not come from hooks.
        guard !driverRuns.withLock({ $0.contains(runID) }) else { return }
        guard supervisor.invalidateProviderWorkState(runID: runID) else { return }
        LoomLog.error(.claudeHooks, key: "hook-overflow", "Hook events were lost because the intake was full; the run's state is unknown")
        Task { await publishHookLoss(runID: runID) }
    }

    /// Called from the ingress as a message arrives: from then on the run's hooks are known to work.
    nonisolated func noteHookArrival(runID: UUID) {
        _ = hookArrivals.withLock { $0.insert(runID) }
    }

    // MARK: Hook watchdog

    /// Claude reports a running turn in its registry but no hook has ever reached Loom for this run:
    /// the hooks are not being delivered (a Claude that renamed them, settings that disable hooks,
    /// a helper that cannot connect). Only "busy" is taken as proof: at startup Claude can sit at a
    /// folder-trust or first-run question, where it runs no hooks and reports no turn.
    private func armSilenceWatchdog(runID: UUID) {
        guard silenceWatchdogs[runID] == nil, silenceIssues[runID] == nil,
              !hookArrivals.withLock({ $0.contains(runID) }) else { return }
        let grace = hookSilenceGrace
        silenceWatchdogs[runID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            await self?.silenceElapsed(runID: runID)
        }
    }

    private func silenceElapsed(runID: UUID) async {
        guard !hookArrivals.withLock({ $0.contains(runID) }),
              silenceIssues[runID] == nil,
              registryWatches[runID] != nil,
              supervisor.providerWorkStateIsReliable(runID: runID),
              let context = await supervisor.runContext(runID: runID) else { return }
        // A hook may have arrived while the context was read.
        guard !hookArrivals.withLock({ $0.contains(runID) }) else { return }
        silenceIssues[runID] = Self.hookSilenceIssue
        LoomLog.error(.claudeHooks, "No hook event reached Sphyrna for run \(runID.uuidString.prefix(8)) although Claude reports a running turn")
        supervisor.journal?.record("hook_silence", ["run": .string(String(runID.uuidString.prefix(8)))])
        await supervisor.events.publish(sessionID: context.activeSessionID, change: .issue(Self.hookSilenceIssue))
    }

    /// The first event of a run ends the watchdog; its issue goes if it is still the one shown.
    private func hookArrived(runID: UUID) async {
        silenceWatchdogs.removeValue(forKey: runID)?.cancel()
        guard let issue = silenceIssues.removeValue(forKey: runID) else { return }
        LoomLog.notice(.claudeHooks, "Hook events reached Sphyrna for run \(runID.uuidString.prefix(8)) after all")
        guard let sessionID = await supervisor.activeSessionID(runID: runID) else { return }
        if await supervisor.events.snapshot().sessions[sessionID]?.issue == issue {
            await supervisor.events.publish(sessionID: sessionID, change: .issue(nil))
        }
    }

    private static let reportedStatuses = Mutex<Set<String>>([])

    private func noteUnknownRegistryStatus(_ status: String) {
        let token = ClaudeRegistryDiagnostics.token(status)
        guard Self.reportedStatuses.withLock({ $0.insert(token).inserted }) else { return }
        supervisor.journal?.record("cli_compat_warning", [
            "kind": "unknown_registry_status", "status": .string(token),
        ])
    }

    /// For tests: the runs that currently show the watchdog's issue.
    func silenceIssueRuns() -> Set<UUID> { Set(silenceIssues.keys) }

    private func publishHookLoss(runID: UUID) async {
        guard let context = await supervisor.runContext(runID: runID) else {
            supervisor.clearProviderWorkInvalidation(runID: runID)
            return
        }
        try? await supervisor.updateProviderWorkState(runID: runID, state: ProviderWorkState(activity: .unknown))
        await supervisor.events.publish(sessionID: context.activeSessionID, change: .reason(nil))
        await supervisor.events.publish(sessionID: context.activeSessionID,
            change: .issue("Claude hook events were lost; state is unknown. Stop and resume this session to restore reliable tracking."))
    }

    /// Drops what the adapter kept for a deleted conversation (its last status). Per-run state
    /// (tracker, registry watch) already went with the run's end.
    func forget(sessionID: UUID) {
        lastStatuses[sessionID] = nil
    }

    public func status(sessionID: UUID) async -> ClaudeSessionStatus? {
        if let runID = await supervisor.session(id: sessionID)?.currentRun?.id {
            var status = await trackers[runID]?.status() ?? ClaudeSessionStatus()
            if !supervisor.providerWorkStateIsReliable(runID: runID) { status.activity = .unknown; status.reason = nil }
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
        default: status.activity = .unknown; status.reason = nil
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
        noteHookArrival(runID: envelope.managedRunID)
        await hookArrived(runID: envelope.managedRunID)
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
            if source == "fork", forkRuns.withLock({ $0.contains(envelope.managedRunID) }) {
                // The safety net of the fork route: the card was made with the fork's id before the spawn (a pre-assigned
                // `--session-id`), so there is nothing to adopt. A hook that names another id is recorded and changes nothing: the
                // card stays as it is, and no second card appears.
                if event.providerSessionID.lowercased() != context.session.providerConversationID?.lowercased() {
                    supervisor.journal?.record("side_chat_identity_mismatch", [:])
                    LoomLog.error(.claudeHooks, "A side chat's SessionStart named an id other than its card's; ignored")
                }
            } else {
                do {
                    _ = try await supervisor.adoptConversation(
                        runID: envelope.managedRunID,
                        conversationID: event.providerSessionID,
                        transition: transition, at: receivedAt
                    )
                } catch SessionManagementError.conversationBeingDeleted {
                    // A deleted conversation never comes back; this is not an error to show.
                    return .staleRun
                } catch SessionManagementError.runNotFound {
                    // The run is being stopped (a Stop right after the start): its identity no longer matters.
                    return .staleRun
                }
            }
        }
        guard supervisor.providerWorkStateIsReliable(runID: envelope.managedRunID) else {
            await publishHookLoss(runID: envelope.managedRunID)
            return .unreliable
        }
        let disposition = try await tracker.receive(envelope, receivedAt: receivedAt)
        guard case .applied = disposition else { return disposition }
        if event.isSubagentLifecycle {
            // Only the subagent list moves: no status, work state or usage stamp.
            await publishSubagents(runID: envelope.managedRunID, tracker: tracker, fallback: context.activeSessionID)
            noteSubagentDetails(runID: envelope.managedRunID, event: event)
            return disposition
        }
        if case .userPromptSubmit = event.kind, !event.promptIsSynthetic {
            // A hand-back or a task notification starts Claude's own turn, not the user's use.
            // This is a usage timestamp only. An asynchronous helper may run
            // after user work starts, so it cannot establish a process baseline. A catalog that
            // cannot take it must not keep the turn's state from being published.
            do {
                try await supervisor.markProviderUsed(
                    runID: envelope.managedRunID, at: min(receivedAt, envelope.sentAt)
                )
            } catch SessionCatalogError.deletionPending {
                LoomLog.debug(.catalog, "Use stamp skipped: the session is being deleted")
            } catch {
                LoomLog.error(.catalog, key: "mark-used", "The session's use time could not be recorded (\(LoomLog.category(of: error)))")
            }
        }
        switch event.kind {
        case .stop, .stopFailure:
            // A finished turn (also one ended by an API error) is real use: the card time and the
            // activity order follow it. Best effort: a session being deleted refuses the stamp, and
            // that must not keep the turn's status from being published.
            try? await supervisor.markProviderActivity(
                runID: envelope.managedRunID, at: min(receivedAt, envelope.sentAt)
            )
        default: break
        }
        registryWatches[envelope.managedRunID]?.watch.request(generation: await tracker.registryGeneration())
        let status = await tracker.status()
        let activeSessionID = await supervisor.activeSessionID(runID: envelope.managedRunID)
            ?? context.activeSessionID
        lastStatuses[activeSessionID] = status
        // The reason goes first, so a consumer that sees "needs approval" already has what for.
        await supervisor.events.publish(sessionID: activeSessionID, change: .reason(status.reason))
        // The main thread's mode and effort as the CLI reports them; a subagent may run in a mode of its own.
        if event.agentID == nil, event.permissionMode != nil || event.effort != nil {
            await supervisor.events.publish(
                sessionID: activeSessionID,
                change: .reportedChoices(permissionMode: event.permissionMode, effort: event.effort))
        }
        // A Chat-face run's work state is its driver's (see `driverRuns`).
        if !isDriverRun(envelope.managedRunID) {
            try await supervisor.updateProviderWorkState(
                runID: envelope.managedRunID,
                state: ProviderWorkState(
                    activity: status.activity,
                    pendingProviderWorkCount:
                        status.backgroundTaskCount + status.scheduledTaskCount
                )
            )
        }
        switch event.kind {
        case .sessionStart, .userPromptSubmit, .stop:
            // A new conversation, the next real prompt and the end of a turn change the list.
            await publishSubagents(runID: envelope.managedRunID, tracker: tracker, fallback: context.activeSessionID)
        case .permissionRequest where event.isSubagentPermissionPrompt:
            // The subagent that asked is marked in the list (V23).
            await publishSubagents(runID: envelope.managedRunID, tracker: tracker, fallback: context.activeSessionID)
        default: break
        }
        return disposition
    }

    /// Hands the run's current subagent list to the event hub (which ignores an unchanged one and one
    /// for a run that is over). Called while the run's transition is held, so lists reach the hub in order.
    private func publishSubagents(runID: UUID, tracker: ClaudeHookStateTracker, fallback: UUID) async {
        let records = await tracker.subagentRecords()
        let sessionID = await supervisor.activeSessionID(runID: runID) ?? fallback
        await supervisor.events.publish(sessionID: sessionID, change: .subagents(records))
    }

    /// A subagent's description, kind and depth are in a `meta.json` Claude writes a few milliseconds after
    /// `SubagentStart`. It is read off the hook path: a short bounded retry after a start, one try at the
    /// stop (the file exists by then).
    private func noteSubagentDetails(runID: UUID, event: ClaudeHookEvent) {
        guard let agentID = event.agentID,
              let file = SubagentMeta.fileURL(
                agentID: agentID, transcriptPath: event.transcriptPath,
                agentTranscriptPath: event.agentTranscriptPath) else { return }
        let attempts: Int
        switch event.kind {
        case .subagentStart: attempts = Self.metaAttempts
        case .subagentStop: attempts = 1
        default: return
        }
        Task { [weak self] in
            await self?.resolveSubagentMeta(runID: runID, agentID: agentID, file: file, attempts: attempts)
        }
    }

    static let metaAttempts = 8
    static let metaRetryDelay = Duration.milliseconds(40)

    private func resolveSubagentMeta(runID: UUID, agentID: String, file: URL, attempts: Int) async {
        for attempt in 0..<attempts {
            guard trackers[runID] != nil else { return }
            if let found = SubagentMeta.existingFile(agentID: agentID, at: file), let meta = SubagentMeta.read(found) {
                while transitioningRuns.contains(runID) {
                    guard trackers[runID] != nil else { return }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                transitioningRuns.insert(runID)
                defer { transitioningRuns.remove(runID) }
                guard let tracker = trackers[runID], let context = await supervisor.runContext(runID: runID) else { return }
                if await tracker.applySubagentMeta(id: agentID, meta) {
                    await publishSubagents(runID: runID, tracker: tracker, fallback: context.activeSessionID)
                }
                return
            }
            if attempt + 1 < attempts { try? await Task.sleep(for: Self.metaRetryDelay) }
        }
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
                    "Ambiguous new session \(threadID) may belong to another session and is still running"
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
        after sequence: UInt64, at date: Date = Date(), initialStatus: CodexThreadStatus? = nil
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
        let tracker = CodexEventStateTracker(threadID: threadID, managedRunID: runID,
                                             after: sequence, initialStatus: initialStatus)
        trackers[runID] = tracker
        lastStatuses[sessionID] = nil
        if initialStatus != nil { try await publish(runID: runID, tracker: tracker) }
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
        } else if case .event(_, .turnCompleted) = inbound {
            try await supervisor.markProviderActivity(runID: runID, at: receivedAt)
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
