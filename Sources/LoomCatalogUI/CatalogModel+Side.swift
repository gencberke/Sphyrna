import Foundation
import LoomChat
import LoomCore
import Observation

// The Side tab (V22 part 3) on the model: a session's side chats, which one the tab shows, the question that starts or continues
// one, "Send to main as a note", Close and Discard. A side chat is a fork of the session (part 2's engine, reached only through
// `ChatSessionHost.sideChatDriver(for:parentSessionID:)` and `startSideChat(parentSessionID:)`), a real session of the catalog that no
// list shows. Its stream is the main chat's own (`LiveChatFeed`, the same rows) cut at the fork's first question, and it has no
// `SessionRowModel` and no `ChatComposerModel`: the tab's composer (`SideComposerView`) is its own small one. Nothing here is
// written to disk; what the tab remembers (the open side chat, the typed text) lives in memory.

// MARK: Words

/// What the tab says. One place, so a test reads the same words the views draw.
enum SideText {
    static let tabTitle = "Side"
    static let emptyState = "Ask on the side. A side chat is a copy of this session: it sees the session up to now, and the main session never sees it."
    static let forkUnsupported = "This Claude version cannot fork a session"
    static let unavailable = "Side chats are not available here"
    static let headerTitle = "Side chat"
    static let newSideChat = "New side chat"
    static let earlier = "Earlier side chats"
    static let placeholder = "Ask on the side"
    static let close = "Close"
    static let modelHelp = "Same model as the session, so it reuses its cache"
    static let allowEdits = "Allow edits"
    static let allowEditsHelp = "Claude may ask to change files or run commands here. Each request asks you first."
    static let discard = "Discard Side Chat"
    static let sendNote = "Send to Main as a Note"
    static let noteSent = "Sent to the main session"
    static let notesNeedChat = "Notes go to Claude in a Chat session"
    static let discardTitle = "Discard this side chat?"
    static let discardMessage = "Loom deletes its copy of the session. The main session is not touched."
    static let discardCancel = "Cancel"
    static let discardConfirm = "Discard"
    static let discarding = "Discarding this side chat…"
    static let starting = "Starting the side chat…"

    /// "Forked at 14:05 · sees the session up to then · the main session never sees it". The time is the app's own format:
    /// the time alone on the day of the fork, else with the day.
    static func headerNote(forkedAt: Date, now: Date = Date()) -> String {
        let when = Calendar.current.isDate(forkedAt, inSameDayAs: now)
            ? LoomDateFormat.time(forkedAt) : ChatTime.label(for: forkedAt, now: now)
        return "Forked at \(when) \u{00B7} sees the session up to then \u{00B7} the main session never sees it"
    }

    /// An entry of the "Earlier side chats" menu: the first line of the question, cut, and when it was forked.
    static func earlierEntry(_ item: SideChatItem, now: Date = Date()) -> String {
        let question = item.title.map { line -> String in
            line.count > LoomTheme.Side.earlierQuestionLimit ? String(line.prefix(LoomTheme.Side.earlierQuestionLimit)) + "…" : line
        } ?? "No question yet"
        return "\(question) \u{00B7} \(ChatTime.label(for: item.forkedAt, now: now))"
    }

    /// The message "Send to main as a note" sends: the side question quoted line by line, then the answer.
    static func note(question: String, answer: String) -> String {
        let quoted = question.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        return "A note from a side chat:\n\n\(quoted)\n\n\(answer)"
    }
}

// MARK: One side chat as the tab lists it

struct SideChatItem: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The fork's Claude session id, which names its transcript.
    let conversationID: String?
    let forkedAt: Date
    /// The uuid of the first question; nil until one was sent. The thread starts at its record.
    let firstUUID: String?
    /// The first line of the first question, the card's title.
    let title: String?
    let lastActivityAt: Date

    init?(_ record: CatalogSession) {
        guard let link = record.sideChat else { return nil }
        id = record.session.id
        conversationID = record.session.providerConversationID
        forkedAt = link.forkedAt
        firstUUID = link.firstUUID
        title = record.title
        lastActivityAt = record.lastActivityAt
    }
}

// MARK: Following a side chat's driver

/// What the tab reads of a running side chat, kept up to date from its driver: whether it runs, waits for the user, and whether
/// edits are allowed. The tab bar's dot and the composer's bar read these; nothing outside the tab does.
@MainActor @Observable
final class SideChatLive {
    let id: UUID
    @ObservationIgnored let driver: ChatSessionDriver
    private(set) var phase: ChatDriverPhase = .stopped
    private(set) var isWaiting = false
    private(set) var allowsEdits = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Told, on the main actor, after every read: the session service decides whether this side chat has to end now (D-72).
    @ObservationIgnored var onRead: (@MainActor () -> Void)?

