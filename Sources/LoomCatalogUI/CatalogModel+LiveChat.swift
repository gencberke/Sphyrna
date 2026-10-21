import Foundation
import LoomChat
import LoomCore

/// The live Chat face's actions on the model (V16): thin calls into the app's `ChatSessionHost`, which owns the
/// drivers and their state (the session service holds it). The composer (V17) and the cards (V18) call these; evidence does too. Each refuses
/// without the app's Chat host, and for a session whose run is a terminal run (that is a handover, V19).
extension CatalogModel {
    /// Makes the Chat face's holder for this runtime, with the model's closures; the app gives it to the session service it
    /// creates and then calls `chatSessionsInstalled`. Each turn's context window feeds the context ring.
    public func makeChatSessionHost(runtime: SessionRuntime, dataRoot: URL) -> ChatSessionHost {
        ChatSessionHost(
            runtime: runtime, dataRoot: dataRoot, journal: DiagnosticJournal.forDataRoot(dataRoot),
            // A live change of mode, model or effort is what the project starts its next session with.
            choicesChanged: { [weak self] _, _ in self?.refreshLastUsedChoices() },
            contextWindow: { [weak self] model, window in self?.usage?.setContextWindow(Int64(window), forModel: model) },
            driversChanged: { [weak self] in self?.chatDriversRevision += 1 },
            // Claude names an untitled Chat session (the terminal face's own naming, on demand): a title that is not custom.
            titleGenerated: { [weak self] id, title in
                guard let self else { return }
                Task { await self.terminalTitleChanged(sessionID: id, title: title) }
            },
            // A deleted session's composer must not write its draft again, and its feed has nothing left to show.
            driverForgotten: { [weak self] driver in self?.chatAttachments.driverForgotten(driver) }
        )
    }

    /// Makes the Chat face's holder and installs it in one step (a model with a service of its own, or none).
    public func installChatSessions(runtime: SessionRuntime, dataRoot: URL) {
        let host = makeChatSessionHost(runtime: runtime, dataRoot: dataRoot)
        chatSessions = host
        chatSessionsInstalled(runtime: runtime, host: host)
    }

    /// What installing the host does besides holding it: the Changes tab's git reader, and the removal of the files of sessions
    /// deleted while no host ran. Once, in the app.
    public func chatSessionsInstalled(runtime: SessionRuntime, host: ChatSessionHost) {
        // The Changes tab's Branch scope reads git through the runtime's supervisor, so the helper is owned and stopped by Quit.
        Task { [weak self] in
            let supervisor = await runtime.supervisor
            self?.changes.reader = ChangesReader.live(git: GitChanges.live(supervisor: supervisor))
        }
        // Queues of sessions deleted while no host ran (launch recovery) hold the user's text: they go.
        Task { await host.removeQueuesOfDeletedSessions() }
    }

    /// The Chat-face driver whose run is on this card (it follows the run to a new card on `/clear`).
    func liveChatDriver(for sessionID: UUID) -> ChatSessionDriver? {
        _ = chatDriversRevision
        return chatSessions?.existingDriver(for: sessionID)
    }

    /// The driver the session's live chat shows: the one that exists, or, for a stopped session the Chat face owns,
    /// a new one in the stopped phase (its composer resumes the session). Made on the first look and kept by the host.
    func liveChatDriverForDisplay(of row: SessionRowModel) -> ChatSessionDriver? {
        if let driver = liveChatDriver(for: row.id) { return driver }
        guard showsStoppedLiveChat(row) else { return nil }
        return chatSessions?.driver(for: row.id)
    }

    /// The live stream of a driver (its presentation under the transcript's history), kept with the driver while a view shows
    /// it or its run lives, and then among the few last used. Made by the first view that shows it, with that view's
    /// session id and folder.
    func liveChatFeed(for driver: ChatSessionDriver, card: UUID, conversationID: String?, workingDirectory: String?) -> LiveChatFeed? {
        guard chatSessions != nil else { return nil }
        let config = claudeConfigDirectory
        return chatAttachments.attachment(for: driver) {
            let feed = LiveChatFeed(source: driver, card: card, conversationID: conversationID, configDirectory: config,
                                    workingDirectory: workingDirectory)
            feed.onUnused = { [weak attachments = chatAttachments, weak driver] in
                guard let attachments, let driver else { return }
                attachments.releaseAttachment(for: driver)
            }
            return feed
        }
    }

    public enum LiveChatError: Error, Equatable {
        /// The live Chat face is off, or the app has no runtime.
        case unavailable
        case noDriver(UUID)
    }

    /// The session's driver: one that exists, or a new one unless a terminal run holds the session.
    func chatDriver(for sessionID: UUID) throws -> ChatSessionDriver {
        guard let host = chatSessions else { throw LiveChatError.unavailable }
        if let driver = host.existingDriver(for: sessionID) { return driver }
        if let row = rowModels[sessionID], runEndpoint(of: row) == .terminal || terminalView(for: sessionID) != nil {
            throw LiveChatError.noDriver(sessionID)
        }
        return host.driver(for: sessionID)
    }

    /// Sends a message (↵: `next`; ⌘↵: after the turn). A stopped Chat session resumes first.
    @discardableResult
    public func sendChatMessage(_ text: String, to sessionID: UUID, afterTurn: Bool = false) async throws -> String {
        let receipt = try await chatDriver(for: sessionID).send(text, timing: afterTurn ? .afterTurn : .next)
        switch receipt {
        case let .sent(id), let .queued(id): return id
        }
    }

