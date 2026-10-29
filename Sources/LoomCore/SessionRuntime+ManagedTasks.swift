import CryptoKit
import Foundation

struct ManagedTaskControllerState: Sendable {
    let run: ManagedTaskRun
    let controller: any ManagedTaskController
    var initialized = false
    var pendingInput: ManagedTaskInput?
    var effect: SessionTaskInputEffectMarker?
    var observation: ManagedTaskInputObservation?
}

extension SessionRuntime {
    func publishManagedTaskPresentation(_ value: ManagedTaskPresentation) async {
        managedTaskPresentations[value.run.taskID] = value
        await supervisor.events.publish(sessionID: value.run.sessionID, change: .managedTaskChanged(value.run.taskID))
    }

    /// Invalidate requests before releasing the protocol owner. Removing the
    /// controller first makes concurrent Stop/Quit/reconciliation idempotent.
    func closeManagedTaskController(runID: UUID) async {
        guard let state = managedTaskControllers.removeValue(forKey: runID) else { return }
        await endManagedTaskPresentation(runID: runID, verified: false)
        await state.controller.close()
    }

    func endManagedTaskPresentation(runID: UUID, verified: Bool) async {
        guard let pair = taskLaunchContexts.first(where: { $0.value.currentRunID == runID }),
              let old = managedTaskPresentations[pair.key], old.run.runID == runID,
              let next = try? ManagedTaskPresentation(run: old.run, binding: old.binding,
                effectiveSettings: old.effectiveSettings, status: verified ? .stopped : .unknown,
                progress: [], permissions: [], canTakeOver: false), next != old else { return }
        await publishManagedTaskPresentation(next)
    }

    func refreshManagedCodexStatus(taskID: UUID, runID: UUID) async {
        guard let old = managedTaskPresentations[taskID], old.run.runID == runID,
              let binding = old.binding, runs[runID]?.server != nil,
              let plan = taskRunPlans[binding.sessionID], plan.claim.managedRunID == runID,
              plan.claim.generation == binding.generation, let revision = plan.lease.admit({ $0 }) else { return }
        let status = await taskNativeStatus(binding)
        guard let current = managedTaskPresentations[taskID], current.run == old.run,
              current.binding == binding, taskRunPlans[binding.sessionID]?.lease === plan.lease,
              plan.lease.permits(revision: revision), current.status != status,
              let next = try? ManagedTaskPresentation(run: current.run, binding: binding,
                effectiveSettings: current.effectiveSettings, status: status,
                progress: status == .unknown || status == .stopped ? [] : current.progress,
                permissions: current.permissions, canTakeOver: current.canTakeOver) else { return }
        await publishManagedTaskPresentation(next)
    }

    /// A user response applies to one still-live occurrence of one run. It
    /// cannot create a permission rule or authorize a later native request.
    public func respondManagedTask(taskID: UUID, expectedRunID: UUID, expectedGeneration: UUID,
                                   occurrenceID: UUID, decision: ManagedTaskUserDecision) async throws -> ManagedTaskWriteOutcome {
        guard !shuttingDown, let view = managedTaskPresentations[taskID], view.run.runID == expectedRunID,
              view.run.generation == expectedGeneration, let binding = view.binding,
              view.permissions.contains(where: { $0.id == occurrenceID && $0.binding == binding }),
              let plan = taskRunPlans[binding.sessionID], plan.claim.managedRunID == expectedRunID,
              plan.claim.generation == expectedGeneration, plan.lease.isEnabled else { throw SessionTaskError.staleBinding }
        guard let revision = plan.lease.admit({ $0 }) else { return .deferred }
        guard
              await supervisor.taskBinding(for: plan.claim) == binding,
              taskRunPlans[binding.sessionID]?.lease === plan.lease, plan.lease.isEnabled,
              managedTaskPresentations[taskID]?.permissions.contains(where: { $0.id == occurrenceID && $0.binding == binding }) == true
        else { throw SessionTaskError.staleBinding }
        guard plan.lease.permits(revision: revision) else { return .deferred }
        if let state = managedTaskControllers[expectedRunID], state.run == view.run {
            return await state.controller.respond(occurrenceID: occurrenceID, decision: decision) { write in
                try plan.lease.withOptionalAdmission(revision: revision) { try write() }
            }
        }
        return try await respondManagedCodex(taskID: taskID, binding: binding, occurrenceID: occurrenceID,
                                             decision: decision, plan: plan, revision: revision)
    }

