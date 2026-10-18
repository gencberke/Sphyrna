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
    @ObservationIgnored private var lastTurnID: String?
    @ObservationIgnored private var lastSequence = 0
    @ObservationIgnored private var refusedSequence = 0
    @ObservationIgnored private var store = ChatRowStore()
    /// Times the rows were derived for an attached stream so far, and what the last one spent in milliseconds: applying the change to the model, deriving
    /// the rows (`ChatRowStore`), and updating the stream. For the budget tests and for measuring; not for logic.
    @ObservationIgnored private(set) var rebuilds = 0
    @ObservationIgnored private(set) var lastTimings = Timings()
    /// The attached stream has not been given rows yet: the first rows open where the reader was.
    @ObservationIgnored private var needsInitial = false

    struct Timings: Equatable {
        var model = 0.0
        var derive = 0.0
        var stream = 0.0
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
            model = whole
            isLoaded = true
            lastSequence = change.sequence
            hasOlder = change.hasOlder
            if change.kind == .replaced { lastActivity = first ? whole.entries.last?.timestamp : Date() }
            rebuild(cause: reusesRows ? .older : .replaced, fresh: [])
        case .growth:
            guard isLoaded, change.sequence == lastSequence + 1, model.apply(change) else {
                refusedSequence = max(refusedSequence, change.sequence)
                onGap?()
                return false
            }
            lastSequence = change.sequence
            hasOlder = change.hasOlder
            lastActivity = Date()
            pendingModelMs = Self.milliseconds(since: began)
            rebuild(cause: .growth(change.delta), fresh: Set(change.delta.inserted))
        }
        return true
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
                              liveStarts: liveStarts, lastActivity: lastActivity)
    }

    /// Hands the attached stream what differs from the rows it has (`ChatRowStore`). `cause` says what changed; without one,
    /// only the reader's state did. Nothing is derived while no stream is attached.
    private func rebuild(cause: ChatRowStore.Cause = .state, fresh: Set<String> = []) {
        let began = ContinuousClock.now
        let input = buildInput()
        unknownRecordCount = model.unknownRecordCount
        guard let controller else { return }
        rebuilds += 1
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
