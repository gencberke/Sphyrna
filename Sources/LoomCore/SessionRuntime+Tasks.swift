import Darwin
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
            let router = SessionTaskWireRouter(coordinator: coordinator, create: { [weak self] call in
                guard let self else { return .init(status: "unavailable") }
                return await self.submitTaskRequest(call)
            }, requested: { [weak self] id in await self?.markTaskNeedsDelivery(id) })
            let socket = try SessionTaskSocket(path: path, handler: router.handle)
            guard !shuttingDown else { _ = await socket.stopAndWait(); return }
            taskCoordinator = coordinator
            taskSocketPath = path
            taskSocket = socket
            taskReadFence = router.readFence
            inputGate.observeRegistrations { [weak self] runID in Task { await self?.taskTerminalAttached(runID) } }
        } catch {
            LoomLog.error(.lifecycle, "Task channel unavailable (\(LoomLog.category(of: error)))")
        }
    }

    /// The reservation is app-owned, bounded and cannot adopt an existing row.
    func reserveTaskChild(taskID: UUID, childID: UUID, parent: SessionTaskClaim,
                          operationID: UUID? = nil, fingerprint: String? = nil) async throws {
        guard !shuttingDown, !deletionsInFlight.contains(parent.sessionID),
              taskChildReservations.count < OpenSessionCoordinator.maximumEntries,
              taskChildReservations[taskID] == nil, !taskChildReservations.values.contains(where: { $0.childID == childID }),
              parent.sessionID != childID,
              await authenticateTaskRun(parent) != nil,
              try await catalog.session(id: childID) == nil,
              await supervisor.session(id: childID) == nil else { throw SessionTaskError.unauthorized }
        guard !shuttingDown, !deletionsInFlight.contains(parent.sessionID), taskChildReservations[taskID] == nil,
              !taskChildReservations.values.contains(where: { $0.childID == childID }),
              await authenticateTaskRun(parent) != nil else { throw SessionTaskError.unauthorized }
        guard !shuttingDown, !deletionsInFlight.contains(parent.sessionID), taskChildReservations[taskID] == nil,
              !taskChildReservations.values.contains(where: { $0.childID == childID }) else { throw SessionTaskError.unauthorized }
        taskChildReservations[taskID] = SessionTaskChildReservation(parent: parent, childID: childID,
                                                                     operationID: operationID, fingerprint: fingerprint)
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
            revokeTaskRun(sessionID: sessionID, runID: old.claim.managedRunID)
        }
        retiredTaskRuns[sessionID] = nil
        let plan = SessionTaskRunPlan(sessionID: sessionID, runID: runID)
        taskRunPlans[sessionID] = plan
        taskIngress.register(runID: runID, lease: plan.lease)
    }

    func revokeTaskRun(sessionID: UUID, runID: UUID? = nil, identityChanged: Bool = false) {
        guard let plan = taskRunPlans[sessionID], runID == nil || plan.claim.managedRunID == runID else { return }
        plan.lease.revoke()
        taskParentRevoked(plan.claim)
        if retiredTaskRuns[sessionID] == nil, retiredTaskRuns.count >= 256, let first = retiredTaskRuns.keys.first {
            retiredTaskRuns[first] = nil
        }
        retiredTaskRuns[sessionID] = SessionTaskRetiredRun(runID: plan.claim.managedRunID, generation: plan.claim.generation)
        taskIngress.remove(runID: plan.claim.managedRunID)
        taskExpectedInputs[plan.claim.managedRunID] = nil
        finishTaskProofWaiters(runID: plan.claim.managedRunID, observation: nil)
        taskRunPlans[sessionID] = nil
        if !shuttingDown {
            Task { [weak self] in
                await self?.fenceTaskRun(sessionID: sessionID, runID: plan.claim.managedRunID,
                                         generation: plan.claim.generation, identityChanged: identityChanged)
            }
        }
    }

    func taskEnvironment(sessionID: UUID) -> [String: String] {
        guard let plan = taskRunPlans[sessionID], plan.lease.isEnabled, let socket = taskSocketPath else { return [:] }
        return plan.environment(socket: socket, helper: configuration.hookHelperPath)
    }

    func authenticateTaskRun(_ claim: SessionTaskClaim) async -> SessionTaskBinding? {
        guard !shuttingDown, !deletionsInFlight.contains(claim.sessionID),
              let plan = taskRunPlans[claim.sessionID], plan.lease.isEnabled,
              plan.claim.managedRunID == claim.managedRunID, plan.claim.generation == claim.generation,
              secureEqual(plan.claim.credential, claim.credential),
              let binding = await supervisor.taskBinding(for: claim),
              !shuttingDown, !deletionsInFlight.contains(claim.sessionID),
              let current = taskRunPlans[claim.sessionID], current.lease === plan.lease,
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
        case .atPrompt, .turnComplete, .failed:
            guard work.pendingProviderWorkCount == 0 else { return .working }
            if runs[binding.managedRunID]?.provider == .codex {
                // Current native idle, not a completed or failed older turn,
                // is the authority for admitting another input.
                guard let native = await harnesses.codex.adapter.status(sessionID: binding.sessionID),
                      native.providerThreadID == binding.nativeSessionID, native.nativeThreadStatus == .idle,
                      await supervisor.taskBinding(for: plan.claim) == binding,
                      taskRunPlans[binding.sessionID]?.lease === plan.lease,
                      plan.lease.permits(revision: revision), !shuttingDown,
                      runs[binding.managedRunID]?.server?.requests.isEmpty == true else { return .unknown }
                return .ready
            }
            if case .failed = work.activity { return .unknown }
            return .ready
        case .working: return .working
        case .waitingForApproval, .waitingForInput: return .waitingForUser
        case .unknown, .sessionEnded: return .unknown
        }
    }

    func prepareTaskInput(purpose: SessionTaskExpectedInput.Purpose, binding: SessionTaskBinding,
                          digest: Data, effect: SessionTaskInputEffectMarker,
                          ticket: TerminalInputQueue.AutomaticInputTicket? = nil, requiresNativeReceipt: Bool = false,
                          clientMessageID: String? = nil, rolloutCandidate: CodexTaskInputProofCandidate? = nil) async -> Bool {
        if let old = taskExpectedInputs[binding.managedRunID], old.binding == binding, old.confirmedObservation != nil,
           case .child = old.purpose, case .child = purpose, old.purpose != purpose {
            taskExpectedInputs[binding.managedRunID] = nil
        }
        guard digest.count == 32, let plan = taskRunPlans[binding.sessionID], plan.lease.isEnabled,
              plan.claim.managedRunID == binding.managedRunID, plan.claim.generation == binding.generation,
              taskExpectedInputs[binding.managedRunID] == nil,
              await supervisor.taskBinding(for: plan.claim) == binding,
              let current = taskRunPlans[binding.sessionID], current.lease === plan.lease,
              current.lease.isEnabled, taskExpectedInputs[binding.managedRunID] == nil else { return false }
        taskExpectedInputs[binding.managedRunID] = SessionTaskExpectedInput(purpose: purpose, binding: binding,
            digest: digest, ticket: ticket, effect: effect, requiresNativeReceipt: requiresNativeReceipt,
            clientMessageID: clientMessageID, rolloutCandidate: rolloutCandidate)
        return true
    }

    /// Wait only for the exact admitted input's provider observation. No timer
    /// or transcript scan runs when no helper is waiting for that proof.
    func taskInputObservation(purpose: SessionTaskExpectedInput.Purpose,
                              binding: SessionTaskBinding) async -> SessionTaskExecutionReference? {
        guard let expected = taskExpectedInputs[binding.managedRunID], expected.purpose == purpose,
              expected.binding == binding, let plan = taskRunPlans[binding.sessionID], plan.lease.isEnabled,
              plan.claim.managedRunID == binding.managedRunID, plan.claim.generation == binding.generation else { return nil }
        var result = expected.confirmedObservation
        if result == nil {
            guard taskProofWaiters.count < 32 else { return nil }
            let id = UUID()
            result = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume(returning: nil); return }
                    let timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        await self?.finishTaskProofWaiter(id, result: nil)
                    }
                    taskProofWaiters[id] = SessionTaskProofWaiter(purpose: purpose, binding: binding,
                                                                   continuation: continuation, timeout: timeout)
                    updateTaskQuiescenceObservers()
                    scheduleTaskFileProof(runID: binding.managedRunID)
                }
            } onCancel: { Task { await self.finishTaskProofWaiter(id, result: nil) } }
        }
        guard let result, await authenticateTaskRun(plan.claim) == binding,
              let current = taskExpectedInputs[binding.managedRunID], current.purpose == purpose,
              current.binding == binding, current.confirmedObservation == result else { return nil }
        return result
    }

    func finishTaskProofWaiter(_ id: UUID, result: SessionTaskExecutionReference?) {
        guard let waiter = taskProofWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: result)
        updateTaskQuiescenceObservers()
    }

    func finishTaskProofWaiters(runID: UUID, observation: SessionTaskExpectedInput?) {
        let ids = taskProofWaiters.compactMap { id, waiter in
            waiter.binding.managedRunID == runID ? id : nil
        }
        for id in ids {
            guard let waiter = taskProofWaiters[id] else { continue }
            let proof = observation?.purpose == waiter.purpose && observation?.binding == waiter.binding
                ? observation?.confirmedObservation : nil
            finishTaskProofWaiter(id, result: proof)
        }
    }

    private func rejectTaskInput(runID: UUID, plan: SessionTaskRunPlan) {
        plan.lease.noteUnclassifiedInput()
        inputGate.noteUnclassifiedInput(runID: runID)
        taskExpectedInputs[runID] = nil
        finishTaskProofWaiters(runID: runID, observation: nil)
    }

    func observeClaudeTaskHook(_ envelope: ClaudeHookEnvelope, event: ClaudeHookEvent) async {
        guard case .userPromptSubmit = event.kind, !event.promptIsSynthetic, event.agentID == nil,
              let plan = taskRunPlans[envelope.sessionID], plan.claim.managedRunID == envelope.managedRunID,
              plan.lease.isEnabled else { return }
        guard envelope.taskGeneration == plan.claim.generation,
              let credential = envelope.taskCredential, secureEqual(credential, plan.claim.credential),
              let context = await supervisor.runContext(runID: envelope.managedRunID),
              let binding = await supervisor.taskBinding(for: plan.claim),
              let cwd = event.workingDirectory,
              URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path ==
                  URL(fileURLWithPath: context.session.workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path,
              event.providerSessionID.caseInsensitiveCompare(binding.nativeSessionID) == .orderedSame,
              let currentPlan = taskRunPlans[envelope.sessionID], currentPlan.lease === plan.lease,
              currentPlan.lease.isEnabled, var expected = taskExpectedInputs[envelope.managedRunID],
              expected.binding == binding, expected.effect.hasEffect,
              let digest = event.taskPromptDigest, digest == expected.digest else {
            rejectTaskInput(runID: envelope.managedRunID, plan: plan)
            return
        }
        if let promptID = event.promptID, !promptID.isEmpty, promptID.utf8.count <= 256, !promptID.utf8.contains(0) {
            expected.observed = .providerPrompt(promptID)
        } else { expected.observed = .appInputObservation(UUID()) }
        taskExpectedInputs[envelope.managedRunID] = expected
        if let ticket = expected.ticket { _ = inputGate.confirmAutomaticInput(runID: envelope.managedRunID, ticket: ticket) }
        finishTaskProofWaiters(runID: envelope.managedRunID, observation: expected)
    }

    func observeCodexTaskInput(serverID: UUID, observation: CodexTaskInputObservation) async {
        guard let server = codexServers.first(where: { $0.id == serverID }),
              let plan = taskRunPlans[server.ownerCard], plan.lease.isEnabled else { return }
        guard let expected = taskExpectedInputs[plan.claim.managedRunID] else {
            rejectTaskInput(runID: plan.claim.managedRunID, plan: plan)
            return
        }
        guard observation.sequence > expected.lastSequence else { return }
        let binding = await supervisor.taskBinding(for: plan.claim)
        guard let currentPlan = taskRunPlans[server.ownerCard], currentPlan.lease === plan.lease,
              currentPlan.lease.isEnabled, var current = taskExpectedInputs[plan.claim.managedRunID],
              current.purpose == expected.purpose, current.digest == expected.digest,
              observation.sequence > current.lastSequence else { return }
        current.lastSequence = observation.sequence
        guard let binding, binding == current.binding,
              observation.threadID == binding.nativeSessionID, let turn = observation.turnID,
              current.effect.hasEffect, current.expectedNativeTurn == nil || current.expectedNativeTurn == turn,
              observation.digest == current.digest,
              current.clientMessageID == nil || observation.clientID == current.clientMessageID else {
            rejectTaskInput(runID: plan.claim.managedRunID, plan: plan)
            return
        }
        current.observed = .nativeTurn(turn)
        taskExpectedInputs[plan.claim.managedRunID] = current
        if current.confirmedObservation != nil {
            if let ticket = current.ticket { _ = inputGate.confirmAutomaticInput(runID: binding.managedRunID, ticket: ticket) }
            finishTaskProofWaiters(runID: binding.managedRunID, observation: current)
        }
    }

    func confirmCodexTaskTurn(_ turn: String, purpose: SessionTaskExpectedInput.Purpose,
                              binding: SessionTaskBinding) -> Bool {
        guard var current = taskExpectedInputs[binding.managedRunID], current.purpose == purpose,
              current.binding == binding, current.requiresNativeReceipt else { return false }
        if let observed = current.observed, observed != .nativeTurn(turn) { return false }
        current.expectedNativeTurn = turn
        taskExpectedInputs[binding.managedRunID] = current
        if current.confirmedObservation != nil {
            if let ticket = current.ticket { _ = inputGate.confirmAutomaticInput(runID: binding.managedRunID, ticket: ticket) }
            finishTaskProofWaiters(runID: binding.managedRunID, observation: current)
        } else { scheduleTaskFileProof(runID: binding.managedRunID) }
        return true
    }

    /// Only a helper already waiting on this exact input can request one
    /// bounded read. New provider ingress invalidates the read revision.
    func scheduleTaskFileProof(runID: UUID) {
        guard var expected = taskExpectedInputs[runID], expected.confirmedObservation == nil,
              expected.rolloutCandidate != nil, expected.effect.hasEffect, expected.expectedNativeTurn != nil,
              !expected.proofReadInFlight, expected.proofReadAttempts < 3,
              taskProofWaiters.values.contains(where: { $0.binding == expected.binding && $0.purpose == expected.purpose }),
              let plan = taskRunPlans[expected.binding.sessionID], plan.claim.managedRunID == runID,
              plan.claim.generation == expected.binding.generation,
              let revision = plan.lease.admit({ $0 }), expected.lastProofReadRevision != revision,
              let candidate = expected.rolloutCandidate, let turn = expected.expectedNativeTurn else { return }
        expected.proofReadInFlight = true
        expected.proofReadAttempts += 1
        expected.lastProofReadRevision = revision
        taskExpectedInputs[runID] = expected
        let purpose = expected.purpose, binding = expected.binding, digest = expected.digest
        Task { [weak self] in
            let proof = await Task.detached {
                CodexTaskInputProofReader.proof(candidate, nativeTurnID: turn, digest: digest)
            }.value
            await self?.finishTaskFileProof(proof, binding: binding, purpose: purpose, turn: turn,
                                            digest: digest, plan: plan, revision: revision)
        }
    }

    private func finishTaskFileProof(_ proof: CodexTaskInputProof?, binding: SessionTaskBinding,
                                     purpose: SessionTaskExpectedInput.Purpose, turn: String, digest: Data,
                                     plan: SessionTaskRunPlan, revision: UInt64) async {
        let runID = binding.managedRunID
        guard let current = taskExpectedInputs[runID], current.binding == binding, current.purpose == purpose,
              current.digest == digest, current.expectedNativeTurn == turn, current.proofReadInFlight,
              taskRunPlans[binding.sessionID]?.lease === plan.lease else { return }
        defer {
            if var pending = taskExpectedInputs[runID], pending.binding == binding, pending.purpose == purpose {
                pending.proofReadInFlight = false
                taskExpectedInputs[runID] = pending
                scheduleTaskFileProof(runID: runID)
            }
        }
        guard let proof, plan.lease.permits(revision: revision),
              await authenticateTaskRun(plan.claim) == binding, plan.lease.permits(revision: revision),
              let server = runs[runID]?.server, let coordinator = server.coordinator else { return }
        // The coordinator owns both the metadata-only join and its Stop cleanup
        // barrier. It never sends another user input or requests history.
        guard await coordinator.joinTaskAfterInputProof(binding),
              let nextRevision = plan.lease.admit({ $0 }),
              let now = taskExpectedInputs[runID], now.binding == binding, now.purpose == purpose,
              now.digest == digest, now.expectedNativeTurn == turn, now.effect.hasEffect else { return }
        let unchanged = await Task.detached { CodexTaskInputProofReader.remainsCurrent(proof) }.value
        guard unchanged, plan.lease.permits(revision: nextRevision),
              await authenticateTaskRun(plan.claim) == binding, plan.lease.permits(revision: nextRevision),
              var latest = taskExpectedInputs[runID], latest.binding == binding, latest.purpose == purpose,
              latest.digest == digest, latest.expectedNativeTurn == turn, latest.effect.hasEffect,
              taskProofWaiters.values.contains(where: { $0.binding == binding && $0.purpose == purpose }),
              let ticket = latest.ticket, inputGate.confirmAutomaticInput(runID: runID, ticket: ticket) else { return }
        latest.observed = .nativeTurn(turn)
        taskExpectedInputs[runID] = latest
        finishTaskProofWaiters(runID: runID, observation: latest)
    }

    /// A deletion fence remains held until the owned run is gone and the task
    /// database has forgotten its relationships.
    func mayForgetTaskSession(_ sessionID: UUID) async -> Bool {
        guard !shuttingDown, deletionsInFlight.contains(sessionID),
              !startingSessions.contains(sessionID), taskRunPlans[sessionID] == nil else { return false }
        let current = await supervisor.session(id: sessionID)
        return !shuttingDown && deletionsInFlight.contains(sessionID) &&
            !startingSessions.contains(sessionID) && taskRunPlans[sessionID] == nil && current?.currentRun == nil
    }

    func forgetTasksAfterVerifiedStop(sessionID: UUID) async throws {
        guard await mayForgetTaskSession(sessionID) else { throw SessionTaskError.unverified }
        let reservations = taskChildReservations.filter {
            $0.value.parent.sessionID == sessionID || $0.value.childID == sessionID
        }
        // An offer still in flight can add its card after a snapshot. Keep the
        // deletion pending until it returns and can no longer do so.
        guard reservations.values.allSatisfy(\.offered) else { throw SessionTaskError.unverified }
        for request in await openRequests.snapshot() where request.task != nil &&
            (request.requesterID == sessionID || request.task?.childID == sessionID) {
            do { try await openRequests.dismiss(request.id) }
            catch { throw SessionTaskError.unverified }
        }
        var coordinator = taskCoordinator
        if coordinator == nil {
            // Deletion is also available before runtime.start(). If a task
            // store already exists, open it even when the channel is down;
            // never silently skip an unsafe or unreadable store.
            let directory = catalog.dataRoot.appendingPathComponent("session-tasks", isDirectory: true)
            var info = stat()
            if lstat(directory.path, &info) == 0 {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
                      info.st_mode & 0o077 == 0 else { throw SessionTaskError.storage }
                coordinator = try await SessionTaskCoordinator.open(url: directory.appendingPathComponent("tasks.sqlite3"),
                                                                     host: SessionTaskRuntimeHost(runtime: self))
            } else if errno != ENOENT { throw SessionTaskError.storage }
        }
        if let coordinator { try await coordinator.forgetAfterVerifiedStop(sessionID: sessionID) }
        else if !(await mayForgetTaskSession(sessionID)) { throw SessionTaskError.unverified }
        for id in reservations.keys {
            taskChildReservations[id] = nil
            taskLaunchContexts[id] = nil
            tasksNeedingDelivery.remove(id)
            taskDeliveriesRequested.remove(id)
        }
        updateTaskQuiescenceObservers()
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
