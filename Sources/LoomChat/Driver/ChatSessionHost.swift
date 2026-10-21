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
    private let driverForgotten: @MainActor (ChatSessionDriver) -> Void
    /// By the card each driver's run is on. Re-keyed synchronously from the driver when its run moves (a driver must
    /// not wait for the main actor), so it is behind a lock rather than main-actor state.
    private let drivers = ChatDriverRegistry()
    /// The drivers of the Chat → terminal moves under way, by the session the move began on (V19): a `/clear` that re-keys a
    /// driver meanwhile does not lose it. Dropped by `finishHandover`.
    var movingDrivers: [UUID: ChatSessionDriver] = [:]
    /// - Parameters:
    ///   - dataRoot: Loom's data folder; queues are kept in its `chat-queues` folder.
    ///   - choicesChanged: a live change of mode, model or effort (the runtime already stored it in the catalog).
    ///   - contextWindow: feeds the context ring (`UsageModel.setContextWindow`).
    ///   - driversChanged: a driver moved to another card (`/clear`): views that look drivers up read again.
    ///   - titleGenerated: Claude named an untitled session (the owner records it as a title that is not custom).
    ///   - driverForgotten: `forget` is about to drop this driver: whoever holds something for it lets go of it now, before
    ///     the session's queue and draft files go.
    public init(runtime: SessionRuntime, dataRoot: URL, journal: DiagnosticJournal? = nil,
                choicesChanged: @escaping @MainActor (UUID, ClaudeLaunchChoices) -> Void = { _, _ in },
                contextWindow: @escaping @MainActor (String, Int) -> Void = { _, _ in },
                driversChanged: @escaping @MainActor () -> Void = {},
                titleGenerated: @escaping @MainActor (UUID, String) -> Void = { _, _ in },
                driverForgotten: @escaping @MainActor (ChatSessionDriver) -> Void = { _ in }) {
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
        self.driverForgotten = driverForgotten
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

    /// Starts the session an agent's approved open request opens (C5b, D-40) in the Chat face: the runtime approves
    /// `requestID` with a Chat start and the request's message is sent once Ready. Same contract as `startNewSession`:
    /// `onReady` runs at Ready, a start that fails before it throws and its caller lets the host `forget` the driver,
    /// and a message that fails afterwards goes to the session's own draft.
    @discardableResult
    public func startOpenedSession(requestID: UUID, sessionID: UUID = UUID(),
                                   onReady: (@Sendable () async -> Void)? = nil) async throws -> ChatSessionDriver {
        let driver = driver(for: sessionID)
        let hold = afterReadyForTesting
        try await driver.startOpened(requestID: requestID, onReady: {
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

    /// The session was deleted through Loom, or its start failed before Ready: its driver goes, and its queue and draft
    /// files with it (they are what the user wrote), and the copies of its files rewinds.
    public func forget(sessionID: UUID) {
        // What the app holds for the driver (a composer's unsent draft) is told first, so it cannot write the draft again.
        if let driver = drivers[sessionID] { driverForgotten(driver) }
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