    func submitInitialManagedTaskInput(_ intent: SessionTaskInputIntent,
                                       context: SessionTaskLaunchContext) async -> SessionTaskInputEffect {
        let task = intent.task, taskID = task.id, sessionID = task.childSessionID
        guard let provider = task.harness.provider, let transport = harnesses[provider]?.taskTransport else { return .deferred }
        if transport == .terminalHook {
            return await submitInitialManagedClaudeTaskInput(intent, context: context, provider: provider)
        }
        guard !context.starting, context.managedRun == nil, transport == .ownedAppServer,
              let reservation = taskChildReservations[taskID],
              await authenticateTaskRun(reservation.parent) == task.parentBinding,
              startingTaskChildren.insert(sessionID).inserted else { return .deferred }
        defer { startingTaskChildren.remove(sessionID); taskLaunchContexts[taskID]?.starting = false }
        taskLaunchContexts[taskID]?.starting = true
        let runID = UUID()
        beginTaskRun(sessionID: sessionID, runID: runID)
        guard let plan = taskRunPlans[sessionID], plan.claim.managedRunID == runID else { return .unknown }
        let opening = SessionOpening(approvedTask: task, firstMessage: "", modeFromUserDefault: context.modeFromUserDefault)
        do {
            let binding = try await withNewStart(provider: provider, projectID: context.projectID, opening: opening, draft: nil) {
                directory, toolchain in
                guard toolchain.capabilities.supportsListen, toolchain.capabilities.supportsRemote,
                      try await self.catalog.session(id: sessionID) == nil,
                      await self.supervisor.session(id: sessionID) == nil,
                      self.taskLaunchContexts[taskID]?.stopRequested == false,
                      await self.authenticateTaskRun(reservation.parent) == task.parentBinding else {
                    throw SessionTaskError.unauthorized
                }
                var effective = task.requestedChoices
                if effective.mode == nil { effective.mode = .askBeforeEdits }
                _ = try CodexLaunchSettings(effective)
                let run = ManagedTaskRun(taskID: taskID, sessionID: sessionID, runID: runID,
                    generation: plan.claim.generation, workingDirectory: directory, requestedChoices: task.requestedChoices)
                self.taskLaunchContexts[taskID]?.managedRun = run
                try await self.supervisor.createSession(ManagedSession(id: sessionID, provider: provider, workingDirectory: directory),
                    projectID: context.projectID, title: task.childName, openedBy: task.parentSessionID)
                guard self.taskLaunchContexts[taskID]?.stopRequested == false, !self.shuttingDown,
                      self.taskRunPlans[sessionID]?.lease === plan.lease, plan.lease.isEnabled,
                      await self.authenticateTaskRun(reservation.parent) == task.parentBinding else {
                    throw SessionTaskError.unauthorized
                }
                let (server, coordinator) = try await self.ensureCodex(card: sessionID, toolchain: toolchain,
                                                                         choices: effective, managedRun: run)
                guard let launch = await server.manager.managedLaunch(), let client = server.client,
                      self.taskLaunchContexts[taskID]?.stopRequested == false, !self.shuttingDown else {
                    _ = await self.tearDown(server, card: sessionID)
                    throw SessionTaskError.unverified
                }
                _ = await self.register(launch, runID: runID, provider: provider, server: server, tee: nil)
                await self.refreshTaskDiscovery(server: server, directory: directory)
                let thread = try await client.startManagedThread(workingDirectory: directory, choices: effective)
                guard self.taskLaunchContexts[taskID]?.stopRequested == false, !self.shuttingDown,
                      self.taskRunPlans[sessionID]?.lease === plan.lease, plan.lease.isEnabled,
                      await self.authenticateTaskRun(reservation.parent) == task.parentBinding else {
                    throw SessionTaskError.unauthorized
                }
                try await coordinator.bindManagedCreator(sessionID: sessionID, managedRunID: runID,
                                                         workingDirectory: directory, thread: thread)
                guard let binding = await self.supervisor.taskBinding(for: plan.claim),
                      binding.nativeSessionID == thread.identity.id,
                      self.taskLaunchContexts[taskID]?.stopRequested == false, !self.shuttingDown,
                      self.taskRunPlans[sessionID]?.lease === plan.lease, plan.lease.isEnabled else {
                    throw SessionTaskError.unverified
                }
                server.resumeSettings = thread.settings
                do {
                    try await self.catalog.recordLaunchChoices(task.requestedChoices, sessionID: sessionID,
                                                               rememberingInProject: false)
                } catch {
                    LoomLog.error(.catalog, "Managed task choices could not be recorded (\(LoomLog.category(of: error)))")
                }
                let settings = ManagedTaskEffectiveSettings(model: thread.settings.model, effort: thread.settings.effort,
                                                            permissionMode: thread.settings.mode.rawValue)
                let presentation = try ManagedTaskPresentation(run: run, binding: binding, effectiveSettings: settings,
                    status: thread.identity.initialStatus == .idle ? .ready : .unknown,
                    progress: [], permissions: [], canTakeOver: true)
                await self.publishManagedTaskPresentation(presentation)
                self.updateTaskQuiescenceObservers()
                return binding
            }
            guard taskLaunchContexts[taskID]?.stopRequested == false,
                  await authenticateTaskRun(reservation.parent) == task.parentBinding else {
                _ = await stopTaskChild(taskID: taskID, childSessionID: sessionID, binding: binding)
                return .started(binding: binding)
            }
            return .started(binding: binding)
        } catch {
            if await supervisor.runContext(runID: runID) != nil {
                _ = try? await stopConversation(sessionID: sessionID, expectedRunID: runID)
            } else { revokeTaskRun(sessionID: sessionID, runID: runID) }
            return .unknown
        }
    }

