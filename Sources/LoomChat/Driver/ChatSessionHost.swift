import Foundation
import LoomCore
import Synchronization

/// The app's Chat-face drivers: one per session that ran (or is about to run) in the Chat face in this app run, made
/// on first use and kept, so the session's live model, queue and pending requests outlive a view.
///
/// A driver is found by the card its run is on now. A `/clear` moves the run to a new card (the supervisor's card
/// semantics, the same in both faces); the driver follows it and is re-keyed here at once (`driversChanged` tells the
/// UI), so the new card shows the live chat and the old one its transcript.
///
/// It also switches faces (CHAT-SPEC → Switching faces). The order is the one Stop uses (interrupt, `result`, stdin,
/// exit), so a switch during a turn or with a card waiting leaves nothing half done: the request is withdrawn by the
/// interrupt before stdin closes. The terminal side of a switch (resuming the PTY run) belongs to the caller, which
/// owns the terminal view.
@MainActor
public final class ChatSessionHost {
    public let runtime: SessionRuntime
    public let queueStore: ChatQueueStore
    /// The composers' unsent drafts (V17), in the data folder's `chat-drafts`.
    public let draftStore: ChatDraftStore
    /// The copies a files rewind keeps for Undo (V21), in the data folder's `chat-rewinds`.
    public let rewindStore: ChatRewindStore
    private let journal: DiagnosticJournal?
    private let choicesChanged: @MainActor (UUID, ClaudeLaunchChoices) -> Void
    private let contextWindow: @MainActor (String, Int) -> Void
    private let driversChanged: @MainActor () -> Void
    private let titleGenerated: @MainActor (UUID, String) -> Void
    /// By the card each driver's run is on. Re-keyed synchronously from the driver when its run moves (a driver must
    /// not wait for the main actor), so it is behind a lock rather than main-actor state.
    private let drivers = ChatDriverRegistry()
    /// What the app keeps per driver while the driver is here (the live chat's presentation, the composer), by driver and
    /// by the type of the thing kept.
    private var attachments: [AttachmentKey: (driver: ChatSessionDriver, value: AnyObject)] = [:]
    /// The `ChatDriverAttachment`s by last use, the newest last: past `attachmentLimit`, the oldest one not in use goes.
    /// Other attachments (the composer's model, which holds an unsent draft) are not trimmed.
    private var attachmentOrder: [AttachmentKey] = []
    /// How many `ChatDriverAttachment`s are kept at most, besides those in use (`ChatDriverAttachment.isInUse`).
    public static let attachmentLimit = 4

    private struct AttachmentKey: Hashable {
        let driver: ObjectIdentifier
        let type: ObjectIdentifier
    }

    /// - Parameters:
    ///   - dataRoot: Loom's data folder; queues are kept in its `chat-queues` folder.
    ///   - choicesChanged: a live change of mode, model or effort (the runtime already stored it in the catalog).
    ///   - contextWindow: feeds the context ring (`UsageModel.setContextWindow`).
    ///   - driversChanged: a driver moved to another card (`/clear`): views that look drivers up read again.
    ///   - titleGenerated: Claude named an untitled session (the owner records it as a title that is not custom).
    public init(runtime: SessionRuntime, dataRoot: URL, journal: DiagnosticJournal? = nil,
                choicesChanged: @escaping @MainActor (UUID, ClaudeLaunchChoices) -> Void = { _, _ in },
                contextWindow: @escaping @MainActor (String, Int) -> Void = { _, _ in },
                driversChanged: @escaping @MainActor () -> Void = {},
                titleGenerated: @escaping @MainActor (UUID, String) -> Void = { _, _ in }) {
        self.runtime = runtime
        queueStore = ChatQueueStore(directory: dataRoot.appendingPathComponent("chat-queues", isDirectory: true))
        draftStore = ChatDraftStore(directory: dataRoot.appendingPathComponent("chat-drafts", isDirectory: true))
        rewindStore = ChatRewindStore(directory: dataRoot.appendingPathComponent("chat-rewinds", isDirectory: true))
        // An Undo lives only in memory and no driver exists yet: every copy an earlier run left is unreachable (D-72).
        rewindStore.removeAll()
        self.journal = journal
        self.choicesChanged = choicesChanged
        self.contextWindow = contextWindow
        self.driversChanged = driversChanged
        self.titleGenerated = titleGenerated
        // A deletion the runtime finishes by itself (launch recovery has no UI model) removes the host's files too.
        runtime.conversationForgetters.register { [weak self] id, _ in
            await MainActor.run { self?.forget(sessionID: id) }
        }
    }

