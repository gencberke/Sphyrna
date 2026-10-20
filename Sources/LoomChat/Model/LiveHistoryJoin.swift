import Foundation

/// A Chat-face run's live model shown under the session's history from its transcript (V16): one stream, the
/// transcript's older turns above and the driver's live turns below, with nothing twice and nothing lost at the joint.
///
/// The transcript holds the live run's records too (the CLI writes them as the run goes), so the history is cut before the
/// first entry that is also in the live run. Content entries decide the cut, at the entry, so a turn that began before the
/// run keeps what it held. An entry of the history is the live run's when:
/// - it has the id of a live entry: an answer by its API message id and block, a tool by its call id, a prompt sent while
///   idle by the uuid Loom sent it with, a prompt a running turn read (`queued_command`) by its `source_uuid`;
/// - its id is a uuid "Read now" sent a message again under (the live row keeps its first uuid, `sentAliases`);
/// - it is a prompt with the text of one of the run's prompts, written at or after the run began (a uuid Loom never saw).
/// Markers, notices and requests get made-up ids in each model; history entries with such an id (`reset:3`) are renamed,
/// so they never meet one of the live model's.
///
/// A driver keeps its model across runs (a Stop and a resume, Chat → Terminal → Chat). Only the newest run's part of it
/// is shown (`runStart`); earlier runs are in the transcript, with whatever ran in the terminal between them. The rows
/// only Loom has of those runs (face, mode and model markers, "Session started", failure notices, answered cards) are
/// carried into the history by their time.
///
/// The joined model is history then live. A live growth becomes a growth of the joined model by moving its counts and turn
/// positions past the history. A live change that brings an entry the history still holds (the transcript was read after
/// the CLI wrote it, before the live model had it) cuts the history again, and the caller rebuilds from `model`.
public struct LiveHistoryJoin: Sendable {
    /// What is shown above the live run: the transcript cut where the run begins, with the earlier runs' Loom-only rows.
    public private(set) var history = TurnModel(source: .sessionTranscript)
    /// The transcript as read (renamed), before the cut.
    private var transcript = TurnModel(source: .sessionTranscript)
    /// Entries of the transcript kept above the cut.
    private var keptTranscriptEntries = 0
    public private(set) var live: TurnModel
    /// Older turns exist before the history's first entry.
    public private(set) var hasOlder = false
    /// Where the live run's lines begin in the transcript, as far as the history knows: the line of the first entry cut
    /// away, else the history's newest line. A scan for a live entry's line ("Show all") starts there; nil reads from the
    /// file's start.
    public private(set) var liveLinesStart: UInt64?
    /// The history's content entry ids, and the texts of its prompts written since the run began: a live entry with one of
    /// them means the history must be cut again.
    private var historyIDs: Set<String> = []
    private var historyRunPrompts: Set<String> = []
    /// Where the newest run began in the live model: the part shown starts there (`requestedRunStart`, within the counts
    /// the live model held here has).
    public private(set) var runStart = RunStart()
    /// The run start as the driver gave it: a model that has not caught up yet shows from where it can, and the next
    /// snapshot puts the start where it belongs.
    public private(set) var requestedRunStart = RunStart()

    /// The live model's counts when a run began.
    public struct RunStart: Sendable, Equatable {
        public var entries: Int
        public var turns: Int
        public var unknownRecords: Int
        /// When the run was launched, on Loom's clock: a transcript prompt written since may be one of its sends.
        public var time: Date?
        /// Counts the driver's runs: a new number is a new run, even one that added nothing to the model.
        public var generation: Int

        public init(entries: Int = 0, turns: Int = 0, unknownRecords: Int = 0, time: Date? = nil, generation: Int = 0) {
            self.entries = entries
            self.turns = turns
            self.unknownRecords = unknownRecords
            self.time = time
            self.generation = generation
        }
    }

    public enum Outcome: Sendable {
        /// The live change as a change of the joined model (its sequence is the live one; the caller numbers it).
        case growth(ModelChange)
        /// The change touched only runs before the newest one: nothing shown changed.
        case unchanged
        /// The joined model changed as a whole: rebuild from `model`.
        case rebuilt
        /// The change was not made on the live model held here: ask the source for a snapshot.
        case refused
    }

    public init(live: TurnModel) {
        self.live = live
    }

    /// The history (the transcript's model as read so far) above the live model, cut where the live run begins.
    public mutating func setHistory(_ transcript: TurnModel, hasOlder: Bool) {
        self.hasOlder = hasOlder
        self.transcript = Self.renamed(transcript)
        cut()
    }

