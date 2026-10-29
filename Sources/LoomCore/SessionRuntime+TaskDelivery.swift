import CryptoKit
import Foundation

/// Live launch coordination only; task authority remains in the durable store.
/// A managed child never retains a terminal presentation sink or callback.
struct SessionTaskLaunchContext: Sendable {
    struct WakeReservation: Sendable {
        let operationID: UUID
        let binding: SessionTaskBinding
        let ticket: TerminalInputQueue.AutomaticInputTicket
    }
    let childID: UUID
    let projectID: UUID
    let modeFromUserDefault: Bool
    var managedRun: ManagedTaskRun?
    var starting = false
    var stopRequested = false
    var firstInputEffect: SessionTaskInputEffectMarker?
    var wakeNeeded = false
    var wakeInFlight = false
    var wakeRetryRequested = false
    var wakeReservation: WakeReservation?

    var currentRunID: UUID? { managedRun?.runID }
}

struct SessionTaskInterruptWaiter {
    let target: SessionTaskRoundTarget
    let parentBinding: SessionTaskBinding
    let parentPlan: SessionTaskRunPlan
    let childPlan: SessionTaskRunPlan
    let promptGeneration: UUID
    let inputGeneration: UInt64
    let requestedAt: Double
    let ticket: TerminalInputQueue.AutomaticInputTicket
    let continuation: CheckedContinuation<Bool, Never>
    let timeout: Task<Void, Never>
    var evaluating = false
    var retryRequested = false
}

struct ManagedCodexInterruptSignal {
    let parentRunID: UUID
    let childRunID: UUID
    let continuation: AsyncStream<Void>.Continuation
}

private final class SessionTaskInterruptClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func write(_ body: () throws -> Int) rethrows -> Int {
        try lock.withLock {
            let before = Date().timeIntervalSince1970 * 1_000
            let count = try body()
            if count > 0 { value = before }
            return count
        }
    }
    var requestedAt: Double? { lock.withLock { value } }
}

extension SessionRuntime {
    func approveManagedTaskRequest(_ spec: OpenSessionSpec) async throws -> UUID {
        guard let grant = spec.task, let coordinator = taskCoordinator,
              let reservation = taskChildReservations[grant.taskID], reservation.childID == grant.childID,
              reservation.operationID == grant.operationID, let fingerprint = reservation.fingerprint,
              taskLaunchContexts[grant.taskID] == nil else { throw SessionTaskError.unauthorized }
        let task = try await coordinator.createApproved(taskID: grant.taskID, parent: reservation.parent,
            childID: grant.childID, harness: spec.choices.harness, childName: spec.title, choices: spec.choices,
            creationOperationID: grant.operationID, creationFingerprint: fingerprint)
        _ = try await coordinator.requestRound(taskID: task.id, parent: reservation.parent,
                                                operationID: grant.operationID, message: spec.message)
        guard taskLaunchContexts[task.id] == nil,
              await authenticateTaskRun(reservation.parent) == task.parentBinding else { throw SessionTaskError.unauthorized }
        taskLaunchContexts[task.id] = SessionTaskLaunchContext(childID: grant.childID, projectID: spec.projectID,
            modeFromUserDefault: spec.modeFromUserDefault)
        _ = try await coordinator.deliverPending(taskID: task.id)
        guard let run = taskLaunchContexts[task.id]?.managedRun,
              await supervisor.runContext(runID: run.runID) != nil else { throw SessionTaskError.unverified }
        markTaskNeedsDelivery(task.id)
        return run.sessionID
    }

    func taskTerminalAttached(_ runID: UUID) {
        for (taskID, context) in taskLaunchContexts {
            if context.currentRunID == runID { scheduleTaskDelivery(taskID) }
            if context.wakeNeeded && taskChildReservations[taskID]?.parent.managedRunID == runID { scheduleTaskWake(taskID) }
        }
        if let sessionID = taskRunPlans.first(where: { $0.value.claim.managedRunID == runID })?.key {
            markPeerNeedsDelivery(sessionID)
        }
    }

    func scheduleTaskDelivery(_ taskID: UUID) {
        guard !shuttingDown, tasksNeedingDelivery.contains(taskID),
              let context = taskLaunchContexts[taskID], !context.stopRequested else { return }
        guard taskDeliveriesInFlight.insert(taskID).inserted else {
            taskDeliveriesRequested.insert(taskID)
            return
        }
        Task { [weak self] in await self?.performTaskDelivery(taskID) }
    }

