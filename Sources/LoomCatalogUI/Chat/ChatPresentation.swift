import AppKit
import Foundation
import LoomChat
import Observation

/// What the chat view of one session shows and what the reader did to it: the model the rows come from, the view, the
/// folds, flags and "Show all" texts, the working state and the drift notice. It is keyed by the session (its memory is
/// `ChatSessionMemoryStore`'s for that session id), not by the view: a view attaches its `ChatStreamController` and detaches
/// when it goes, and the presentation goes on taking changes without drawing, so a session whose model lives on (a chat driver's)
/// does not start over when its view is made again. The row derivation (`ChatRowStore`, `ChatRowBuilder`) stays the seam: this
/// builds a `ChatBuildInput` and hands the stream what differs.
///
/// It takes `ModelChange`s from a source (`ModelChangeSource`): a snapshot first, then growth. It keeps its own copy of the
/// model, so a source never shares the buffers of a model that grows, and a change costs its size. A change that is not the
/// next one is not applied; `onGap` asks the source for a snapshot.
@MainActor
@Observable
final class ChatPresentation {
    private(set) var viewMode = ChatViewMode.normal
    private(set) var unknownRecordCount = 0
    private(set) var driftDismissed = false
    private(set) var hasOlder = false

    @ObservationIgnored let sessionID: String
    @ObservationIgnored private(set) var model = TurnModel(source: .sessionTranscript)
    @ObservationIgnored private(set) var workingDirectory: String?
    @ObservationIgnored private(set) var isWorking: Bool
    /// The model holds something a source gave (the first snapshot arrived).
    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private(set) weak var controller: ChatStreamController?
    @ObservationIgnored var onGap: (() -> Void)?
    @ObservationIgnored private var toggled: Set<String> = []
    @ObservationIgnored private var flags: [String: Set<String>] = [:]
    @ObservationIgnored private var fullOutputs: [String: ChatFullOutput] = [:]
    @ObservationIgnored private var liveStarts: [String: Date] = [:]
    @ObservationIgnored private var lastActivity: Date?
    /// A request of this session waits for the user (the feed's cards): the live row says "Waiting for you".
    @ObservationIgnored private(set) var isWaitingForUser = false
    /// The last activity comes only from the source's own clock (`setLastActivity`: a chat driver's newest stdout line);
    /// a change applied, a snapshot taken after Loom's own edit included, does not count as activity.
    @ObservationIgnored var activityFromSource = false
    @ObservationIgnored private var lastTurnID: String?
    @ObservationIgnored private var lastSequence = 0
    @ObservationIgnored private var refusedSequence = 0
    @ObservationIgnored private var store = ChatRowStore()
    /// Times the rows were derived for an attached stream so far, and what the last one spent in milliseconds: applying the change to the model, deriving
    /// the rows (`ChatRowStore`), and updating the stream. The last one's total also spaces the streaming flushes
    /// (`streamingInterval`); tests set it to stand for a flush's cost.
    @ObservationIgnored private(set) var rebuilds = 0
    @ObservationIgnored var lastTimings = Timings()
    /// The attached stream has not been given rows yet: the first rows open where the reader was.
    @ObservationIgnored private var needsInitial = false
    /// Streaming text is shown at most once per this interval (nil: every change at once, as the tests and a transcript
    /// follower want it). A change that only grew the text of a block that is still streaming derives its rows at the first
    /// change after a quiet interval, and then once per interval with everything that came meanwhile; any other change
    /// (a new row, a tool, the end of the block, the reader's state) derives the rows at once and takes the text with it.
    @ObservationIgnored var rowsInterval: Duration?
    /// The interval a live chat shows streaming text at: well inside the 100 ms a reader takes for "now".
    static let streamingRowsInterval = Duration.milliseconds(80)
    /// A flush that costs more than its share spaces the next one out: the wait is at least this many times the last rows'
    /// cost (`lastTimings`), so a cheap flush (about 16 ms) keeps the interval and a costly one is not run back to back.
    static let flushCostFactor = 5.0
    /// The longest that cost stretches the interval to.
    static let streamingRowsCeiling = Duration.milliseconds(160)

    /// How long streaming text waits after the last rows now: `rowsInterval`, or `flushCostFactor` times the last flush's cost
    /// up to `streamingRowsCeiling` when that is longer. One cheap flush brings it back to `rowsInterval`. Nil: no wait.
    var streamingInterval: Duration? {
        guard let base = rowsInterval else { return nil }
        return max(base, min(.milliseconds(Self.flushCostFactor * lastFlushCost), Self.streamingRowsCeiling))
    }