    /// The session's driver, made when first asked for. A side chat's driver is made by `sideChatDriver(for:parentSessionID:)`
    /// (its callers know what it is; the host reads nothing from the catalog here).
    public func driver(for sessionID: UUID) -> ChatSessionDriver {
        if let driver = drivers[sessionID] { return driver }
        return makeDriver(sessionID: sessionID, sideChatParent: nil)
    }

    private func makeDriver(sessionID: UUID, sideChatParent: UUID?) -> ChatSessionDriver {
        let record = choicesChanged
        let window = contextWindow
        let changed = driversChanged
        let titled = titleGenerated
        let registry = drivers
        let driver = ChatSessionDriver(
            sessionID: sessionID, runtime: runtime, queueStore: queueStore, draftStore: draftStore,
            // The fork shares the parent's working folder: a files rewind there would change files under the main session.
            rewindStore: sideChatParent == nil ? rewindStore : nil,
            journal: journal,
            requestPolicy: sideChatParent == nil ? nil : SideChatPolicy(), sideChatParent: sideChatParent,
            onChoicesChanged: { choices in Task { @MainActor in record(sessionID, choices) } },
            onContextWindow: { model, size in Task { @MainActor in window(model, size) } },
            onMoved: { from, to in
                registry.move(from: from, to: to)
                Task { @MainActor in changed() }
            },
            onTitle: { card, title in Task { @MainActor in titled(card, title) } }
        )
        drivers[sessionID] = driver
        return driver
    }

    /// The driver whose run is on this card, if there is one.
    public func existingDriver(for sessionID: UUID) -> ChatSessionDriver? { drivers[sessionID] }

    /// Something the app keeps for a driver for as long as the host keeps the driver: made by `make` on first use, then the
    /// same object, whichever card the driver's run is on (it follows a `/clear` with the driver). The live chat keeps
    /// the session's presentation here, so it outlives the views that show it. Gone with `forget`, with
    /// `releaseAttachment` once nothing uses it, or as the least recently used of more than `attachmentLimit` (one in
    /// use stays).
    public func existingAttachment<T: AnyObject>(for driver: ChatSessionDriver) -> T? {
        guard let found = attachments[AttachmentKey(driver: ObjectIdentifier(driver), type: ObjectIdentifier(T.self))],
              found.driver === driver else { return nil }
        return found.value as? T
    }

    public func attachment<T: AnyObject>(for driver: ChatSessionDriver, make: () -> T) -> T {
        let key = AttachmentKey(driver: ObjectIdentifier(driver), type: ObjectIdentifier(T.self))
        if let found = attachments[key], found.driver === driver, let value = found.value as? T {
            if value is ChatDriverAttachment { touch(key) }
            return value
        }
        let value = make()
        attachments[key] = (driver, value)
        if value is ChatDriverAttachment { touch(key) }
        trimAttachments()
        return value
    }

    private func touch(_ key: AttachmentKey) {
        attachmentOrder.removeAll { $0 == key }
        attachmentOrder.append(key)
    }

    /// The driver's trimmable attachments go unless they are in use; a view that shows the session again makes a new one.
    public func releaseAttachment(for driver: ChatSessionDriver) {
        let id = ObjectIdentifier(driver)
        for key in attachmentOrder where key.driver == id {
            guard let found = attachments[key], found.driver === driver, !Self.isInUse(found.value) else { continue }
            dropAttachment(key)
        }
    }

    /// The drivers that have a trimmable attachment, the least recently used first (tests).
    public var attachedDriverOrder: [ObjectIdentifier] {
        attachmentOrder.filter { attachments[$0] != nil }.map(\.driver)
    }

