import Foundation

public struct ProviderWorkState: Equatable, Sendable {
    public let activity: AgentActivity
    public let pendingProviderWorkCount: Int

    public init(activity: AgentActivity, pendingProviderWorkCount: Int = 0) {
        self.activity = activity
        self.pendingProviderWorkCount = max(0, pendingProviderWorkCount)
    }
}

public struct SessionIdlePolicy: Equatable, Sendable {
    public var idleAfter: TimeInterval
    public var staleAfter: TimeInterval
    public var stopGraceSeconds: Double

    public init(
        idleAfter: TimeInterval = 60 * 60,
        staleAfter: TimeInterval = 15 * 24 * 60 * 60,
        stopGraceSeconds: Double = 0.2
    ) {
        self.idleAfter = idleAfter
        self.staleAfter = staleAfter
        self.stopGraceSeconds = stopGraceSeconds
    }
}

public enum SessionIdleBlocker: Hashable, Sendable {
    case notDue
    case unknownAgentState
    case activeTurn
    case waitingForApproval
    case waitingForInput
    case pendingProviderWork(Int)
    case pendingPromptDelivery(Int)
    /// Terminal input was accepted within the idle period; it counts as use.
    case recentTerminalInput
    case baselineNotCaptured
    case nonBaselineDescendants(Int)
    case ambiguousIdentity
    case stopUnverified
    /// The conversation is being deleted: its input stays closed and only the deletion stops it.
    case deletionPending
}

public enum SessionIdleEvaluation: Sendable {
    case notRunning
    case alreadyIdle
    case blocked(Set<SessionIdleBlocker>)
    case transitioned(SessionStopReport)
    case interruptedByNewWork(SessionStopReport, pendingPromptIDs: Set<UUID>)
    case stopFailed(SessionStopReport)
}

/// What a provider keeps next to a conversation's own run (Codex: the
/// conversation's app-server, in the same run scope). Automatic idle must see
/// its work and end it before `idle` is shown.
public struct SessionRunCompanion: Sendable {
    public struct Work: Sendable {
        /// Provider infrastructure that is not user work (the server's leader).
        public let infrastructure: Set<ProcessIdentity>
        /// Every live process of the conversation beyond its own run's tree.
        public let live: [ProcessRecord]

        public init(infrastructure: Set<ProcessIdentity>, live: [ProcessRecord]) {
            self.infrastructure = infrastructure
            self.live = live
        }
    }

    public var work: @Sendable (_ sessionID: UUID) async throws -> Work?
    /// Ends what the companion kept for a run that was just stopped; the
    /// returned failures make the stop unverified.
    public var teardown: @Sendable (_ runID: UUID) async -> [String]

    public init(
        work: @escaping @Sendable (UUID) async throws -> Work?,
        teardown: @escaping @Sendable (UUID) async -> [String]
    ) {
        self.work = work
        self.teardown = teardown
    }
}

