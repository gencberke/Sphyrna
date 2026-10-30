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
            let mailbox: SessionMailbox?
            do {
                mailbox = try await SessionMailbox.open(url: catalog.dataRoot.appendingPathComponent("session-mailbox/mailbox.sqlite3"), exclusive: true)
            } catch {
                // The task channel still serves; agent sends answer "unavailable" for this app session.
                mailbox = nil
                LoomLog.error(.lifecycle, "Peer mailbox unavailable (\(LoomLog.category(of: error)))")
            }
            let path = configuration.socketDirectory
                .appendingPathComponent("c-\(UUID().uuidString.prefix(8)).sock").path
            let router = SessionTaskWireRouter(coordinator: coordinator, create: { [weak self] call in
                guard let self else { return .init(status: "unavailable") }
                return await self.submitTaskRequest(call)
            }, requested: { [weak self] id in await self?.markTaskNeedsDelivery(id) },
               reported: { [weak self] id in await self?.markTaskNeedsWake(id) },
               peerSend: { [weak self] call in await self?.submitPeerSend(call) ?? .init(status: "unavailable") },
               peerInbox: { [weak self] call in await self?.peerInbox(call) ?? Data(#"{"version":5,"status":"unavailable"}"#.utf8) },
               peerAck: { [weak self] call in await self?.peerInboxAck(call) ?? .init(status: "unavailable") })
            let socket = try SessionTaskSocket(path: path, handler: router.handle)
            guard !shuttingDown else { _ = await socket.stopAndWait(); return }
            taskCoordinator = coordinator
            taskSocketPath = path
            taskSocket = socket
            taskReadFence = router.readFence
            peerMailbox = mailbox
            peerReadFence = SessionTaskReadFence { [weak self] id in Task { await self?.markPeerNeedsDelivery(id) } }
            await supervisor.setManagedScopeReceiptWriter { binding in
                try await coordinator.recordManagedScopeStopped(binding)
            }
            guard !shuttingDown, taskCoordinator === coordinator else { return }
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
        peerTargetFences.rotate(sessionID)
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
        peerTargetFences.rotate(sessionID)
        peersNeedingDelivery.remove(sessionID)
        failPeerRequests(from: plan.claim)
        taskParentRevoked(plan.claim)
        if retiredTaskRuns[sessionID] == nil, retiredTaskRuns.count >= 256, let first = retiredTaskRuns.keys.first {
            retiredTaskRuns[first] = nil
        }
        retiredTaskRuns[sessionID] = SessionTaskRetiredRun(runID: plan.claim.managedRunID, generation: plan.claim.generation)
        taskIngress.remove(runID: plan.claim.managedRunID)
        taskExpectedInputs[plan.claim.managedRunID] = nil
        finishTaskProofWaiters(runID: plan.claim.managedRunID, observation: nil)
        finishTaskInterruptWaiters(runID: plan.claim.managedRunID)
        finishManagedCodexInterruptSignals(runID: plan.claim.managedRunID)
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
        if let managed = managedTaskControllers[binding.managedRunID], managed.run.sessionID == binding.sessionID,
           let view = managedTaskPresentations[managed.run.taskID], view.binding == binding {
            guard taskRunPlans[binding.sessionID]?.lease === plan.lease,
                  plan.lease.permits(revision: revision), !shuttingDown else { return .unknown }
            if !view.permissions.isEmpty { return .waitingForUser }
            return view.status
        }
        let work = await supervisor.providerWorkState(sessionID: binding.sessionID)
        guard let current = taskRunPlans[binding.sessionID], current.lease === plan.lease,
              current.lease.permits(revision: revision), !shuttingDown,
              let work else { return .unknown }
        if let server = runs[binding.managedRunID]?.server, !server.requests.isEmpty { return .waitingForUser }
        switch work.activity {
        case .atPrompt, .turnComplete, .failed, .waitingForInput:
            guard work.pendingProviderWorkCount == 0 else { return .working }
            guard let provider = runs[binding.managedRunID]?.provider,
                  let transport = harnesses[provider]?.taskTransport else { return .unknown }
            if transport == .ownedAppServer {
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
            guard transport == .terminalHook,
                  let context = await supervisor.runContext(runID: binding.managedRunID),
                  let idle = await harnesses.claude.adapter.taskIdleProof(runID: binding.managedRunID,
                      nativeSessionID: binding.nativeSessionID, workingDirectory: context.session.workingDirectory),
                  idle.promptGeneration != nil || !plan.lease.hasUnclassifiedInput,
                  await supervisor.taskBinding(for: plan.claim) == binding,
                  taskRunPlans[binding.sessionID]?.lease === plan.lease,
                  plan.lease.permits(revision: revision), !shuttingDown else {
                if case .waitingForInput = work.activity { return .waitingForUser }
                return .unknown
            }
            return .ready
        case .working: return .working
        case .waitingForApproval: return .waitingForUser
        case .unknown, .sessionEnded: return .unknown
        }
    }

    func prepareTaskInput(purpose: SessionTaskExpectedInput.Purpose, binding: SessionTaskBinding,
                          digest: Data, effect: SessionTaskInputEffectMarker,
                          ticket: TerminalInputQueue.AutomaticInputTicket? = nil, requiresNativeReceipt: Bool = false,
                          clientMessageID: String? = nil, rolloutCandidate: CodexTaskInputProofCandidate? = nil) async -> Bool {
        let old = taskExpectedInputs[binding.managedRunID]
        var retained: SessionTaskExpectedInput.RetainedChildProof?
        if let old {
            guard old.binding == binding, old.purpose != purpose, old.confirmedObservation != nil else { return false }
            if let generation = old.acceptedGeneration,
               !inputGate.hasInputGeneration(runID: binding.managedRunID, generation: generation) { return false }
            switch purpose {
            case .wake, .peer: retained = old.retainedChildProof() ?? old.retainedChild
            case .child: retained = old.retainedChildProof()
            }
        }
        guard digest.count == 32, let plan = taskRunPlans[binding.sessionID], plan.lease.isEnabled,
              plan.claim.managedRunID == binding.managedRunID, plan.claim.generation == binding.generation,
              await supervisor.taskBinding(for: plan.claim) == binding,
              let current = taskRunPlans[binding.sessionID], current.lease === plan.lease,
              current.lease.isEnabled else { return false }
        if let old {
            guard let latest = taskExpectedInputs[binding.managedRunID], latest.effect === old.effect,
                  latest.purpose == old.purpose, latest.binding == old.binding,
                  latest.confirmedObservation == old.confirmedObservation,
                  latest.acceptedGeneration == old.acceptedGeneration else { return false }
            if let generation = old.acceptedGeneration,
               !inputGate.hasInputGeneration(runID: binding.managedRunID, generation: generation) { return false }
        } else if taskExpectedInputs[binding.managedRunID] != nil { return false }
        var expected = SessionTaskExpectedInput(purpose: purpose, binding: binding,
            digest: digest, ticket: ticket, effect: effect, requiresNativeReceipt: requiresNativeReceipt,
            clientMessageID: clientMessageID, rolloutCandidate: rolloutCandidate)
        expected.retainedChild = retained
        taskExpectedInputs[binding.managedRunID] = expected
        return true
    }

    /// Wait only for the exact admitted input's provider observation. No timer
    /// or transcript scan runs when no helper is waiting for that proof.
    func taskInputObservation(purpose: SessionTaskExpectedInput.Purpose,
                              binding: SessionTaskBinding) async -> SessionTaskExecutionReference? {
        guard let expected = taskExpectedInputs[binding.managedRunID], expected.binding == binding,
              let plan = taskRunPlans[binding.sessionID], plan.lease.isEnabled,
              plan.claim.managedRunID == binding.managedRunID, plan.claim.generation == binding.generation else { return nil }
        // A newer possible native input may have superseded this execution.
        // A deferred write restores the retained proof separately.
        guard expected.purpose == purpose else { return nil }
        var result = expected.confirmedObservation
        if result == nil || plan.lease.permits({ true }) == nil {
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
                    // The ingress may have settled just before the observer was
                    // installed. Its exact current proof is safe to deliver now.
                    if plan.lease.permits({ true }) != nil,
                       let latest = taskExpectedInputs[binding.managedRunID],
                       latest.purpose == purpose, latest.binding == binding, latest.confirmedObservation != nil {
                        finishTaskProofWaiters(runID: binding.managedRunID, observation: latest)
                    }
                }
            } onCancel: { Task { await self.finishTaskProofWaiter(id, result: nil) } }
        }
        guard let result, let revision = plan.lease.admit({ $0 }),
              await authenticateTaskRun(plan.claim) == binding, plan.lease.permits(revision: revision),
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

    /// A plain terminal line may establish a new clean boundary only after
    /// the exact provider input is observed after the complete PTY write.
    private func observeManualInput(runID: UUID, binding: SessionTaskBinding, digest: Data?,
                                    observedAt: UInt64?, plan: SessionTaskRunPlan) {
        plan.lease.noteUnclassifiedInput()
        taskExpectedInputs[runID] = nil
        finishTaskProofWaiters(runID: runID, observation: nil)
        guard let digest, let observedAt else { inputGate.noteUnclassifiedInput(runID: runID); return }
        switch inputGate.confirmManualInput(runID: runID, digest: digest, observedAt: observedAt) {
        case .confirmed: break
        case .unverified: inputGate.noteUnclassifiedInput(runID: runID)
        case .pendingDrain:
            _ = inputGate.notifyWhenIdle(runID: runID) { [weak self] in
                Task { await self?.finishManualInput(runID: runID, binding: binding, digest: digest,
                                                     observedAt: observedAt, plan: plan) }
            }
        }
    }

    private func finishManualInput(runID: UUID, binding: SessionTaskBinding, digest: Data,
                                   observedAt: UInt64, plan: SessionTaskRunPlan) async {
        guard !shuttingDown, taskRunPlans[binding.sessionID]?.lease === plan.lease,
              await authenticateTaskRun(plan.claim) == binding,
              taskRunPlans[binding.sessionID]?.lease === plan.lease,
              case .confirmed = inputGate.confirmManualInput(runID: runID, digest: digest, observedAt: observedAt) else { return }
        await taskRunBecameQuiescent(sessionID: binding.sessionID, runID: runID)
    }

    func observeClaudeTaskHook(_ envelope: ClaudeHookEnvelope, event: ClaudeHookEvent) async {
        guard case .userPromptSubmit = event.kind, !event.promptIsSynthetic, event.agentID == nil,
              let plan = taskRunPlans[envelope.sessionID], plan.claim.managedRunID == envelope.managedRunID,
              plan.lease.isEnabled else { return }
        // A managed pipe's first hook can precede system/init and contain no
        // prompt text. Its ordered controller observes the exact submitted
        // input instead; the hook still participates in the ingress fence.
        if managedTaskControllers[envelope.managedRunID] != nil { return }
        guard envelope.taskGeneration == plan.claim.generation,
              let credential = envelope.taskCredential, secureEqual(credential, plan.claim.credential),
              let context = await supervisor.runContext(runID: envelope.managedRunID),
              let binding = await supervisor.taskBinding(for: plan.claim),
              let cwd = event.workingDirectory,
              URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path ==
                  URL(fileURLWithPath: context.session.workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path,
              event.providerSessionID.caseInsensitiveCompare(binding.nativeSessionID) == .orderedSame,
              let currentPlan = taskRunPlans[envelope.sessionID], currentPlan.lease === plan.lease,
              currentPlan.lease.isEnabled else {
            rejectTaskInput(runID: envelope.managedRunID, plan: plan)
            return
        }
        guard var expected = taskExpectedInputs[envelope.managedRunID], expected.binding == binding,
              expected.effect.hasEffect, let digest = event.taskPromptDigest, digest == expected.digest else {
            observeManualInput(runID: envelope.managedRunID, binding: binding, digest: event.taskPromptDigest,
                               observedAt: envelope.taskIngressUptime, plan: plan)
            return
        }
        guard let prompt = await harnesses.claude.adapter.taskCurrentPrompt(runID: envelope.managedRunID),
              prompt.promptID == event.promptID,
              let current = taskExpectedInputs[envelope.managedRunID], current.effect === expected.effect,
              current.binding == binding, current.digest == digest,
              taskRunPlans[envelope.sessionID]?.lease === plan.lease, plan.lease.isEnabled else { return }
        expected = current
        expected.providerPromptGeneration = prompt.generation
        if let promptID = event.promptID, !promptID.isEmpty, promptID.utf8.count <= 256, !promptID.utf8.contains(0) {
            expected.observed = .providerPrompt(promptID)
        } else { expected.observed = .appInputObservation(prompt.generation) }
        taskExpectedInputs[envelope.managedRunID] = expected
        acceptTaskObservation(expected)
    }

    func observeCodexTaskInput(serverID: UUID, observation: CodexTaskInputObservation) async {
        guard let server = codexServers.first(where: { $0.id == serverID }),
              let plan = taskRunPlans[server.ownerCard], plan.lease.isEnabled else { return }
        let runID = plan.claim.managedRunID
        let expected = taskExpectedInputs[runID]
        if let expected, observation.sequence <= expected.lastSequence { return }
        guard let binding = await supervisor.taskBinding(for: plan.claim),
              let currentPlan = taskRunPlans[server.ownerCard], currentPlan.lease === plan.lease,
              currentPlan.lease.isEnabled, observation.threadID == binding.nativeSessionID,
              let turn = observation.turnID else {
            rejectTaskInput(runID: plan.claim.managedRunID, plan: plan)
            return
        }
        if let expected {
            guard taskExpectedInputs[runID]?.effect === expected.effect else { return }
        } else if taskExpectedInputs[runID] != nil { return }
        guard let expected, var current = taskExpectedInputs[runID], current.effect === expected.effect,
              current.purpose == expected.purpose, current.digest == expected.digest,
              observation.sequence > current.lastSequence, binding == current.binding,
              current.effect.hasEffect, current.expectedNativeTurn == nil || current.expectedNativeTurn == turn,
              observation.digest == current.digest,
              current.clientMessageID == nil || observation.clientID == current.clientMessageID else {
            observeManualInput(runID: runID, binding: binding, digest: observation.digest,
                               observedAt: observation.receivedUptime, plan: plan)
            return
        }
        current.lastSequence = observation.sequence
        current.observed = .nativeTurn(turn)
        taskExpectedInputs[plan.claim.managedRunID] = current
        if current.confirmedObservation != nil {
            acceptTaskObservation(current)
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
            acceptTaskObservation(current)
        } else { scheduleTaskFileProof(runID: binding.managedRunID) }
        return true
    }

    func acceptTaskObservation(_ proposed: SessionTaskExpectedInput) {
        let runID = proposed.binding.managedRunID
        guard var current = taskExpectedInputs[runID], current.effect === proposed.effect,
              current.confirmedObservation != nil else { return }
        if let ticket = current.ticket, current.acceptedGeneration == nil {
            // An unrelated user key can make the composer unsafe for another
            // write without erasing the already observed native execution.
            current.acceptedGeneration = inputGate.confirmAutomaticInputGeneration(runID: runID, ticket: ticket)
        }
        current.retainedChild = nil
        taskExpectedInputs[runID] = current
        if let plan = taskRunPlans[current.binding.sessionID], plan.lease.permits({ true }) != nil {
            finishTaskProofWaiters(runID: runID, observation: current)
        } else { updateTaskQuiescenceObservers() }
        observeTaskWakeIfProved(current)
        if let server = runs[runID]?.server {
            Task { await self.refreshManagedCodexRequests(server) }
        }
    }

    private func observeTaskWakeIfProved(_ expected: SessionTaskExpectedInput) {
        guard expected.confirmedObservation != nil, case let .wake(taskID, operationID) = expected.purpose,
              let coordinator = taskCoordinator else { return }
        let binding = expected.binding
        Task { _ = try? await coordinator.observeWakeConsumption(taskID: taskID, operationID: operationID, binding: binding) }
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
              latest.ticket != nil else { return }
        latest.observed = .nativeTurn(turn)
        taskExpectedInputs[runID] = latest
        acceptTaskObservation(latest)
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
            managedTaskPresentations[id] = nil
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