    private func performTaskDelivery(_ taskID: UUID) async {
        if let coordinator = taskCoordinator {
            do {
                let receipt = try await coordinator.deliverPending(taskID: taskID)
                if receipt.delivery != .deferred && receipt.delivery != .queued {
                    tasksNeedingDelivery.remove(taskID)
                    updateTaskQuiescenceObservers()
                }
            } catch SessionTaskError.notReady {
                if let task = try? await coordinator.projectionForUser(taskID: taskID), task.pendingRoundID == nil {
                    tasksNeedingDelivery.remove(taskID)
                    updateTaskQuiescenceObservers()
                }
            } catch {
                // A pending round can become eligible at a later provider edge.
            }
        }
        taskDeliveriesInFlight.remove(taskID)
        if taskDeliveriesRequested.remove(taskID) != nil { scheduleTaskDelivery(taskID) }
    }

    func markTaskNeedsDelivery(_ taskID: UUID) {
        tasksNeedingDelivery.insert(taskID)
        updateTaskQuiescenceObservers()
        scheduleTaskDelivery(taskID)
    }

    func updateTaskQuiescenceObservers() {
        for (sessionID, plan) in taskRunPlans {
            let runID = plan.claim.managedRunID
            let deliveryNeeded = taskLaunchContexts.contains { taskID, context in
                let parent = taskChildReservations[taskID]?.parent
                let parentMatches = parent?.sessionID == sessionID && parent?.managedRunID == runID
                return (tasksNeedingDelivery.contains(taskID) && (context.currentRunID == runID || parentMatches)) ||
                    (context.wakeNeeded && parentMatches)
            }
            let proofNeeded = taskProofWaiters.values.contains { $0.binding.managedRunID == runID }
            let interruptNeeded = taskInterruptWaiters.values.contains {
                $0.target.binding.managedRunID == runID || $0.parentBinding.managedRunID == runID
            } || managedCodexInterruptSignals.values.contains { $0.parentRunID == runID || $0.childRunID == runID }
            let presentationNeeded = runs[runID]?.server != nil &&
                taskLaunchContexts.values.contains { $0.currentRunID == runID }
            if deliveryNeeded || proofNeeded || interruptNeeded || presentationNeeded || peersNeedingDelivery.contains(sessionID) {
                plan.lease.observeQuiescence { [weak self, weak lease = plan.lease] in
                    guard let lease else { return }
                    Task {
                        await self?.taskRunBecameQuiescent(sessionID: sessionID, runID: runID)
                        lease.finishQuiescenceNotification()
                    }
                }
            } else { plan.lease.observeQuiescence(nil) }
        }
    }

    func taskRunBecameQuiescent(sessionID: UUID, runID: UUID) async {
        for signal in managedCodexInterruptSignals.values where signal.parentRunID == runID || signal.childRunID == runID {
            signal.continuation.yield(())
        }
        if let plan = taskRunPlans[sessionID], plan.claim.managedRunID == runID,
           plan.lease.permits({ true }) != nil, let expected = taskExpectedInputs[runID],
           expected.confirmedObservation != nil {
            finishTaskProofWaiters(runID: runID, observation: expected)
        }
        if peersNeedingDelivery.contains(sessionID) { schedulePeerDelivery(sessionID) }
        if runs[runID]?.server != nil,
           let taskID = taskLaunchContexts.first(where: { $0.value.currentRunID == runID })?.key {
            await refreshManagedCodexStatus(taskID: taskID, runID: runID)
        }
        for (taskID, context) in taskLaunchContexts {
            let parent = taskChildReservations[taskID]?.parent
            let parentMatches = parent?.sessionID == sessionID && parent?.managedRunID == runID
            if tasksNeedingDelivery.contains(taskID) && (context.currentRunID == runID || parentMatches) {
                scheduleTaskDelivery(taskID)
            }
            if context.wakeNeeded && parentMatches { scheduleTaskWake(taskID) }
        }
        scheduleTaskFileProof(runID: runID)
        scheduleTaskInterruptProof(runID: runID)
    }

    /// A report is app-only. Its separate, bounded nudge is submitted only at
    /// a later clean Ready edge and remains subject to the durable wake lease.
    func markTaskNeedsWake(_ taskID: UUID) {
        guard var context = taskLaunchContexts[taskID], !context.stopRequested, !shuttingDown else { return }
        context.wakeNeeded = true
        taskLaunchContexts[taskID] = context
        updateTaskQuiescenceObservers()
        scheduleTaskWake(taskID)
    }

    private func scheduleTaskWake(_ taskID: UUID) {
        guard var context = taskLaunchContexts[taskID], context.wakeNeeded,
              !context.stopRequested, !shuttingDown else { return }
        if context.wakeInFlight {
            context.wakeRetryRequested = true
            taskLaunchContexts[taskID] = context
            return
        }
        context.wakeInFlight = true
        context.wakeRetryRequested = false
        taskLaunchContexts[taskID] = context
        Task { [weak self] in await self?.performTaskWake(taskID) }
    }