    /// A new run began at these counts of the live model. The caller reads the history again (the transcript now holds the
    /// earlier runs and anything between them) and rebuilds.
    public mutating func setRunStart(_ start: RunStart) {
        requestedRunStart = start
        runStart = RunStart(entries: min(start.entries, live.entries.count), turns: min(start.turns, live.turns.count),
                            unknownRecords: min(start.unknownRecords, live.unknownRecordCount), time: start.time,
                            generation: start.generation)
        cut()
    }

    /// No history (a new card after `/clear`, or none could be read).
    public mutating func clearHistory() {
        transcript = TurnModel(source: .sessionTranscript)
        hasOlder = false
        cut()
        liveLinesStart = nil
    }

    /// The history kept nothing of the transcript (the read lies inside the live run) while older turns exist: read older
    /// ones.
    public var needsOlder: Bool { keptTranscriptEntries == 0 && hasOlder }

    /// Takes a change of the live model.
    public mutating func apply(_ change: ModelChange) -> Outcome {
        switch change.kind {
        case .replaced, .older:
            guard let whole = change.model else { return .refused }
            live = whole
            setRunStart(requestedRunStart)
            return .rebuilt
        case .growth:
            guard live.apply(change) else { return .refused }
            if change.entriesBefore < runStart.entries || change.turnsBefore < runStart.turns {
                cut()
                return .rebuilt
            }
            if change.appended.contains(where: { entry in
                guard Self.isContent(entry) else { return false }
                if historyIDs.contains(entry.id) { return true }
                if case let .user(prompt) = entry.body { return historyRunPrompts.contains(prompt.text) }
                return false
            }) {
                cut()
                return .rebuilt
            }
            let index = live.index, first = runStart.entries
            let shown = { (id: String) in (index[id] ?? 0) >= first }
            var moved = change
            moved.entriesBefore += history.entries.count - runStart.entries
            moved.turnsBefore += history.turns.count - runStart.turns
            moved.updated = change.updated.filter { shown($0.id) }
            moved.delta.updated = change.delta.updated.filter(shown)
            moved.delta.inserted = change.delta.inserted.filter(shown)
            moved.turns = change.turns.filter { $0.position >= runStart.turns }.map {
                ModelChange.TurnAt(position: $0.position - runStart.turns + history.turns.count, turn: $0.turn)
            }
            moved.unknownRecordCount += history.unknownRecordCount - runStart.unknownRecords
            moved.hasOlder = hasOlder
            if moved.isEmpty { return .unchanged }
            return .growth(moved)
        }
    }

