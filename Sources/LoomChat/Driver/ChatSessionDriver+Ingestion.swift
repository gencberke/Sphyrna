import Foundation
import LoomCore

extension ChatSessionDriver {
    // MARK: Ingestion

    func receive(_ input: ChatPipeSink.Input, from sink: ChatPipeSink) async {
        switch input {
        case let .frames(frames, at, bytes):
            lastActivity = at
            ingesting = true
            let activityBefore = model.activity
            for frame in frames {
                guard case let .message(message) = frame else {
                    note(model.apply(frame, at: at))
                    continue
                }
                await ingest(message, at: at)
            }
            if model.activity != activityBefore { streamActivityChanged = true }
            ingesting = false
            flushModelChanges()
            sink.taken(bytes)
            changed()
        case .ended:
            await outputEnded()
        }
    }

    private func ingest(_ message: StreamMessage, at now: Date) async {
        guard let current = run else { return }
        await current.channel.receive(message)
        // The `switch` is the last statement: a `return` in a case, or in the helpers it calls, ends `ingest`.
        switch message {
        case let .commandLifecycle(lifecycle):
            // Only Loom's own sends: a task notification has a uuid of its own and lifecycle records too.
            guard sent[model.rowID(forSent: lifecycle.commandUUID)] != nil else { return }
            note(model.apply(message, at: now))
            releasePayloads()
        case let .result(result):
            await ingestResult(result, at: now)
        case let .controlRequest(request):
            guard case let .canUseTool(tool) = request.kind else { return }
            await receiveToolRequest(request, tool: tool, at: now)
        case let .controlCancel(requestID):
            await receiveCancel(requestID)
        case let .conversationReset(reset):
            // The run goes to a new card, whose stream starts with the marker (`followMove`). The reset's own
            // `new_conversation_id` is NOT adopted: the real CLI fills it with the record's uuid, and the transcript is written
            // under the session id of the SessionStart hook and of the `system/init` that follow (measured, 2.1.300). Taking
            // it made an empty card, and the real id a second move.
            resetTrigger = reset.trigger
            // What the CLI keeps of live settings across a reset (`/clear`, a compaction) is not measured: Ask's layer goes on
            // again, in the chain. A task of its own: this loop is what delivers the answers to its requests.
            if isAsk {
                askLayerPending = true
                Task { await self.reapplyAskLayer() }
            }
        default:
            let unknownBefore = model.unknownRecordCount
            note(model.apply(message, at: now))
            releasePayloads()
            await observe(message, unknownBefore: unknownBefore)
        }
    }

    private func observe(_ message: StreamMessage, unknownBefore: Int) async {
        if background.apply(message) {
            if let activity = publishedActivity { await publish(activity) }
            changed()
        }
        switch message {
        case let .systemInit(info):
            permissionMode = info.permissionMode ?? permissionMode
            if info.effort != nil { effortCleared = false }
            if info.model != nil { liveModel = nil }
            let listed = Set(info.capabilities ?? [])
            for capability in Self.requiredCapabilities where !listed.contains(capability) {
                noteDrift(.missingCapability(capability))
            }
            if let id = info.sessionID { await adopt(id, transition: .automatic) }
            if !turnRunning {
                // A turn the CLI started itself (a finished background task, a queued turn).
                await beginTurn()
            }
        case let .status(status):
            permissionMode = status.permissionMode ?? permissionMode
        case let .user(user):
            let finished = Set(user.content.compactMap { block -> String? in
                if case let .toolResult(result) = block { result.toolUseID } else { nil }
            })
            guard !finished.isEmpty else { return }
            let done = requests.filter { $0.request.toolUseID.map(finished.contains) == true }
            guard !done.isEmpty else { return }
            // The tool call finished some other way: its card folds without a line (the tool's row says how it ended).
            for request in done { settle(request, as: .resolved, summary: "Resolved: \(request.subject)") }
            requests.removeAll { $0.request.toolUseID.map(finished.contains) == true }
            changed()
            await publishRequests()
            await afterRequestsChanged()
        case let .assistant(assistant):
            guard let category = assistant.error else { return }
            lastErrorCategory = category
            if ChatPolicySignal.categories.contains(category) {
                policySignal = ChatPolicySignal(category: category, source: .assistantError)
            } else if assistant.stopReason != "refusal" {
                noteDrift(.apiError(category: category, status: nil))
            }
        case let .apiRetry(retry):
            if let category = retry.error, ChatPolicySignal.categories.contains(category) {
                policySignal = ChatPolicySignal(category: category, source: .apiRetry)
            }
        case let .unknown(unknown):
            if model.unknownRecordCount > unknownBefore {
                noteDrift(.unknownRecord(type: unknown.type, subtype: unknown.subtype))
            }
        default:
            break
        }
    }

