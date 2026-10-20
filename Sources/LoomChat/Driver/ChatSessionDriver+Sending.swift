import Foundation
import LoomCore

extension ChatSessionDriver {
    // MARK: Sending

    /// Sends a message. `.next` goes to the CLI now (read after the running tool); `.afterTurn` waits in Loom's queue
    /// while a turn runs, a request waits, or the queue already holds (or pauses) items. ↵ is always `next` (CHAT-SPEC →
    /// Keys); `now` is only "Read now". A stopped session is resumed first. A queued message
    /// carries text only: one with attachments is refused (`queueTextOnly`) rather than losing them.
    @discardableResult
    public func send(_ text: String, attachments: [ChatOutgoingAttachment] = [],
                     timing: ChatSendTiming = .next) async throws -> ChatSendReceipt {
        let message = ChatSentMessage(text: text, attachments: attachments)
        guard !message.blocks.isEmpty else { throw ChatDriverError.emptyMessage }
        if timing == .afterTurn, turnRunning || !requests.isEmpty || !queue.isEmpty || queue.paused != nil {
            guard attachments.isEmpty else { throw ChatDriverError.queueTextOnly }
            return .queued(try enqueue(text))
        }
        guard !handover.isHolding else { throw ChatDriverError.handingOver }
        // A files rewind (or its Undo) is under way: a turn must not start in the middle of it.
        guard !rewindBusy else { throw ChatDriverError.busy }
        try await ensureLive()
        return .sent(try await write(message, priority: .next))
    }

    /// "Retry" on a message that was not delivered (the process ended before the CLI took it): the same message is sent
    /// again, as a new row. Loom never does this by itself (concept §5.4). The old row stays as the record of the
    /// first try.
    @discardableResult
    public func retry(messageID: String) async throws -> String {
        guard model.entry(id: messageID).map({ entry in
            if case let .user(prompt) = entry.body { prompt.delivery == .notDelivered } else { false }
        }) == true, let message = sent[messageID] else { throw ChatDriverError.notPending(messageID) }
        guard !handover.isHolding else { throw ChatDriverError.handingOver }
        guard !rewindBusy else { throw ChatDriverError.busy }
        try await ensureLive()
        let uuid = try await write(message, priority: .next)
        sent[messageID] = nil
        heldPayloads.removeAll { $0 == messageID }
        note(model.noteFollowUp(.sentAgain, forRow: messageID))
        changed()
        if let at = undelivered.firstIndex(of: message.rowText) { undelivered.remove(at: at) }
        withdrawFromDrafts(messageID: messageID, message: message)
        return uuid
    }

    /// The message went out again, so the copy that came back as a draft goes: from the composers that have not taken it, from
    /// the draft file, and (`withdrawnDrafts`) from a composer that has. Without it a successful Retry left the message twice.
    private func withdrawFromDrafts(messageID: String, message: ChatSentMessage) {
        returnedDrafts.removeAll { $0.messageID == messageID }
        withdrawnDrafts.append(ChatReturnedDraft(messageID: messageID, text: message.text, attachments: message.attachments))
        if let draftStore {
            do { try draftStore.withdraw(text: message.text, attachments: message.attachments, sessionID: sessionID) } catch {
                LoomLog.error(.lifecycle, "A message sent again could not be taken out of its draft (\(LoomLog.category(of: error)))")
            }
        }
        changed()
    }

    /// "Read now": a sent message still waiting is taken back (`cancel_async_message`) and sent again with priority
    /// `now`, which cuts the running step. Its row keeps its place and its id; the CLI knows it by a new uuid from now
    /// on (`TurnModel.sentUUID(ofRow:)`). False when the CLI had already taken it into the turn.
    @discardableResult
    public func readNow(messageID: String) async throws -> Bool {
        guard let current = run, let message = sent[messageID],
              unreadRows.contains(messageID) else { throw ChatDriverError.notPending(messageID) }
        let reply = try await current.channel.request(.cancelAsyncMessage(messageUUID: model.sentUUID(ofRow: messageID)))
        guard reply.wasCancelled != false else { return false }
        let uuid = UUID().uuidString.lowercased()
        note(model.rekeyPendingUser(from: messageID, to: uuid))
        sent[messageID] = message
        try await deliver(OutgoingUserMessage(uuid: uuid, content: message.blocks, priority: .now), row: messageID,
                          on: current.channel)
        changed()
        return true
    }

    /// Esc: stops the running turn. Messages the CLI held unread come back as drafts; the queue pauses.
    public func interrupt() async {
        guard let current = run, phase != .stopping, turnRunning || !requests.isEmpty else { return }
        await sendInterrupt(on: current.channel, timeout: 10)
    }

