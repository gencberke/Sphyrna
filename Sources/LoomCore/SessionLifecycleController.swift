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
    case baselineNotCaptured
    case nonBaselineDescendants(Int)
}

public enum SessionIdleEvaluation: Sendable {
    case notRunning
    case alreadyIdle
    case blocked(Set<SessionIdleBlocker>)
    case transitioned(SessionStopReport)
    case interruptedByNewWork(SessionStopReport, pendingPromptIDs: Set<UUID>)
    case stopFailed(SessionStopReport)
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
    public let policy: SessionIdlePolicy
    private var baselines: [UUID: Baseline] = [:]
    private var pendingPrompts: [UUID: Set<UUID>] = [:]
    private var generations: [UUID: UInt64] = [:]

    public init(
        supervisor: ProcessSupervisor, catalog: SessionCatalog,
        policy: SessionIdlePolicy = SessionIdlePolicy()
    ) {
        self.supervisor = supervisor
        self.catalog = catalog
        self.policy = policy
    }

    /// Call after provider startup helpers (including baseline MCP servers)
    /// have settled. Later descendants are treated as live user work.
    public func captureProcessBaseline(sessionID: UUID) async throws {
        guard let run = await supervisor.session(id: sessionID)?.currentRun else {
            throw SessionManagementError.sessionNotRunning(sessionID)
        }
        let records = try await supervisor.sample(sessionID: sessionID)
        baselines[sessionID] = Baseline(
            runID: run.id, identities: Set(records.map(\.identity))
        )
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
    }

    public func pendingPromptIDs(sessionID: UUID) -> Set<UUID> {
        pendingPrompts[sessionID] ?? []
    }

    public func markViewed(sessionID: UUID, at date: Date = Date()) async throws {
        try await catalog.markUsed(sessionID: sessionID, at: date, reactivate: false)
    }

    public func reactivate(sessionID: UUID, at date: Date = Date()) async throws {
        try await catalog.markUsed(sessionID: sessionID, at: date, reactivate: true)
    }

    @discardableResult
    public func classifyStale(at date: Date = Date()) async throws -> [UUID] {
        try await catalog.classifyStale(
            before: date.addingTimeInterval(-policy.staleAfter)
        )
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

        var blockers: Set<SessionIdleBlocker> = []
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

        let records = try await supervisor.sample(sessionID: sessionID)
        if let baseline = baselines[sessionID], baseline.runID == run.id {
            let additional = Set(records.map(\.identity)).subtracting(baseline.identities)
            if !additional.isEmpty {
                blockers.insert(.nonBaselineDescendants(additional.count))
            }
        } else {
            blockers.insert(.baselineNotCaptured)
        }
        guard blockers.isEmpty else { return .blocked(blockers) }

        let generation = generations[sessionID, default: 0]
        let report = try await supervisor.stopForIdle(
            sessionID: sessionID, graceSeconds: policy.stopGraceSeconds
        )
        guard report.succeeded else { return .stopFailed(report) }
        baselines[sessionID] = nil
        let pending = pendingPrompts[sessionID] ?? []
        if generations[sessionID, default: 0] != generation || !pending.isEmpty {
            try await catalog.updateLifecycle(sessionID: sessionID, lifecycle: .active)
            return .interruptedByNewWork(report, pendingPromptIDs: pending)
        }
        try await catalog.updateLifecycle(sessionID: sessionID, lifecycle: .idle)
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
        } catch {
            // Do not leave an untracked resumed process alive when the durable
            // lifecycle update fails after the PTY has already launched.
            _ = try? await supervisor.stop(sessionID: sessionID)
            throw error
        }
        return launch
    }
}
