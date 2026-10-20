import Foundation
import LoomCore

extension ChatSessionDriver {
    // MARK: Start, resume, stop

    /// Starts this (new) session in the Chat face with the draft's workspace and choices. Ready when
    /// it returns: the CLI answered `initialize`; the draft's first message (if any) was then sent over stdin.
    /// `onReady` runs once `initialize` succeeded, before the first message goes out (V19: "started" is told then,
    /// not when the child is spawned). A start that fails before that throws with nothing kept: the caller still has
    /// the text and gives it back to the draft. A first message that cannot go out afterwards goes to this session's
    /// own draft, because the draft page is gone by then.
    @discardableResult
    public func startNew(projectID: UUID?, draft: NewSessionLaunch? = nil,
                         onReady: (@Sendable () async -> Void)? = nil) async throws -> ChatSendReceipt? {
        let id = sessionID
        let message = (draft?.firstMessage).flatMap { $0.isEmpty ? nil : $0 }
        try await launch(isResume: false) { sink in
            try await self.runtime.startChatConversation(
                projectID: projectID, sessionID: id, draft: draft, outputSink: sink
            )
        }
        await onReady?()
        guard let message else { return nil }
        do {
            return try await send(message)
        } catch {
            keepForUser([ChatReturnedDraft(messageID: "", text: message, attachments: [])])
            throw error
        }
    }

    /// Resumes the stopped session in the Chat face (`--resume`, with the mode, model and effort the catalog holds).
    public func resume() async throws {
        let id = sessionID
        try await launch(isResume: true) { sink in
            try await self.runtime.resumeChatConversation(sessionID: id, outputSink: sink)
        }
    }

    /// Stops the run in the verified order (interrupt, `result`, stdin, exit). Returns the supervisor's report. A
    /// Stop while the child starts cancels the start: the spawn is let finish, then the child is stopped in the same
    /// order, and the start ends with `ChatDriverError.stopping` (never as a failure).
    @discardableResult
    public func stop() async throws -> SessionStopReport {
        if phase == .starting {
            startCancelled = true
            setPhase(.stopping)
            if run == nil { _ = await waitForStart() }
        }
        stopRequested = true
        await followRun()
        do {
            return try await runtime.stopConversation(sessionID: sessionID)
        } catch {
            // Nothing of this run was stopped (it had ended, or nothing runs): no stop is under way.
            if run == nil {
                stopRequested = false
                if phase == .stopping { setPhase(.stopped) }
            } else if phase.isLive {
                stopRequested = false
            }
            throw error
        }
    }

