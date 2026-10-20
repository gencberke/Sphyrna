import Foundation
import LoomCore

extension ChatSessionDriver {
    // MARK: Requests (cards)

    /// Answers a waiting request with a decision. A denial with `interrupt` stops the turn ("Deny and stop"). `record` is
    /// the one line the stream keeps of the card.
    public func respond(to requestID: String, with decision: PermissionDecision,
                        record: RequestRecord? = nil) async throws {
        // Nothing is answered while the session stops: the Stop's interrupt withdraws every request.
        guard phase != .stopping else { throw ChatDriverError.stopping }
        guard let current = run, let request = requests.first(where: { $0.requestID == requestID }) else {
            throw ChatDriverError.noSuchRequest(requestID)
        }
        // One answer per request: a second call, while the first is on its way, is refused before it touches anything.
        guard answering.insert(requestID).inserted else { throw ChatDriverError.answerInProgress }
        defer { answering.remove(requestID) }
        let stops: Bool
        if case .deny(_, true) = decision { stops = true } else { stops = false }
        if stops {
            model.noteInterruptSent()
            // Deny and stop ends the turn like an interrupt does: nothing queued goes out behind it.
            if !queue.isEmpty, queue.paused == nil { pauseQueue(.interrupted) }
        }
        guard await current.channel.respond(to: requestID, with: decision) else {
            if stops { model.clearInterruptSent() }
            // Still waiting: the answer could not be queued (the input is full); the card stays answerable.
            if await current.channel.pendingRequests.contains(where: { $0.requestID == requestID }) {
                throw ChatDriverError.inputFull
            }
            await retire(requestID: requestID, as: .resolved, summary: "No longer waiting: \(request.subject)")
            await afterRequestsChanged()
            throw ChatDriverError.noSuchRequest(requestID)
        }
        // The CLI withdrew it while the answer was on its way: its "Cancelled" line stands, and no "Allowed once" joins it.
        guard requests.contains(where: { $0.requestID == requestID }) else { return }
        if let record { note(model.recordRequest(record, at: clock())) }
        await retire(requestID: requestID, as: .answered, summary: record?.summary ?? "Answered: \(request.subject)")
        await afterRequestsChanged()
        // Messages the CLI holds unread come back as drafts, as on an interrupt.
        if stops, !unreadRows.isEmpty, let again = run {
            await sendInterrupt(on: again.channel, timeout: 10)
        }
    }

    /// A card's answer, as the user gave it: builds the decision and the stream's line from the request and sends it. A
    /// plan approval also records the mode as the session's choice (in the mode chain).
    public func answer(requestID: String, _ answer: ChatRequestAnswer) async throws {
        if case .approvePlan = answer {
            try await serialMode { try await answerNow(requestID: requestID, answer) }
        } else {
            try await answerNow(requestID: requestID, answer)
        }
    }

    private func answerNow(requestID: String, _ answer: ChatRequestAnswer) async throws {
        guard phase != .stopping else { throw ChatDriverError.stopping }
        guard let request = requests.first(where: { $0.requestID == requestID }) else {
            throw ChatDriverError.noSuchRequest(requestID)
        }
        // Ask refuses every tool approval; none is allowed while it is on (a card that was waiting when Ask came on is
        // refused when Ask is chosen, so this is the defence for the one that arrives some other way).
        if isAsk {
            switch answer {
            case .allowOnce, .allowForSession: throw ChatDriverError.notOffered
            default: break
            }
        }
        let plan: ChatAnswerPlan
        // While Ask is on a plan is approved in Ask: any other mode would lift `dontAsk` and leave the deny rules with Bash open.
        var answer = answer
        if isAsk, case .approvePlan = answer { answer = .approvePlan(mode: ClaudePermissionMode.ask.rawValue) }
        do { plan = try request.answerPlan(for: answer) } catch let error as ChatAnswerError {
            throw error == .incomplete ? ChatDriverError.incompleteAnswer : ChatDriverError.notOffered
        }
        try await respond(to: requestID, with: plan.decision, record: plan.record)
        // A mode a plan approval, or an "Allow for this session" that carries `setMode`, sets is the session's choice.
        if let mode = plan.mode {
            let wire = ClaudePermissionMode(rawValue: mode)?.cliValue ?? mode
            permissionMode = wire
            model.noteMarkedMode(wire)
            await recordChoices(ClaudeLaunchChoices(permissionMode: mode))
        }
    }

