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
    private let journal: DiagnosticJournal?
    private let choicesChanged: @MainActor (UUID, ClaudeLaunchChoices) -> Void
    private let contextWindow: @MainActor (String, Int) -> Void
    private let driversChanged: @MainActor () -> Void
    /// By the card each driver's run is on. Re-keyed synchronously from the driver when its run moves (a driver must
    /// not wait for the main actor), so it is behind a lock rather than main-actor state.
    private let drivers = ChatDriverRegistry()
    /// What the app keeps per driver while the driver is here (the live chat's presentation), by driver.
    private var attachments: [ObjectIdentifier: (driver: ChatSessionDriver, value: AnyObject)] = [:]

    /// - Parameters:
    ///   - dataRoot: Loom's data folder; queues are kept in its `chat-queues` folder.
    ///   - choicesChanged: a live change of mode, model or effort (the runtime already stored it in the catalog).
    ///   - contextWindow: feeds the context ring (`UsageModel.setContextWindow`).
    ///   - driversChanged: a driver moved to another card (`/clear`): views that look drivers up read again.
    public init(runtime: SessionRuntime, dataRoot: URL, journal: DiagnosticJournal? = nil,
                choicesChanged: @escaping @MainActor (UUID, ClaudeLaunchChoices) -> Void = { _, _ in },
                contextWindow: @escaping @MainActor (String, Int) -> Void = { _, _ in },
                driversChanged: @escaping @MainActor () -> Void = {}) {
        self.runtime = runtime
        queueStore = ChatQueueStore(directory: dataRoot.appendingPathComponent("chat-queues", isDirectory: true))
        self.journal = journal
        self.choicesChanged = choicesChanged
        self.contextWindow = contextWindow
        self.driversChanged = driversChanged
    }

    /// The session's driver, made when first asked for.
    public func driver(for sessionID: UUID) -> ChatSessionDriver {
        if let driver = drivers[sessionID] { return driver }
        let record = choicesChanged
        let window = contextWindow
        let changed = driversChanged
        let registry = drivers
        let driver = ChatSessionDriver(
            sessionID: sessionID, runtime: runtime, queueStore: queueStore, journal: journal,
            onChoicesChanged: { choices in Task { @MainActor in record(sessionID, choices) } },
            onContextWindow: { model, size in Task { @MainActor in window(model, size) } },
            onMoved: { from, to in
                registry.move(from: from, to: to)
                Task { @MainActor in changed() }
            }
        )
        drivers[sessionID] = driver
        return driver
    }

    /// The driver whose run is on this card, if there is one.
    public func existingDriver(for sessionID: UUID) -> ChatSessionDriver? { drivers[sessionID] }

    /// Something the app keeps for a driver for as long as the host keeps the driver: made by `make` on first use, then the
    /// same object, whichever card the driver's run is on (it follows a `/clear` with the driver). The live chat keeps
    /// the session's presentation here, so it outlives the views that show it. Gone with `forget`.
    public func existingAttachment<T: AnyObject>(for driver: ChatSessionDriver) -> T? {
        guard let found = attachments[ObjectIdentifier(driver)], found.driver === driver else { return nil }
        return found.value as? T
    }

    public func attachment<T: AnyObject>(for driver: ChatSessionDriver, make: () -> T) -> T {
        let key = ObjectIdentifier(driver)
        if let found = attachments[key], found.driver === driver, let value = found.value as? T { return value }
        let value = make()
        attachments[key] = (driver, value)
        return value
    }

    /// Starts a new Claude session in the Chat face from a draft (title, ticket, workspace, choices, first message).
    @discardableResult
    public func startNewSession(projectID: UUID?, sessionID: UUID = UUID(), draft: NewSessionLaunch? = nil)
        async throws -> ChatSessionDriver {
        let driver = driver(for: sessionID)
        try await driver.startNew(projectID: projectID, draft: draft)
        return driver
    }

    /// Chat → Terminal: ends the Chat-face run in the verified order. The caller then resumes the terminal face with
    /// the same choices (`SessionRuntime.resumeConversation(sessionID:…choices:)`).
    public func leaveChat(sessionID: UUID) async throws {
        guard let driver = drivers[sessionID] else { return }
        let phase = await driver.currentPhase
        if phase.isLive || phase == .starting { try await driver.stop() }
        await driver.noteFace(.continuedInTerminal)
    }

    /// Terminal → Chat: stops the terminal run if one lives (the runtime's verified stop), then resumes the session in
    /// the Chat face.
    public func enterChat(sessionID: UUID) async throws -> ChatSessionDriver {
        let driver = driver(for: sessionID)
        let terminalLives = await runtime.supervisor.session(id: sessionID)?.currentRun != nil
        let chatLives = await driver.currentPhase.isLive
        if terminalLives, !chatLives {
            let report = try await runtime.stopConversation(sessionID: sessionID)
            guard report.succeeded else { throw SessionRuntimeError.unverifiedStop(sessionID) }
        }
        try await driver.resume()
        await driver.noteFace(.backInChat)
        return driver
    }

    /// The session was deleted through Loom: its driver goes, and its queue file with it (the items are what the user
    /// wrote).
    public func forget(sessionID: UUID) {
        if let driver = drivers[sessionID] { attachments[ObjectIdentifier(driver)] = nil }
        drivers[sessionID] = nil
        do { try queueStore.forget(sessionID: sessionID) } catch {
            LoomLog.error(.lifecycle, "A deleted session's Chat queue could not be removed (\(LoomLog.category(of: error)))")
        }
    }

    /// Removes queue files of sessions the catalog no longer has (deleted while no host ran, or by launch recovery).
    public func removeQueuesOfDeletedSessions() async {
        for id in queueStore.sessionIDs() {
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

    func move(from: UUID, to: UUID) {
        state.withLock { drivers in
            guard let driver = drivers.removeValue(forKey: from) else { return }
            drivers[to] = driver
        }
    }
}