    /// A message Claude read (or that was withdrawn) keeps no payload here: the images and pasted texts of a long session
    /// would stay in memory for nothing. Only unread messages (Read now, Retry, a draft handed back) need theirs.
    func releasePayloads() {
        guard !heldPayloads.isEmpty else { return }
        var read: [String] = []
        for row in heldPayloads {
            // Cancelled ones wait for `keepForUser`, which hands them back to the user first.
            if model.delivery(ofRow: row) == .read {
                sent[row] = ChatSentMessage(text: sent[row]?.text ?? "", attachments: [])
                read.append(row)
            }
        }
        guard !read.isEmpty else { return }
        heldPayloads.removeAll { read.contains($0) }
        releaseFromDraft(read)
    }

    /// Loom's own messages the CLI holds unread, in the order they were written: the rows `Read now` offers. They come from
    /// the payloads kept, not from a walk over the model's entries (that costs the whole stream on every read).
    var unreadRows: [String] {
        heldPayloads.filter {
            let delivery = model.delivery(ofRow: $0)
            return delivery == .pending || delivery == .queued
        }
    }

    /// Esc: an interrupt, except that it does nothing while a request waits (Esc never denies, and never ends a turn a card
    /// holds). The Interrupt button and Stop call `interrupt()`; the card's own buttons answer.
    public func interruptFromEscape() async {
        guard requests.isEmpty else { return }
        await interrupt()
    }

    func ensureLive() async throws {
        switch phase {
        case .stopping: throw ChatDriverError.stopping
        case .starting, .stopped, .failed: try await resume()
        case .ready, .working, .needsYou: break
        }
    }

    func write(_ message: ChatSentMessage, priority: OutgoingUserMessage.Priority) async throws -> String {
        // A message goes out after the mode transition that is under way, and after Ask's layer is back on following a reset:
        // it is the first thing the CLI does with the new rules, never a turn that runs before them. (The transitions
        // run in order; this joins the chain behind them.)
        await settleModeTransitions()
        guard let current = run else { throw ChatDriverError.stopping }
        let uuid = UUID().uuidString.lowercased()
        sent[uuid] = message
        heldPayloads.append(uuid)
        // On disk before it is written: a crash or a Quit while Claude has not read it leaves it in the draft.
        holdInDraft(uuid, message)
        note(model.appendPendingUser(uuid: uuid, text: message.rowText, images: message.images, at: clock(),
                                     whileWorking: turnRunning, typedText: message.text))
        do {
            try await deliver(OutgoingUserMessage(uuid: uuid, content: message.blocks, priority: priority), row: uuid,
                              on: current.channel)
        } catch {
            // The caller keeps the text (the composer puts it back, the queue keeps the item): the row offers no Retry.
            heldPayloads.removeAll { $0 == uuid }
            releaseFromDraft([uuid])
            note(model.noteFollowUp(.handedBack, forRow: uuid))
            changed()
            throw error
        }
        // The files are no longer as the newest rewind left them: its Undo goes.
        closeRewindUndo(to: .expired)
        await beginTurn()
        requestTitleIfNeeded(for: message)
        return uuid
    }

    // MARK: The session's title

    /// A Chat run has no terminal title, and the CLI's SDK mode does not name a session by itself as the terminal face does
    /// (a short model call on the first message). So the first message that is sent to an untitled session asks for it
    /// (`generate_session_title`, persisted as the transcript's `ai-title`): a slash command is no title, an answer that
    /// fails or holds none is not shown, and the next message tries again while the session is still untitled, up to
    /// `titleAttemptLimit` times for a card (each try is a model call). An answer belongs to the card it was asked for: one
    /// that comes back after the run moved to another card (`/clear`) names the card it was asked for, and leaves the new
    /// card's own title alone.
    enum TitleState { case needed, requesting, done }
    /// How many title requests that fail or hold no title a card gets before it stays untitled until Loom starts again (the
    /// driver lives as long as the app).
    static let titleAttemptLimit = 3

    private func requestTitleIfNeeded(for message: ChatSentMessage) {
        guard titleState == .needed, let current = run else { return }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("/") else { return }
        titleState = .requesting
        let card = sessionID
        Task { await generateTitle(from: text, card: card, on: current.channel) }
    }