    /// The visible run is a fence, not a source of native identity. The live
    /// owned binding is resolved again before revocation and before Resume.
    public func takeOverManagedTask(taskID: UUID, expectedRunID: UUID, expectedGeneration: UUID,
                                    rows: UInt16 = 24, columns: UInt16 = 80,
                                    outputSink: (any TerminalOutputSink)? = nil) async throws -> RuntimeLaunch {
        guard !shuttingDown, let view = managedTaskPresentations[taskID], view.canTakeOver,
              view.run.runID == expectedRunID, view.run.generation == expectedGeneration,
              let binding = view.binding, let settings = view.effectiveSettings,
              let plan = taskRunPlans[view.run.sessionID], plan.claim.managedRunID == expectedRunID,
              plan.claim.generation == expectedGeneration, let revision = plan.lease.admit({ $0 }),
              await supervisor.taskBinding(for: plan.claim) == binding,
              taskRunPlans[view.run.sessionID]?.lease === plan.lease, plan.lease.permits(revision: revision),
              managedTaskPresentations[taskID]?.run == view.run, managedTaskPresentations[taskID]?.binding == binding,
              let coordinator = taskCoordinator else { throw SessionTaskError.staleBinding }
        var resumeChoices = ClaudeLaunchChoices()
        if managedTaskControllers[expectedRunID] != nil {
            guard let choices = managedClaudeTakeOverChoices(run: view.run, settings: settings) else {
                throw SessionTaskError.unverified
            }
            resumeChoices = choices
        }
        // Cancel the live run's write lease before any awaited store or Stop
        // operation, then durably fence both input and wake authority.
        guard plan.lease.revokeIfCurrent(revision: revision) else { throw SessionTaskError.staleBinding }
        revokeTaskRun(sessionID: binding.sessionID, runID: expectedRunID)
        try await coordinator.fence(taskID: taskID, binding: binding)
        guard case .verified = await stopTaskChild(taskID: taskID, childSessionID: binding.sessionID, binding: binding),
              let record = try await catalog.session(id: binding.sessionID),
              record.session.providerConversationID == binding.nativeSessionID,
              await supervisor.session(id: binding.sessionID)?.currentRun == nil else {
            throw SessionTaskError.unverified
        }
        return try await resumeConversation(sessionID: binding.sessionID, rows: rows, columns: columns,
                                            outputSink: outputSink, choices: resumeChoices)
    }

