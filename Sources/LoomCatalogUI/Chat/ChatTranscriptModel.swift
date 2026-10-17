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
/// (live tail). It finds the file, cold-opens the newest turns through a `TranscriptLens`, derives the rows, and follows
/// the file with a `TranscriptGrowthFeed` only while the view is on screen and the window can be seen. Everything that
/// draws or scrolls is the `ChatStreamController`'s.
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
    private(set) var viewMode = ChatViewMode.normal
    private(set) var isFollowing = true
    private(set) var showsJump = false
    private(set) var unknownRecordCount = 0
    private(set) var driftDismissed = false
    var isFeeding: Bool { feed != nil }
    private(set) var hasOlder = false

    @ObservationIgnored let controller: ChatStreamController
    @ObservationIgnored let sessionID: String
    @ObservationIgnored private(set) var workingDirectory: String?
    @ObservationIgnored let configDirectory: URL
    @ObservationIgnored private let locate: @Sendable (String, URL, String?) -> ClaudeTranscriptFile?
    @ObservationIgnored private var lens: TranscriptLens?
    @ObservationIgnored private var feed: TranscriptGrowthFeed?
    @ObservationIgnored private var file: ClaudeTranscriptFile?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var model = TurnModel(source: .sessionTranscript)
    @ObservationIgnored private var toggled: Set<String> = []
    @ObservationIgnored private var flags: [String: Set<String>] = [:]
    @ObservationIgnored private var fullOutputs: [String: ChatFullOutput] = [:]
    @ObservationIgnored private var loadingFull: Set<String> = []
    @ObservationIgnored private var liveStarts: [String: Date] = [:]
    @ObservationIgnored private var lastActivity: Date?
    @ObservationIgnored private var lastBytes = 0
    @ObservationIgnored private var loadingOlder = false
    @ObservationIgnored private var onScreen = false
    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private(set) var isWorking: Bool
    @ObservationIgnored private var lastTurnID: String?
    @ObservationIgnored var onOpenSubagent: ((_ agentID: String?, _ toolUseID: String) -> Void)?

    init(sessionID: String, configDirectory: URL, workingDirectory: String?, isWorking: Bool = false,
         locate: @escaping @Sendable (String, URL, String?) -> ClaudeTranscriptFile? = {
             ClaudeTranscriptLocator.locate(sessionID: $0, configDirectory: $1, workingDirectory: $2)
         }) {
        self.sessionID = sessionID
        self.configDirectory = configDirectory
        self.workingDirectory = workingDirectory
        self.isWorking = isWorking
        self.locate = locate
        let context = ChatRowContext()
        context.workingDirectory = workingDirectory
        controller = ChatStreamController(context: context)
        if let memory = ChatSessionMemoryStore.memory(for: sessionID) {
            viewMode = memory.viewMode
            toggled = memory.toggled
            flags = memory.flags
            driftDismissed = memory.driftDismissed
        }
        wireController()
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
        context.toggle = { [weak self] id in self?.toggle(id) }
        context.toggleFlag = { [weak self] id, flag in self?.toggleFlag(id, flag) }
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
        let id = sessionID, config = configDirectory, directory = workingDirectory, locate = locate
        opening = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { locate(id, config, directory) }.value
            guard !Task.isCancelled, let self else { return }
            guard let found, let opened = TranscriptLens(file: found) else {
                phase = .unavailable
                opening = nil
                return
            }
            let update = await opened.coldOpen()
            guard !closed, !Task.isCancelled else {
                await opened.close()
                return
            }
            lens = opened
            file = found
            opening = nil
            lastBytes = update.bytesRead
            model = update.model
            hasOlder = update.hasOlder
            lastActivity = update.model.entries.last?.timestamp
            phase = .ready
            rebuild(initial: true)
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
    func setWorking(_ value: Bool) {
        guard isWorking != value else { return }
        isWorking = value
        if phase == .ready { rebuild() }
    }

    func setWorkingDirectory(_ value: String?) {
        workingDirectory = value
        controller.context.workingDirectory = value
    }

    func dismissDrift() {
        driftDismissed = true
    }

    // MARK: Feed

    private func reconcileFeed() {
        let wanted = onScreen && windowVisible && phase == .ready && !closed
        controller.setAnimates(windowVisible && onScreen)
        if wanted { startFeed() } else { stopFeed() }
    }

    private func startFeed() {
        guard feed == nil, let lens, let file else { return }
        let opened = TranscriptGrowthFeed(file: file, lens: lens)
        feed = opened
        generation += 1
        let mine = generation
        let updates = opened.updates
        consumer = Task { [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled, generation == mine else { return }
                apply(update)
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

    /// The file grew (or was replaced): take the lens's model and redraw the rows it touched.
    func apply(_ update: TranscriptLens.Update) {
        // An update computed before a later one (an older page was loaded meanwhile) would put the model back.
        guard update.bytesRead >= lastBytes else { return }
        lastBytes = update.bytesRead
        model = update.model
        hasOlder = update.hasOlder
        lastActivity = Date()
        var fresh = Set(update.delta.inserted)
        if update.restarted { fresh = [] }
        rebuild(fresh: fresh)
    }

    // MARK: Older turns

    func loadOlder() {
        guard !loadingOlder, hasOlder, let lens else {
            controller.olderLoadFinished()
            return
        }
        loadingOlder = true
        Task { [weak self] in
            let update = await lens.loadOlder()
            guard let self else { return }
            loadingOlder = false
            if let update, update.bytesRead >= lastBytes {
                lastBytes = update.bytesRead
                model = update.model
                hasOlder = update.hasOlder
                rebuild()
            }
            controller.olderLoadFinished()
        }
    }

    // MARK: Rows

    /// Derives the rows from the model and the view's state, and hands them to the stream.
    func rebuild(fresh: Set<String> = [], initial: Bool = false) {
        if let turn = model.turns.last {
            if lastTurnID != turn.id {
                // A new turn closes the previous turn's fold if the reader had opened it.
                if let previous = lastTurnID, viewMode != .verbose { toggled.remove(ChatRowBuilder.foldID(previous)) }
                lastTurnID = turn.id
            }
            if isWorking, turn.startedAt == nil, liveStarts[turn.id] == nil { liveStarts[turn.id] = Date() }
        }
        let input = ChatBuildInput(model: model, mode: viewMode, toggled: toggled, flags: flags, fullOutputs: fullOutputs,
                                   isWorking: isWorking, hasOlder: hasOlder, workingDirectory: workingDirectory,
                                   liveStarts: liveStarts, lastActivity: lastActivity)
        let rows = ChatRowBuilder.rows(input)
        unknownRecordCount = model.unknownRecordCount
        controller.apply(rows, fresh: fresh, hasOlder: hasOlder,
                         initial: initial ? ChatSessionMemoryStore.memory(for: sessionID)?.scroll : nil)
    }

    // MARK: Actions

    func toggle(_ rowID: String) {
        if toggled.contains(rowID) { toggled.remove(rowID) } else { toggled.insert(rowID) }
        rebuild()
    }

    func toggleFlag(_ rowID: String, _ flag: String) {
        var set = flags[rowID] ?? []
        if set.contains(flag) { set.remove(flag) } else { set.insert(flag) }
        flags[rowID] = set.isEmpty ? nil : set
        rebuild()
    }

    func cycleViewMode() {
        viewMode = viewMode.next
        rebuild()
    }

    func setViewMode(_ mode: ChatViewMode) {
        guard viewMode != mode else { return }
        viewMode = mode
        rebuild()
    }

    /// "Show all": reads the whole result of a clipped tool call from the transcript. The read and the cut to about 1 MiB
    /// happen off the main thread; the row gets the cut text, or says the result could not be read.
    func showAll(_ entry: ChatEntry) {
        guard let lens, let offset = entry.sourceOffset, fullOutputs[entry.id] == nil, loadingFull.insert(entry.id).inserted else { return }
        let id = entry.id
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) { () -> ChatFullOutput in
                guard let text = await lens.fullToolResult(toolUseID: id, from: offset) else { return .missing }
                return ChatFullOutput.prepared(text)
            }.value
            guard let self else { return }
            loadingFull.remove(id)
            guard !closed else { return }
            fullOutputs[id] = prepared
            rebuild()
        }
    }

    func jumpToLatest() { controller.jumpToLatest() }

    // MARK: Memory and shutdown

    func saveMemory() {
        guard phase == .ready else { return }
        ChatSessionMemoryStore.save(ChatSessionMemory(viewMode: viewMode, toggled: toggled, flags: flags,
                                                      scroll: controller.memory, driftDismissed: driftDismissed), for: sessionID)
    }

    /// The view is closed for good: nothing watches, ticks or animates any more.
    func close() {
        guard !closed else { return }
        saveMemory()
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