    private func generateTitle(from text: String, card: UUID, on channel: ControlChannel) async {
        // Only an untitled session is named (a resumed one may carry the terminal's title or the user's own).
        guard let record = try? await runtime.catalog.session(id: card) else { titleFailed(for: card); return }
        guard (record.title ?? "").isEmpty, !record.titleIsCustom else { titleSettled(for: card); return }
        do {
            let reply = try await channel.request(.generateSessionTitle(description: text), timeout: .seconds(60))
            guard let title = reply.generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                titleFailed(for: card)
                return
            }
            titleSettled(for: card)
            onTitle(card, title)
        } catch {
            titleFailed(for: card)
        }
    }

    /// The card has a title: nothing more is asked for it. A card the run has left keeps the state of the card it is on.
    private func titleSettled(for card: UUID) {
        guard card == sessionID else { return }
        titleState = .done
    }

    /// The request failed or held no title: the next message asks again, until the card has had its tries.
    private func titleFailed(for card: UUID) {
        guard card == sessionID else { return }
        titleFailures += 1
        titleState = titleFailures >= Self.titleAttemptLimit ? .done : .needed
    }

    // MARK: Unread messages in the draft file

    private func holdInDraft(_ row: String, _ message: ChatSentMessage) {
        guard let draftStore else { return }
        do { try draftStore.hold(id: row, text: message.text, attachments: message.attachments, sessionID: sessionID) } catch {
            LoomLog.error(.lifecycle, "A message sent could not be kept in the draft until Claude reads it (\(LoomLog.category(of: error)))")
        }
    }

    private func releaseFromDraft(_ rows: [String]) {
        guard let draftStore, !rows.isEmpty else { return }
        do { try draftStore.release(ids: rows, sessionID: sessionID) } catch {
            LoomLog.error(.lifecycle, "A message Claude read could not be taken out of the draft (\(LoomLog.category(of: error)))")
        }
    }

    /// Queues a message on the channel. One that cannot go out shows "Not delivered" and the error says why.
    private func deliver(_ message: OutgoingUserMessage, row: String, on channel: ControlChannel) async throws {
        do {
            try await channel.write(message.line())
        } catch {
            note(model.markNotDelivered([row]))
            throw (error as? ControlError) == .outputFull ? ChatDriverError.inputFull : ChatDriverError.stopping
        }
    }

    func sendInterrupt(on channel: ControlChannel, timeout seconds: Double) async {
        model.noteInterruptSent()
        // Paused before the reply is awaited: the interrupted turn's `result` can come first and must not release it.
        if !queue.isEmpty, queue.paused == nil { pauseQueue(.interrupted) }
        let receipt: InterruptReceipt?
        do {
            receipt = try await channel.request(.interrupt(cancelQueued: true), timeout: .seconds(seconds))
                .interruptReceipt
        } catch ControlError.unsupported {
            receipt = try? await channel.request(.interrupt(cancelQueued: false), timeout: .seconds(seconds))
                .interruptReceipt
        } catch {
            receipt = nil
        }
        var cancelledDrafts: [ChatReturnedDraft] = []
        for id in receipt?.cancelled ?? [] {
            let row = model.rowID(forSent: id)
            guard let message = sent[row] else { continue }
            cancelledDrafts.append(ChatReturnedDraft(messageID: row, text: message.text, attachments: message.attachments))
            if let lifecycle = CommandLifecycle(json: ["command_uuid": .string(id), "state": "cancelled"]) {
                note(model.apply(.commandLifecycle(lifecycle), at: clock()))
            }
        }
        keepForUser(cancelledDrafts)
        for draft in cancelledDrafts {
            sent[draft.messageID] = ChatSentMessage(text: draft.text, attachments: [])
            heldPayloads.removeAll { $0 == draft.messageID }
        }
        changed()
    }

    /// Messages Claude never read go back to the user: to a composer through `takeReturnedDrafts`, and into the session's
    /// draft file at once, in front of what is typed, so they survive a crash or a Quit and a composer made later finds
    /// them. Nothing the user sent is lost when a run ends.
    func keepForUser(_ drafts: [ChatReturnedDraft]) {
        guard !drafts.isEmpty else { return }
        var kept = drafts
        if let draftStore {
            do {
                // They leave the draft's held list (written when they were sent) and come into its text, in front.
                try draftStore.prepend(texts: drafts.map(\.text), attachments: drafts.flatMap(\.attachments), sessionID: sessionID,
                                       settling: drafts.map(\.messageID))
                let at = clock()
                for index in kept.indices { kept[index].persistedAt = at }
            } catch {
                LoomLog.error(.lifecycle, "Messages Claude did not read could not be saved as a draft (\(LoomLog.category(of: error)))")
            }
        }
        returnedDrafts += kept
    }
}
