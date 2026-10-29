import Foundation
import LoomCore

typealias ManagedClaudeTaskWriter = @Sendable (Data, @escaping ManagedTaskWriteAdmission) async -> ManagedTaskWriteOutcome

/// Claude's task-only stream-json controller. The runtime owns the process;
/// this object owns only its bounded protocol state and exact request replies.
/// It neither enables the Chat product nor generates a session title.
public actor ManagedClaudeTaskController: ManagedTaskController {
    public nonisolated let outputSink: any PipeOutputSink
    private nonisolated let sink: ManagedClaudeTaskSink
    private let run: ManagedTaskRun
    private let ingress: ManagedTaskIngress
    private let fence = ManagedClaudeWriteFence()
    private var pipe: PipeEndpoint?
    private var writer: ManagedClaudeTaskWriter?
    private var reader: Task<Void, Never>?
    private var closed = false
    private var initialized = false
    private let initializeID = "sphyrna-managed-init-" + UUID().uuidString.lowercased()
    private var resolvedModels = Set<String>()
    private var binding: SessionTaskBinding?
    private var lifecycleSupported = false
    private var submittedInputs = 0
    private var active: InputState?
    private var pending: [UUID: PermissionState] = [:]
    private var earlyRequests: [IncomingControlRequest] = []
    private var answering = Set<UUID>()
    private var progress = ""
    private var interrupting = false
    private var interruptRequestID: String?
    private var interruptReply: Bool?
    private var interruptSupported = false
    private var lastEnded: SessionTaskExecutionReference?

    private struct InputState {
        let input: ManagedTaskInput
        var written = false
        var consumed = false
        var nativeStarted = false
        var observed = false
        var result: TurnResult?
        let executionFence = ManagedClaudeWriteFence()
        var execution: SessionTaskExecutionReference { .appInputObservation(input.clientMessageID) }
    }

    private struct PermissionState {
        let occurrence: ManagedTaskPermissionOccurrence
        let tool: ToolPermissionRequest
    }

    public init(run: ManagedTaskRun, ingress: ManagedTaskIngress) throws {
        guard run.requestedChoices.harness == .claude,
              run.expectedNativeSessionID.flatMap(UUID.init(uuidString:)) != nil,
              run.requestedChoices.mode != .fullAccess else { throw SessionTaskError.invalidPayload }
        self.run = run
        self.ingress = ingress
        let sink = ManagedClaudeTaskSink(ingress: ingress)
        self.sink = sink
        outputSink = sink
    }

    deinit {
        fence.revoke()
        sink.close()
        reader?.cancel()
    }

    public func attach(pipe: PipeEndpoint) async throws {
        guard self.pipe == nil, writer == nil, !closed else { throw SessionTaskError.staleBinding }
        self.pipe = pipe
        try await connect { frame, admission in await pipe.writeManaged(frame, admission: admission) }
    }

    /// An injected wire is used only by deterministic protocol tests. The
    /// public factory always attaches the supervisor-owned pipe.
    func connect(writer: @escaping ManagedClaudeTaskWriter) async throws {
        guard self.writer == nil, !closed else { throw SessionTaskError.staleBinding }
        self.writer = writer
        let sink = self.sink
        reader = Task { [weak self, sink] in
            for await batch in sink.batches {
                guard let self, !Task.isCancelled else { sink.close(); break }
                await self.apply(batch)
                sink.applied(batch.id)
            }
            await self?.outputEnded()
        }
        do {
            try Task.checkCancellation()
            let outcome = await write(ControlWire.requestLine(id: initializeID, .initialize)) { try $0() }
            guard outcome == .submitted else { throw SessionTaskError.unverified }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !initialized, !closed, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            guard initialized, !closed else { throw SessionTaskError.unverified }
        } catch {
            await fail()
            throw error
        }
    }

    public func submit(_ input: ManagedTaskInput,
                       admission: @escaping ManagedTaskWriteAdmission) async -> ManagedTaskWriteOutcome {
        guard !closed, initialized, input.run == run, active == nil,
              pending.isEmpty, earlyRequests.isEmpty, !interrupting,
              (submittedInputs == 0 && input.binding == nil) ||
                (binding != nil && input.binding == binding) else { return .deferred }
        active = InputState(input: input)
        let frame = OutgoingUserMessage(uuid: input.clientMessageID.uuidString.lowercased(), text: input.pointer).line()
        let outcome = await write(frame, admission: admission)
        guard !closed, active?.input == input else { return .unknown }
        switch outcome {
        case .submitted:
            submittedInputs += 1
            active?.written = true
            await observeInput()
            if let result = active?.result { await endTurn(result) }
        case .deferred:
            if active?.consumed == true { await fail(); return .unknown }
            active = nil
        case .unknown:
            await fail()
        }
        return outcome
    }

    public func respond(occurrenceID: UUID, decision: ManagedTaskUserDecision,
                        admission: @escaping ManagedTaskWriteAdmission) async -> ManagedTaskWriteOutcome {
        guard !closed, let state = pending[occurrenceID], let active, active.observed,
              state.occurrence.binding == binding,
              state.occurrence.operationID == active.input.operationID,
              !answering.contains(occurrenceID),
              let nativeID = state.occurrence.nativeRequestID.string,
              let answer = permissionDecision(decision, for: state) else { return .deferred }
        answering.insert(occurrenceID)
        defer { answering.remove(occurrenceID) }
        let outcome = await write(ControlWire.successLine(id: nativeID, answer.payload), admission: admission)
        if outcome == .unknown { await fail(); return .unknown }
        if outcome == .submitted, pending.removeValue(forKey: occurrenceID) != nil {
            await emit(.permissionResolved(occurrenceID))
            if pending.isEmpty { await emit(.status(.working)) }
        }
        return outcome
    }

    public func interrupt(_ target: SessionTaskRoundTarget,
                          admission: @escaping ManagedTaskWriteAdmission) async -> SessionTaskEffect {
        guard !closed, !interrupting, interruptSupported, let active, active.observed,
              target.binding == binding, target.taskID == run.taskID,
              target.roundID == active.input.roundID, target.inputOperationID == active.input.operationID,
              target.execution == active.execution else { return .deferred }
        interrupting = true
        defer { interrupting = false; interruptRequestID = nil; interruptReply = nil }
        let execution = active.execution
        let requestID = "sphyrna-managed-stop-" + UUID().uuidString.lowercased()
        interruptRequestID = requestID
        interruptReply = nil
        let executionFence = active.executionFence
        let outcome = await write(ControlWire.requestLine(id: requestID, .interrupt(cancelQueued: false))) { syscall in
            try executionFence.attempt { try admission(syscall) }
        }
        if outcome == .deferred { return .deferred }
        guard outcome == .submitted else { await fail(); return .unknown }
        // An interrupt receipt can precede the tools' drain. No successor
        // input is admitted until the exact native result has ended this turn.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !closed, interruptReply != false,
              (lastEnded != execution || interruptReply != true), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { await fail(); return .unknown }
        }
        if !closed, lastEnded == execution, interruptReply == true { return .verified }
        await fail()
        return .unknown
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        fence.revoke()
        sink.close()
        reader?.cancel()
        reader = nil
        writer = nil
        active?.executionFence.revoke()
        active = nil
        pending.removeAll()
        earlyRequests.removeAll()
        progress = ""
        let pipe = self.pipe
        self.pipe = nil
        await pipe?.closeInput()
    }

    private func write(_ frame: Data,
                       admission: @escaping ManagedTaskWriteAdmission) async -> ManagedTaskWriteOutcome {
        guard !closed, let writer else { return .deferred }
        let fence = self.fence
        return await writer(frame) { syscall in try fence.attempt { try admission(syscall) } }
    }

    private func apply(_ batch: ManagedClaudeTaskSink.Batch) async {
        guard !closed else { return }
        for frame in batch.frames {
            guard !closed else { break }
            guard case let .message(message) = frame else { await fail(); break }
            await receive(message)
        }
        if !closed, !progress.isEmpty {
            if let item = try? ManagedTaskProgress(kind: .message, text: progress) { await emit(.progress(item)) }
            progress = ""
        }
    }

    private func receive(_ message: StreamMessage) async {
        switch message {
        case let .controlResponse(response) where response.requestID == initializeID:
            guard !initialized, case let .success(payload) = response.outcome else { await fail(); return }
            let info = InitializeResponse(json: payload)
            guard info.currentPermissionMode == expectedMode else { await fail(); return }
            if let wanted = run.requestedChoices.model {
                resolvedModels.insert(wanted)
                for model in info.models where model.value == wanted {
                    if let resolved = model.resolvedModel { resolvedModels.insert(resolved) }
                }
            }
            await emit(.initialized(nativeSessionID: nil, workingDirectory: nil,
                                    settings: .init(model: nil, effort: nil, permissionMode: info.currentPermissionMode)))
            guard !closed else { return }
            await emit(.status(.ready))
            guard !closed else { return }
            initialized = true
        case let .controlResponse(response) where response.requestID == interruptRequestID:
            guard case let .success(payload) = response.outcome,
                  let queued = payload["still_queued"]?.array, queued.isEmpty,
                  let cancelled = payload["cancelled"]?.array, cancelled.isEmpty else {
                interruptReply = false
                return
            }
            interruptReply = true
        case let .systemInit(info):
            guard initialized, let id = info.sessionID,
                  UUID(uuidString: id) == run.expectedNativeSessionID.flatMap(UUID.init(uuidString:)),
                  let cwd = info.cwd, sameDirectory(cwd, run.workingDirectory),
                  info.permissionMode == expectedMode,
                  run.requestedChoices.effort == nil || info.effort == run.requestedChoices.effort,
                  run.requestedChoices.model == nil || info.model.map(resolvedModels.contains) == true else {
                await fail(); return
            }
            let observed = SessionTaskBinding(sessionID: run.sessionID, nativeSessionID: id,
                                             managedRunID: run.runID, generation: run.generation)
            guard binding == nil || binding == observed else { await fail(); return }
            binding = observed
            lifecycleSupported = info.capabilities?.contains("msg_lifecycle_v1") == true
            interruptSupported = info.capabilities?.contains("interrupt_receipt_v1") == true
            await emit(.initialized(nativeSessionID: id, workingDirectory: cwd,
                                    settings: .init(model: info.model, effort: info.effort, permissionMode: info.permissionMode)))
            await observeInput()
        case let .commandLifecycle(lifecycle):
            guard let active, lifecycle.commandUUID.lowercased() == active.input.clientMessageID.uuidString.lowercased() else {
                // The preceding turn may publish its final lifecycle after
                // its result. Any other command belongs to an unowned input.
                if lifecycle.state == .completed,
                   let id = UUID(uuidString: lifecycle.commandUUID), lastEnded == .appInputObservation(id) { return }
                await fail()
                return
            }
            if lifecycle.state == .started {
                self.active?.nativeStarted = true
                await observeInput()
            } else if lifecycle.state == .cancelled || lifecycle.state == nil { await fail() }
        case let .user(user):
            if user.hasToolResult {
                let ids = Set(user.content.compactMap { block -> String? in
                    if case let .toolResult(result) = block { result.toolUseID } else { nil }
                })
                for (id, item) in pending where item.tool.toolUseID.map(ids.contains) == true {
                    pending[id] = nil
                    await emit(.permissionResolved(id))
                }
                return
            }
            guard user.parentToolUseID == nil, !user.isMeta, user.originKind != "task-notification" else { return }
            guard let active, user.isReplay,
                  user.uuid?.lowercased() == active.input.clientMessageID.uuidString.lowercased(),
                  user.text == active.input.pointer, user.originKind == "human",
                  user.sessionID.flatMap(UUID.init(uuidString:)) == run.expectedNativeSessionID.flatMap(UUID.init(uuidString:)) else {
                await fail(); return
            }
            self.active?.consumed = true
            await observeInput()
        case let .controlRequest(request):
            await permission(request)
        case let .controlCancel(id):
            earlyRequests.removeAll { $0.requestID == id }
            for (key, item) in pending where item.occurrence.nativeRequestID.string == id {
                pending[key] = nil
                await emit(.permissionResolved(key))
            }
        case let .result(result): await endTurn(result)
        case let .streamEvent(event) where event.parentToolUseID == nil:
            if case let .blockDelta(_, .text(text)) = event.event { appendProgress(text) }
        case let .assistant(message) where message.parentToolUseID == nil && !message.isSidechain:
            for case let .text(text) in message.content { appendProgress(text) }
        case let .status(status):
            if let mode = status.permissionMode, mode != expectedMode { await fail() }
        case .conversationReset: await fail()
        case let .unknown(message):
            if ["control_request", "control_response", "control_cancel_request", "command_lifecycle"].contains(message.type ?? "") {
                await fail()
            }
        default: break
        }
    }

    private func observeInput() async {
        guard let active, active.written, (active.consumed || (active.nativeStarted && lifecycleSupported)),
              !active.observed, let binding,
              let observation = try? ManagedTaskInputObservation(input: active.input, binding: binding,
                                                                 execution: active.execution) else { return }
        self.active?.observed = true
        await emit(.inputObserved(observation))
        guard !closed else { return }
        await emit(.status(.working))
        let requests = earlyRequests
        earlyRequests.removeAll()
        for request in requests { await permission(request) }
    }

    private func permission(_ request: IncomingControlRequest) async {
        guard !closed, let active else { await fail(); return }
        guard case let .canUseTool(tool) = request.kind else { await fail(); return }
        guard !earlyRequests.contains(where: { $0.requestID == request.requestID }),
              !pending.values.contains(where: { $0.occurrence.nativeRequestID.string == request.requestID }),
              pending.count + earlyRequests.count < 8 else { await fail(); return }
        guard active.observed, let binding else { earlyRequests.append(request); return }
        let summary = ChatPendingRequest(requestID: request.requestID, request: tool, arrivedAt: Date()).summary
        guard let occurrence = try? ManagedTaskPermissionOccurrence(id: UUID(), binding: binding, taskID: run.taskID,
            roundID: active.input.roundID, operationID: active.input.operationID,
            nativeRequestID: .string(request.requestID), request: summary, originalInput: tool.input) else {
            await fail(); return
        }
        pending[occurrence.id] = PermissionState(occurrence: occurrence, tool: tool)
        await emit(.permissionRequested(occurrence))
        await emit(.status(.waitingForUser))
    }

    private func permissionDecision(_ decision: ManagedTaskUserDecision, for state: PermissionState) -> PermissionDecision? {
        switch decision {
        case .allow:
            guard state.occurrence.request.kind == .approval else { return nil }
            return .allow(updatedInput: state.tool.input, toolUseID: state.tool.toolUseID)
        case .deny:
            return .deny(message: ChatRequestAnswer.defaultDenyMessage)
        case let .answer(value):
            guard state.occurrence.request.kind == .question, let answers = value.object,
                  let questions = state.tool.input["questions"]?.array, !questions.isEmpty,
                  let original = state.tool.input.object,
                  questions.compactMap({ $0["question"]?.string }).count == questions.count,
                  Set(questions.compactMap { $0["question"]?.string }).count == questions.count,
                  Set(answers.keys) == Set(questions.compactMap { $0["question"]?.string }),
                  answers.values.allSatisfy({ $0.string?.isEmpty == false }),
                  let bytes = try? JSONEncoder().encode(value), bytes.count <= 16 * 1024 else { return nil }
            var input = original
            input["answers"] = value
            return .allow(updatedInput: .object(input), toolUseID: state.tool.toolUseID)
        }
    }

    private func endTurn(_ result: TurnResult) async {
        guard let active else { return }
        guard active.written else { self.active?.result = result; return }
        guard active.observed, pending.isEmpty, earlyRequests.isEmpty,
              result.sessionID.flatMap(UUID.init(uuidString:)) == run.expectedNativeSessionID.flatMap(UUID.init(uuidString:)),
              (result.queuedTurnCount ?? 0) == 0 else { await fail(); return }
        appendProgress(result.result ?? "")
        active.executionFence.revoke()
        self.active = nil
        lastEnded = active.execution
        await emit(.turnEnded(execution: active.execution, failed: result.isError))
        guard !closed else { return }
        await emit(.status(.ready))
    }

    private var expectedMode: String {
        run.requestedChoices.mode.flatMap { ClaudePermissionMode(rawValue: $0.rawValue) }?
            .launchValue(chat: false) ?? "default"
    }

    private func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardized.path ==
            URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardized.path
    }

    private func appendProgress(_ text: String) {
        let bytes = (progress + String(text.prefix(ManagedTaskProgress.maximumTextBytes))).utf8
        progress = String(decoding: bytes.suffix(ManagedTaskProgress.maximumTextBytes), as: UTF8.self)
        // Cutting a UTF-8 scalar can add a replacement character; keep the
        // encoded payload inside the display contract after that replacement.
        while progress.utf8.count > ManagedTaskProgress.maximumTextBytes { progress.removeFirst() }
    }

    private func emit(_ kind: ManagedTaskControllerEvent.Kind) async {
        await ingress.emit(.init(run: run, kind: kind))
    }

    private func fail() async {
        guard !closed else { return }
        fence.revoke()
        sink.close(invalid: true)
        await close()
        await emit(.status(.unknown))
        await emit(.ended)
    }

    private func outputEnded() async {
        guard !closed else { return }
        let wasActive = active != nil || !pending.isEmpty
        if wasActive { await fail() }
        else { await close(); await emit(.ended) }
    }
}