    /// A request leaves the list: on its own id only (the user's answer, the CLI withdrawing it) or its own `tool_use_id`
    /// finishing, never on a `result`. It is kept, settled, with the one line it leaves.
    private func retire(requestID: String, as outcome: ChatSettledRequest.Outcome, summary: String) async {
        if let request = requests.first(where: { $0.requestID == requestID }) { settle(request, as: outcome, summary: summary) }
        requests.removeAll { $0.requestID == requestID }
        changed()
        await publishRequests()
    }

    func settle(_ request: ChatPendingRequest, as outcome: ChatSettledRequest.Outcome, summary: String) {
        settled.append(ChatSettledRequest(request: request, outcome: outcome, summary: summary, settledAt: clock()))
        if settled.count > Self.settledLimit { settled.removeFirst(settled.count - Self.settledLimit) }
    }

    /// The run's pending requests, provider-independent, for Home, the sidebar and the Dock (and V18's cards).
    func publishRequests() async {
        await followRun()
        await runtime.supervisor.events.publish(
            sessionID: sessionID, change: .pendingRequests(requests.map(\.summary))
        )
    }

    func afterRequestsChanged() async {
        guard phase == .needsYou || phase == .working else { return }
        if requests.isEmpty, turnRunning {
            setPhase(.working)
            await publish(.working)
        } else if requests.isEmpty {
            setPhase(.ready)
        }
    }

    // MARK: Where a request becomes a card

    // The two cases of `ingest` that turn the CLI's control messages into cards. `ingest` ends with its `switch`, so a
    // `return` in either helper means the same as a `return` in the case did. Keep it that way: nothing may follow the
    // `switch` in `ingest`.

    /// A tool permission request arrived: it is listed (the card), the plan of an `ExitPlanMode` joins the stream, and the
    /// session needs the user.
    func receiveToolRequest(_ request: IncomingControlRequest, tool: ToolPermissionRequest, at now: Date) async {
        let agent = tool.agentID.map { id -> ChatRequestAgent in
            let task = model.subagentTask(agentID: id)
            return ChatRequestAgent(id: id, type: task?.subagentType, description: task?.description)
        }
        // A request that comes while Loom stops the run is withdrawn by the Stop's interrupt: it is never listed, so
        // no card shows it and nothing can answer it.
        guard phase != .stopping else { return }
        requests.append(ChatPendingRequest(requestID: request.requestID, request: tool, arrivedAt: now, agent: agent))
        if tool.toolName == "ExitPlanMode", let id = tool.toolUseID, let plan = tool.input["plan"]?.string {
            note(model.updatePlan(toolUseID: id, markdown: plan, filePath: tool.input["planFilePath"]?.string))
        }
        await publishRequests()
        await beginTurn()
        setPhase(.needsYou)
        await publish(.waitingForApproval)
    }

    /// The CLI withdrew a request (an interrupt, a Stop): the card folds as cancelled, and the stream keeps the line.
    func receiveCancel(_ requestID: String) async {
        guard let request = requests.first(where: { $0.requestID == requestID }) else { return }
        let summary = "Cancelled: \(request.subject)"
        note(model.recordRequest(RequestRecord(kind: request.recordKind, summary: summary), at: clock()))
        await retire(requestID: requestID, as: .cancelled, summary: summary)
        await afterRequestsChanged()
    }
}
