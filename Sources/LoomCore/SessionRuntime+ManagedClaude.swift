import CryptoKit
import Foundation

extension SessionRuntime {
    private func expectedManagedClaudeMode(_ run: ManagedTaskRun) -> HarnessMode {
        let selected = run.requestedChoices.mode ?? .askBeforeEdits
        return selected == .ask ? .askBeforeEdits : selected
    }

    /// The controller's output is already fenced at synchronous pipe ingress.
    /// This reducer retains only bounded presentation data and exact proof.
    func receiveManagedControllerEvent(_ event: ManagedTaskControllerEvent) async {
        let run = event.run
        guard let plan = taskRunPlans[run.sessionID], plan.claim.managedRunID == run.runID,
              plan.claim.generation == run.generation, plan.lease.isEnabled else { return }
        // Await ownership checks before taking the mutable snapshots below. A
        // submit or Stop may run while the supervisor actor is suspended.
        var observedBinding: SessionTaskBinding?
        switch event.kind {
        case let .initialized(nativeID?, cwd?, reported):
            guard HarnessMode.fromStored(reported.permissionMode) == expectedManagedClaudeMode(run),
                  let expected = run.expectedNativeSessionID,
                  nativeID.caseInsensitiveCompare(expected) == .orderedSame,
                  cwd.hasPrefix("/"), URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path ==
                    URL(fileURLWithPath: run.workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path,
                  let model = reported.model, ClaudeLaunchChoices.isSafeToken(model),
                  run.requestedChoices.model.map({ ClaudeDefaultModel.matches(default: $0, transcriptModel: model) }) ?? true,
                  run.requestedChoices.effort.map({ $0 == reported.effort }) ?? true else {
                plan.lease.invalidate()
                return
            }
            do { _ = try await supervisor.adoptConversation(runID: run.runID, conversationID: nativeID, transition: .bind) }
            catch { plan.lease.invalidate(); return }
            guard let actual = await supervisor.taskBinding(for: plan.claim),
                  actual.nativeSessionID.caseInsensitiveCompare(nativeID) == .orderedSame else { return }
            observedBinding = actual
        case let .inputObserved(observed):
            guard await supervisor.taskBinding(for: plan.claim) == observed.binding else { return }
        default: break
        }
        guard var state = managedTaskControllers[run.runID], state.run == run,
              taskRunPlans[run.sessionID]?.lease === plan.lease, plan.lease.isEnabled,
              let old = managedTaskPresentations[run.taskID], old.run == run else { return }
        var binding = old.binding, settings = old.effectiveSettings, status = old.status
        var progress = old.progress, permissions = old.permissions
        switch event.kind {
        case let .initialized(nativeID, cwd, reported):
            guard HarnessMode.fromStored(reported.permissionMode) == expectedManagedClaudeMode(run) else {
                plan.lease.invalidate()
                return
            }
            if nativeID == nil && cwd == nil {
                state.initialized = true
                settings = reported
            } else {
                guard nativeID != nil, cwd != nil, let actual = observedBinding else {
                    plan.lease.invalidate()
                    return
                }
                binding = actual
                settings = reported
                state.initialized = true
            }
        case let .inputObserved(observed):
            guard let expected = state.pendingInput, expected == observed.input,
                  state.effect?.hasEffect == true, binding == observed.binding else { return }
            state.observation = observed
            let purpose = SessionTaskExpectedInput.Purpose.child(taskID: run.taskID, roundID: expected.roundID,
                                                                 operationID: expected.operationID)
            let digest = Data(SHA256.hash(data: Data(expected.pointer.utf8)))
            var proof: SessionTaskExpectedInput
            if let prepared = taskExpectedInputs[run.runID] {
                guard prepared.purpose == purpose, prepared.binding == observed.binding,
                      prepared.digest == digest, prepared.effect === state.effect else { plan.lease.invalidate(); return }
                proof = prepared
            } else {
                // The first Claude input is sent before the native ID exists;
                // its controller supplies the binding only after system/init.
                guard expected.binding == nil else { plan.lease.invalidate(); return }
                proof = SessionTaskExpectedInput(purpose: purpose, binding: observed.binding, digest: digest,
                    ticket: nil, effect: state.effect!, requiresNativeReceipt: false,
                    clientMessageID: nil, rolloutCandidate: nil)
            }
            proof.observed = observed.execution
            taskExpectedInputs[run.runID] = proof
            acceptTaskObservation(proof)
        case let .status(value):
            switch value {
            case .ready where binding != nil && permissions.isEmpty: status = .ready
            case .working: status = .working
            case .waitingForUser: status = .waitingForUser
            case .notStarted: status = .notStarted
            default: status = .unknown
            }
        case let .progress(value):
            progress.append(value)
            while progress.count > ManagedTaskPresentation.maximumProgressRows ||
                    progress.reduce(0, { $0 + $1.text.utf8.count }) > ManagedTaskPresentation.maximumProgressBytes {
                progress.removeFirst()
            }
        case let .permissionRequested(occurrence):
            guard let pending = state.pendingInput, let observed = state.observation,
                  occurrence.taskID == run.taskID, occurrence.binding == binding,
                  occurrence.roundID == pending.roundID, occurrence.operationID == pending.operationID,
                  observed.input == pending, !permissions.contains(where: { $0.id == occurrence.id }),
                  permissions.count < ManagedTaskPresentation.maximumPermissions else {
                plan.lease.invalidate()
                return
            }
            permissions.append(occurrence)
            status = .waitingForUser
        case let .permissionResolved(id):
            permissions.removeAll { $0.id == id }
        case .turnEnded:
            break // Native end is not a task result.
        case .ended:
            status = .unknown
            permissions.removeAll()
        }
        guard taskRunPlans[run.sessionID]?.lease === plan.lease, plan.lease.isEnabled,
              managedTaskControllers[run.runID]?.run == run else { return }
        managedTaskControllers[run.runID] = state
        guard let view = try? ManagedTaskPresentation(run: run, binding: binding, effectiveSettings: settings,
            status: status, progress: status == .unknown || status == .stopped ? [] : progress, permissions: permissions,
            canTakeOver: binding != nil && settings.flatMap({ managedClaudeTakeOverChoices(run: run, settings: $0) }) != nil) else {
            plan.lease.invalidate()
            return
        }
        await publishManagedTaskPresentation(view)
        let activity: AgentActivity = switch status {
        case .ready: .atPrompt
        case .working: .working
        case .waitingForUser: .waitingForApproval
        default: .unknown
        }
        guard taskRunPlans[run.sessionID]?.lease === plan.lease, plan.lease.isEnabled,
              managedTaskPresentations[run.taskID]?.run == run,
              managedTaskPresentations[run.taskID]?.status == status else { return }
        try? await supervisor.updateProviderWorkState(runID: run.runID, state: ProviderWorkState(activity: activity))
    }

    private func managedControllerCondition(runID: UUID, operationID: UUID?) -> Bool {
        guard let state = managedTaskControllers[runID] else { return false }
        if let operationID { return state.observation?.input.operationID == operationID }
        return state.initialized
    }

    private func managedControllerIsLive(runID: UUID) -> Bool {
        guard let state = managedTaskControllers[runID], let plan = taskRunPlans[state.run.sessionID],
              plan.claim.managedRunID == runID, plan.claim.generation == state.run.generation else { return false }
        return plan.lease.isEnabled && !shuttingDown
    }

    private func waitForManagedController(runID: UUID, operationID: UUID? = nil) async -> Bool {
        let stream = await supervisor.events.subscribe()
        if managedControllerCondition(runID: runID, operationID: operationID) { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                for await _ in stream {
                    guard !Task.isCancelled, let self else { return false }
                    if await self.managedControllerCondition(runID: runID, operationID: operationID) { return true }
                    if !(await self.managedControllerIsLive(runID: runID)) { return false }
                }
                return false
            }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func submitInitialManagedClaudeTaskInput(_ intent: SessionTaskInputIntent, context: SessionTaskLaunchContext,
                                             provider: ManagedSession.Provider) async -> SessionTaskInputEffect {
        let task = intent.task, taskID = task.id, sessionID = task.childSessionID
        if context.managedRun != nil { return await submitManagedClaudeInput(intent, context: context, binding: nil) }
        guard task.requestedChoices.claudeChoices != nil, !context.starting,
              let factory = configuration.managedClaudeControllerFactory,
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
            _ = try await withNewStart(provider: provider, projectID: context.projectID, opening: opening, draft: nil) {
                directory, toolchain in
                guard try await self.catalog.session(id: sessionID) == nil,
                      await self.supervisor.session(id: sessionID) == nil,
                      self.taskLaunchContexts[taskID]?.stopRequested == false,
                      await self.authenticateTaskRun(reservation.parent) == task.parentBinding else {
                    throw SessionTaskError.unauthorized
                }
                let run = ManagedTaskRun(taskID: taskID, sessionID: sessionID, runID: runID,
                    generation: plan.claim.generation, workingDirectory: directory, requestedChoices: task.requestedChoices,
                    expectedNativeSessionID: sessionID.uuidString)
                let ingress = ManagedTaskIngress(begin: { plan.lease.beginHook() }, end: { plan.lease.finishHook() },
                    invalidate: { plan.lease.invalidate() }, emit: { [weak self] event in
                        guard let self else { return }
                        await self.receiveManagedControllerEvent(event)
                    })
                let controller = try factory(run, ingress)
                self.taskLaunchContexts[taskID]?.managedRun = run
                self.managedTaskControllers[runID] = ManagedTaskControllerState(run: run, controller: controller)
                let initial = try ManagedTaskPresentation(run: run, binding: nil, effectiveSettings: nil,
                    status: .notStarted, progress: [], permissions: [], canTakeOver: false)
                await self.publishManagedTaskPresentation(initial)
                return try await self.startClaude(sessionID: sessionID, projectID: context.projectID,
                    directory: directory, toolchain: toolchain, opening: opening, draft: nil, face: .managedTask) { profile in
                    await self.harnesses.claude.handOverWorkState(runID: runID)
                    guard let coordinator = self.taskCoordinator else { throw SessionTaskError.unverified }
                    try await coordinator.beginManagedLaunch(taskID: taskID, childID: sessionID,
                                                              runID: runID, generation: run.generation)
                    guard await self.mayOpenManagedTaskScope(run) else {
                        try? await coordinator.confirmManagedLaunchNoEffect(taskID: taskID, childID: sessionID,
                                                                           runID: runID, generation: run.generation)
                        throw SessionTaskError.unverified
                    }
                    let scope = try await self.supervisor.openScope()
                    await self.managedScopeOpenedForTesting?(run)
                    guard await self.mayOpenManagedTaskScope(run) else {
                        if (await self.supervisor.releaseScope(scope)).isEmpty {
                            try? await coordinator.confirmManagedLaunchNoEffect(taskID: taskID, childID: sessionID,
                                                                               runID: runID, generation: run.generation)
                        }
                        throw SessionTaskError.unverified
                    }
                    let scoped = ManagedTaskScopeBinding(taskID: taskID, sessionID: sessionID, runID: runID,
                        generation: plan.claim.generation, ownerRunID: self.supervisor.ownershipRunID, scope: scope.record)
                    do {
                        try await self.supervisor.registerManagedScope(scoped, scope: scope)
                        try await coordinator.prepareManagedScope(scoped)
                        guard await self.supervisor.managedScopeIsOpen(scoped, scope: scope),
                              self.taskLaunchContexts[taskID]?.stopRequested == false, !self.shuttingDown,
                              self.taskRunPlans[sessionID]?.lease === plan.lease, plan.lease.isEnabled,
                              await self.authenticateTaskRun(reservation.parent) == task.parentBinding else {
                            throw SessionTaskError.unauthorized
                        }
                        let launch = try await self.supervisor.launchPipes(sessionID: sessionID, executable: toolchain.executable,
                            arguments: profile.launchArguments(extra: toolchain.extraArguments), environment: profile.environment,
                            outputSink: controller.outputSink, managedRunID: runID, scope: scope)
                        self.runs[runID] = RunRecord(runID: runID, launchSessionID: sessionID, provider: provider,
                            server: nil, startedAt: Date(), isResume: false, diagnostics: nil,
                            endpoint: .pipe(launch.pipe), activeSession: sessionID)
                        try await controller.attach(pipe: launch.pipe)
                        return RuntimePipeLaunch(sessionID: sessionID, runID: runID, pipe: launch.pipe)
                    } catch {
                        if await self.supervisor.runContext(runID: runID) != nil {
                            _ = try? await self.stopConversation(sessionID: sessionID, expectedRunID: runID)
                        } else {
                            let errors = await self.supervisor.releaseScope(scope)
                            if !errors.isEmpty { throw LoomError.message("Managed task scope cleanup could not be verified") }
                            try? await coordinator.confirmManagedLaunchNoEffect(taskID: taskID, childID: sessionID,
                                                                               runID: runID, generation: run.generation)
                        }
                        throw error
                    }
                }
            }
            guard let current = taskLaunchContexts[taskID], current.stopRequested == false,
                  await authenticateTaskRun(reservation.parent) == task.parentBinding else {
                _ = await stopTaskChild(taskID: taskID, childSessionID: sessionID, binding: nil)
                return .unknown
            }
            return await submitManagedClaudeInput(intent, context: current, binding: nil)
        } catch {
            if await supervisor.runContext(runID: runID) != nil {
                _ = try? await stopConversation(sessionID: sessionID, expectedRunID: runID)
            } else { revokeTaskRun(sessionID: sessionID, runID: runID) }
            // A launch that never reached `scoped` never sent its provider SPAWN; the store refuses any other phase.
            try? await taskCoordinator?.confirmManagedLaunchNotAdmitted(taskID: taskID, childID: sessionID, runID: runID,
                                                                       generation: plan.claim.generation)
            if let controller = managedTaskControllers.removeValue(forKey: runID)?.controller { await controller.close() }
            return .unknown
        }
    }

    func submitManagedClaudeInput(_ intent: SessionTaskInputIntent, context: SessionTaskLaunchContext,
                                  binding: SessionTaskBinding?) async -> SessionTaskInputEffect {
        let task = intent.task
        guard let run = context.managedRun, managedTaskControllers[run.runID]?.run == run,
              let parent = taskRunPlans[task.parentSessionID], let child = taskRunPlans[run.sessionID],
              parent.claim.managedRunID == task.parentBinding.managedRunID, parent.claim.generation == task.parentBinding.generation,
              child.claim.managedRunID == run.runID, child.claim.generation == run.generation,
              let origin = taskChildReservations[task.id]?.parent,
              await authenticateTaskRun(origin) == task.parentBinding,
              await waitForManagedController(runID: run.runID),
              var state = managedTaskControllers[run.runID], state.run == run,
              taskRunPlans[run.sessionID]?.lease === child.lease, child.lease.isEnabled else { return .deferred }
        if let binding {
            guard await taskNativeStatus(binding) == .ready else { return .deferred }
        } else {
            guard intent.round.ordinal == 1, task.childBinding == nil else { return .unknown }
        }
        let pointer = "Sphyrna task: run \"$SPHYRNA_CLI\" task input --task \(task.id.uuidString.lowercased()) --round \(intent.round.id.uuidString.lowercased()) --operation \(intent.round.operationID.uuidString.lowercased()); report using task --help."
        guard let input = try? ManagedTaskInput(run: run, roundID: intent.round.id, operationID: intent.round.operationID,
                                                binding: binding, clientMessageID: UUID(), pointer: pointer) else { return .deferred }
        let effect = SessionTaskInputEffectMarker()
        let purpose = SessionTaskExpectedInput.Purpose.child(taskID: task.id, roundID: intent.round.id,
                                                             operationID: intent.round.operationID)
        if let binding {
            let digest = Data(SHA256.hash(data: Data(pointer.utf8)))
            guard await prepareTaskInput(purpose: purpose, binding: binding, digest: digest, effect: effect) else { return .deferred }
        }
        // Re-read after the Ready/status await so we do not replace native
        // identity or a newer operation with a stale controller snapshot.
        guard let latest = managedTaskControllers[run.runID], latest.run == run,
              latest.pendingInput == nil || latest.observation != nil,
              taskRunPlans[run.sessionID]?.lease === child.lease, child.lease.isEnabled,
              let parentRevision = parent.lease.admit({ $0 }), let childRevision = child.lease.admit({ $0 }),
              taskLaunchContexts[task.id]?.stopRequested == false else {
            if let binding { clearTaskExpectation(purpose, binding: binding) }
            return .deferred
        }
        state = latest
        if taskLaunchContexts[task.id]?.firstInputEffect?.hasEffect != true { taskLaunchContexts[task.id]?.firstInputEffect = effect }
        state.pendingInput = input; state.effect = effect; state.observation = nil
        managedTaskControllers[run.runID] = state
        let outcome = await state.controller.submit(input, admission: { write in
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
        switch outcome {
        case .deferred:
            if !effect.hasEffect, managedTaskControllers[run.runID]?.pendingInput == input {
                managedTaskControllers[run.runID]?.pendingInput = nil
                managedTaskControllers[run.runID]?.effect = nil
            }
            if let binding { clearTaskExpectation(purpose, binding: binding) }
            return .deferred
        case .unknown: return .unknown
        case .submitted: break
        }
        guard await waitForManagedController(runID: run.runID, operationID: input.operationID),
              let current = managedTaskControllers[run.runID], current.pendingInput == input,
              let observed = current.observation, observed.input == input,
              await authenticateTaskRun(child.claim) == observed.binding,
              taskRunPlans[run.sessionID]?.lease === child.lease, child.lease.isEnabled else { return .unknown }
        let nativeTurn: String?
        if case let .nativeTurn(id) = observed.execution { nativeTurn = id } else { nativeTurn = nil }
        let settings = managedTaskPresentations[task.id]?.effectiveSettings
        return .submitted(binding: observed.binding, nativeTurnID: nativeTurn, actualModel: settings?.model,
                          actualEffort: settings?.effort, actualMode: HarnessMode.fromStored(settings?.permissionMode))
    }
}