    private func launch(
        isResume: Bool,
        _ start: @escaping @Sendable (ChatPipeSink) async throws -> RuntimePipeLaunch
    ) async throws {
        if phase == .stopping { throw ChatDriverError.stopping }
        if phase == .starting {
            guard await waitForStart() else { throw ChatDriverError.couldNotStart("the start failed") }
            return
        }
        guard !phase.isLive else { return }
        runStart = LiveHistoryJoin.RunStart(entries: model.entries.count, turns: model.turns.count,
                                            unknownRecords: model.unknownRecordCount, time: clock(),
                                            generation: runStart.generation + 1)
        setPhase(.starting)
        // The start holds the mode chain until the process is ready (and, for an Ask session, has Ask's layer on): a mode
        // picked meanwhile runs after it.
        await acquireMode()
        defer { releaseMode() }
        stopRequested = false
        startCancelled = false
        // A card the last run left unanswered was shown as cut off; this run starts clean.
        settled.removeAll { $0.outcome == .processEnded }
        undelivered = []
        let sink = ChatPipeSink(clock: clock)
        let launched: RuntimePipeLaunch
        do {
            launched = try await start(sink)
        } catch {
            finishStartWaiters(false)
            if startCancelled {
                startCancelled = false
                setPhase(.stopped)
                throw ChatDriverError.stopping
            }
            setPhase(.failed(.couldNotStart(LoomLog.category(of: error))))
            throw error
        }
        let channel = ControlChannel()
        var current = Run(runID: launched.runID, pipe: launched.pipe, channel: channel, sink: sink, isResume: isResume)
        current.writer = Task {
            for await line in channel.outgoing {
                do { try await launched.pipe.write(line) } catch { break }
            }
        }
        current.reader = Task { [weak self] in
            for await input in sink.inputs {
                guard let self else {
                    sink.close()
                    return
                }
                await self.receive(input, from: sink)
            }
        }
        let drain = channel.events
        Task { for await _ in drain {} }
        run = current
        let runID = launched.runID
        if let stored = try? await runtime.catalog.launchChoices(sessionID: sessionID) {
            choices = stored
            choicesLoaded = true
        }
        try? await runtime.supervisor.registerStopHooks(runID: runID, hooks: ManagedRunStopHooks(
            prepare: {}, completed: {},
            leave: { [weak self] request in await self?.leave(request) },
            moved: { [weak self] card in await self?.followMove(to: card) }
        ))
        if startCancelled {
            // The waiting Stop goes on now and stops the child in the verified order.
            finishStartWaiters(false)
            throw ChatDriverError.stopping
        }
        var askFailed = false
        do {
            let reply = try await channel.request(.initialize, timeout: readyTimeout)
            guard run?.runID == runID, phase == .starting else { throw ChatDriverError.stopping }
            let response = reply.initializeResponse
            permissionMode = response.currentPermissionMode ?? permissionMode
            note(model.apply(ready: response, resumed: isResume, at: clock()))
            // A session that is in Ask starts in it: the rules and the style are live settings, so neither the spawn nor
            // `--resume` brings them back. Before anything else is sent, or the first message would run without them.
            if isAsk {
                do { try await applyAskLayer(on: channel) } catch {
                    askFailed = true
                    throw error
                }
            }
            setPhase(.ready)
            await publish(.atPrompt)
            finishStartWaiters(true)
        } catch {
            finishStartWaiters(false)
            // A Stop during Starting: the start is cancelled, not failed.
            if stopRequested || startCancelled || phase == .stopping { throw ChatDriverError.stopping }
            if askFailed, run?.runID == runID {
                // Ask could not be turned on: the session does not run without it (a message would reach a Claude that may edit).
                setPhase(.failed(.couldNotStart("ask")))
                await runtime.supervisor.events.publish(sessionID: sessionID, change: .issue("Ask mode could not be turned on."))
                Task { try? await self.stopAfterFailure() }
                throw ChatDriverError.couldNotStart("ask")
            }
            guard run?.runID == runID else {
                // The child ended before it was ready; `outputEnded` says why (it may still be reading stderr).
                if phase == .starting { await waitForRunEnd() }
                if case let .failed(.couldNotStart(reason)) = phase { throw ChatDriverError.couldNotStart(reason) }
                throw ChatDriverError.couldNotStart(LoomLog.category(of: error))
            }
            // The child lives but never answered: stop it, and say so.
            setPhase(.failed(.notReady))
            await runtime.supervisor.events.publish(
                sessionID: sessionID, change: .issue("Claude did not answer in the Chat face.")
            )
            journal?.record("chat.not_ready", ["error": .string(LoomLog.category(of: error))])
            Task { try? await self.stopAfterFailure() }
            throw ChatDriverError.couldNotStart("no answer to initialize")
        }
    }

    private func stopAfterFailure() async throws {
        stopRequested = true
        _ = try await runtime.stopConversation(sessionID: sessionID)
        // The phase stays failed: the run never became ready.
        if phase == .stopped { setPhase(.failed(.notReady)) }
    }