    private func ingestResult(_ result: TurnResult, at now: Date) async {
        let stoppedByLoom = model.interruptSent
        note(model.apply(.result(result), at: now))
        for (name, window) in result.contextWindows {
            let key = windowKey(name)
            contextWindows[key] = window
            onContextWindow(key, window)
        }
        // An interrupt's own result (`error_during_execution`, `is_error`, no text) is not a failed turn, nor is a
        // turn a `now` send cut.
        let failed = result.isError && !result.wasInterrupted
        if result.terminalReason == "api_error" {
            noteDrift(.apiError(category: lastErrorCategory, status: result.apiErrorStatus))
        }
        lastErrorCategory = nil
        // A `now` send cut the turn, or the CLI holds more turns: the next turn follows at once.
        let continues = !stoppedByLoom && (
            (result.queuedTurnCount ?? 0) > 0
                || !unreadRows.isEmpty
        )
        guard !continues else { return }
        turnRunning = false
        turnsEnded += 1
        wakeTurnEndWaiters()
        if phase == .working || phase == .needsYou { setPhase(requests.isEmpty ? .ready : .needsYou) }
        if failed, !queue.isEmpty { pauseQueue(.failedTurn) }
        guard phase != .stopping else { return }
        let category = result.terminalReason ?? result.subtype.rawValue
        await publish(failed ? .failed(category) : .turnComplete)
        if let runID = run?.runID { try? await runtime.supervisor.markProviderActivity(runID: runID, at: now) }
        if modeBusy || askLayerPending {
            // A message waits for a mode transition (`write`), and this loop delivers the answers that transition waits for:
            // the release goes on in a task of its own.
            Task { await self.releaseQueueReportingIssue() }
        } else {
            await releaseQueueReportingIssue()
        }
    }

    // MARK: Following the run's card

    /// The card the run is on now, as the supervisor has it (a `/clear` the hooks reported first moved it).
    func followRun() async {
        guard let runID = run?.runID, let card = await runtime.supervisor.activeSessionID(runID: runID) else { return }
        await followMove(to: card)
    }

    /// The run moved to another card (`/clear`; the supervisor moved it, with its choices and face): the driver goes
    /// with it. Its owner re-keys it, the queue goes to the new card, and the stream starts over with the marker
    /// (the old card keeps the old conversation's transcript).
    func followMove(to card: UUID) async {
        guard card != sessionID, run != nil else { return }
        // A handover that still waits ends: the session was cleared, it is not the one the user chose to move.
        if handover.isHolding, !handover.isCommitted {
            handover.endByClear()
            wakeTurnEndWaiters()
        }
        let old = sessionID
        sessionID = card
        // The new card has no title yet, and its own tries.
        titleState = .needed
        titleFailures = 0
        if let queueStore {
            do {
                try queueStore.save(queue, sessionID: card)
                try queueStore.remove(sessionID: old)
            } catch {
                queueIssue = .notSaved(LoomLog.category(of: error))
            }
        }
        // The draft file goes with the run, held messages included: the driver writes and releases them under the new card.
        if let draftStore {
            do { try draftStore.move(from: old, to: card) } catch {
                LoomLog.error(.lifecycle, "A draft could not follow its run to the new card (\(LoomLog.category(of: error)))")
            }
        }
        var fresh = TurnModel(source: .live)
        fresh.ready = model.ready
        fresh.latestInit = model.latestInit
        fresh.rateLimit = model.rateLimit
        fresh.startMarkerPlaced = true
        fresh.markedMode = model.markedMode
        model = fresh
        // The new card's stream starts at the marker. The run goes on, so its generation stays.
        runStart = LiveHistoryJoin.RunStart(time: clock(), generation: runStart.generation)
        streamReplaced = true
        note(model.appendMarker(.reset(trigger: resetTrigger ?? "clear"), at: clock()))
        resetTrigger = nil
        if !ingesting { flushModelChanges() }
        onMoved(old, card)
        journal?.record("chat.moved", [:])
        conversationID = await runtime.supervisor.session(id: card)?.providerConversationID ?? conversationID
        // The new card's hub entry: the run's requests and work state (the move's `runStarted` cleared them).
        await runtime.supervisor.events.publish(sessionID: card, change: .pendingRequests(requests.map(\.summary)))
        if let activity = publishedActivity { await publish(activity) }
        changed()
    }
}