    /// History then live: what the stream shows.
    public var model: TurnModel {
        let shownFromStart = runStart.entries == 0 && runStart.turns == 0
        guard !history.entries.isEmpty || !history.turns.isEmpty || !shownFromStart else { return live }
        var joined = live
        joined.entries = history.entries + live.entries[runStart.entries...]
        joined.turns = history.turns + live.turns[runStart.turns...]
        joined.index = Dictionary(joined.entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, later in later })
        joined.unknownRecordCount = history.unknownRecordCount + live.unknownRecordCount - runStart.unknownRecords
        return joined
    }

    // MARK: Cutting

    /// Cuts the transcript before the first entry of the live run, and puts the earlier runs' Loom-only rows into what is
    /// left, by time.
    private mutating func cut() {
        let shown = live.entries[runStart.entries...]
        let liveIDs = Set(shown.lazy.filter(Self.isContent).map(\.id))
        let livePrompts = Set(shown.compactMap { entry -> String? in if case let .user(prompt) = entry.body { prompt.text } else { nil } })
        let aliases = live.sentAliases
        let since = runStart.time
        var cut = transcript
        let end = cut.entries.firstIndex { entry in
            guard Self.isContent(entry) else { return false }
            if liveIDs.contains(entry.id) { return true }
            if let row = aliases[entry.id], liveIDs.contains(row) { return true }
            return Self.isRunPrompt(entry, since: since) && livePrompts.contains(Self.promptText(entry) ?? "")
        } ?? cut.entries.count
        if end < cut.entries.count {
            liveLinesStart = cut.entries[end...].first(where: { $0.sourceOffset != nil })?.sourceOffset
                ?? cut.entries[..<end].last(where: { $0.sourceOffset != nil })?.sourceOffset
            let removedUnknown = cut.entries[end...].filter(Self.isUnknownRecord).count
            // A turn stays while one of its entries does: one that began before the run keeps what it held.
            let kept = Set(cut.entries[..<end].map(\.turnID))
            cut.entries.removeSubrange(end...)
            cut.turns.removeAll { !kept.contains($0.id) }
            cut.index = cut.index.filter { $0.value < end }
            cut.unknownRecordCount = max(0, cut.unknownRecordCount - removedUnknown)
        } else {
            liveLinesStart = cut.entries.last(where: { $0.sourceOffset != nil })?.sourceOffset
        }
        keptTranscriptEntries = cut.entries.count
        historyIDs = Set(cut.entries.lazy.filter(Self.isContent).map(\.id))
        historyRunPrompts = Set(cut.entries.compactMap { Self.isRunPrompt($0, since: since) ? Self.promptText($0) : nil })
        history = Self.carrying(live.entries[..<runStart.entries].filter(Self.isLoomOnly), into: cut)
    }

    private static func promptText(_ entry: ChatEntry) -> String? {
        if case let .user(prompt) = entry.body { prompt.text } else { nil }
    }

    /// A prompt of the transcript written at or after `since`.
    private static func isRunPrompt(_ entry: ChatEntry, since: Date?) -> Bool {
        guard case .user = entry.body, let since, let time = entry.timestamp else { return false }
        return time >= since
    }

    /// A row of an earlier run that only Loom has: no transcript writes it. Markers Loom placed (made-up ids: "Session
    /// started", "Resumed", mode and model changes, "Continued in Terminal"), failure notices and answered
    /// cards. Rows the transcript has too ("You stopped", compaction, retries, notices of local commands) stay out.
    static func isLoomOnly(_ entry: ChatEntry) -> Bool {
        guard let colon = entry.id.firstIndex(of: ":"), isMadeUp(entry.id) else { return false }
        return ["start", "model", "mode", "marker", "failure", "request"].contains(String(entry.id[..<colon]))
    }

    /// `rows` put into `history` by their time: after the last entry at or before it (and the entries without a time that
    /// follow that one), in the turn of the entry before them.
    static func carrying(_ rows: [ChatEntry], into history: TurnModel) -> TurnModel {
        guard !rows.isEmpty else { return history }
        var model = history
        for row in rows {
            var position = 0
            if let time = row.timestamp {
                if let last = model.entries.lastIndex(where: { ($0.timestamp ?? .distantFuture) <= time }) { position = last + 1 }
            } else {
                position = model.entries.count
            }
            while position < model.entries.count, model.entries[position].timestamp == nil { position += 1 }
            var carried = row
            carried.turnID = position > 0 ? model.entries[position - 1].turnID : ""
            model.entries.insert(carried, at: position)
        }
        model.index = Dictionary(model.entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, later in later })
        return model
    }

    /// An entry whose id names the same thing in a transcript and in the live model.
    static func isContent(_ entry: ChatEntry) -> Bool {
        switch entry.body {
        case .user, .assistantText, .thinking, .tool, .subagent, .plan: true
        case .request, .marker, .unknown: false
        }
    }

    private static func isUnknownRecord(_ entry: ChatEntry) -> Bool {
        if case let .unknown(raw) = entry.body { raw.reason == .unknownType } else { false }
    }

    /// The transcript's model with its made-up ids (`prefix:number`, from `nextID`) moved out of the live model's way, and
    /// the turns that begin with one renamed with it.
    static func renamed(_ transcript: TurnModel) -> TurnModel {
        var renames: [String: String] = [:]
        for entry in transcript.entries where isMadeUp(entry.id) { renames[entry.id] = "history:" + entry.id }
        guard !renames.isEmpty else { return transcript }
        var model = transcript
        var turnRenames: [String: String] = [:]
        for position in model.turns.indices {
            guard let first = renames[model.turns[position].firstEntryID] else { continue }
            let id = "turn:" + first
            turnRenames[model.turns[position].id] = id
            model.turns[position].id = id
            model.turns[position].firstEntryID = first
        }
        for position in model.entries.indices {
            if let id = renames[model.entries[position].id] { model.entries[position].id = id }
            if let turn = turnRenames[model.entries[position].turnID] { model.entries[position].turnID = turn }
        }
        model.index = Dictionary(model.entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, later in later })
        return model
    }

    /// `reset:3`: letters, a colon, digits.
    private static func isMadeUp(_ id: String) -> Bool {
        guard let colon = id.firstIndex(of: ":"), colon > id.startIndex else { return false }
        let head = id[..<colon], tail = id[id.index(after: colon)...]
        return !tail.isEmpty && head.allSatisfy(\.isLetter) && tail.allSatisfy(\.isNumber)
    }
}
