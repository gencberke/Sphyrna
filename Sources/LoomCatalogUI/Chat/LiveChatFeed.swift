import Foundation
import LoomChat
import LoomCore
import Observation

/// The live chat of one Chat-face driver (V16): the session's `ChatPresentation`, fed by the driver's changes under the
/// history its transcript holds. The app's `ChatSessionHost` keeps one per driver for as long as it keeps the driver, so the
/// presentation (model, folds, view, scroll memory) outlives the views that show it and a window that is covered.
///
/// - History: the transcript is cold-opened once, through a `TranscriptLens`, and cut where the live run begins
///   (`LiveHistoryJoin`); older turns load from the lens when the reader scrolls up. No `TranscriptGrowthFeed` runs: while
///   the driver owns the session, everything new comes from the driver, so nothing is drawn twice.
/// - Live: the driver's `ModelChangeSource`, applied in order. A change that is not the next number, or that does not fit
///   the model held, asks the driver for a snapshot. The presentation gets numbers of its own, from 1 per presentation.
/// - Runs: the driver keeps its model across a Stop and a resume, or Chat → Terminal → Chat. Only the newest run's part
///   is shown live; when a new run begins, the history is read again (the transcript now holds the earlier runs and
///   whatever ran in the terminal between them) and the stream rebuilt.
/// - `/clear`: the driver moves to a new card and its model starts over. The feed follows it with a new presentation (the
///   old card's is saved), without history: the new card's stream begins with the marker.
/// - Live state (`updates`): working, the newest stdout line (the live row's "No activity" rule), the policy signal and
///   drift that is not an unknown record (those have their own notice, from the rows).
@MainActor
@Observable
final class LiveChatFeed: ChatDriverAttachment {
    enum Phase: Equatable {
        /// The history and the driver's first snapshot are on their way: nothing is drawn yet.
        case opening
        case ready
    }

    private(set) var phase = Phase.opening
    /// The presentation of the card the run is on. A new one after `/clear`.
    private(set) var presentation: ChatPresentation
    private(set) var policySignal: ChatPolicySignal?
    var policyDismissed = false
    /// Drift signals other than unknown records (a capability the CLI did not list, an API error category).
    private(set) var wireDrift = 0
    var wireDriftDismissed = false

