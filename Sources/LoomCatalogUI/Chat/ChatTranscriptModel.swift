import AppKit
import Foundation
import LoomChat
import LoomCore
import Observation

/// What a session's chat view keeps since launch (CHAT-SPEC → Scrolling → Memory, Views): its view, the folds and bodies
/// the reader opened, and where the reader was. Bounded to the last 64 sessions.
struct ChatSessionMemory: Equatable {
    var viewMode = ChatViewMode.normal
    var toggled: Set<String> = []
    var flags: [String: Set<String>] = [:]
    var scroll = ChatScrollMemory()
    var driftDismissed = false
}

@MainActor
enum ChatSessionMemoryStore {
    private static var entries: [String: ChatSessionMemory] = [:]
    private static var order: [String] = []
    static let limit = 64

    static func memory(for key: String) -> ChatSessionMemory? { entries[key] }

    static func save(_ memory: ChatSessionMemory, for key: String) {
        entries[key] = memory
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit { entries[order.removeFirst()] = nil }
    }

    static func removeAll() {
        entries = [:]
        order = []
    }
}

/// The chat view of one session whose history is a transcript file: stopped (read only) or running in a terminal
/// (live tail). It finds the file, cold-opens the newest turns through a `TranscriptLens`, and follows the file with a
/// `TranscriptGrowthFeed` only while the view is on screen and the window can be seen. It hands the lens's changes to the
/// session's `ChatPresentation`, which holds the model and the reader's state and derives the rows; everything that draws or
/// scrolls is the `ChatStreamController`'s.
@MainActor
@Observable
final class ChatTranscriptModel {
    enum Phase: Equatable {
        case resolving
        case ready
        /// No transcript resolves: the owner draws its fallback (the kept last screen).
        case unavailable
    }

    private(set) var phase = Phase.resolving
    private(set) var isFollowing = true
    private(set) var showsJump = false
    var viewMode: ChatViewMode { presentation.viewMode }
    var unknownRecordCount: Int { presentation.unknownRecordCount }
    var driftDismissed: Bool { presentation.driftDismissed }
    var hasOlder: Bool { presentation.hasOlder }
    var isFeeding: Bool { feed != nil }
    var isWorking: Bool { presentation.isWorking }
    var workingDirectory: String? { presentation.workingDirectory }
    /// The model the rows come from: the presentation's own copy.
    var model: TurnModel { presentation.model }

    @ObservationIgnored let controller: ChatStreamController
    @ObservationIgnored let presentation: ChatPresentation
    @ObservationIgnored let sessionID: String
    @ObservationIgnored let configDirectory: URL
    @ObservationIgnored private let locate: @Sendable (String, URL, String?) -> ClaudeTranscriptFile?
    @ObservationIgnored private let limits: TranscriptLens.Limits
    @ObservationIgnored private var lens: TranscriptLens?
    @ObservationIgnored private var feed: TranscriptGrowthFeed?
    @ObservationIgnored private var file: ClaudeTranscriptFile?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadingFull: Set<String> = []
    @ObservationIgnored private var loadingOlder = false
    @ObservationIgnored private var resyncing = false
    @ObservationIgnored private var onScreen = false
    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored var onOpenSubagent: ((_ agentID: String?, _ toolUseID: String) -> Void)?

    init(sessionID: String, configDirectory: URL, workingDirectory: String?, isWorking: Bool = false,
         limits: TranscriptLens.Limits = TranscriptLens.Limits(),
         locate: @escaping @Sendable (String, URL, String?) -> ClaudeTranscriptFile? = {
             ClaudeTranscriptLocator.locate(sessionID: $0, configDirectory: $1, workingDirectory: $2)
         }) {
        self.sessionID = sessionID
        self.configDirectory = configDirectory
        self.locate = locate
        self.limits = limits
        presentation = ChatPresentation(sessionID: sessionID, workingDirectory: workingDirectory, isWorking: isWorking)
        let context = ChatRowContext()
        context.workingDirectory = workingDirectory
        controller = ChatStreamController(context: context)
        wireController()
        presentation.attach(controller)
        presentation.onGap = { [weak self] in self?.resync() }
    }

    isolated deinit {
        opening?.cancel()
        consumer?.cancel()
        feed?.stop()
        controller.stop()
        if let lens { Task { await lens.close() } }
    }

    // MARK: Wiring

    private func wireController() {
        let context = controller.context
        context.toggle = { [weak self] id in self?.presentation.toggle(id) }
        context.toggleFlag = { [weak self] id, flag in self?.presentation.toggleFlag(id, flag) }
        context.showAll = { [weak self] entry in self?.showAll(entry) }
        context.openSubagent = { [weak self] run in self?.onOpenSubagent?(run.agentID, run.toolUseID) }
        context.openImage = { image in ChatQuickLook.show(image) }
        controller.onNeedOlder = { [weak self] in self?.loadOlder() }
        controller.onCycleView = { [weak self] in self?.cycleViewMode() }
        controller.onLatchChange = { [weak self] following, jump in
            guard let self else { return }
            if isFollowing != following { isFollowing = following }
            if showsJump != jump { showsJump = jump }
        }
    }

    // MARK: Opening

