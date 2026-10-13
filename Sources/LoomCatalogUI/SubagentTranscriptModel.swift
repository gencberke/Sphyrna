import Foundation
import LoomCore
import Observation

/// What the subagent panel shows (FB4-5): the entries of one subagent's transcript, fed by a
/// `SubagentTranscriptFeed` that exists only while the panel is on screen and the window is visible.
/// The ring keeps the last `ringLimit` entries; the brief is kept apart from it, so it stays when the ring
/// moves on. A batch is one observable update, and the feed has already parsed it off the main thread.
@MainActor
@Observable
final class SubagentTranscriptModel {
    static let ringLimit = 400

    struct Item: Identifiable, Equatable {
        let id: Int
        let entry: SubagentTranscriptEntry
    }

    enum Phase: Equatable {
        /// The feed is not started yet or has not delivered its first batch.
        case loading
        case live
        /// Nothing can be read: the subagent's transcript was not found, or is not a file Loom may open.
        case unavailable
    }

    private(set) var items: [Item] = []
    private(set) var brief: String?
    /// Entries before the first one shown exist but are not shown: the ring moved on, or the file's start
    /// was not read.
    private(set) var omitsEarlier = false
    private(set) var phase = Phase.loading
    private(set) var isRunning: Bool

    @ObservationIgnored let agentID: String
    @ObservationIgnored private(set) var transcriptPath: String?
    @ObservationIgnored private let locate: @MainActor (String) async -> SubagentTranscriptFile?
    @ObservationIgnored private let coalescing: TimeInterval
    @ObservationIgnored private var feed: SubagentTranscriptFeed?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var onScreen = false
    @ObservationIgnored private var windowVisible: Bool
    @ObservationIgnored private var closed = false

    /// `locate` turns the record's path into a checked file (or nothing); the model never opens a path itself.
    init(agentID: String, transcriptPath: String?, isRunning: Bool, windowVisible: Bool,
         coalescing: TimeInterval = SubagentTranscriptFeed.defaultCoalescing,
         locate: @escaping @MainActor (String) async -> SubagentTranscriptFile?) {
        self.agentID = agentID
        self.transcriptPath = transcriptPath
        self.isRunning = isRunning
        self.windowVisible = windowVisible
        self.coalescing = coalescing
        self.locate = locate
    }

    deinit {
        starting?.cancel()
        consumer?.cancel()
        feed?.stop()
    }

    /// A feed exists right now.
    var isFeeding: Bool { feed != nil }
    var entryCount: Int { items.count }

    // MARK: Inputs

    /// The panel's view appeared or went away.
    func setOnScreen(_ value: Bool) {
        onScreen = value
        reconcile()
    }

    /// The window can be seen (the catalog model's visibility edge).
    func setWindowVisible(_ value: Bool) {
        windowVisible = value
        reconcile()
    }

    func setRunning(_ value: Bool) {
        if isRunning != value { isRunning = value }
    }

    /// The record learned the path after the panel opened (its meta file was read late).
    func setTranscriptPath(_ path: String?) {
        guard transcriptPath == nil, let path else { return }
        transcriptPath = path
        if phase == .unavailable { phase = .loading }
        reconcile()
    }

    /// The panel is closed for good.
    func close() {
        closed = true
        stopFeed()
    }

    // MARK: Feed

    private func reconcile() {
        let wanted = !closed && onScreen && windowVisible
        if wanted { startFeed() } else { stopFeed() }
    }

    private func startFeed() {
        guard feed == nil, starting == nil else { return }
        guard let path = transcriptPath else {
            if phase != .unavailable { phase = .unavailable }
            return
        }
        generation += 1
        let mine = generation
        let locate = locate
        starting = Task { [weak self] in
            let file = await locate(path)
            guard let self, generation == mine else { return }
            starting = nil
            guard let file, let opened = SubagentTranscriptFeed(file: file, coalescing: coalescing) else {
                if phase != .unavailable { phase = .unavailable }
                return
            }
            feed = opened
            let batches = opened.batches
            consumer = Task { [weak self] in
                for await batch in batches {
                    guard !Task.isCancelled else { return }
                    self?.apply(batch)
                }
            }
            opened.start()
        }
    }

    private func stopFeed() {
        generation += 1
        starting?.cancel()
        starting = nil
        consumer?.cancel()
        consumer = nil
        feed?.stop()
        feed = nil
    }

    // MARK: Batches

    /// One batch is one update of the observable state.
    func apply(_ batch: SubagentTranscriptBatch) {
        var ring = batch.replacesEarlier ? [] : items
        var omitted = batch.replacesEarlier ? batch.omitsEarlier : (omitsEarlier || batch.omitsEarlier)
        var newBrief = brief
        var sawBrief = false
        for entry in batch.entries {
            // The first brief of a batch that starts the file over, or the first ever, is the panel's brief.
            if case let .brief(text) = entry, !sawBrief, newBrief == nil || batch.replacesEarlier {
                newBrief = text
                sawBrief = true
                continue
            }
            ring.append(Item(id: nextID, entry: entry))
            nextID += 1
        }
        if ring.count > Self.ringLimit {
            ring.removeFirst(ring.count - Self.ringLimit)
            omitted = true
        }
        items = ring
        if brief != newBrief { brief = newBrief }
        if omitsEarlier != omitted { omitsEarlier = omitted }
        if phase != .live { phase = .live }
    }
}
