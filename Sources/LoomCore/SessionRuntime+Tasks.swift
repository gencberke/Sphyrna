import Foundation

extension SessionRuntime {
    func startTaskAuthority() async {
        guard taskCoordinator == nil, !shuttingDown else { return }
        do {
            let host = SessionTaskRuntimeHost(runtime: self)
            let database = catalog.dataRoot.appendingPathComponent("session-tasks/tasks.sqlite3")
            let coordinator = try await SessionTaskCoordinator.open(url: database, host: host)
            guard !shuttingDown else { return }
            let path = configuration.socketDirectory
                .appendingPathComponent("c-\(UUID().uuidString.prefix(8)).sock").path
            let router = SessionTaskWireRouter(coordinator: coordinator)
            let socket = try SessionTaskSocket(path: path, handler: router.handle)
            guard !shuttingDown else { _ = await socket.stopAndWait(); return }
            taskCoordinator = coordinator
            taskSocketPath = path
            taskSocket = socket
            taskReadFence = router.readFence
        } catch {
            LoomLog.error(.lifecycle, "Task channel unavailable (\(LoomLog.category(of: error)))")
        }
    }

    func beginTaskRun(sessionID: UUID, runID: UUID) {
        guard taskSocketPath != nil, !shuttingDown else { return }
        if let old = taskRunPlans[sessionID] {
            old.lease.revoke()
            taskIngress.remove(runID: old.claim.managedRunID)
        }
        let plan = SessionTaskRunPlan(sessionID: sessionID, runID: runID)
        taskRunPlans[sessionID] = plan
        taskIngress.register(runID: runID, lease: plan.lease)
    }

    func revokeTaskRun(sessionID: UUID, runID: UUID? = nil) {
        guard let plan = taskRunPlans[sessionID], runID == nil || plan.claim.managedRunID == runID else { return }
        plan.lease.revoke()
        taskIngress.remove(runID: plan.claim.managedRunID)
        taskExpectedInputs[plan.claim.managedRunID] = nil
        taskRunPlans[sessionID] = nil
    }

    func taskEnvironment(sessionID: UUID) -> [String: String] {
        guard let plan = taskRunPlans[sessionID], plan.lease.isEnabled, let socket = taskSocketPath else { return [:] }
        return plan.environment(socket: socket, helper: configuration.hookHelperPath)
    }

    func authenticateTaskRun(_ claim: SessionTaskClaim) async -> SessionTaskBinding? {
        guard !shuttingDown, let plan = taskRunPlans[claim.sessionID], plan.lease.isEnabled,
              plan.claim.managedRunID == claim.managedRunID, plan.claim.generation == claim.generation,
              secureEqual(plan.claim.credential, claim.credential),
              let binding = await supervisor.taskBinding(for: claim),
              !shuttingDown, let current = taskRunPlans[claim.sessionID], current.lease === plan.lease,
              current.lease.isEnabled else { return nil }
        return binding
    }

    func observeCodexTaskInput(serverID: UUID, observation: CodexTaskInputObservation) async {
        guard let server = codexServers.first(where: { $0.id == serverID }),
              let plan = taskRunPlans[server.ownerCard], plan.lease.isEnabled,
              let expected = taskExpectedInputs[plan.claim.managedRunID],
              observation.sequence > expected.lastSequence else { return }
        let binding = await supervisor.taskBinding(for: plan.claim)
        guard let currentPlan = taskRunPlans[server.ownerCard], currentPlan.lease === plan.lease,
              currentPlan.lease.isEnabled, var current = taskExpectedInputs[plan.claim.managedRunID],
              current.purpose == expected.purpose, current.digest == expected.digest,
              observation.sequence > current.lastSequence else { return }
        current.lastSequence = observation.sequence
        guard let binding, binding == current.binding,
              observation.threadID == binding.nativeSessionID, let turn = observation.turnID,
              observation.digest == current.digest else {
            taskExpectedInputs[plan.claim.managedRunID] = nil
            return
        }
        current.observed = .nativeTurn(turn)
        taskExpectedInputs[plan.claim.managedRunID] = current
        if let ticket = current.ticket { _ = inputGate.confirmAutomaticInput(runID: binding.managedRunID, ticket: ticket) }
    }

    /// App-only task metadata. Subscribe to updates before loading pages; a
    /// coalesced revision asks the caller to reread the relevant durable pages.
    public func sessionTaskProjections(parentSessionID: UUID? = nil, after: UUID? = nil,
                                       limit: Int = 50) async throws -> SessionTaskProjectionPage {
        guard let taskCoordinator else { throw SessionTaskError.storage }
        return try await taskCoordinator.projectionsForUser(parentSessionID: parentSessionID, after: after, limit: limit)
    }

    public func sessionTaskProjection(id: UUID) async throws -> SessionTaskProjection? {
        guard let taskCoordinator else { throw SessionTaskError.storage }
        return try await taskCoordinator.projectionForUser(taskID: id)
    }

    /// The selected task's recent results for the user. This does not mark
    /// them read by the parent or consume a provider wake.
    public func sessionTaskLatestEvents(id: UUID, limit: Int = 10) async throws -> [SessionTaskEvent] {
        guard let taskCoordinator else { throw SessionTaskError.storage }
        return try await taskCoordinator.latestEventsForUser(taskID: id, limit: limit)
    }

    public func sessionTaskProjectionUpdates() async -> AsyncStream<UInt64> {
        guard let taskCoordinator else { return AsyncStream { $0.finish() } }
        return await taskCoordinator.projectionUpdatesForUser()
    }
}
