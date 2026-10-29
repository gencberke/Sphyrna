import CryptoKit
import Foundation

/// Only presentation resources and the existing runtime launch are held
/// here; task authority and messages remain in the durable coordinator.
struct SessionTaskLaunchContext: Sendable {
    let childID: UUID
    let projectID: UUID
    let rows: UInt16
    let columns: UInt16
    let output: any TerminalOutputSink
    let ready: @MainActor @Sendable (RuntimeLaunch) async -> Void
    let modeFromUserDefault: Bool
    var launch: RuntimeLaunch?
    var starting = false
    var stopRequested = false
    var firstInputEffect: SessionTaskInputEffectMarker?
}

extension SessionRuntime {
    func approveTaskRequest(_ spec: OpenSessionSpec, rows: UInt16, columns: UInt16,
                            outputSink: (any TerminalOutputSink)?,
                            onTerminalReady: (@MainActor @Sendable (RuntimeLaunch) async -> Void)?) async throws -> RuntimeLaunch {
        guard let grant = spec.task, let coordinator = taskCoordinator,
              let outputSink, let onTerminalReady,
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
            rows: rows, columns: columns, output: outputSink, ready: onTerminalReady,
            modeFromUserDefault: spec.modeFromUserDefault)
        _ = try await coordinator.deliverPending(taskID: task.id)
        guard let launch = taskLaunchContexts[task.id]?.launch else { throw SessionTaskError.unverified }
        markTaskNeedsDelivery(task.id)
        return launch
    }

    func taskTerminalAttached(_ runID: UUID) {
        guard let taskID = taskLaunchContexts.first(where: { $0.value.launch?.runID == runID })?.key else { return }
        scheduleTaskDelivery(taskID)
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

    private func updateTaskQuiescenceObservers() {
        for (sessionID, plan) in taskRunPlans {
            let runID = plan.claim.managedRunID
            let needed = taskLaunchContexts.contains { taskID, context in
                guard tasksNeedingDelivery.contains(taskID) else { return false }
                let parent = taskChildReservations[taskID]?.parent
                return context.launch?.runID == runID || (parent?.sessionID == sessionID && parent?.managedRunID == runID)
            }
            if needed {
                plan.lease.observeQuiescence { [weak self] in
                    Task { await self?.taskRunBecameQuiescent(sessionID: sessionID, runID: runID) }
                }
            } else { plan.lease.observeQuiescence(nil) }
        }
    }

    func taskRunBecameQuiescent(sessionID: UUID, runID: UUID) {
        for (taskID, context) in taskLaunchContexts where tasksNeedingDelivery.contains(taskID) {
            let parent = taskChildReservations[taskID]?.parent
            if context.launch?.runID == runID || (parent?.sessionID == sessionID && parent?.managedRunID == runID) {
                scheduleTaskDelivery(taskID)
            }
        }
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
            if context.launch != nil && !shuttingDown {
                let childID = context.childID
                Task { [weak self] in
                    _ = await self?.stopTaskChild(taskID: taskID, childSessionID: childID, binding: nil)
                }
            }
        }
        updateTaskQuiescenceObservers()
    }

    func fenceTaskRun(sessionID: UUID, runID: UUID, generation: UUID) async {
        guard let coordinator = taskCoordinator else { return }
        var cursor: UUID?
        repeat {
            guard let page = try? await coordinator.projectionsForUser(parentSessionID: sessionID, after: cursor, limit: 50) else { return }
            for task in page.items where task.lifecycle == .active && task.parentBinding.managedRunID == runID &&
                task.parentBinding.generation == generation {
                try? await coordinator.fence(taskID: task.id, binding: task.parentBinding)
            }
            cursor = page.next
        } while cursor != nil
        if let child = try? await coordinator.projectionForChild(sessionID), child.lifecycle == .active,
           let binding = child.childBinding, binding.managedRunID == runID, binding.generation == generation {
            try? await coordinator.fence(taskID: child.id, binding: binding)
        }
    }

    private func rememberTaskLaunch(_ taskID: UUID, launch: RuntimeLaunch) -> Bool {
        guard var context = taskLaunchContexts[taskID], context.childID == launch.sessionID,
              context.launch == nil else { return false }
        context.launch = launch
        taskLaunchContexts[taskID] = context
        return true
    }

    private func launchedTaskBinding(_ launch: RuntimeLaunch) async -> SessionTaskBinding? {
        guard let plan = taskRunPlans[launch.sessionID], plan.claim.managedRunID == launch.runID,
              let binding = await supervisor.taskBinding(for: plan.claim),
              taskRunPlans[launch.sessionID]?.lease === plan.lease, plan.lease.isEnabled else { return nil }
        return binding
    }

    private func waitForTaskBinding(_ launch: RuntimeLaunch, stream: AsyncStream<SessionEventFrame>) async -> SessionTaskBinding? {
        if let binding = await launchedTaskBinding(launch) { return binding }
        return await withTaskGroup(of: SessionTaskBinding?.self) { group in
            group.addTask { [weak self] in
                for await _ in stream {
                    guard !Task.isCancelled, let self else { return nil }
                    if let binding = await self.launchedTaskBinding(launch) { return binding }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let binding = await group.next() ?? nil
            group.cancelAll()
            return binding
        }
    }

    func submitTaskInput(_ intent: SessionTaskInputIntent) async -> SessionTaskInputEffect {
        let task = intent.task
        guard !shuttingDown, var context = taskLaunchContexts[task.id], !context.stopRequested,
              let reservation = taskChildReservations[task.id],
              await authenticateTaskRun(reservation.parent) == task.parentBinding else { return .deferred }
        if task.childBinding == nil {
            guard !context.starting, context.launch == nil, let provider = task.harness.provider else { return .unknown }
            context.starting = true
            taskLaunchContexts[task.id] = context
            let stream = await supervisor.events.subscribe()
            let ready: @MainActor @Sendable (RuntimeLaunch) async -> Void = { [weak self, callback = context.ready] launch in
                guard let self, await self.rememberTaskLaunch(task.id, launch: launch) else { return }
                await callback(launch)
            }
            do {
                let launch = try await startConversation(provider: provider, projectID: context.projectID,
                    rows: context.rows, columns: context.columns, outputSink: context.output,
                    opening: SessionOpening(approvedTask: task, firstMessage: "", modeFromUserDefault: context.modeFromUserDefault),
                    onTerminalReady: ready)
                await ready(launch) // Claude returns before its caller adopts; Codex already called it.
                taskLaunchContexts[task.id]?.starting = false
                guard let binding = await waitForTaskBinding(launch, stream: stream) else {
                    if taskLaunchContexts[task.id]?.stopRequested == true {
                        _ = await stopTaskChild(taskID: task.id, childSessionID: launch.sessionID, binding: nil)
                    }
                    return .unknown
                }
                let current = try? await taskCoordinator?.projectionForUser(taskID: task.id)
                guard taskLaunchContexts[task.id]?.stopRequested == false,
                      current?.lifecycle == .active,
                      await authenticateTaskRun(reservation.parent) == task.parentBinding else {
                    _ = await stopTaskChild(taskID: task.id, childSessionID: launch.sessionID, binding: binding)
                    return .started(binding: binding)
                }
                return .started(binding: binding)
            } catch {
                taskLaunchContexts[task.id]?.starting = false
                if taskLaunchContexts[task.id]?.launch != nil {
                    _ = await stopTaskChild(taskID: task.id, childSessionID: task.childSessionID, binding: nil)
                }
                return .unknown
            }
        }
        guard let binding = task.childBinding, let launch = context.launch,
              launch.sessionID == binding.sessionID, launch.runID == binding.managedRunID,
              let parentPlan = taskRunPlans[task.parentSessionID], let childPlan = taskRunPlans[binding.sessionID],
              parentPlan.claim.managedRunID == task.parentBinding.managedRunID,
              parentPlan.claim.generation == task.parentBinding.generation,
              childPlan.claim.managedRunID == binding.managedRunID, childPlan.claim.generation == binding.generation,
              await taskNativeStatus(binding) == .ready else { return .deferred }
        // This succeeds only for a newly attached, untouched terminal. After a
        // proved task input, confirmAutomaticInput establishes later boundaries.
        _ = inputGate.establishFreshCleanInput(runID: binding.managedRunID)
        guard let ticket = inputGate.reserveAutomaticInput(runID: binding.managedRunID) else {
            _ = inputGate.notifyWhenAutomaticMayProceed(runID: binding.managedRunID) { [weak self] in
                Task { await self?.scheduleTaskDelivery(task.id) }
            }
            return .deferred
        }
        let purpose = SessionTaskExpectedInput.Purpose.child(taskID: task.id, roundID: intent.round.id,
                                                             operationID: intent.round.operationID)
        let pointer = "Sphyrna task: run \"$SPHYRNA_CLI\" task input --task \(task.id.uuidString.lowercased()) --round \(intent.round.id.uuidString.lowercased()) --operation \(intent.round.operationID.uuidString.lowercased()); report using task --help."
        let digest = Data(SHA256.hash(data: Data(pointer.utf8)))
        let effect = SessionTaskInputEffectMarker()
        if taskLaunchContexts[task.id]?.firstInputEffect?.hasEffect != true {
            taskLaunchContexts[task.id]?.firstInputEffect = effect
        }
        guard await prepareTaskInput(purpose: purpose, binding: binding, digest: digest, effect: effect, ticket: ticket,
                                     requiresNativeReceipt: launch.provider == .codex),
              let parentRevision = parentPlan.lease.admit({ $0 }), let childRevision = childPlan.lease.admit({ $0 }),
              taskLaunchContexts[task.id]?.stopRequested == false else {
            inputGate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket)
            clearTaskExpectation(purpose, binding: binding)
            return .deferred
        }
        let transaction: TerminalWriteTransaction = { write in
            try parentPlan.lease.withOptionalAdmission(revision: parentRevision) {
                try childPlan.lease.withOptionalAdmission(revision: childRevision) {
                    try effect.write(write)
                }
            }
        }
        if launch.provider == .codex {
            guard let client = runs[binding.managedRunID]?.server?.client else {
                inputGate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket)
                clearTaskExpectation(purpose, binding: binding)
                return .deferred
            }
            let gate = inputGate
            do {
                let turn = try await client.startTaskTurn(threadID: binding.nativeSessionID, text: pointer, transaction: { write in
                    try transaction { try gate.writeReservedAutomatic(runID: binding.managedRunID, ticket: ticket, write) ?? 0 }
                })
                guard let turn else {
                    inputGate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket)
                    clearTaskExpectation(purpose, binding: binding)
                    return .deferred
                }
                guard confirmCodexTaskTurn(turn, purpose: purpose, binding: binding) else { return .unknown }
                return .submitted(binding: binding, nativeTurnID: turn, actualModel: nil, actualEffort: nil, actualMode: nil)
            } catch { return .unknown }
        }
        guard inputGate.enqueueReservedAutomatic(runID: binding.managedRunID, ticket: ticket,
                                                 bytes: Data((pointer + "\r").utf8), transaction: transaction) else {
            inputGate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket)
            clearTaskExpectation(purpose, binding: binding)
            _ = inputGate.notifyWhenAutomaticMayProceed(runID: binding.managedRunID) { [weak self] in
                Task { await self?.scheduleTaskDelivery(task.id) }
            }
            return .deferred
        }
        switch await ticket.writeOutcome() {
        case .written:
            return .submitted(binding: binding, nativeTurnID: nil, actualModel: nil, actualEffort: nil, actualMode: nil)
        case .notWritten:
            clearTaskExpectation(purpose, binding: binding)
            return .deferred
        case .unknown: return .unknown
        }
    }

    private func clearTaskExpectation(_ purpose: SessionTaskExpectedInput.Purpose, binding: SessionTaskBinding) {
        guard let current = taskExpectedInputs[binding.managedRunID], current.purpose == purpose,
              current.binding == binding, !current.effect.hasEffect else { return }
        taskExpectedInputs[binding.managedRunID] = nil
    }

    func stopTaskChild(taskID: UUID, childSessionID: UUID, binding: SessionTaskBinding?) async -> SessionTaskEffect {
        guard var context = taskLaunchContexts[taskID], context.childID == childSessionID else { return .unknown }
        context.stopRequested = true
        taskLaunchContexts[taskID] = context
        guard let launch = context.launch, binding == nil ||
              (binding?.sessionID == launch.sessionID && binding?.managedRunID == launch.runID) else { return .unknown }
        if let binding {
            guard let plan = taskRunPlans[binding.sessionID], plan.claim.managedRunID == binding.managedRunID,
                  plan.claim.generation == binding.generation else {
                let report = await supervisor.lastStopReport(sessionID: childSessionID)
                let current = await supervisor.session(id: childSessionID)
                return report?.runID == launch.runID && report?.succeeded == true && current?.currentRun == nil ? .verified : .unknown
            }
        }
        do {
            let report = try await stopConversation(sessionID: childSessionID)
            return report.runID == launch.runID && report.succeeded ? .verified : .unknown
        } catch {
            let report = await supervisor.lastStopReport(sessionID: childSessionID)
            let current = await supervisor.session(id: childSessionID)
            return report?.runID == launch.runID && report?.succeeded == true && current?.currentRun == nil ? .verified : .unknown
        }
    }
}