    @ObservationIgnored let source: any ChatLiveSource
    /// The cards that wait above the composer (approvals, questions, plans): V18. They follow the driver's live state.
    @ObservationIgnored let cards: PinnedCardsModel
    @ObservationIgnored private(set) var card: UUID
    @ObservationIgnored private var conversationID: String?
    @ObservationIgnored private let configDirectory: URL?
    @ObservationIgnored private(set) var workingDirectory: String?
    @ObservationIgnored private let locate: @Sendable (String, URL, String?) -> ClaudeTranscriptFile?
    @ObservationIgnored private let limits: TranscriptLens.Limits
    @ObservationIgnored private var join = LiveHistoryJoin(live: TurnModel(source: .live))
    @ObservationIgnored private var lens: TranscriptLens?
    /// The newest driver change applied; nil until the first snapshot.
    @ObservationIgnored private var driverSequence: Int?
    /// The number the presentation got last.
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var historyRead = false
    @ObservationIgnored private var readingHistory = false
    /// The run (`RunStart.generation`) the history was read for: a new one reads it again.
    @ObservationIgnored private var readGeneration: Int?
    /// "Show all" asked while the history was being read again: done once it is there.
    @ObservationIgnored private var pendingShowAll: [ChatEntry] = []
    /// Views showing the feed now (attached or not), and whether the driver's run lives: a feed nobody shows whose run
    /// is over can go (`isInUse`).
    @ObservationIgnored private(set) var viewCount = 0
    @ObservationIgnored private var driverLive = false
    /// The feed is no longer needed: its owner (the app's host) lets it go.
    @ObservationIgnored var onUnused: (() -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private weak var controller: ChatStreamController?
    @ObservationIgnored private var loadingOlder = false
    @ObservationIgnored private var loadingFull: Set<String> = []
    /// Snapshots asked of the driver after a gap (tests read it).
    @ObservationIgnored private(set) var snapshotsAsked = 0

    /// Older reads in a row at the start while the history read lies inside the live run.
    static let olderRoundsAtOpen = 20
    /// Lines "Show all" scans for a live entry's result, from where the live run's lines begin.
    static let liveScanLines = 50_000

    /// - Parameters:
    ///   - card: the card the driver's run is on.
    ///   - conversationID: the Claude session id (the transcript's name and the presentation's memory key), when known.
    ///   - configDirectory: the profile's config directory the transcript lies below; nil reads no history.
    init(source: any ChatLiveSource, card: UUID, conversationID: String?, configDirectory: URL?, workingDirectory: String?,
         limits: TranscriptLens.Limits = TranscriptLens.Limits(),
         locate: @escaping @Sendable (String, URL, String?) -> ClaudeTranscriptFile? = {
             ClaudeTranscriptLocator.locate(sessionID: $0, configDirectory: $1, workingDirectory: $2)
         }) {
        self.source = source
        cards = PinnedCardsModel(source: source)
        self.card = card
        self.conversationID = conversationID
        self.configDirectory = configDirectory
        self.workingDirectory = workingDirectory
        self.limits = limits
        self.locate = locate
        presentation = ChatPresentation(sessionID: conversationID ?? card.uuidString, workingDirectory: workingDirectory)
        // The live row's "No activity" follows the driver's stdout, not Loom's own edits (`follow`).
        presentation.activityFromSource = true
        wire(presentation)
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        presentation.detach()
        if let lens { Task { await lens.close() } }
    }

    private func wire(_ presentation: ChatPresentation) {
        // A presentation that missed a change rebuilds from the joined model (never re-entered from inside its `apply`).
        presentation.onGap = { [weak self, weak presentation] in
            Task { @MainActor in
                guard let self, let presentation, presentation === self.presentation else { return }
                self.presentWhole()
            }
        }
    }

    // MARK: Starting

    /// Reads the history and follows the driver. Idempotent; the feed then runs for as long as it lives.
    func start() {
        guard !started else { return }
        started = true
        let source = source
        tasks.append(Task { [weak self] in
            let changes = await source.modelChanges().changes
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                await take(change)
            }
        })
        tasks.append(Task { [weak self] in
            let updates = await source.updates()
            for await _ in updates {
                let state = await source.liveState()
                guard let self, !Task.isCancelled else { return }
                follow(state)
            }
        })
        tasks.append(Task { [weak self] in await self?.readHistory() })
    }

    private func readHistory() async {
        let opened = card
        readingHistory = true
        defer {
            readingHistory = false
            if card == opened {
                historyRead = true
                presentWhole()
                let waiting = pendingShowAll
                pendingShowAll = []
                for entry in waiting { loadingFull.remove(entry.id); showAll(entry) }
            }
        }
        let state = await source.liveState()
        guard card == opened else { return }
        if state.sessionID == card {
            join.setRunStart(state.runStart)
            readGeneration = state.runStart.generation
        }
        guard let lens = await openLens() else { return }
        let first = await lens.coldOpenChange()
        guard card == opened, let model = first.model else { return }
        join.setHistory(model, hasOlder: first.hasOlder)
        // A cold open that lies inside the live run keeps nothing: read on until something before the run shows.
        var rounds = 0
        while join.needsOlder, rounds < Self.olderRoundsAtOpen, let older = await lens.loadOlderChange(), card == opened,
              let model = older.model {
            join.setHistory(model, hasOlder: older.hasOlder)
            rounds += 1
        }
    }

    /// The lens on the transcript of the conversation the run is in: opened once, when first needed.
    private func openLens() async -> TranscriptLens? {
        if let lens { return lens }
        let opened = card
        if conversationID == nil {
            let state = await source.liveState()
            if state.sessionID == card { conversationID = state.conversationID }
        }
        guard let id = conversationID, let configDirectory else { return nil }
        let locate = locate, directory = workingDirectory, limits = limits
        let found = await Task.detached(priority: .userInitiated) { locate(id, configDirectory, directory) }.value
        guard card == opened, lens == nil, let found, let made = TranscriptLens(file: found, limits: limits) else { return lens }
        lens = made
        return made
    }

    /// A new run began: the history is read again from a new lens (the old one read from where its reads left off), and
    /// nothing is handed to the presentation until it is there.
    private func readHistoryAgain() {
        historyRead = false
        readingHistory = true
        if let lens {
            self.lens = nil
            Task { await lens.close() }
        }
        join.clearHistory()
        tasks.append(Task { [weak self] in await self?.readHistory() })
    }

    // MARK: The driver's changes