    /// What the last flush cost the main thread, in milliseconds: from the start of its rebuild to the end of the run-loop
    /// turn it ran in, after Core Animation committed it (SwiftUI's update, layout and display of the rows included), or
    /// the rebuild alone (`lastTimings`) until that turn has ended.
    var lastFlushCost: Double { max(lastTimings.total, lastTurnMs) }
    @ObservationIgnored private(set) var lastTurnMs = 0.0
    @ObservationIgnored private var turnObserver: CFRunLoopObserver?
    /// After Core Animation's commit observer (order 2,000,000) in the same `beforeWaiting`.
    private static let afterCommitOrder: CFIndex = 2_100_000

    /// Times the run-loop turn of a rebuild that began at `began`, once: the first rebuild of a turn starts the clock, and a
    /// one-shot observer that runs after Core Animation's commit stops it.
    private func timeTurn(from began: ContinuousClock.Instant) {
        guard turnObserver == nil else { return }
        lastTurnMs = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Self.afterCommitOrder) {
            [weak self] observer, _ in
            if let observer { CFRunLoopObserverInvalidate(observer) }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.turnObserver = nil
                self.lastTurnMs = Self.milliseconds(from: began, to: .now)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        turnObserver = observer
    }
    /// The model grew by streaming text that the stream does not show yet, and what grew (for `ChatRowStore`).
    @ObservationIgnored private var pendingDelta: ModelDelta?
    @ObservationIgnored private var lastRowsAt: ContinuousClock.Instant?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Changes whose rows waited for the interval so far (tests and evidence).
    @ObservationIgnored private(set) var deferredChanges = 0

    /// Turns whose rows `ChatRowStore` derived since the presentation was made (tests: a change costs the turns it touched).
    var rowTurnsDerived: Int { store.turnsDerived }

    struct Timings: Equatable {
        var model = 0.0
        var derive = 0.0
        var stream = 0.0

        var total: Double { model + derive + stream }
    }