/// Provider-independent idle/stale coordinator. The UI must register a prompt
/// before attempting terminal delivery; this gives shutdown a durable-in-memory
/// handoff token when new work races the controlled stop.
public actor SessionLifecycleController {
    private struct Baseline: Sendable {
        let runID: UUID
        let identities: Set<ProcessIdentity>
    }

    private let supervisor: ProcessSupervisor
    private let catalog: SessionCatalog
    public let inputGate: TerminalInputGate
    public let policy: SessionIdlePolicy
    private let companion: SessionRunCompanion?
    private var baselines: [UUID: Baseline] = [:]
    private var pendingPrompts: [UUID: Set<UUID>] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var timer: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var blockedDue: [UUID: Date] = [:]
    // Only sessions blocked by sampled descendants need a process recheck:
    // their children can exit without producing a provider event.
    private var descendantRechecks: [UUID: Date] = [:]
    // Re-checks back off 5, 10, 20 ... 300 s while the children stay; any
    // state change of the conversation starts over at the first step.
    struct DescendantRecheckSchedule: Equatable, Sendable {
        var initial: TimeInterval = 5
        var cap: TimeInterval = 300
        func next(after current: TimeInterval?) -> TimeInterval {
            guard let current else { return initial }
            return min(cap, current * 2)
        }
    }
    private let recheckSchedule: DescendantRecheckSchedule
    private var descendantBackoff: [UUID: TimeInterval] = [:]
    private var timerFires = 0
    private var completedTimerEvaluations = 0
    private var scheduleGeneration: UInt64 = 0
    private struct LifecycleState: Equatable, Sendable {
        let runID: UUID?
        let status: ProviderWorkState?
        let lifecycle: SessionLifecycle?
        let conversationID: String?
        let identity: SessionIdentityState

        init(_ state: SessionViewState) {
            runID = state.runID
            status = state.status
            lifecycle = state.lifecycle
            conversationID = state.conversationID
            identity = state.identity
        }
    }
    private var observedStates: [UUID: LifecycleState] = [:]
    private var observedCatalogRevision: UInt64 = 0

    public init(
        supervisor: ProcessSupervisor, catalog: SessionCatalog,
        policy: SessionIdlePolicy = SessionIdlePolicy(),
        inputGate: TerminalInputGate = TerminalInputGate(),
        companion: SessionRunCompanion? = nil
    ) {
        self.init(
            supervisor: supervisor, catalog: catalog, policy: policy,
            inputGate: inputGate, companion: companion,
            recheckSchedule: DescendantRecheckSchedule()
        )
    }

    init(
        supervisor: ProcessSupervisor, catalog: SessionCatalog,
        policy: SessionIdlePolicy, inputGate: TerminalInputGate = TerminalInputGate(),
        companion: SessionRunCompanion? = nil,
        recheckSchedule: DescendantRecheckSchedule
    ) {
        self.recheckSchedule = recheckSchedule
        self.companion = companion
        self.supervisor = supervisor
        self.catalog = catalog
        self.policy = policy
        self.inputGate = inputGate
    }

    deinit {
        timer?.cancel()
        eventTask?.cancel()
    }

    /// One event listener and one timer serve every session. The timer is
    /// scheduled for the next idle/stale deadline or blocked-child recheck.
    public func startAutomaticEvaluation() async throws {
        guard eventTask == nil else { return }
        let stream = await supervisor.events.subscribe()
        try await startAutomaticEvaluation(stream: stream)
    }

    /// Internal consumer seam; tests can deliver an actual coalesced hub frame.
    func startAutomaticEvaluation(stream: AsyncStream<SessionEventFrame>) async throws {
        guard eventTask == nil else { return }
        let initial = await supervisor.events.snapshot()
        observedStates = initial.sessions.mapValues(LifecycleState.init)
        observedCatalogRevision = initial.catalogRevision
        eventTask = Task { [weak self] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await self?.handle(frame)
            }
        }
        try await reschedule()
    }

    public func stopAutomaticEvaluation() {
        descendantRechecks.removeAll()
        descendantBackoff.removeAll()
        eventTask?.cancel()
        eventTask = nil
        timer?.cancel()
        timer = nil
    }

    public func timerFireCount() -> Int { timerFires }

    func automaticScheduleRevision() -> UInt64 { scheduleGeneration }

    func automaticEvaluationCompletionCount() -> Int { completedTimerEvaluations }

    func handle(_ frame: SessionEventFrame) async {
        // bufferingNewest(1) can replace the authority event with an issue or
        // request frame. The full state retains its lifecycle effects.
        let latest = frame.sessions.mapValues(LifecycleState.init)
        let changed = Set(latest.keys).union(observedStates.keys).filter {
            latest[$0] != observedStates[$0]
        }
        let catalogChanged = observedCatalogRevision != frame.catalogRevision
        guard !changed.isEmpty || catalogChanged else { return }
        observedStates = latest
        observedCatalogRevision = frame.catalogRevision
        for id in changed {
            blockedDue[id] = nil
            descendantRechecks[id] = nil
            descendantBackoff[id] = nil
        }
        try? await reschedule()
    }

    private func reschedule() async throws {
        guard eventTask != nil else { return }
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        timer?.cancel()
        timer = nil
        // Only running conversations can become idle, and the oldest idle row
        // decides the stale deadline: no full catalog scan per event.
        var next: Date?
        let running = try await catalog.sessions(ids: Array(await supervisor.runningSessionIDs()))
        let activeIDs = Set(running.filter { $0.lifecycle == .active }.map { $0.session.id })
        descendantRechecks = descendantRechecks.filter { activeIDs.contains($0.key) }
        descendantBackoff = descendantBackoff.filter { activeIDs.contains($0.key) }
        for record in running where record.lifecycle == .active {
            guard let due = await nextIdleEvaluation(record) else { continue }
            if next == nil || due < next! { next = due }
        }
        // Stale depends on time since last use, not on how the run ended; a
        // live run never counts, or an old idle-blocked one would spin the timer.
        if let oldest = try await catalog.oldestStaleCandidate(excluding: Set(await supervisor.runningSessionIDs())) {
            let due = oldest.addingTimeInterval(policy.staleAfter)
            if next == nil || due < next! { next = due }
        }
        guard generation == scheduleGeneration, let next else { return }
        let delay = max(0, next.timeIntervalSinceNow)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    /// Last use, counting terminal input accepted after the last recorded use.
    private func effectiveLastUse(_ record: CatalogSession) async -> Date {
        guard let runID = await supervisor.session(id: record.session.id)?.currentRun?.id,
              let input = inputGate.lastInputDate(runID: runID) else { return record.lastUsedAt }
        return max(record.lastUsedAt, input)
    }

    private func nextIdleEvaluation(_ record: CatalogSession) async -> Date? {
        let due = (await effectiveLastUse(record)).addingTimeInterval(policy.idleAfter)
        if let recheck = descendantRechecks[record.session.id] { return max(due, recheck) }
        return blockedDue[record.session.id] == record.lastUsedAt ? nil : due
    }

    private func timerFired() async {
        timerFires += 1
        defer { completedTimerEvaluations += 1 }
        let now = Date()
        do {
            let running = Array(await supervisor.runningSessionIDs())
            for record in try await catalog.sessions(ids: running) where
                record.lifecycle == .active {
                guard let due = await nextIdleEvaluation(record), due <= now else { continue }
                let outcome = try await evaluateIdle(
                    sessionID: record.session.id, at: now
                )
                descendantRechecks[record.session.id] = nil
                // Other blockers are event-driven; only children that may exit
                // silently need a process re-check, and only when nothing else
                // holds the session.
                if eventTask != nil, case let .blocked(reasons) = outcome,
                   !reasons.isEmpty, reasons.allSatisfy({
                       if case .nonBaselineDescendants = $0 { true } else { false }
                   }) {
                    let interval = recheckSchedule.next(after: descendantBackoff[record.session.id])
                    descendantBackoff[record.session.id] = interval
                    descendantRechecks[record.session.id] = Date().addingTimeInterval(interval)
                } else {
                    descendantBackoff[record.session.id] = nil
                }
                // Recent input only postpones the decision; the next deadline
                // is computed from that input, so nothing waits for an event.
                if case let .blocked(reasons) = outcome, !reasons.contains(.recentTerminalInput) {
                    blockedDue[record.session.id] = record.lastUsedAt
                }
                if case .stopFailed = outcome {
                    blockedDue[record.session.id] = record.lastUsedAt
                }
            }
            _ = try await classifyStale(at: now)
            try await reschedule()
        } catch {
            // A later state change reschedules after a transient catalog error.
        }
    }

    /// Only the launch leader is known to be provider infrastructure. A quiet
    /// turn or an asynchronous hook timestamp does not prove that any child is
    /// a startup helper: unverified descendants must continue to block idle.
    /// This stays true when the same run moves to a new conversation.
    public func captureProcessBaseline(sessionID: UUID) async throws {
        guard let run = await supervisor.session(id: sessionID)?.currentRun else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        baselines[sessionID] = Baseline(runID: run.id, identities: [run.leader])
        blockedDue[sessionID] = nil
        descendantBackoff[sessionID] = nil
        try await reschedule()
    }

    @discardableResult
    public func registerPendingPrompt(sessionID: UUID, id: UUID = UUID()) -> UUID {
        pendingPrompts[sessionID, default: []].insert(id)
        generations[sessionID, default: 0] &+= 1
        return id
    }

    public func completePromptDelivery(sessionID: UUID, id: UUID) {
        pendingPrompts[sessionID]?.remove(id)
        if pendingPrompts[sessionID]?.isEmpty == true { pendingPrompts[sessionID] = nil }
        generations[sessionID, default: 0] &+= 1
        blockedDue[sessionID] = nil
        descendantBackoff[sessionID] = nil
        Task { try? await self.reschedule() }
    }

    public func pendingPromptIDs(sessionID: UUID) -> Set<UUID> {
        pendingPrompts[sessionID] ?? []
    }

    public func markViewed(sessionID: UUID, at date: Date = Date()) async throws {
        try await catalog.markUsed(sessionID: sessionID, at: date, reactivate: false)
        try await reschedule()
    }

    public func reactivate(sessionID: UUID, at date: Date = Date()) async throws {
        try await catalog.markUsed(sessionID: sessionID, at: date, reactivate: true)
        blockedDue[sessionID] = nil
        descendantBackoff[sessionID] = nil
        await supervisor.events.publish(sessionID: sessionID, change: .lifecycle(.active))
        try await reschedule()
    }

    @discardableResult
    public func classifyStale(at date: Date = Date()) async throws -> [UUID] {
        let changed = try await catalog.classifyStale(
            before: date.addingTimeInterval(-policy.staleAfter),
            excluding: Set(await supervisor.runningSessionIDs()),
            staleAfter: policy.staleAfter
        )
        if !changed.isEmpty {
            await supervisor.events.publishCatalogLifecycle(.stale, ids: changed)
        }
        return changed
    }

    public func evaluateIdle(
        sessionID: UUID, at date: Date = Date()
    ) async throws -> SessionIdleEvaluation {
        guard let catalogSession = try await catalog.session(id: sessionID) else {
            throw SessionManagementError.sessionNotFound(sessionID)
        }
        if catalogSession.lifecycle == .idle || catalogSession.lifecycle == .stale {
            return .alreadyIdle
        }
        guard let session = await supervisor.session(id: sessionID),
              let run = session.currentRun else { return .notRunning }
        if try await catalog.isDeletionPending(sessionID) { return .blocked([.deletionPending]) }

        var blockers: Set<SessionIdleBlocker> = []
        if await supervisor.identityState(sessionID: sessionID) == .ambiguous {
            blockers.insert(.ambiguousIdentity)
        }
        if date.timeIntervalSince(catalogSession.lastUsedAt) < policy.idleAfter {
            blockers.insert(.notDue)
        }
        let work = await supervisor.providerWorkState(sessionID: sessionID)
        if let work {
            switch work.activity {
            case .unknown: blockers.insert(.unknownAgentState)
            case .working: blockers.insert(.activeTurn)
            case .waitingForApproval: blockers.insert(.waitingForApproval)
            case .waitingForInput: blockers.insert(.waitingForInput)
            case .turnComplete, .failed, .sessionEnded: break
            }
            if work.pendingProviderWorkCount > 0 {
                blockers.insert(.pendingProviderWork(work.pendingProviderWorkCount))
            }
        } else {
            blockers.insert(.unknownAgentState)
        }
        let promptCount = pendingPrompts[sessionID]?.count ?? 0
        if promptCount > 0 { blockers.insert(.pendingPromptDelivery(promptCount)) }

        // The conversation's whole run scope counts, not only the run's own
        // tree: work its provider server forked is background work too.
        var observed = Set(try await supervisor.sample(sessionID: sessionID).map(\.identity))
        var infrastructure: Set<ProcessIdentity> = []
        if let work = try await companion?.work(sessionID) {
            observed.formUnion(work.live.map(\.identity))
            infrastructure = work.infrastructure
        }
        if let baseline = baselines[sessionID], baseline.runID == run.id {
            let additional = observed.subtracting(baseline.identities).subtracting(infrastructure)
            if !additional.isEmpty {
                blockers.insert(.nonBaselineDescendants(additional.count))
            }
        } else {
            blockers.insert(.baselineNotCaptured)
        }
        await supervisor.events.publish(
            sessionID: sessionID, change: .blockers(blockers)
        )
        guard blockers.isEmpty else { return .blocked(blockers) }

        // From here until the stop finishes the run's terminal refuses new
        // input whole. Bytes still in flight keep the run alive instead.
        // Input the terminal accepted recently counts as use even if the
        // provider has not read it yet (bytes in the PTY are not a prompt the
        // provider reported), so the stop is decided against that input too.
        let closing = inputGate.closeIfIdle(
            runID: run.id, reason: "the conversation is being stopped for inactivity",
            quietFor: policy.idleAfter
        )
        if closing == .pending || closing == .recentInput {
            let hold: SessionIdleBlocker = closing == .pending
                ? .pendingPromptDelivery(max(1, inputGate.pendingByteCount(runID: run.id)))
                : .recentTerminalInput
            await supervisor.events.publish(sessionID: sessionID, change: .blockers([hold]))
            return .blocked([hold])
        }
        let generation = generations[sessionID, default: 0]
        let report = try await supervisor.stopForIdle(
            sessionID: sessionID, graceSeconds: policy.stopGraceSeconds
        )
        guard report.succeeded else {
            // A deletion that began meanwhile closed the input for good (contract 8.1): only a
            // stop that fails for inactivity alone gives it back.
            if !(try await catalog.isDeletionPending(sessionID)) { inputGate.reopen(runID: run.id) }
            await supervisor.events.publish(
                sessionID: sessionID,
                change: .blockers([.stopUnverified])
            )
            return .stopFailed(report)
        }
        // `idle` means everything the conversation held is released: its
        // provider server goes too, and a teardown that cannot be verified is a
        // failed stop, never idle.
        if let errors = await companion?.teardown(run.id), !errors.isEmpty {
            await supervisor.events.publish(sessionID: sessionID, change: .blockers([.stopUnverified]))
            return .stopFailed(report.adding(errors: errors))
        }
        baselines[sessionID] = nil
        let pending = pendingPrompts[sessionID] ?? []
        if generations[sessionID, default: 0] != generation || !pending.isEmpty {
            try await catalog.updateLifecycle(sessionID: sessionID, lifecycle: .active)
            await supervisor.events.publish(
                sessionID: sessionID, change: .lifecycle(.active)
            )
            return .interruptedByNewWork(report, pendingPromptIDs: pending)
        }
        try await catalog.updateLifecycle(sessionID: sessionID, lifecycle: .idle)
        await supervisor.events.publish(
            sessionID: sessionID, change: .lifecycle(.idle)
        )
        return .transitioned(report)
    }

    public func resume(
        sessionID: UUID, executable: String, profile: ProviderLaunchProfile,
        rows: UInt16 = 24, columns: UInt16 = 80,
        outputSink: (any TerminalOutputSink)? = nil,
        at date: Date = Date()
    ) async throws -> ManagedSessionLaunch {
        let launch = try await supervisor.launch(
            sessionID: sessionID, executable: executable,
            arguments: profile.arguments, environment: profile.environment,
            rows: rows, columns: columns, outputSink: outputSink
        )
        do {
            try await catalog.markUsed(
                sessionID: sessionID, at: date, reactivate: true
            )
            await supervisor.events.publish(
                sessionID: sessionID, change: .lifecycle(.active)
            )
        } catch {
            // Do not leave an untracked resumed process alive when the durable
            // lifecycle update fails after the PTY has already launched.
            _ = try? await supervisor.stop(sessionID: sessionID)
            throw error
        }
        return launch
    }
}