    private func performTaskWake(_ taskID: UUID) async {
        var deferred = false
        defer {
            if var context = taskLaunchContexts[taskID] {
                let anotherEdge = context.wakeRetryRequested
                context.wakeInFlight = false
                context.wakeReservation = nil
                context.wakeNeeded = deferred || anotherEdge
                taskLaunchContexts[taskID] = context
                updateTaskQuiescenceObservers()
                // A new report arriving during this attempt is another edge;
                // a deferred attempt alone must not spin.
                if anotherEdge { scheduleTaskWake(taskID) }
            }
        }
        guard !shuttingDown, let coordinator = taskCoordinator,
              let reservation = taskChildReservations[taskID],
              let task = try? await coordinator.projectionForUser(taskID: taskID), task.lifecycle == .active,
              await authenticateTaskRun(reservation.parent) == task.parentBinding else { return }
        guard await taskNativeStatus(task.parentBinding) == .ready else { deferred = true; return }
        _ = inputGate.establishFreshCleanInput(runID: task.parentBinding.managedRunID)
        guard let ticket = inputGate.reserveAutomaticInput(runID: task.parentBinding.managedRunID) else {
            deferred = true
            _ = inputGate.notifyWhenAutomaticMayProceed(runID: task.parentBinding.managedRunID) { [weak self] in
                Task { await self?.markTaskNeedsWake(taskID) }
            }
            return
        }
        let operationID = UUID()
        guard var context = taskLaunchContexts[taskID], !context.stopRequested else {
            inputGate.releaseReservedAutomatic(runID: task.parentBinding.managedRunID, ticket: ticket)
            return
        }
        context.wakeReservation = .init(operationID: operationID, binding: task.parentBinding, ticket: ticket)
        taskLaunchContexts[taskID] = context
        do {
            let receipt = try await coordinator.wakePending(taskID: taskID, operationID: operationID)
            if receipt.delivery == .deferred { deferred = true }
        } catch SessionTaskError.notReady {
            // The parent read and acknowledged the events before admission.
        } catch {
            // Exhaustion, expiry and unknown outcomes never trigger a retry.
        }
        inputGate.releaseReservedAutomatic(runID: task.parentBinding.managedRunID, ticket: ticket)
    }

    /// Revocation wins before a not-yet-admitted first input. An empty child
    /// already spawned is stopped through the ordinary owner; an in-flight
    /// spawn observes this flag when it returns and performs the same cleanup.
    func taskParentRevoked(_ claim: SessionTaskClaim) {
        for (taskID, reservation) in taskChildReservations where reservation.parent.sessionID == claim.sessionID &&
            reservation.parent.managedRunID == claim.managedRunID && reservation.parent.generation == claim.generation {
            tasksNeedingDelivery.remove(taskID)
            guard var context = taskLaunchContexts[taskID], context.firstInputEffect?.hasEffect != true else { continue }
            context.stopRequested = true
            taskLaunchContexts[taskID] = context
            if context.managedRun != nil && !shuttingDown {
                let childID = context.childID
                Task { [weak self] in
                    _ = await self?.stopTaskChild(taskID: taskID, childSessionID: childID, binding: nil)
                }
            }
        }
        updateTaskQuiescenceObservers()
    }

    func fenceTaskRun(sessionID: UUID, runID: UUID, generation: UUID, identityChanged: Bool = false) async {
        guard let coordinator = taskCoordinator else { return }
        var cursor: UUID?
        repeat {
            guard let page = try? await coordinator.projectionsForUser(parentSessionID: sessionID, after: cursor, limit: 50) else { return }
            for task in page.items where (task.lifecycle == .active || (identityChanged && task.lifecycle == .revoked)) &&
                task.parentBinding.managedRunID == runID &&
                task.parentBinding.generation == generation {
                try? await coordinator.fence(taskID: task.id, binding: task.parentBinding, identityChanged: identityChanged)
            }
            cursor = page.next
        } while cursor != nil
        if let child = try? await coordinator.projectionForChild(sessionID),
           child.lifecycle == .active || (identityChanged && child.lifecycle == .revoked),
           let binding = child.childBinding, binding.managedRunID == runID, binding.generation == generation {
            try? await coordinator.fence(taskID: child.id, binding: binding, identityChanged: identityChanged)
        }
    }