    func managedClaudeTakeOverChoices(run: ManagedTaskRun, settings: ManagedTaskEffectiveSettings) -> ClaudeLaunchChoices? {
        let selected = run.requestedChoices.mode ?? .askBeforeEdits
        let expected = selected == .ask ? HarnessMode.askBeforeEdits : selected
        guard let mode = settings.permissionMode, HarnessMode.fromStored(mode) == expected,
              let model = settings.model, ClaudeLaunchChoices.isSafeToken(model),
              let effort = settings.effort, ClaudeLaunchChoices.effortLevels.contains(effort) else { return nil }
        return ClaudeLaunchChoices(permissionMode: mode, model: model, effort: effort)
    }

    func submitManagedTaskInput(_ intent: SessionTaskInputIntent, context: SessionTaskLaunchContext) async -> SessionTaskInputEffect {
        let task = intent.task
        if let runID = context.managedRun?.runID, managedTaskControllers[runID] != nil {
            return await submitManagedClaudeInput(intent, context: context, binding: task.childBinding)
        }
        guard let run = context.managedRun, let binding = task.childBinding,
              binding.sessionID == run.sessionID, binding.managedRunID == run.runID, binding.generation == run.generation,
              let parent = taskRunPlans[task.parentSessionID], let child = taskRunPlans[run.sessionID],
              parent.claim.managedRunID == task.parentBinding.managedRunID, parent.claim.generation == task.parentBinding.generation,
              child.claim.managedRunID == run.runID, child.claim.generation == run.generation,
              let origin = taskChildReservations[task.id]?.parent,
              await authenticateTaskRun(origin) == task.parentBinding,
              await taskNativeStatus(binding) == .ready,
              let client = runs[run.runID]?.server?.client else { return .deferred }
        let purpose = SessionTaskExpectedInput.Purpose.child(taskID: task.id, roundID: intent.round.id,
                                                             operationID: intent.round.operationID)
        let pointer = "Sphyrna task: run \"$SPHYRNA_CLI\" task input --task \(task.id.uuidString.lowercased()) --round \(intent.round.id.uuidString.lowercased()) --operation \(intent.round.operationID.uuidString.lowercased()); report using task --help."
        let digest = Data(SHA256.hash(data: Data(pointer.utf8)))
        let clientID = UUID().uuidString.lowercased(), effect = SessionTaskInputEffectMarker()
        if taskLaunchContexts[task.id]?.firstInputEffect?.hasEffect != true {
            taskLaunchContexts[task.id]?.firstInputEffect = effect
        }
        guard await prepareTaskInput(purpose: purpose, binding: binding, digest: digest, effect: effect,
                                     requiresNativeReceipt: true, clientMessageID: clientID),
              let parentRevision = parent.lease.admit({ $0 }), let childRevision = child.lease.admit({ $0 }),
              taskLaunchContexts[task.id]?.stopRequested == false else {
            clearTaskExpectation(purpose, binding: binding)
            return .deferred
        }
        do {
            let turn = try await client.startTaskTurn(threadID: binding.nativeSessionID, text: pointer,
                clientMessageID: clientID, transaction: { write in
                    var result: Result<Int?, Error>?
                    let allowed = intent.attemptDelivery {
                        result = Result {
                            try parent.lease.withOptionalAdmission(revision: parentRevision) {
                                try child.lease.withOptionalAdmission(revision: childRevision) { try effect.write(write) }
                            }
                        }
                        return true
                    }
                    guard allowed, let result else { return nil }
                    return try result.get()
                })
            guard let turn else { clearTaskExpectation(purpose, binding: binding); return .deferred }
            guard confirmCodexTaskTurn(turn, purpose: purpose, binding: binding) else { return .unknown }
            let settings = managedTaskPresentations[task.id]?.effectiveSettings
            return .submitted(binding: binding, nativeTurnID: turn, actualModel: settings?.model,
                              actualEffort: settings?.effort, actualMode: HarnessMode.fromStored(settings?.permissionMode))
        } catch { return .unknown }
    }
}