    /// Everything of one type the host keeps for its drivers (Quit flushes the composers this way).
    public func kept<T: AnyObject>(ofType type: T.Type) -> [T] {
        attachments.values.compactMap { $0.value as? T }
    }

    private func trimAttachments() {
        var excess = attachmentOrder.count - Self.attachmentLimit
        for key in attachmentOrder where excess > 0 {
            guard let found = attachments[key], !Self.isInUse(found.value) else { continue }
            dropAttachment(key)
            excess -= 1
        }
    }

    private func dropAttachment(_ key: AttachmentKey) {
        attachments[key] = nil
        attachmentOrder.removeAll { $0 == key }
    }

    private static func isInUse(_ value: AnyObject) -> Bool { (value as? ChatDriverAttachment)?.isInUse ?? false }

    /// Starts a new Claude session in the Chat face from a draft (workspace, choices, first message).
    /// `onReady` runs once Claude answered `initialize` (Ready), before the first message goes out: the caller tells the
    /// draft and shows the session then. A start that fails before that throws; its caller then lets the host `forget`
    /// the driver (the card stays in the catalog, as after a terminal start that failed). A first message that fails
    /// afterwards goes to the session's own draft.
    @discardableResult
    public func startNewSession(projectID: UUID?, sessionID: UUID = UUID(), draft: NewSessionLaunch? = nil,
                                onReady: (@Sendable () async -> Void)? = nil)
        async throws -> ChatSessionDriver {
        let driver = driver(for: sessionID)
        let hold = afterReadyForTesting
        try await driver.startNew(projectID: projectID, draft: draft, onReady: {
            await onReady?()
            await hold?()
        })
        return driver
    }

    /// Test seam: runs right after `onReady` and before the draft's first message goes out.
    var afterReadyForTesting: (@Sendable () async -> Void)?

    // MARK: Side chats (V22)

    /// Forks `parentSessionID` into a new side chat and returns its driver, Ready (the fork answered `initialize`); the first
    /// question goes through the driver's `send`. The parent's run, driver, queue and card are not touched, and a live parent never
    /// blocks it. A start that fails leaves nothing behind: no card, no driver, and no file the fork may have written.
    public func startSideChat(parentSessionID: UUID) async throws -> ChatSessionDriver {
        let id = UUID()
        let driver = makeDriver(sessionID: id, sideChatParent: parentSessionID)
        do {
            try await driver.startFork()
        } catch {
            // The runtime removed the card when the spawn failed; a fork that spawned and then did not become ready is stopped and
            // deleted through the same verified path as a discard. Best effort: the original failure is what the caller gets.
            _ = try? await discardSideChat(id: id)
            forget(sessionID: id)
            throw error
        }
        return driver
    }

    /// The driver of a side chat that already exists (Loom started again, or the tab shows an older one): made as a side chat's.
    /// The card's parent is the caller's to give (`SessionCatalog.sideChats(of:)` lists them by parent).
    public func sideChatDriver(for sideChatID: UUID, parentSessionID: UUID) -> ChatSessionDriver {
        if let driver = drivers[sideChatID] { return driver }
        return makeDriver(sessionID: sideChatID, sideChatParent: parentSessionID)
    }

    /// Discards a side chat: its process is stopped in the driver's order (interrupt, `result`, stdin, exit) and awaited, then
    /// the fork's files and card are deleted through the verified path. The parent is not touched. Returns the deletion's outcome;
    /// the driver and the files the host keeps for it go with a finished deletion.
    @discardableResult
    public func discardSideChat(id: UUID) async throws -> ConversationDeletionOutcome {
        if let driver = drivers[id], await driver.currentPhase.isLive {
            do {
                let report = try await driver.stop()
                guard report.succeeded else { throw SessionRuntimeError.unverifiedStop(id) }
            } catch SessionRuntimeError.notRunning {}
        }
        let outcome = try await runtime.discardSideChat(id: id)
        if outcome == .deleted { forget(sessionID: id) }
        return outcome
    }