    private func take(_ change: ModelChange) async {
        switch change.kind {
        case .replaced, .older:
            if let last = driverSequence, change.sequence < last { return }
            let state = await source.liveState()
            if let last = driverSequence, change.sequence < last { return }
            if state.sessionID != card { moved(to: state) }
            driverSequence = change.sequence
            _ = join.apply(change)
            presentWhole()
        case .growth:
            guard let last = driverSequence, change.sequence > last else { return }
            guard change.sequence == last + 1 else { return await resnapshot() }
            switch join.apply(change) {
            case let .growth(moved):
                driverSequence = change.sequence
                present(moved)
            case .rebuilt:
                driverSequence = change.sequence
                presentWhole()
            case .unchanged:
                driverSequence = change.sequence
            case .refused:
                await resnapshot()
            }
        }
    }

    private func resnapshot() async {
        snapshotsAsked += 1
        let snapshot = await source.snapshotChange()
        await take(snapshot)
    }

    /// The run moved to a new card (`/clear`): a new presentation, no history.
    private func moved(to state: ChatLiveState) {
        let newCard = state.sessionID
        card = newCard
        conversationID = nil
        if let lens {
            self.lens = nil
            Task { await lens.close() }
        }
        join.clearHistory()
        join.setRunStart(state.runStart)
        readGeneration = state.runStart.generation
        historyRead = true
        for entry in pendingShowAll { loadingFull.remove(entry.id) }
        pendingShowAll = []
        let attached = controller
        presentation.detach()
        presentation = ChatPresentation(sessionID: newCard.uuidString, workingDirectory: workingDirectory,
                                        isWorking: presentation.isWorking)
        presentation.activityFromSource = true
        presentation.setLastActivity(state.lastActivity)
        wire(presentation)
        sequence = 0
        if let attached { presentation.attach(attached) }
    }

    // MARK: Handing changes to the presentation

    private var canPresent: Bool { historyRead && driverSequence != nil }

    /// The joined model as a whole (the first build, a cut moved, a snapshot, a move).
    private func presentWhole() {
        guard canPresent else { return }
        if phase != .ready {
            phase = .ready
        }
        if sequence == 0 { presentation.beginSource() }
        sequence += 1
        presentation.apply(join.model.snapshot(sequence: sequence, hasOlder: join.hasOlder))
    }

    private func present(_ change: ModelChange) {
        guard canPresent else { return }
        var numbered = change
        sequence += 1
        numbered.sequence = sequence
        presentation.apply(numbered)
    }

    private func follow(_ state: ChatLiveState) {
        if state.sessionID == card, let id = state.conversationID { conversationID = id }
        // A new run, even one that added nothing: what ran since the last read (a terminal's turns) is read in.
        if state.sessionID == card, historyRead, !readingHistory, let read = readGeneration, state.runStart.generation != read {
            readHistoryAgain()
        }
        cards.apply(state)
        let live = state.phase.isLive || state.phase == .starting || state.phase == .stopping
        if driverLive != live {
            let wasInUse = isInUse
            driverLive = live
            if wasInUse, !isInUse { onUnused?() }
        }
        presentation.setWorking(state.turnRunning)
        presentation.setLastActivity(state.lastActivity)
        if policySignal != state.policySignal { policySignal = state.policySignal }
        let drift = state.drift.filter { if case .unknownRecord = $0 { false } else { true } }.count
        if wireDrift != drift { wireDrift = drift }
    }

    // MARK: Views

    /// The feed is shown by a view, or its run lives: the host keeps it.
    var isInUse: Bool { viewCount > 0 || driverLive }

    /// A view of the feed appeared (`attach` follows once it can be seen) or went for good.
    func viewAppeared() { viewCount += 1 }

    func viewWentAway(_ controller: ChatStreamController) {
        detach(controller)
        viewCount = max(0, viewCount - 1)
        if !isInUse { onUnused?() }
    }

    /// The ended view of a session (its transcript, with the cards its run's end cut off above the bottom edge) shows the
    /// feed's cards: it counts as a view, so the host keeps the feed while that view is on screen and lets it go (as the least
    /// recently used) once nobody shows it. The driver keeps what was cut off, so the next view reads it again.
    func endedViewAppeared() {
        viewCount += 1
        followState()
    }

    func endedViewWentAway() {
        viewCount = max(0, viewCount - 1)
        if !isInUse { onUnused?() }
    }