    init(sessionID: String, workingDirectory: String?, isWorking: Bool = false) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.isWorking = isWorking
        if let memory = ChatSessionMemoryStore.memory(for: sessionID) {
            viewMode = memory.viewMode
            toggled = memory.toggled
            flags = memory.flags
            driftDismissed = memory.driftDismissed
        }
    }

    // MARK: Source

    /// A new source starts counting its changes from 1.
    func beginSource() {
        lastSequence = 0
        refusedSequence = 0
    }

    /// A change that was refused is ahead of what the presentation holds (a snapshot taken meanwhile did not reach it).
    var isBehind: Bool { refusedSequence > lastSequence }

    /// The sequence number a change made by hand (not from a source) takes.
    var nextSequence: Int { lastSequence + 1 }

    /// Takes a change from the source. False when it was not applied: it is old, or it is not the next one (then `onGap` runs).
    @discardableResult
    func apply(_ change: ModelChange) -> Bool {
        guard change.sequence > lastSequence else { return false }
        if change.isEmpty {
            // Nothing in it, but it carries the source's number: ahead of ours means a change never reached us (it was in flight
            // when a feed stopped). Nothing is drawn and the last activity stays.
            refusedSequence = max(refusedSequence, change.sequence)
            onGap?()
            return false
        }
        let began = ContinuousClock.now
        pendingModelMs = 0
        switch change.kind {
        case .replaced, .older:
            guard let whole = change.model else { return false }
            // Older turns put in front keep the rows of the turns they did not change. That holds only when the change is the next
            // one: a later number means growth that never reached us is in it, and the turns it touched have to be built again.
            let reusesRows = change.kind == .older && isLoaded && change.sequence == lastSequence + 1
            let first = !isLoaded
            dropPendingRows()
            model = whole
            isLoaded = true
            lastSequence = change.sequence
            hasOlder = change.hasOlder
            if change.kind == .replaced, !activityFromSource { lastActivity = first ? whole.entries.last?.timestamp : Date() }
            rebuild(cause: reusesRows ? .older : .replaced, fresh: [])
        case .growth:
            guard isLoaded, change.sequence == lastSequence + 1, model.apply(change) else {
                refusedSequence = max(refusedSequence, change.sequence)
                onGap?()
                return false
            }
            lastSequence = change.sequence
            hasOlder = change.hasOlder
            if !activityFromSource { lastActivity = Date() }
            pendingModelMs = Self.milliseconds(since: began)
            if defers(change) { return true }
            rebuild(cause: .growth(change.delta), fresh: Set(change.delta.inserted))
        }
        return true
    }

    /// Whether the rows of `change` wait for the interval: the stream is attached and shows rows, the change only grew the
    /// text of blocks that are still streaming, and the last rows were derived less than `streamingInterval` ago. The wait is
    /// recorded (`pendingDelta`) and ends in `flushRows`.
    private func defers(_ change: ModelChange) -> Bool {
        guard let interval = streamingInterval, controller != nil, let last = lastRowsAt, Self.isStreamingTextOnly(change) else { return false }
        guard ContinuousClock.now < last + interval else { return false }
        pendingDelta = Self.merged(pendingDelta ?? ModelDelta(), change.delta)
        deferredChanges += 1
        if flushTask == nil {
            // The due time is asked again on waking: the turn of the rebuild that this change came with has ended by then, and
            // its cost (`lastTurnMs`, zero while it ran) stretches the wait it was scheduled without.
            flushTask = Task { [weak self] in
                while let due = self?.flushDue, ContinuousClock.now < due {
                    try? await Task.sleep(until: due, clock: .continuous)
                    if Task.isCancelled { return }
                }
                guard let self, !Task.isCancelled else { return }
                flushTask = nil
                flushRows()
            }
        }
        return true
    }

    /// When the waiting text is due: the last rows plus `streamingInterval` as it is now.
    private var flushDue: ContinuousClock.Instant? {
        lastRowsAt.map { $0 + (streamingInterval ?? .zero) }
    }

    private static func merged(_ first: ModelDelta, _ second: ModelDelta) -> ModelDelta {
        var out = first
        out.inserted += second.inserted
        for id in second.updated where !out.inserted.contains(id) && !out.updated.contains(id) { out.updated.append(id) }
        out.turnsChanged = out.turnsChanged || second.turnsChanged
        return out
    }

    /// The change grew the text of streaming blocks and nothing else.
    private static func isStreamingTextOnly(_ change: ModelChange) -> Bool {
        guard change.kind == .growth, change.appended.isEmpty, change.delta.inserted.isEmpty, !change.delta.turnsChanged,
              !change.activityChanged, !change.updated.isEmpty else { return false }
        return change.updated.allSatisfy { entry in
            switch entry.body {
            case let .assistantText(text): text.isStreaming
            case let .thinking(thinking): thinking.isStreaming
            default: false
            }
        }
    }

    /// The rows of the text that grew while the interval ran (the timer calls it; tests call it in place of the clock).
    func flushRows() {
        guard pendingDelta != nil else { return }
        rebuild()
    }

    /// Text grew that the stream does not show yet.
    var hasPendingRows: Bool { pendingDelta != nil }

    private func dropPendingRows() {
        pendingDelta = nil
        flushTask?.cancel()
        flushTask = nil
    }

    // MARK: Stream

    /// A view's stream shows this presentation from now on.
    func attach(_ controller: ChatStreamController) {
        self.controller = controller
        needsInitial = true
        if isLoaded { rebuild(cause: .replaced, fresh: []) }
    }

    /// The view is gone: the presentation keeps its model and takes changes without deriving rows.
    func detach() {
        saveMemory()
        controller = nil
        // The next attach derives every row from the model, with the text that grew meanwhile.
        dropPendingRows()
        lastRowsAt = nil
    }

    // MARK: Reader and session state

    /// The session works now (from the session's status): its newest turn is live and shows the live row.
    func setWorking(_ value: Bool) {
        guard isWorking != value else { return }
        isWorking = value
        if isLoaded { rebuild() }
    }

    /// When the source last heard from the session (a chat driver's newest stdout line, which can come with no change of
    /// the rows): the live row's "No activity" rule reads it. It only moves forward, and by a second or more, so a busy run
    /// redraws its live row at most once a second for it.
    func setLastActivity(_ value: Date?) {
        guard let value, value.timeIntervalSince(lastActivity ?? .distantPast) >= 1 else { return }
        lastActivity = value
        if isLoaded { rebuild() }
    }

    /// Whether a request of this session waits for the user. Only the live row reads it, so only the newest turn is derived again.
    func setWaitingForUser(_ value: Bool) {
        guard isWaitingForUser != value else { return }
        isWaitingForUser = value
        if isLoaded { rebuild() }
    }

    func setWorkingDirectory(_ value: String?) {
        workingDirectory = value
        controller?.context.workingDirectory = value
    }

    func dismissDrift() { driftDismissed = true }

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

    func hasFullOutput(_ id: String) -> Bool { fullOutputs[id] != nil }

    /// What "Show all" read for a tool call.
    func setFullOutput(_ output: ChatFullOutput, for id: String) {
        fullOutputs[id] = output
        rebuild()
    }

    func saveMemory() {
        guard isLoaded else { return }
        let scroll = controller?.memory ?? ChatSessionMemoryStore.memory(for: sessionID)?.scroll ?? ChatScrollMemory()
        ChatSessionMemoryStore.save(ChatSessionMemory(viewMode: viewMode, toggled: toggled, flags: flags, scroll: scroll,
                                                      driftDismissed: driftDismissed), for: sessionID)
    }

    // MARK: Rows

    /// The input of the row derivation, with the state that follows the newest turn kept up to date.
    func buildInput() -> ChatBuildInput {
        if let turn = model.turns.last {
            if lastTurnID != turn.id {
                // A new turn closes the previous turn's fold if the reader had opened it.
                if let previous = lastTurnID, viewMode != .verbose { toggled.remove(ChatRowBuilder.foldID(previous)) }
                lastTurnID = turn.id
            }
            if isWorking, turn.startedAt == nil, liveStarts[turn.id] == nil { liveStarts[turn.id] = Date() }
        }
        return ChatBuildInput(model: model, mode: viewMode, toggled: toggled, flags: flags, fullOutputs: fullOutputs,
                              isWorking: isWorking, hasOlder: hasOlder, workingDirectory: workingDirectory,
                              liveStarts: liveStarts, lastActivity: lastActivity, isWaitingForUser: isWaitingForUser)
    }

    /// Hands the attached stream what differs from the rows it has (`ChatRowStore`). `cause` says what changed; without one,
    /// only the reader's state did. Nothing is derived while no stream is attached.
    private func rebuild(cause: ChatRowStore.Cause = .state, fresh: Set<String> = []) {
        let began = ContinuousClock.now
        var cause = cause
        // Text that grew while the interval ran is part of this rebuild, whatever asked for it.
        if let pending = pendingDelta {
            switch cause {
            case .state:
                cause = .growth(pending)
            case let .growth(delta):
                cause = .growth(Self.merged(delta, pending))
            case .older, .replaced:
                break
            }
        }
        dropPendingRows()
        let input = buildInput()
        unknownRecordCount = model.unknownRecordCount
        guard let controller else { return }
        rebuilds += 1
        lastRowsAt = began
        timeTurn(from: began)
        let change = store.update(input, cause: cause)
        let derived = ContinuousClock.now
        switch change {
        case let .all(rows):
            controller.apply(rows, fresh: fresh, hasOlder: hasOlder,
                             initial: needsInitial ? ChatSessionMemoryStore.memory(for: sessionID)?.scroll : nil)
            needsInitial = false
        case let .patches(patches):
            controller.apply(patches: patches, fresh: fresh, hasOlder: hasOlder)
        }
        #if DEBUG
        if Self.verifiesRows { verify(controller, input) }
        #endif
        lastTimings = Timings(model: pendingModelMs, derive: Self.milliseconds(from: began, to: derived),
                              stream: Self.milliseconds(from: derived, to: .now))
        pendingModelMs = 0
    }

    @ObservationIgnored private var pendingModelMs = 0.0

    #if DEBUG
    /// Checks, after every rebuild, that the stream holds the rows `ChatRowBuilder` derives from scratch (a debug build only,
    /// and costly: it derives all of them). Tests turn it on; `onMismatch` gets the report, and without it a mismatch stops the
    /// debug build.
    nonisolated(unsafe) static var verifiesRows = false
    nonisolated(unsafe) static var onMismatch: ((String) -> Void)?

    private func verify(_ controller: ChatStreamController, _ input: ChatBuildInput) {
        let expected = ChatRowBuilder.rows(input)
        guard controller.rows != expected || store.rows != expected else { return }
        let first = zip(controller.rows, expected).enumerated().first { $1.0 != $1.1 }?.offset ?? min(controller.rows.count, expected.count)
        let report = "session \(sessionID): rows differ from a full rebuild at \(first) (\(controller.rows.count) shown, \(expected.count) expected)"
        if let onMismatch = Self.onMismatch { onMismatch(report) } else { assertionFailure(report) }
    }
    #endif

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double { milliseconds(from: start, to: .now) }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let d = end - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