    /// Terminal → Chat: stops the terminal run if one lives (the runtime's verified stop), then resumes the session in
    /// the Chat face. `beforeResume` runs after the stop, right before the Chat run starts: false ends the move there
    /// (a Stop or a cancel came in meanwhile) with a `CancellationError`.
    public func enterChat(sessionID: UUID, beforeResume: (@MainActor () -> Bool)? = nil) async throws -> ChatSessionDriver {
        let driver = driver(for: sessionID)
        let terminalLives = await runtime.supervisor.session(id: sessionID)?.currentRun != nil
        let chatLives = await driver.currentPhase.isLive
        if terminalLives, !chatLives {
            let report = try await runtime.stopConversation(sessionID: sessionID)
            guard report.succeeded else { throw SessionRuntimeError.unverifiedStop(sessionID) }
        }
        if let beforeResume, !beforeResume() { throw CancellationError() }
        try await driver.resume()
        await driver.returnedToChat()
        return driver
    }

    /// The session was deleted through Loom, or its start failed before Ready: its driver goes, and its queue and draft
    /// files with it (they are what the user wrote), and the copies of its files rewinds.
    public func forget(sessionID: UUID) {
        if let driver = drivers[sessionID] {
            let id = ObjectIdentifier(driver)
            for key in Array(attachments.keys) where key.driver == id {
                // What the session's composer still holds in memory must not write the draft again.
                (attachments[key]?.value as? ChatHostedAttachment)?.hostForgot()
                dropAttachment(key)
            }
        }
        drivers[sessionID] = nil
        do { try queueStore.forget(sessionID: sessionID) } catch {
            LoomLog.error(.lifecycle, "A deleted session's Chat queue could not be removed (\(LoomLog.category(of: error)))")
        }
        do { try draftStore.forget(sessionID: sessionID) } catch {
            LoomLog.error(.lifecycle, "A deleted session's Chat draft could not be removed (\(LoomLog.category(of: error)))")
        }
        do { try rewindStore.forget(sessionID: sessionID) } catch {
            LoomLog.error(.lifecycle, "A deleted session's rewind copies could not be removed (\(LoomLog.category(of: error)))")
        }
    }

    /// Removes queue, draft and rewind-copy files of sessions the catalog no longer has (deleted while no host ran, or by
    /// launch recovery).
    public func removeQueuesOfDeletedSessions() async {
        for id in queueStore.sessionIDs().union(draftStore.sessionIDs()).union(rewindStore.sessionIDs()) {
            // A catalog that cannot answer removes nothing.
            guard (try? await runtime.catalog.session(id: id).map { _ in true } ?? false) == false else { continue }
            forget(sessionID: id)
        }
    }
}

/// An attachment that learns the host forgot its session (deleted through Loom): it stops writing the session's files.
@MainActor
public protocol ChatHostedAttachment: AnyObject {
    func hostForgot()
}

/// An attachment that can say it is needed now (a view shows it, or its run lives): the host keeps it past its limit.
@MainActor
public protocol ChatDriverAttachment: AnyObject {
    var isInUse: Bool { get }
}

/// The host's drivers by card, behind a lock: a driver re-keys itself here when its run moves.
final class ChatDriverRegistry: Sendable {
    private let state = Mutex<[UUID: ChatSessionDriver]>([:])

    subscript(sessionID: UUID) -> ChatSessionDriver? {
        get { state.withLock { $0[sessionID] } }
        set { state.withLock { $0[sessionID] = newValue } }
    }

    /// Re-keys the driver of `from` to `to`. A different driver already under `to` is never replaced silently: the move is
    /// refused and logged (false), and both stay where they are. Returns whether the driver was re-keyed.
    @discardableResult
    func move(from: UUID, to: UUID) -> Bool {
        state.withLock { drivers in
            guard let driver = drivers[from] else { return false }
            if let existing = drivers[to], existing !== driver {
                LoomLog.error(.lifecycle, "A Chat driver was not re-keyed to its run's new card: another driver already has it")
                return false
            }
            drivers.removeValue(forKey: from)
            drivers[to] = driver
            return true
        }
    }
}