    func submitTaskInput(_ intent: SessionTaskInputIntent) async -> SessionTaskInputEffect {
        let task = intent.task
        guard !shuttingDown, let context = taskLaunchContexts[task.id], !context.stopRequested,
              let reservation = taskChildReservations[task.id],
              await authenticateTaskRun(reservation.parent) == task.parentBinding else { return .deferred }
        if task.childBinding == nil { return await submitInitialManagedTaskInput(intent, context: context) }
        return await submitManagedTaskInput(intent, context: context)
    }

    func clearTaskExpectation(_ purpose: SessionTaskExpectedInput.Purpose, binding: SessionTaskBinding) {
        guard let current = taskExpectedInputs[binding.managedRunID], current.purpose == purpose,
              current.binding == binding, !current.effect.hasEffect else { return }
        if let retained = current.retainedChild {
            taskExpectedInputs[binding.managedRunID] = .restoring(retained)
        } else { taskExpectedInputs[binding.managedRunID] = nil }
    }

    func deliverTaskWake(_ intent: SessionTaskWakeIntent) async -> SessionTaskEffect {
        let binding = intent.parentBinding
        guard !shuttingDown, let context = taskLaunchContexts[intent.taskID], !context.stopRequested,
              let reservation = context.wakeReservation, reservation.operationID == intent.operationID,
              reservation.binding == binding, let origin = taskChildReservations[intent.taskID]?.parent,
              let plan = taskRunPlans[binding.sessionID], let readFence = taskReadFence,
              plan.claim.managedRunID == binding.managedRunID, plan.claim.generation == binding.generation,
              await authenticateTaskRun(origin) == binding, await taskNativeStatus(binding) == .ready,
              let record = runs[binding.managedRunID], let transport = harnesses[record.provider]?.taskTransport,
              let revision = plan.lease.admit({ $0 }) else { return .deferred }
        let ticket = reservation.ticket
        let purpose = SessionTaskExpectedInput.Purpose.wake(taskID: intent.taskID, operationID: intent.operationID)
        let pointer = "Sphyrna updates: run \"$SPHYRNA_CLI\" task read --task \(intent.taskID.uuidString.lowercased())"
        let digest = Data(SHA256.hash(data: Data(pointer.utf8)))
        let effect = SessionTaskInputEffectMarker()
        let clientMessageID = transport == .ownedAppServer ? UUID().uuidString.lowercased() : nil
        guard await prepareTaskInput(purpose: purpose, binding: binding, digest: digest, effect: effect, ticket: ticket,
                                     requiresNativeReceipt: transport == .ownedAppServer, clientMessageID: clientMessageID),
              plan.lease.permits(revision: revision), taskLaunchContexts[intent.taskID]?.wakeReservation?.operationID == intent.operationID else {
            clearTaskExpectation(purpose, binding: binding)
            return .deferred
        }
        // Read/ack, authority revocation, provider ingress and user edits all
        // meet at the actual bounded write, not at scheduling time.
        let transaction: TerminalWriteTransaction = { write in
            var result: Result<Int?, Error>?
            let allowed = readFence.attemptWake(taskID: intent.taskID) {
                intent.attemptDelivery {
                    result = Result { try plan.lease.withOptionalAdmission(revision: revision) { try effect.write(write) } }
                    return true
                }
            }
            guard allowed, let result else { return nil }
            return try result.get()
        }
        if transport == .ownedAppServer {
            guard let client = record.server?.client else { clearTaskExpectation(purpose, binding: binding); return .deferred }
            let gate = inputGate
            do {
                guard let turn = try await client.startTaskTurn(threadID: binding.nativeSessionID, text: pointer,
                    clientMessageID: clientMessageID, transaction: { write in
                        try transaction { try gate.writeReservedAutomatic(runID: binding.managedRunID, ticket: ticket, write) ?? 0 }
                    }) else { clearTaskExpectation(purpose, binding: binding); return .deferred }
                guard confirmCodexTaskTurn(turn, purpose: purpose, binding: binding) else { return .unknown }
                return .verified
            } catch { return .unknown }
        }
        guard transport == .terminalHook,
              inputGate.enqueueReservedAutomatic(runID: binding.managedRunID, ticket: ticket,
                                                  bytes: Data((pointer + "\r").utf8), transaction: transaction) else {
            clearTaskExpectation(purpose, binding: binding)
            return .deferred
        }
        switch await ticket.writeOutcome() {
        case .written: return .verified
        case .notWritten: clearTaskExpectation(purpose, binding: binding); return .deferred
        case .unknown: return .unknown
        }
    }