    /// The driver's live state once, for the cards (a feed made for an ended view starts no history read or stream).
    private func followState() {
        let source = source
        tasks.append(Task { [weak self] in
            let state = await source.liveState()
            guard let self, !Task.isCancelled else { return }
            follow(state)
        })
    }

    /// A view's stream shows the presentation (and the next one after a move) from now on. One stream at a time: Loom
    /// shows a session's chat in one place (the detail pane of its one window, for the selected session), and a second
    /// view that attaches takes the presentation over; the earlier one keeps its last rows until it attaches again.
    func attach(_ controller: ChatStreamController) {
        guard self.controller !== controller || presentation.controller !== controller else { return }
        self.controller = controller
        controller.context.workingDirectory = workingDirectory
        presentation.attach(controller)
    }

    /// The view went or cannot be seen: the presentation keeps taking changes without drawing.
    func detach(_ controller: ChatStreamController) {
        guard self.controller === controller else { return }
        presentation.detach()
        self.controller = nil
    }

    func setWorkingDirectory(_ value: String?) {
        guard workingDirectory != value else { return }
        workingDirectory = value
        presentation.setWorkingDirectory(value)
    }

    /// Older turns of the history, when the reader scrolls to the top.
    func loadOlder(_ controller: ChatStreamController?) {
        guard !loadingOlder, join.hasOlder, let lens else {
            controller?.olderLoadFinished()
            return
        }
        loadingOlder = true
        let opened = card
        Task { [weak self] in
            let change = await lens.loadOlderChange()
            guard let self else { return }
            loadingOlder = false
            // A read again (a new run) or a move replaced the lens meanwhile: this read is of the old one.
            if card == opened, self.lens === lens, let change, let model = change.model {
                join.setHistory(model, hasOlder: change.hasOlder)
                if canPresent {
                    sequence += 1
                    presentation.apply(join.model.snapshot(sequence: sequence, kind: .older, hasOlder: join.hasOlder))
                }
            }
            controller?.olderLoadFinished()
        }
    }

    /// "Show all" for a clipped tool result: a history row reads its own line; a live row's result is found by scanning the
    /// transcript from where the live run's lines begin.
    func showAll(_ entry: ChatEntry) {
        let target = presentation
        guard !target.hasFullOutput(entry.id), loadingFull.insert(entry.id).inserted else { return }
        // A live row's scan starts where the run's lines begin, which a history being read again does not know yet.
        guard entry.sourceOffset != nil || historyRead else {
            pendingShowAll.append(entry)
            return
        }
        let id = entry.id
        Task { [weak self] in
            guard let self else { return }
            let lens = await openLens()
            let offset = entry.sourceOffset ?? join.liveLinesStart ?? 0
            let scan = entry.sourceOffset == nil ? Self.liveScanLines : 400
            let prepared: ChatFullOutput
            if let lens {
                prepared = await Task.detached(priority: .userInitiated) { () -> ChatFullOutput in
                    guard let text = await lens.fullToolResult(toolUseID: id, from: offset, scanLines: scan) else { return .missing }
                    return ChatFullOutput.prepared(text)
                }.value
            } else {
                prepared = .missing
            }
            loadingFull.remove(id)
            guard target === presentation else { return }
            target.setFullOutput(prepared, for: id)
        }
    }

    /// "Show all" can read a clipped result: a history row has its line; a live row needs the transcript's folder.
    func canShowAll(_ entry: ChatEntry) -> Bool { entry.sourceOffset != nil || configDirectory != nil }

    // MARK: The composer

    /// The session's earlier messages, oldest first: what ↑ in the composer recalls (history and live, main thread). Read
    /// when a recall begins, never per keystroke.
    func userMessageTexts() -> [String] {
        join.model.entries.compactMap { entry in
            // The typed text alone: a pasted chip's content is never recalled into the field.
            guard entry.thread == .main, case let .user(prompt) = entry.body, !prompt.isBrief,
                  case let text = prompt.recallText ?? prompt.text, !text.isEmpty else { return nil }
            return text
        }
    }

    // MARK: Tests and evidence

    /// The joined model the presentation should hold.
    var joinedModelForTesting: TurnModel { join.model }

    /// Where the feed stands, as numbers (evidence).
    var progress: [String: Any] {
        ["driverSequence": driverSequence ?? -1, "presented": sequence, "liveEntries": join.live.entries.count,
         "historyEntries": join.history.entries.count, "runStartEntries": join.runStart.entries, "historyRead": historyRead,
         "readingHistory": readingHistory]
    }
}