    private func waitForStart() async -> Bool {
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func finishStartWaiters(_ ready: Bool) {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }

    /// The supervisor's stop hook (Stop, an idle stop, Quit, a face switch), before stdin closes: interrupt a running
    /// turn or a waiting request and wait for the turn's `result`, all within the grace. Only a stop Loom made comes
    /// here (the supervisor does not call it when the leader already exited); its exit is then not a failure.
    func leave(_ request: ManagedRunLeave) async {
        guard let current = run, request.reason != .processExited else { return }
        stopRequested = true
        setPhase(.stopping)
        // Nothing queued goes out during the Stop. A handover keeps the queue and says why it waits.
        if !queue.isEmpty, queue.paused == nil { pauseQueue(handover.isStopping ? .handover : .interrupted) }
        guard turnRunning || !requests.isEmpty else { return }
        let started = clock()
        await sendInterrupt(on: current.channel, timeout: request.graceSeconds)
        let left = request.graceSeconds - clock().timeIntervalSince(started)
        if left > 0 { await waitForTurnEnd(seconds: left) }
    }

    func outputEnded() async {
        guard let current = run else { return }
        // The run is gone for every other call from here on, whatever the awaits below let in.
        run = nil
        // The last mode the CLI reported is not the session's mode any more: the bar shows the chosen one (`choices`).
        permissionMode = nil
        let endedStarting = phase == .starting
        current.sink.close()
        await current.channel.close()
        current.writer?.cancel()
        // A card still waiting when the process ends: cancelled when Loom stopped it, else Claude stopped before the user
        // answered (the card stays, disabled, with Resume).
        for request in requests {
            let outcome: ChatSettledRequest.Outcome = stopRequested ? .cancelled : .processEnded
            let summary = stopRequested ? "Cancelled: \(request.subject)" : "Not answered, Claude stopped: \(request.subject)"
            note(model.recordRequest(RequestRecord(kind: request.recordKind, summary: summary), at: clock()))
            settle(request, as: outcome, summary: summary)
        }
        requests.removeAll()
        background.removeAll()
        finishAskLayerPending()
        let unread = unreadRows
        note(model.markNotDelivered(unread))
        // What the user sent and Claude never read is theirs still: on disk before anything else can fail.
        let unreadMessages = unread.compactMap { id in sent[id].map { (id, $0) } }
        undelivered = unreadMessages.map { $0.1.rowText }
        keepForUser(unreadMessages.map { ChatReturnedDraft(messageID: $0.0, text: $0.1.text, attachments: $0.1.attachments) })
        if turnRunning { note(model.endRunningTurn(at: clock())) }
        turnRunning = false
        wakeTurnEndWaiters()
        finishStartWaiters(false)
        // Whatever the scope does next, the hub must not stay at Working or Needs you.
        publishedActivity = nil
        try? await runtime.supervisor.updateProviderWorkState(runID: current.runID,
                                                              state: ProviderWorkState(activity: .sessionEnded(nil)))
        await runtime.supervisor.events.publish(sessionID: sessionID, change: .pendingRequests([]))
        if stopRequested {
            // A child that never answered stays "not ready" while Loom stops it (never flashes "stopped" in between).
            if phase != .failed(.notReady) { setPhase(.stopped) }
        } else if endedStarting {
            // An exit at once (a bad flag, a resume of a conversation the CLI cannot find): its first stderr line.
            let line = await firstErrorLine(of: current.sink)
            setPhase(.failed(.couldNotStart(line ?? "ended before it was ready")))
            journal?.record("chat.ended_at_start", ["resume": .bool(current.isResume)])
            let issue = startFailureIssue(line: line, sink: current.sink, isResume: current.isResume)
            await runtime.supervisor.events.publish(sessionID: sessionID, change: .issue(issue))
        } else {
            setPhase(.failed(.ended))
            if !queue.isEmpty { pauseQueue(.processEnded) }
            journal?.record("chat.ended", [:])
            await runtime.supervisor.events.publish(
                sessionID: sessionID, change: .issue("Claude ended unexpectedly. Send a message to resume the session.")
            )
        }
        stopRequested = false
        changed()
        let waiters = runEndWaiters
        runEndWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForRunEnd() async {
        await withCheckedContinuation { runEndWaiters.append($0) }
    }

    /// Stderr can trail stdout's end by a moment.
    private func firstErrorLine(of sink: ChatPipeSink) async -> String? {
        if let line = sink.standardErrorFirstLine { return line }
        try? await Task.sleep(for: .milliseconds(100))
        return sink.standardErrorFirstLine
    }

    private func startFailureIssue(line: String?, sink: ChatPipeSink, isResume: Bool) -> String {
        if isResume, let error = ProviderResumeDiagnostics.error(
            provider: .claude, conversationID: conversationID ?? sessionID.uuidString.lowercased(),
            output: sink.standardErrorHead, exitStatus: 1
        ), case LoomError.providerHistoryUnavailable = error {
            return String(describing: error)
        }
        return "Claude ended before it was ready" + (line.map { ": \($0)" } ?? ".")
    }
}
