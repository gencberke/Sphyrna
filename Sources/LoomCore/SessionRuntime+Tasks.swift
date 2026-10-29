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

    /// The reservation is app-owned, bounded and cannot adopt an existing row.
    func reserveTaskChild(taskID: UUID, childID: UUID, parent: SessionTaskClaim) async throws {
        guard !shuttingDown, taskChildReservations.count < OpenSessionCoordinator.maximumEntries,
              taskChildReservations[taskID] == nil, !taskChildReservations.values.contains(where: { $0.childID == childID }),
              parent.sessionID != childID,
              await authenticateTaskRun(parent) != nil,
              try await catalog.session(id: childID) == nil,
              await supervisor.session(id: childID) == nil else { throw SessionTaskError.unauthorized }
        guard !shuttingDown, taskChildReservations[taskID] == nil,
              !taskChildReservations.values.contains(where: { $0.childID == childID }),
              await authenticateTaskRun(parent) != nil else { throw SessionTaskError.unauthorized }
        guard !shuttingDown, taskChildReservations[taskID] == nil,
              !taskChildReservations.values.contains(where: { $0.childID == childID }) else { throw SessionTaskError.unauthorized }
        taskChildReservations[taskID] = SessionTaskChildReservation(parent: parent, childID: childID)
    }

    func ownsReservedTaskChild(taskID: UUID, parent: SessionTaskBinding, childID: UUID) async -> Bool {
        guard !shuttingDown, let reservation = taskChildReservations[taskID], reservation.childID == childID,
              await authenticateTaskRun(reservation.parent) == parent else { return false }
        do { guard try await catalog.session(id: childID) == nil else { return false } }
        catch { return false }
        guard await supervisor.session(id: childID) == nil,
              let current = taskChildReservations[taskID], current.childID == childID,
              await authenticateTaskRun(current.parent) == parent else { return false }
        return !shuttingDown && taskChildReservations[taskID]?.childID == childID
    }

    func beginTaskRun(sessionID: UUID, runID: UUID) {
        guard taskSocketPath != nil, !shuttingDown else { return }
        if let old = taskRunPlans[sessionID] {
            old.lease.revoke()
            taskIngress.remove(runID: old.claim.managedRunID)
        }
        retiredTaskRuns[sessionID] = nil
        let plan = SessionTaskRunPlan(sessionID: sessionID, runID: runID)
        taskRunPlans[sessionID] = plan
        taskIngress.register(runID: runID, lease: plan.lease)
    }

    func revokeTaskRun(sessionID: UUID, runID: UUID? = nil) {
        guard let plan = taskRunPlans[sessionID], runID == nil || plan.claim.managedRunID == runID else { return }
        plan.lease.revoke()
        if retiredTaskRuns[sessionID] == nil, retiredTaskRuns.count >= 256, let first = retiredTaskRuns.keys.first {
            retiredTaskRuns[first] = nil
        }
        retiredTaskRuns[sessionID] = SessionTaskRetiredRun(runID: plan.claim.managedRunID, generation: plan.claim.generation)
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

    /// Reads the existing process owner's state; never starts or probes a provider.
    func taskNativeStatus(_ binding: SessionTaskBinding) async -> SessionTaskNativeStatus {
        guard let plan = taskRunPlans[binding.sessionID],
              plan.claim.managedRunID == binding.managedRunID, plan.claim.generation == binding.generation else {
            guard taskRunPlans[binding.sessionID] == nil,
                  let retired = retiredTaskRuns[binding.sessionID], retired.runID == binding.managedRunID,
                  retired.generation == binding.generation else { return .unknown }
            let report = await supervisor.lastStopReport(sessionID: binding.sessionID)
            let session = await supervisor.session(id: binding.sessionID)
            guard report?.runID == binding.managedRunID, report?.succeeded == true,
                  session?.currentRun == nil, taskRunPlans[binding.sessionID] == nil,
                  retiredTaskRuns[binding.sessionID]?.runID == binding.managedRunID,
                  retiredTaskRuns[binding.sessionID]?.generation == binding.generation else { return .unknown }
            return .stopped
        }
        guard let revision = plan.lease.admit({ $0 }),
              await supervisor.taskBinding(for: plan.claim) == binding else { return .unknown }
        let work = await supervisor.providerWorkState(sessionID: binding.sessionID)
        guard let current = taskRunPlans[binding.sessionID], current.lease === plan.lease,
              current.lease.permits(revision: revision), !shuttingDown,
              let work else { return .unknown }
        if let server = runs[binding.managedRunID]?.server, !server.requests.isEmpty { return .waitingForUser }
        switch work.activity {
        case .atPrompt, .turnComplete: return work.pendingProviderWorkCount == 0 ? .ready : .working
        case .working: return .working
        case .waitingForApproval, .waitingForInput: return .waitingForUser
        case .unknown, .failed, .sessionEnded: return .unknown
        }
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