    init(id: UUID, driver: ChatSessionDriver) {
        self.id = id
        self.driver = driver
    }

    isolated deinit { task?.cancel() }

    var isRunning: Bool { phase.isLive }

    func start() {
        guard task == nil else { return }
        let driver = driver
        task = Task { [weak self] in
            let updates = await driver.updates()
            await self?.read()
            for await _ in updates {
                guard let self, !Task.isCancelled else { return }
                await read()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The follower's task runs (`start()` made it and `stop()` has not ended it).
    var isFollowing: Bool { task != nil }

    func read() async {
        let state = await driver.liveState()
        let side = await driver.sideChatState()
        if phase != state.phase { phase = state.phase }
        let waiting = !state.requests.isEmpty
        if isWaiting != waiting { isWaiting = waiting }
        let edits = side?.allowsEdits ?? false
        if allowsEdits != edits { allowsEdits = edits }
        onRead?()
    }
}

// MARK: What the answers offer

/// The two things a finished side answer offers besides Copy, and where each stands (V22 part 3). The stream's rows read it
/// (`ChatRowContext.sideNotes`); it is observable, so the button becomes "Sent to the main session" in place.
@MainActor @Observable
final class SideAnswerNotes {
    enum Status: Equatable {
        case idle
        case sending
        case sent
        case failed(String)
    }

    enum Availability: Equatable {
        case ready
        /// Off, with the reason the button's help gives.
        case off(String)
    }

    private(set) var statuses: [String: Status] = [:]
    /// Read by the row when it draws, so it follows the parent session (it stops, or leaves the Chat face) without a state of
    /// its own.
    @ObservationIgnored var availability: () -> Availability = { .ready }
    @ObservationIgnored var send: (_ answerID: String) -> Void = { _ in }

    func status(for answerID: String) -> Status { statuses[answerID] ?? .idle }

    func setStatus(_ status: Status, for answerID: String) {
        if statuses[answerID] != status { statuses[answerID] = status }
    }
}

// MARK: The discard question

/// The sheet's question. The default button is Cancel, so a Return never discards; Discard is a click.
@MainActor @Observable
final class SideDiscardRequest: Identifiable {
    enum Button: Equatable { case cancel, discard }

    nonisolated let id: UUID
    let title: String

    /// What Return does in the sheet.
    static let defaultButton = Button.cancel

    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

// MARK: One session's side chats

@MainActor @Observable
final class SideSession {
    let parentID: UUID
    /// The session's side chats, newest first.
    private(set) var items: [SideChatItem] = []
    /// The one the tab shows; nil is the empty state (nothing opened yet, or "New side chat"). Every change is told to
    /// `onShown`.
    private(set) var openID: UUID?
    /// The field's text, kept while the tab is away.
    var composerText = ""
    /// One quiet line under the field: why the last question did not go.
    var notice: String?
    /// A fork is starting or a question is going out.
    private(set) var isBusy = false
    /// The CLI refused to fork: the composer is off for this run of the app.
    var forkUnsupported = false
    var discard: SideDiscardRequest?
    private(set) var discarding: Set<UUID> = []
    private(set) var discardFailures: [UUID: String] = [:]
    private(set) var lives: [UUID: SideChatLive] = [:]
    @ObservationIgnored private(set) var notes: [UUID: SideAnswerNotes] = [:]
    /// Side chats that were sent a question in this run: their thread is not empty, whether or not the card has its uuid yet.
    private(set) var asked: Set<UUID> = []
    /// The tab chose what to show once; later reads leave the choice alone.
    @ObservationIgnored var choseDefault = false
    /// Told when the tab shows another side chat (or none).
    @ObservationIgnored var onShown: (@MainActor (UUID?) -> Void)?
    /// Told when a followed side chat was read (its id).
    @ObservationIgnored var onRead: (@MainActor (UUID) -> Void)?
    @ObservationIgnored private var parentDriver: ChatSessionDriver?
    @ObservationIgnored private var parentWatch: Task<Void, Never>?

    init(parentID: UUID) { self.parentID = parentID }

    func item(_ id: UUID?) -> SideChatItem? { id.flatMap { id in items.first { $0.id == id } } }

    var openItem: SideChatItem? { item(openID) }

    func show(_ id: UUID?) {
        guard openID != id else { return }
        openID = id
        onShown?(id)
    }

    func setItems(_ value: [SideChatItem]) {
        if items != value { items = value }
    }

    func setBusy(_ value: Bool) { if isBusy != value { isBusy = value } }

    func markAsked(_ id: UUID) { asked.insert(id) }

    func hasAsked(_ id: UUID) -> Bool { asked.contains(id) }

    /// One of the side chats waits for the user: the tab bar's dot.
    var isWaiting: Bool { lives.values.contains { $0.isWaiting } }

    func live(for id: UUID?) -> SideChatLive? { id.flatMap { lives[$0] } }

    @discardableResult
    func follow(_ driver: ChatSessionDriver, id: UUID) -> SideChatLive {
        if let known = lives[id], known.driver === driver { return known }
        lives[id]?.stop()
        let made = SideChatLive(id: id, driver: driver)
        made.onRead = { [weak self] in self?.onRead?(id) }
        lives[id] = made
        made.start()
        return made
    }

    /// Watches the parent's driver: `onStopped` runs when its run ends, by a Stop, by itself or in a move to the terminal (the
    /// service tells the move from a stop), with the card the driver's run is on then (not the parent's own after a `/clear`).
    /// One watch per driver.
    func watchParent(_ driver: ChatSessionDriver, onStopped: @escaping @MainActor (_ runCard: UUID) async -> Void) {
        guard parentDriver !== driver else { return }
        parentWatch?.cancel()
        parentDriver = driver
        parentWatch = Task {
            var wasLive = false
            for await _ in await driver.updates() {
                guard !Task.isCancelled else { return }
                let live = await driver.liveState().phase.isLive
                defer { wasLive = live }
                guard wasLive, !live else { continue }
                await onStopped(await driver.sessionID)
            }
        }
    }

    func noteModel(for id: UUID) -> SideAnswerNotes {
        if let known = notes[id] { return known }
        let made = SideAnswerNotes()
        notes[id] = made
        return made
    }

    func setDiscarding(_ id: UUID, _ value: Bool) {
        if value { discarding.insert(id) } else { discarding.remove(id) }
    }

    func setDiscardFailure(_ text: String?, for id: UUID) {
        if discardFailures[id] != text { discardFailures[id] = text }
    }

    /// The parent session is gone: the watch of its run and every follower stop.
    func stopFollowing() {
        parentWatch?.cancel()
        parentWatch = nil
        parentDriver = nil
        for live in lives.values { live.stop() }
        lives = [:]
    }

    /// The side chat is gone: everything held for it goes.
    func forget(_ id: UUID) {
        lives[id]?.stop()
        lives[id] = nil
        notes[id] = nil
        discarding.remove(id)
        discardFailures[id] = nil
        if openID == id { show(nil) }
        items.removeAll { $0.id == id }
    }
}

/// The sessions' side-chat holders, made on first use by an action or a read (never by a view's body).
@MainActor @Observable
final class SideState {
    private(set) var sessions: [UUID: SideSession] = [:]
    /// A followed side chat was read (parent, side chat).
    @ObservationIgnored var onRead: (@MainActor (UUID, UUID) -> Void)?
    /// The tab of a session shows another side chat, or none (parent, side chat).
    @ObservationIgnored var onShown: (@MainActor (UUID, UUID?) -> Void)?

    func existing(for id: UUID?) -> SideSession? { id.flatMap { sessions[$0] } }

    func session(for id: UUID) -> SideSession {
        if let known = sessions[id] { return known }
        let made = SideSession(parentID: id)
        made.onRead = { [weak self] sideID in self?.onRead?(id, sideID) }
        made.onShown = { [weak self] sideID in self?.onShown?(id, sideID) }
        sessions[id] = made
        return made
    }

    /// The parent was deleted: its holder goes and every follower it had is stopped.
    func forget(_ id: UUID) {
        sessions.removeValue(forKey: id)?.stopFollowing()
    }
}

/// What the inspector's side read is for: the session whose tab bar and tab are looked at.
struct SideTrigger: Equatable {
    let session: UUID
}

// MARK: The model

extension CatalogModel {
    // MARK: When the tab is offered

    /// A Claude session that has a provider conversation id, on either face. A side chat itself never has the tab (it is never
    /// selected), and Codex never does.
    func sideTabIsOffered(for row: SessionRowModel?) -> Bool {
        guard let row, capabilities(of: row.record.session.provider).sideChats, !row.record.isSideChat else { return false }
        let identity = row.live?.conversationID ?? row.record.session.providerConversationID
        return identity?.isEmpty == false
    }

    /// The tab bar's dot: one of the session's side chats waits for the user.
    func sideChatIsWaiting(for sessionID: UUID?) -> Bool {
        side.existing(for: sessionID)?.isWaiting ?? false
    }

    /// What the side read is for now: the selected session while its inspector is open and the tab is offered.
    var sideTrigger: SideTrigger? {
        guard let id = selectedSessionID, inspector.isOpen(for: id), sideTabIsOffered(for: selectedRow) else { return nil }
        return SideTrigger(session: id)
    }

    func runSideRead() async {
        guard let trigger = sideTrigger else { return }
        await refreshSideChats(for: trigger.session)
    }

    private func sideRow(_ sessionID: UUID) -> SessionRowModel? {
        selectedRow?.id == sessionID ? selectedRow : rowModels[sessionID]
    }

    // MARK: Reading the list

    /// Reads the session's side chats from the catalog (newest first). A driver that exists for one is followed, so a side chat
    /// that waits raises the tab's dot whether or not the tab is open. The first read opens one if nothing is open: the one that
    /// waits, else the newest that runs.
    func refreshSideChats(for parent: UUID) async {
        guard let catalog, let records = try? await catalog.sideChats(of: parent) else { return }
        let session = side.session(for: parent)
        let items = records.compactMap(SideChatItem.init).sorted { ($0.forkedAt, $0.id.uuidString) > ($1.forkedAt, $1.id.uuidString) }
        session.setItems(items)
        if let open = session.openID, session.item(open) == nil, !session.discarding.contains(open) { session.show(nil) }
        for item in items {
            if let driver = chatSessions?.existingDriver(for: item.id) { followSideChat(driver, id: item.id, in: parent) }
        }
        guard !session.choseDefault else { return }
        session.choseDefault = true
        guard session.openID == nil else { return }
        let waiting = items.first { session.live(for: $0.id)?.isWaiting == true }
        let running = items.first { session.live(for: $0.id)?.isRunning == true }
        if let chosen = waiting ?? running { session.show(chosen.id) }
    }

    // MARK: Choosing what the tab shows

    /// The driver of a listed side chat, made as a side chat's (the host's way) and followed. A stopped one is not started.
    @discardableResult
    func sideDriver(for id: UUID, in parent: UUID) -> ChatSessionDriver? {
        guard let host = chatSessions else { return nil }
        let driver = host.sideChatDriver(for: id, parentSessionID: parent)
        followSideChat(driver, id: id, in: parent)
        return driver
    }

    /// Follows a side chat's driver, and the parent's run once, so the session service learns when the parent's run ended and
    /// when a side chat it is waiting for has settled (D-72).
    @discardableResult
    private func followSideChat(_ driver: ChatSessionDriver, id: UUID, in parent: UUID) -> SideChatLive {
        let session = side.session(for: parent)
        if let parentDriver = chatSessions?.existingDriver(for: parent) {
            session.watchParent(parentDriver) { [weak self, weak session] runCard in
                guard let self, let session else { return }
                await sessions?.parentRunEnded(parent, runCard: runCard, sideChats: Array(session.lives.keys))
            }
        }
        return session.follow(driver, id: id)
    }

    /// The tab shows another side chat (or none): the service retires the one it showed (D-72).
    private func retirePreviouslyOpen(_ previous: UUID?, in parent: UUID) {
        guard let previous else { return }
        Task { [weak self] in
            guard let self else { return }
            // The follower is what tells the service when it has settled.
            if let driver = chatSessions?.existingDriver(for: previous) { followSideChat(driver, id: previous, in: parent) }
            await sessions?.sideChatLeft(previous, in: parent)
        }
    }

    /// Opens one of the session's side chats in the tab (from "Earlier side chats").
    func openSideChat(_ id: UUID, in parent: UUID) {
        let session = side.session(for: parent)
        guard session.item(id) != nil else { return }
        session.choseDefault = true
        sideDriver(for: id, in: parent)
        let previous = session.openID
        session.show(id)
        session.notice = nil
        if previous != id { retirePreviouslyOpen(previous, in: parent) }
    }

    /// "New side chat": an empty thread; the next question forks again.
    func startNewSideChat(in parent: UUID) {
        let session = side.session(for: parent)
        session.choseDefault = true
        let previous = session.openID
        session.show(nil)
        session.notice = nil
        retirePreviouslyOpen(previous, in: parent)
    }

    // MARK: Asking

    /// The question in the field goes to the open side chat, or, with none open, starts a fork and goes to that. A message that
    /// begins with "/" is refused where it stands, before anything is forked: a side chat runs no command.
    func submitSideQuestion(in parent: UUID) async {
        let session = side.session(for: parent)
        let text = session.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.isBusy else { return }
        session.notice = nil
        if text.hasPrefix("/") {
            session.notice = ChatSessionDriver.commandsRefusedText
            return
        }
        if session.forkUnsupported {
            session.notice = SideText.forkUnsupported
            return
        }
        guard let host = chatSessions else {
            session.notice = SideText.unavailable
            return
        }
        session.setBusy(true)
        defer { session.setBusy(false) }
        do {
            let driver: ChatSessionDriver
            if let open = session.openID, session.item(open) != nil, let existing = sideDriver(for: open, in: parent) {
                driver = existing
            } else {
                driver = try await host.startSideChat(parentSessionID: parent)
                let id = await driver.sessionID
                followSideChat(driver, id: id, in: parent)
                await refreshSideChats(for: parent)
                session.show(id)
            }
            session.composerText = ""
            session.markAsked(await driver.sessionID)
            try await driver.send(text, timing: .next)
            // The first question's uuid and title were written by the send: the thread starts there.
            await refreshSideChats(for: parent)
        } catch {
            if session.composerText.isEmpty { session.composerText = text }
            if Self.isForkUnsupported(error) {
                session.forkUnsupported = true
                session.notice = SideText.forkUnsupported
            } else if case ChatDriverError.commandsRefused = error {
                session.notice = ChatSessionDriver.commandsRefusedText
            } else {
                session.notice = Self.userMessage(for: error, context: "The side question could not be sent")
            }
        }
    }

    nonisolated static func isForkUnsupported(_ error: any Error) -> Bool {
        if case let LoomError.message(text) = error { return text == SideText.forkUnsupported }
        return false
    }

    // MARK: Close, edits, discard

    /// "Close": the side chat's process stops in the driver's stop order. The thread stays, read from the fork's transcript, and
    /// the next question resumes it. The toggle "Allow edits" reads off once the run is gone (the face's Close stop does that).
    func closeSideChat(_ id: UUID, in parent: UUID) async {
        guard sideDriver(for: id, in: parent) != nil else { return }
        var failure: (any Error)?
        if let sessions {
            failure = await sessions.closeSideChat(id)
        } else {
            do { try await chatSessions?.closeSession(sessionID: id) } catch { failure = error }
        }
        if let failure { side.session(for: parent).notice = Self.sideChatCloseFailedText(failure) }
    }

    nonisolated static func sideChatCloseFailedText(_ error: any Error) -> String {
        userMessage(for: error, context: "The side chat could not be closed")
    }

    /// "Allow edits" for this side chat only: the driver's policy turns edits and writing commands into cards.
    func setSideAllowsEdits(_ allowed: Bool, chat id: UUID, in parent: UUID) async {
        guard let driver = sideDriver(for: id, in: parent) else { return }
        await driver.setAllowsEdits(allowed)
        await side.session(for: parent).live(for: id)?.read()
    }

    /// "Discard side chat…": opens the question; nothing is deleted until it is confirmed.
    func requestDiscardSideChat(_ id: UUID, in parent: UUID) {
        let session = side.session(for: parent)
        guard let item = session.item(id), !session.discarding.contains(id) else { return }
        session.discard = SideDiscardRequest(id: id, title: item.title ?? SideText.headerTitle)
    }

    func cancelDiscardSideChat(in parent: UUID) {
        side.existing(for: parent)?.discard = nil
    }

    /// The sheet's Discard: part 2's `discardSideChat` stops the fork and deletes its copy through the verified path.
    func confirmDiscardSideChat(in parent: UUID) async {
        let session = side.session(for: parent)
        guard let request = session.discard, let host = chatSessions else { return }
        session.discard = nil
        await discardSideChat(request.id, in: parent, host: host)
    }

    /// "Try again" on a discard that did not finish.
    func retryDiscardSideChat(_ id: UUID, in parent: UUID) async {
        guard let host = chatSessions, !side.session(for: parent).discarding.contains(id) else { return }
        await discardSideChat(id, in: parent, host: host)
    }

    private func discardSideChat(_ id: UUID, in parent: UUID, host: ChatSessionHost) async {
        let session = side.session(for: parent)
        guard !session.discarding.contains(id) else { return }
        session.setDiscarding(id, true)
        session.setDiscardFailure(nil, for: id)
        defer { session.setDiscarding(id, false) }
        do {
            switch try await host.discardSideChat(id: id) {
            case .deleted:
                session.forget(id)
                deletions.finish(id)
            case let .incomplete(record):
                deletions.setPending(record)
                session.setDiscardFailure(DeletionCopy.bannerText(lastFailure: record.lastFailure), for: id)
            }
        } catch {
            session.setDiscardFailure(Self.userMessage(for: error, context: "The side chat could not be discarded"), for: id)
        }
    }

    // MARK: The stream

    /// The open side chat's stream: the main chat's `LiveChatFeed` over the fork's driver, with no history before the first
    /// question, the same rows, and cards that never offer "Allow for this session". Made by the first view that shows it and
    /// kept with the driver.
    func sideFeed(for item: SideChatItem, in parent: UUID) -> LiveChatFeed? {
        guard let host = chatSessions, let driver = host.existingDriver(for: item.id) else { return nil }
        let config = claudeConfigDirectory
        let directory = sideRow(parent)?.record.session.workingDirectory
        let sideSession = side.session(for: parent)
        let id = item.id
        return chatAttachments.attachment(for: driver) {
            let feed = LiveChatFeed(source: driver, card: id, conversationID: item.conversationID, configDirectory: config,
                                    workingDirectory: directory)
            // The card is read again at each history read: the first question's uuid is written when it is sent.
            feed.sideFirstUUID = { [weak sideSession] in sideSession?.item(id)?.firstUUID }
            feed.cards.offersSessionGrants = false
            feed.onUnused = { [weak attachments = chatAttachments, weak driver] in
                guard let attachments, let driver else { return }
                attachments.releaseAttachment(for: driver)
            }
            return feed
        }
    }

    /// The notes holder of a side chat's stream, wired to "Send to main as a note".
    func sideNotes(for id: UUID, in parent: UUID) -> SideAnswerNotes {
        let notes = side.session(for: parent).noteModel(for: id)
        notes.send = { [weak self] answerID in
            Task { await self?.sendSideNote(answerID: answerID, chat: id, in: parent) }
        }
        notes.availability = { [weak self] in self?.sideNoteAvailability(for: parent) ?? .off(SideText.notesNeedChat) }
        return notes
    }

    // MARK: Send to main

    /// A note goes to a Chat session: a live one, or a stopped one the Chat face owns (the send resumes it). A terminal-face
    /// session has no message to send to.
    func sideNoteAvailability(for parent: UUID) -> SideAnswerNotes.Availability {
        changesSendAvailability(for: parent) == .ready ? .ready : .off(SideText.notesNeedChat)
    }

    /// The question and the answer a "Send to main" names: the answer is the finished answer's row, the question the prompt that
    /// started its turn (the last prompt of the main thread before it).
    func sideQuestionAndAnswer(forAnswer answerID: String, chat id: UUID, in parent: UUID) -> (question: String, answer: String)? {
        guard let host = chatSessions, let driver = host.existingDriver(for: id),
              let feed: LiveChatFeed = chatAttachments.existingAttachment(for: driver) else { return nil }
        let model = feed.joinedModel
        guard let position = model.entries.firstIndex(where: { $0.id == answerID }),
              case let .assistantText(answer) = model.entries[position].body else { return nil }
        for entry in model.entries[..<position].reversed() {
            guard entry.thread == .main, case let .user(prompt) = entry.body, !prompt.isBrief else { continue }
            return (prompt.text, answer.text)
        }
        return nil
    }

    /// "Send to main as a note": one message to the parent session through the path the composer's Return takes there
    /// (`next`), as the Changes tab's comments do. A confirmation replaces the button; a refused send shows its reason.
    func sendSideNote(answerID: String, chat id: UUID, in parent: UUID) async {
        let session = side.session(for: parent)
        let notes = session.noteModel(for: id)
        guard notes.status(for: answerID) != .sending, notes.status(for: answerID) != .sent,
              sideNoteAvailability(for: parent) == .ready,
              let thread = sideQuestionAndAnswer(forAnswer: answerID, chat: id, in: parent) else { return }
        notes.setStatus(.sending, for: answerID)
        do {
            _ = try await sendChatMessage(SideText.note(question: thread.question, answer: thread.answer), to: parent)
            notes.setStatus(.sent, for: answerID)
        } catch {
            notes.setStatus(.failed(Self.userMessage(for: error, context: "The note could not be sent")), for: answerID)
        }
    }
}