    /// Finds the transcript and reads its newest turns. Idempotent.
    func open() {
        guard opening == nil, lens == nil, !closed else { return }
        let id = sessionID, config = configDirectory, directory = workingDirectory, locate = locate, limits = limits
        opening = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { locate(id, config, directory) }.value
            guard !Task.isCancelled, let self else { return }
            guard let found, let opened = TranscriptLens(file: found, limits: limits) else {
                phase = .unavailable
                opening = nil
                return
            }
            let first = await opened.coldOpenChange()
            guard !closed, !Task.isCancelled else {
                await opened.close()
                return
            }
            lens = opened
            file = found
            opening = nil
            presentation.beginSource()
            phase = .ready
            presentation.apply(first)
            reconcileFeed()
        }
    }

    // MARK: Inputs

    /// The view appeared or went away.
    func setOnScreen(_ value: Bool) {
        onScreen = value
        if value { open() } else { saveMemory() }
        reconcileFeed()
    }

    /// The window can be seen (not hidden, minimised or covered). A hidden window runs no feed, timer or animation; the
    /// lens keeps its place in the file, so showing it again reads what was written meanwhile.
    func setWindowVisible(_ value: Bool) {
        windowVisible = value
        controller.setAnimates(value && onScreen)
        reconcileFeed()
    }

    /// The session works now (from the session's status): its newest turn is live and shows the live row.
    func setWorking(_ value: Bool) { presentation.setWorking(value) }

    func setWorkingDirectory(_ value: String?) {
        presentation.setWorkingDirectory(value)
    }

    func dismissDrift() { presentation.dismissDrift() }

    // MARK: Feed

    private func reconcileFeed() {
        let wanted = onScreen && windowVisible && phase == .ready && !closed
        controller.setAnimates(windowVisible && onScreen)
        if wanted { startFeed() } else { stopFeed() }
    }

    private func startFeed() {
        guard feed == nil, let lens, let file else { return }
        let opened = TranscriptGrowthFeed(file: file, lens: lens, delivery: .changes)
        feed = opened
        generation += 1
        let mine = generation
        let changes = opened.changes
        consumer = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled, generation == mine else { return }
                presentation.apply(change)
                opened.acknowledge()
            }
        }
        opened.start()
    }

    private func stopFeed() {
        generation += 1
        consumer?.cancel()
        consumer = nil
        feed?.stop()
        feed = nil
    }

    /// The lens (tests read it to lose a change).
    var lensForTesting: TranscriptLens? { lens }

    /// The presentation missed a change (one was lost with a stopped feed, or arrived out of order): ask the lens for the model
    /// as it is. A change that was refused while the snapshot was on its way is behind that snapshot only if the snapshot was
    /// taken first; the presentation says so (`isBehind`), and the snapshot is asked for again.
    private func resync(again: Bool = true) {
        guard !resyncing, let lens else { return }
        resyncing = true
        Task { [weak self] in
            let snapshot = await lens.snapshotChange()
            guard let self else { return }
            resyncing = false
            presentation.apply(snapshot)
            if again, presentation.isBehind, !closed { resync(again: false) }
        }
    }

    /// Takes a whole `TranscriptLens.Update` (a caller that holds a lens of its own, tests): the first one is the model, the
    /// later ones are growth by the update's delta.
    func apply(_ update: TranscriptLens.Update) {
        let next = presentation.nextSequence
        if !presentation.isLoaded || update.restarted {
            presentation.apply(update.model.snapshot(sequence: next, hasOlder: update.hasOlder))
        } else {
            presentation.apply(update.model.growth(sequence: next, entriesBefore: presentation.model.entries.count,
                                                   turnsBefore: presentation.model.turns.count, delta: update.delta,
                                                   hasOlder: update.hasOlder))
        }
    }

    // MARK: Older turns

    func loadOlder() {
        guard !loadingOlder, hasOlder, let lens else {
            controller.olderLoadFinished()
            return
        }
        loadingOlder = true
        Task { [weak self] in
            let change = await lens.loadOlderChange()
            guard let self else { return }
            loadingOlder = false
            if let change { presentation.apply(change) }
            controller.olderLoadFinished()
        }
    }

    // MARK: Actions

    func toggle(_ rowID: String) { presentation.toggle(rowID) }

    func cycleViewMode() { presentation.cycleViewMode() }

    func setViewMode(_ mode: ChatViewMode) { presentation.setViewMode(mode) }

    /// "Show all": reads the whole result of a clipped tool call from the transcript. The read and the cut to about 1 MiB
    /// happen off the main thread; the row gets the cut text, or says the result could not be read.
    func showAll(_ entry: ChatEntry) {
        guard let lens, let offset = entry.sourceOffset, !presentation.hasFullOutput(entry.id), loadingFull.insert(entry.id).inserted else { return }
        let id = entry.id
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) { () -> ChatFullOutput in
                guard let text = await lens.fullToolResult(toolUseID: id, from: offset) else { return .missing }
                return ChatFullOutput.prepared(text)
            }.value
            guard let self else { return }
            loadingFull.remove(id)
            guard !closed else { return }
            presentation.setFullOutput(prepared, for: id)
        }
    }

    func jumpToLatest() { controller.jumpToLatest() }

    // MARK: Memory and shutdown

    func saveMemory() { presentation.saveMemory() }

    /// The view is closed for good: nothing watches, ticks or animates any more.
    func close() {
        guard !closed else { return }
        presentation.detach()
        closed = true
        opening?.cancel()
        stopFeed()
        controller.stop()
        if let lens {
            self.lens = nil
            Task { await lens.close() }
        }
    }
}