    public func interruptChat(_ sessionID: UUID) async throws {
        try await chatDriver(for: sessionID).interrupt()
    }

    /// The driver's own stop, for the tests that need a Stop with no navigation (the app's Stop is the service's).
    func stopChat(_ sessionID: UUID) async throws {
        try await chatDriver(for: sessionID).stop()
    }

    /// "Read now" on the newest message the CLI holds unread: it is taken back and sent again to be read at once.
    public func readNowChat(_ sessionID: UUID) async throws {
        let driver = try chatDriver(for: sessionID)
        guard let messageID = await driver.composerState().unreadMessageIDs.last else { return }
        _ = try await driver.readNow(messageID: messageID)
    }

    /// A content-free summary of the live chat view of a Chat session (evidence): the feed's card and phase, and what the
    /// presentation and its stream hold, as counts and kinds.
    public func liveChatViewSummary(_ sessionID: UUID) async -> [String: Any] {
        var summary = liveChatViewState(sessionID)
        if let driver = chatSessions?.existingDriver(for: sessionID) {
            let snapshot = await driver.snapshot()
            summary["driverEntries"] = snapshot.model.entries.count
            summary["driverCard"] = snapshot.sessionID.uuidString
        }
        return summary
    }

    private func liveChatViewState(_ sessionID: UUID) -> [String: Any] {
        guard let driver = chatSessions?.existingDriver(for: sessionID),
              let feed: LiveChatFeed = chatAttachments.existingAttachment(for: driver) else { return ["feed": false] }
        let presentation = feed.presentation
        let model = presentation.model
        let rows = presentation.controller?.rows ?? []
        var kinds: [String: Int] = [:]
        for row in rows { kinds[row.kind.tag, default: 0] += 1 }
        let live = rows.compactMap { row -> LiveRow? in if case let .live(live) = row.kind { live } else { nil } }.first
        let deliveries: [String] = model.entries.compactMap { entry in
            guard case let .user(prompt) = entry.body else { return nil }
            return String(describing: prompt.delivery)
        }
        return [
            "feed": true, "card": feed.card.uuidString, "phase": feed.phase == .ready ? "ready" : "opening",
            "attached": presentation.controller != nil, "entries": model.entries.count,
            "turns": model.turns.map { String(describing: $0.status) }, "deliveries": deliveries,
            "rows": rows.count, "uniqueRowIDs": Set(rows.map(\.id)).count == rows.count, "rowKinds": kinds,
            "liveRow": live.map { ["label": $0.label, "quietFor": $0.lastActivity.map { Int(Date().timeIntervalSince($0)) } ?? -1] }
                ?? NSNull(),
            "hasOlder": presentation.hasOlder, "viewMode": presentation.viewMode.title,
            "unknownRecords": presentation.unknownRecordCount, "policySignal": feed.policySignal != nil,
            "wireDrift": feed.wireDrift, "snapshotsAsked": feed.snapshotsAsked, "progress": feed.progress,
        ]
    }

    /// Answers the oldest waiting request as a click on its card does, through `answer(requestID:_:)`: so a plan gets its
    /// `setMode`, a question its answers (the first option of each), and every answer its line in the stream. Allow is
    /// Allow once, Approve (Ask before edits) or the first options; deny is Deny, Keep planning, or, for a question
    /// (which has no plain Deny), Stop this turn.
    public func answerFirstChatRequest(_ sessionID: UUID, allow: Bool) async throws {
        let driver = try chatDriver(for: sessionID)
        guard let request = await driver.snapshot().requests.first else { return }
        let answer: ChatRequestAnswer
        switch (request.kind, allow) {
        case (.approval, true): answer = .allowOnce
        case (.approval, false): answer = .deny(note: nil)
        case (.plan, true): answer = .approvePlan(mode: "default")
        case (.plan, false): answer = .keepPlanning(feedback: nil)
        case (.question, true):
            answer = .answers(request.questions.map {
                ChatQuestionAnswer(question: $0.question, picks: $0.options.first.map { [$0.label] } ?? [])
            })
        case (.question, false): answer = .denyAndStop(note: nil)
        }
        try await driver.answer(requestID: request.requestID, answer)
    }

    /// A content-free summary of a Chat session (evidence): phase, counts, delivery and request kinds.
    public func chatSummary(_ sessionID: UUID) async -> [String: Any] {
        guard let driver = chatSessions?.existingDriver(for: sessionID) else { return ["driver": false] }
        let snapshot = await driver.snapshot()
        let deliveries: [String] = snapshot.model.entries.compactMap { entry in
            guard case let .user(prompt) = entry.body else { return nil }
            return String(describing: prompt.delivery)
        }
        return [
            "driver": true, "phase": String(describing: snapshot.phase), "turnRunning": snapshot.turnRunning,
            "turns": snapshot.model.turns.map { String(describing: $0.status) },
            "entries": snapshot.model.entries.count, "deliveries": deliveries,
            "requests": snapshot.requests.map { String(describing: $0.kind) },
            "queue": snapshot.queue.items.count, "queuePaused": snapshot.queue.paused?.rawValue ?? NSNull(),
            "permissionMode": snapshot.permissionMode ?? NSNull(), "drift": snapshot.drift.count,
            "contextWindows": snapshot.contextWindows, "hasRun": snapshot.runID != nil,
        ]
    }
}
