import Foundation
import LoomChat
import LoomCore

/// The live Chat face's actions on the model (V16): thin calls into the app's `ChatSessionHost`, which owns the
/// drivers and their state. The composer (V17) and the cards (V18) call these; evidence does today. Each refuses
/// while the live Chat face is switched off (`SessionFaces.liveChatEnabled`), except for a session whose run already
/// is a Chat-face run.
extension CatalogModel {
    /// Makes the Chat face's holder for this runtime; the app calls it once, with the runtime. Each turn's context
    /// window feeds the context ring.
    public func installChatSessions(runtime: SessionRuntime, dataRoot: URL) {
        let host = ChatSessionHost(
            runtime: runtime, dataRoot: dataRoot, journal: DiagnosticJournal.forDataRoot(dataRoot),
            contextWindow: { [weak self] model, window in self?.usage?.setContextWindow(Int64(window), forModel: model) },
            driversChanged: { [weak self] in self?.chatDriversRevision += 1 }
        )
        chatSessions = host
        // Queues of sessions deleted while no host ran (launch recovery) hold the user's text: they go.
        Task { await host.removeQueuesOfDeletedSessions() }
    }

    /// The Chat-face driver whose run is on this card (it follows the run to a new card on `/clear`).
    func liveChatDriver(for sessionID: UUID) -> ChatSessionDriver? {
        _ = chatDriversRevision
        return chatSessions?.existingDriver(for: sessionID)
    }

    /// The live stream of a driver (its presentation under the transcript's history), kept by the host while a view shows
    /// it or its run lives, and then among the few last used. Made by the first view that shows it, with that view's
    /// session id and folder.
    func liveChatFeed(for driver: ChatSessionDriver, card: UUID, conversationID: String?, workingDirectory: String?) -> LiveChatFeed? {
        guard let host = chatSessions else { return nil }
        let config = claudeConfigDirectory
        return host.attachment(for: driver) {
            let feed = LiveChatFeed(source: driver, card: card, conversationID: conversationID, configDirectory: config,
                                    workingDirectory: workingDirectory)
            feed.onUnused = { [weak host, weak driver] in
                guard let host, let driver else { return }
                host.releaseAttachment(for: driver)
            }
            return feed
        }
    }

    public enum LiveChatError: Error, Equatable {
        /// The live Chat face is off, or the app has no runtime.
        case unavailable
        case noDriver(UUID)
    }

    /// Starts a new Claude session in the Chat face and selects it. The first message goes over stdin once ready.
    @discardableResult
    public func startChatSession(projectID: UUID?, firstMessage: String = "",
                                 choices: ClaudeLaunchChoices = ClaudeLaunchChoices()) async throws -> UUID {
        guard faces.liveChatEnabled, let host = chatSessions else { throw LiveChatError.unavailable }
        let id = UUID()
        select(id)
        try await host.startNewSession(projectID: projectID, sessionID: id,
                                       draft: NewSessionLaunch(firstMessage: firstMessage, choices: choices))
        return id
    }

    /// The session's driver: one that exists, or (with the live Chat face on) a new one.
    func chatDriver(for sessionID: UUID) throws -> ChatSessionDriver {
        guard let host = chatSessions else { throw LiveChatError.unavailable }
        if let driver = host.existingDriver(for: sessionID) { return driver }
        guard faces.liveChatEnabled else { throw LiveChatError.noDriver(sessionID) }
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

    public func stopChat(_ sessionID: UUID) async throws {
        try await chatDriver(for: sessionID).stop()
    }

    public func resumeChat(_ sessionID: UUID) async throws {
        try await chatDriver(for: sessionID).resume()
    }

    /// "Read now" on the newest message the CLI holds unread: it is taken back and sent again to be read at once.
    public func readNowChat(_ sessionID: UUID) async throws {
        let driver = try chatDriver(for: sessionID)
        guard let messageID = await driver.snapshot().model.pendingUserMessageIDs.last else { return }
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
              let feed: LiveChatFeed = chatSessions?.existingAttachment(for: driver) else { return ["feed": false] }
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

    /// Answers the oldest waiting request: allow it as asked, or deny it.
    public func answerFirstChatRequest(_ sessionID: UUID, allow: Bool) async throws {
        let driver = try chatDriver(for: sessionID)
        guard let request = await driver.snapshot().requests.first else { return }
        try await driver.respond(to: request.requestID, with: allow
            ? .allow(updatedInput: request.request.input) : .deny(message: "The user denied this tool use."))
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