    private func waitForClaudeInterrupt(_ target: SessionTaskRoundTarget, parentBinding: SessionTaskBinding,
                                        parentPlan: SessionTaskRunPlan, childPlan: SessionTaskRunPlan,
                                        promptGeneration: UUID, inputGeneration: UInt64, requestedAt: Double,
                                        ticket: TerminalInputQueue.AutomaticInputTicket) async -> Bool {
        guard taskInterruptWaiters.count < 32 else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.finishTaskInterruptWaiter(id, verified: false)
                }
                taskInterruptWaiters[id] = SessionTaskInterruptWaiter(target: target, parentBinding: parentBinding,
                    parentPlan: parentPlan, childPlan: childPlan, promptGeneration: promptGeneration,
                    inputGeneration: inputGeneration, requestedAt: requestedAt, ticket: ticket,
                    continuation: continuation, timeout: timeout)
                updateTaskQuiescenceObservers()
                scheduleTaskInterruptProof(runID: target.binding.managedRunID)
            }
        } onCancel: { Task { await self.finishTaskInterruptWaiter(id, verified: false) } }
    }

    func finishTaskInterruptWaiters(runID: UUID) {
        let ids = taskInterruptWaiters.compactMap { id, waiter in
            waiter.target.binding.managedRunID == runID || waiter.parentBinding.managedRunID == runID ? id : nil
        }
        for id in ids { finishTaskInterruptWaiter(id, verified: false) }
    }

    private func finishTaskInterruptWaiter(_ id: UUID, verified: Bool) {
        guard let waiter = taskInterruptWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: verified)
        updateTaskQuiescenceObservers()
    }

    private func scheduleTaskInterruptProof(runID: UUID) {
        for (id, var waiter) in taskInterruptWaiters where
            waiter.target.binding.managedRunID == runID || waiter.parentBinding.managedRunID == runID {
            if waiter.evaluating { waiter.retryRequested = true; taskInterruptWaiters[id] = waiter; continue }
            waiter.evaluating = true
            waiter.retryRequested = false
            taskInterruptWaiters[id] = waiter
            Task { [weak self] in await self?.evaluateTaskInterruptProof(id) }
        }
    }

    private func evaluateTaskInterruptProof(_ id: UUID) async {
        guard let waiter = taskInterruptWaiters[id] else { return }
        defer {
            if var current = taskInterruptWaiters[id] {
                let retry = current.retryRequested
                current.evaluating = false; current.retryRequested = false
                taskInterruptWaiters[id] = current
                if retry { scheduleTaskInterruptProof(runID: current.target.binding.managedRunID) }
            }
        }
        let binding = waiter.target.binding, purpose = SessionTaskExpectedInput.Purpose.child(
            taskID: waiter.target.taskID, roundID: waiter.target.roundID, operationID: waiter.target.inputOperationID)
        guard !shuttingDown, waiter.target.attemptInterrupt({ true }),
              let parentRevision = waiter.parentPlan.lease.admit({ $0 }),
              let childRevision = waiter.childPlan.lease.admit({ $0 }),
              let coordinator = taskCoordinator,
              let task = try? await coordinator.projectionForUser(taskID: waiter.target.taskID),
              task.lifecycle == .revoked, task.childBinding == binding, task.parentBinding == waiter.parentBinding,
              let reservation = taskChildReservations[waiter.target.taskID],
              await authenticateTaskRun(reservation.parent) == waiter.parentBinding,
              await taskNativeStatus(binding) == .ready,
              let context = await supervisor.runContext(runID: binding.managedRunID),
              let prompt = await harnesses.claude.adapter.taskCurrentPrompt(runID: binding.managedRunID),
              prompt.generation == waiter.promptGeneration,
              let idle = await harnesses.claude.adapter.taskIdleProof(runID: binding.managedRunID,
                  nativeSessionID: binding.nativeSessionID, workingDirectory: context.session.workingDirectory),
              idle.promptGeneration == waiter.promptGeneration, idle.updatedAt > waiter.requestedAt,
              let expected = taskExpectedInputs[binding.managedRunID], expected.purpose == purpose,
              expected.binding == binding, expected.providerPromptGeneration == waiter.promptGeneration,
              expected.confirmedObservation != nil, expected.acceptedGeneration == waiter.inputGeneration,
              taskInterruptWaiters[id] != nil,
              taskRunPlans[binding.sessionID]?.lease === waiter.childPlan.lease,
              taskRunPlans[waiter.parentBinding.sessionID]?.lease === waiter.parentPlan.lease,
              waiter.parentPlan.lease.permits(revision: parentRevision),
              waiter.childPlan.lease.permits(revision: childRevision) else { return }
        let gate = inputGate
        let verified = waiter.target.attemptInterrupt {
            waiter.parentPlan.lease.withOptionalAdmission(revision: parentRevision) {
                waiter.childPlan.lease.withOptionalAdmission(revision: childRevision) {
                    guard gate.hasInputGeneration(runID: binding.managedRunID, generation: waiter.inputGeneration),
                          gate.confirmAutomaticInput(runID: binding.managedRunID, ticket: waiter.ticket) else { return 0 }
                    return 1
                }
            } == 1
        }
        if verified { finishTaskInterruptWaiter(id, verified: true) }
    }

    /// Interrupt only the exact proved execution. The replacement remains
    /// queued until the same owned child reaches a verified Ready edge.
    func interruptTaskRound(_ target: SessionTaskRoundTarget) async -> SessionTaskEffect {
        let binding = target.binding
        guard !shuttingDown, let coordinator = taskCoordinator,
              let task = try? await coordinator.projectionForUser(taskID: target.taskID),
              task.lifecycle == .revoked, task.childBinding == binding,
              let reservation = taskChildReservations[target.taskID],
              let parentPlan = taskRunPlans[task.parentSessionID], let childPlan = taskRunPlans[binding.sessionID],
              parentPlan.claim.managedRunID == task.parentBinding.managedRunID,
              parentPlan.claim.generation == task.parentBinding.generation,
              childPlan.claim.managedRunID == binding.managedRunID, childPlan.claim.generation == binding.generation,
              let parentRevision = parentPlan.lease.admit({ $0 }), let childRevision = childPlan.lease.admit({ $0 }),
              await authenticateTaskRun(reservation.parent) == task.parentBinding,
              let observation = await taskInputObservation(purpose: .child(taskID: target.taskID, roundID: target.roundID,
                                                                           operationID: target.inputOperationID), binding: binding),
              target.execution == nil || target.execution == observation,
              await taskNativeStatus(binding) == .working,
              parentPlan.lease.permits(revision: parentRevision), childPlan.lease.permits(revision: childRevision),
              let record = runs[binding.managedRunID], let transport = harnesses[record.provider]?.taskTransport else { return .deferred }
        if let managed = managedTaskControllers[binding.managedRunID], managed.run.sessionID == binding.sessionID {
            guard await supervisor.taskBinding(for: childPlan.claim) == binding,
                  taskRunPlans[task.parentSessionID]?.lease === parentPlan.lease,
                  taskRunPlans[binding.sessionID]?.lease === childPlan.lease,
                  parentPlan.lease.permits(revision: parentRevision), childPlan.lease.permits(revision: childRevision) else {
                return .deferred
            }
            let outcome = await managed.controller.interrupt(target) { write in
                var result: Result<Int?, Error>?
                let allowed = target.attemptInterrupt {
                    result = Result {
                        try parentPlan.lease.withOptionalAdmission(revision: parentRevision) {
                            try childPlan.lease.withOptionalAdmission(revision: childRevision) { try write() }
                        }
                    }
                    return true
                }
                guard allowed, let result else { return nil }
                return try result.get()
            }
            guard case .verified = outcome else { return outcome }
            guard target.attemptInterrupt({ true }),
                  await taskInputObservation(purpose: .child(taskID: target.taskID, roundID: target.roundID,
                      operationID: target.inputOperationID), binding: binding) == observation,
                  await taskNativeStatus(binding) == .ready,
                  taskRunPlans[task.parentSessionID]?.lease === parentPlan.lease,
                  taskRunPlans[binding.sessionID]?.lease === childPlan.lease,
                  parentPlan.lease.permits({ true }) != nil, childPlan.lease.permits({ true }) != nil,
                  target.attemptInterrupt({ true }) else { return .unknown }
            return .verified
        }
        if taskLaunchContexts[target.taskID]?.managedRun?.runID == binding.managedRunID,
           transport == .ownedAppServer, let turn = target.nativeTurnID, observation == .nativeTurn(turn),
           let client = record.server?.client {
            guard managedCodexInterruptSignals.count < 32 else { return .deferred }
            let signalID = UUID()
            var continuation: AsyncStream<Void>.Continuation!
            let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
            managedCodexInterruptSignals[signalID] = ManagedCodexInterruptSignal(
                parentRunID: parentPlan.claim.managedRunID, childRunID: binding.managedRunID, continuation: continuation)
            updateTaskQuiescenceObservers()
            defer {
                managedCodexInterruptSignals.removeValue(forKey: signalID)?.continuation.finish()
                updateTaskQuiescenceObservers()
            }
            do {
                let accepted = try await client.interruptTaskTurn(threadID: binding.nativeSessionID, turnID: turn) { write in
                    var result: Result<Int?, Error>?
                    let allowed = target.attemptInterrupt {
                        result = Result {
                            try parentPlan.lease.withOptionalAdmission(revision: parentRevision) {
                                try childPlan.lease.withOptionalAdmission(revision: childRevision) { try write() }
                            }
                        }
                        return true
                    }
                    guard allowed, let result else { return nil }
                    return try result.get()
                }
                guard accepted else { return .deferred }
            } catch { return .unknown }
            let ended = await withTaskGroup(of: Bool.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return false }
                    if await self.managedCodexInterruptEnded(target, parentPlan: parentPlan, childPlan: childPlan) { return true }
                    for await _ in stream {
                        guard !Task.isCancelled else { return false }
                        if await self.managedCodexInterruptEnded(target, parentPlan: parentPlan, childPlan: childPlan) { return true }
                    }
                    return false
                }
                group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
                let value = await group.next() ?? false
                group.cancelAll()
                return value
            }
            return ended ? .verified : .unknown
        }
        guard let ticket = inputGate.reserveAutomaticInput(runID: binding.managedRunID) else { return .deferred }
        guard await supervisor.taskBinding(for: childPlan.claim) == binding,
              taskRunPlans[task.parentSessionID]?.lease === parentPlan.lease,
              taskRunPlans[binding.sessionID]?.lease === childPlan.lease,
              parentPlan.lease.permits(revision: parentRevision), childPlan.lease.permits(revision: childRevision) else {
            inputGate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket)
            return .deferred
        }
        let gate = inputGate
        if transport == .terminalHook {
            let purpose = SessionTaskExpectedInput.Purpose.child(taskID: target.taskID, roundID: target.roundID,
                                                                  operationID: target.inputOperationID)
            guard target.nativeTurnID == nil,
                  let expected = taskExpectedInputs[binding.managedRunID], expected.purpose == purpose,
                  expected.binding == binding, expected.confirmedObservation == observation,
                  let promptGeneration = expected.providerPromptGeneration, let inputGeneration = expected.acceptedGeneration,
                  let prompt = await harnesses.claude.adapter.taskCurrentPrompt(runID: binding.managedRunID),
                  prompt.generation == promptGeneration,
                  taskExpectedInputs[binding.managedRunID]?.effect === expected.effect,
                  gate.hasInputGeneration(runID: binding.managedRunID, generation: inputGeneration),
                  parentPlan.lease.permits(revision: parentRevision), childPlan.lease.permits(revision: childRevision) else {
                gate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket)
                return .deferred
            }
            let clock = SessionTaskInterruptClock()
            let admitted = gate.enqueueReservedTaskInterrupt(runID: binding.managedRunID, ticket: ticket) { write in
                var result: Result<Int?, Error>?
                let allowed = target.attemptInterrupt {
                    result = Result {
                        try parentPlan.lease.withOptionalAdmission(revision: parentRevision) {
                            try childPlan.lease.withOptionalAdmission(revision: childRevision) { try clock.write(write) }
                        }
                    }
                    return true
                }
                guard allowed, let result else { return nil }
                return try result.get()
            }
            guard admitted else { gate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket); return .deferred }
            switch await ticket.writeOutcome() {
            case .notWritten: return .deferred
            case .unknown: return .unknown
            case .written:
                guard let requestedAt = clock.requestedAt else { return .unknown }
                let verified = await waitForClaudeInterrupt(target, parentBinding: task.parentBinding,
                    parentPlan: parentPlan, childPlan: childPlan, promptGeneration: promptGeneration,
                    inputGeneration: inputGeneration, requestedAt: requestedAt, ticket: ticket)
                return verified ? .verified : .unknown
            }
        }
        guard transport == .ownedAppServer, let turn = target.nativeTurnID, observation == .nativeTurn(turn),
              let client = record.server?.client else {
            gate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket)
            return .deferred
        }
        do {
            let accepted = try await client.interruptTaskTurn(threadID: binding.nativeSessionID, turnID: turn,
                transaction: { write in
                    var result: Result<Int?, Error>?
                    let allowed = target.attemptInterrupt {
                        result = Result {
                            try parentPlan.lease.withOptionalAdmission(revision: parentRevision) {
                                try childPlan.lease.withOptionalAdmission(revision: childRevision) {
                                    try gate.writeReservedAutomatic(runID: binding.managedRunID, ticket: ticket, write) ?? 0
                                }
                            }
                        }
                        return true
                    }
                    guard allowed, let result else { return nil }
                    return try result.get()
                })
            guard accepted else {
                inputGate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket)
                return .deferred
            }
            // The interrupt is an RPC, not text in the composer. A concurrent
            // user edit still prevents this from reopening the input gate.
            _ = inputGate.confirmAutomaticInput(runID: binding.managedRunID, ticket: ticket)
            return .verified
        } catch {
            inputGate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket)
            return .unknown
        }
    }

    private func managedCodexInterruptEnded(_ target: SessionTaskRoundTarget, parentPlan: SessionTaskRunPlan,
                                            childPlan: SessionTaskRunPlan) async -> Bool {
        let binding = target.binding
        guard let turn = target.nativeTurnID, target.attemptInterrupt({ true }),
              taskRunPlans[parentPlan.claim.sessionID]?.lease === parentPlan.lease,
              taskRunPlans[binding.sessionID]?.lease === childPlan.lease,
              parentPlan.lease.isEnabled, childPlan.lease.isEnabled,
              let status = await harnesses.codex.adapter.status(sessionID: binding.sessionID),
              status.providerThreadID == binding.nativeSessionID, status.lastCompletedTurnID == turn,
              status.nativeThreadStatus == .idle, await supervisor.taskBinding(for: childPlan.claim) == binding,
              taskRunPlans[parentPlan.claim.sessionID]?.lease === parentPlan.lease,
              taskRunPlans[binding.sessionID]?.lease === childPlan.lease,
              parentPlan.lease.permits({ true }) != nil, childPlan.lease.permits({ true }) != nil else { return false }
        return target.attemptInterrupt { true }
    }

    func finishManagedCodexInterruptSignals(runID: UUID) {
        let ids = managedCodexInterruptSignals.compactMap { id, signal in
            signal.parentRunID == runID || signal.childRunID == runID ? id : nil
        }
        for id in ids { managedCodexInterruptSignals.removeValue(forKey: id)?.continuation.finish() }
        updateTaskQuiescenceObservers()
    }

    func stopTaskChild(taskID: UUID, childSessionID: UUID, binding: SessionTaskBinding?) async -> SessionTaskEffect {
        if var context = taskLaunchContexts[taskID] {
            guard context.childID == childSessionID else { return .unknown }
            context.stopRequested = true
            taskLaunchContexts[taskID] = context
            if let run = context.managedRun {
                guard binding == nil || (binding?.sessionID == run.sessionID && binding?.managedRunID == run.runID &&
                      binding?.generation == run.generation) else { return .unknown }
                let current = await supervisor.session(id: childSessionID)
                if let active = current?.currentRun {
                    if active.id == run.runID {
                        do {
                            let report = try await stopConversation(sessionID: childSessionID, expectedRunID: run.runID)
                            let after = await supervisor.session(id: childSessionID)
                            return report.sessionID == childSessionID && report.runID == run.runID && report.succeeded &&
                                after?.currentRun == nil && taskRunPlans[childSessionID] == nil ? .verified : .unknown
                        } catch { return .unknown }
                    }
                    // A later ordinary run is never a Stop target for this
                    // task; only the old binding's durable proof can settle it.
                    guard binding != nil else { return .unknown }
                }
                revokeTaskRun(sessionID: childSessionID, runID: run.runID)
            } else {
                guard binding == nil else { return .unknown }
                if let plan = taskRunPlans[childSessionID] {
                    revokeTaskRun(sessionID: childSessionID, runID: plan.claim.managedRunID)
                }
            }
        }
        // Settle the durable never-opened reservation atomically against a
        // late start. Otherwise only an exact stopped scope receipt can prove
        // the child is gone; an absent in-memory run is never enough.
        guard let coordinator = taskCoordinator else { return .unknown }
        if let binding {
            guard binding.sessionID == childSessionID,
                  taskRunPlans[childSessionID]?.claim.managedRunID != binding.managedRunID,
                  await supervisor.runContext(runID: binding.managedRunID) == nil,
                  (try? await coordinator.managedChildStopped(taskID: taskID, sessionID: childSessionID, binding: binding)) == true,
                  taskRunPlans[childSessionID]?.claim.managedRunID != binding.managedRunID,
                  await supervisor.runContext(runID: binding.managedRunID) == nil else { return .unknown }
            return .verified
        }
        guard
              await supervisor.session(id: childSessionID)?.currentRun == nil,
              taskRunPlans[childSessionID] == nil else { return .unknown }
        var verified = (try? await coordinator.settleUnstartedManagedLaunch(taskID: taskID, childID: childSessionID)) == true
        if !verified {
            verified = (try? await coordinator.managedChildStopped(taskID: taskID, sessionID: childSessionID, binding: nil)) == true
        }
        guard verified,
              await supervisor.session(id: childSessionID)?.currentRun == nil,
              taskRunPlans[childSessionID] == nil else { return .unknown }
        return .verified
    }

}
