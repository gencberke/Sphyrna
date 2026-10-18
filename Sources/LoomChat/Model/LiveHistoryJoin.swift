import Foundation

/// A Chat-face run's live model shown under the session's history from its transcript (V16): one stream, the
/// transcript's older turns above and the driver's live turns below, with nothing twice and nothing lost at the joint.
///
/// The transcript holds the live run's records too (the CLI writes them as the run goes), so the history is cut before the
/// first entry the live model also has. Content entries keep their ids in both sources: a prompt Loom sent by its uuid, an
/// answer by its API message id and block, a tool by its call id. Only those decide the cut, at the entry, so a turn that
/// began before the run keeps what it held. Markers, notices and requests get made-up ids in each model; history entries
/// with such an id (`reset:3`) are renamed, so they never meet one of the live model's.
///
/// A driver keeps its model across runs (a Stop and a resume, Chat → Terminal → Chat). Only the newest run's part of it
/// is shown (`runStart`); earlier runs are in the transcript, with whatever ran in the terminal between them.
///
/// The joined model is history then live. A live growth becomes a growth of the joined model by moving its counts and turn
/// positions past the history. A live change that brings an entry the history still holds (the transcript was read after
/// the CLI wrote it, before the live model had it) cuts the history again, and the caller rebuilds from `model`.
public struct LiveHistoryJoin: Sendable {
    public private(set) var history = TurnModel(source: .sessionTranscript)
    public private(set) var live: TurnModel
    /// Older turns exist before the history's first entry.
    public private(set) var hasOlder = false
    /// Where the live run's lines begin in the transcript, as far as the history knows: the line of the first entry cut
    /// away, else the history's newest line. A scan for a live entry's line ("Show all") starts there; nil reads from the
    /// file's start.
    public private(set) var liveLinesStart: UInt64?
    /// The history's content entry ids: a live entry with one of them means the history must be cut again.
    private var historyIDs: Set<String> = []
    /// Where the newest run began in the live model: the part shown starts there.
    public private(set) var runStart = RunStart()

    /// The live model's counts when a run began.
    public struct RunStart: Sendable, Equatable {
        public var entries: Int
        public var turns: Int
        public var unknownRecords: Int

        public init(entries: Int = 0, turns: Int = 0, unknownRecords: Int = 0) {
            self.entries = entries
            self.turns = turns
            self.unknownRecords = unknownRecords
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
        history = Self.renamed(transcript)
        cut()
    }

    /// A new run began at these counts of the live model. The caller reads the history again (the transcript now holds the
    /// earlier runs and anything between them) and rebuilds.
    public mutating func setRunStart(_ start: RunStart) {
        runStart = RunStart(entries: min(start.entries, live.entries.count), turns: min(start.turns, live.turns.count),
                            unknownRecords: min(start.unknownRecords, live.unknownRecordCount))
        cut()
    }

    /// No history (a new card after `/clear`, or none could be read).
    public mutating func clearHistory() {
        history = TurnModel(source: .sessionTranscript)
        historyIDs = []
        hasOlder = false
        liveLinesStart = nil
    }

    /// The history kept nothing (the read lies inside the live run) while older turns exist: read older ones.
    public var needsOlder: Bool { history.entries.isEmpty && hasOlder }

    /// Takes a change of the live model.
    public mutating func apply(_ change: ModelChange) -> Outcome {
        switch change.kind {
        case .replaced, .older:
            guard let whole = change.model else { return .refused }
            live = whole
            setRunStart(runStart)
            return .rebuilt
        case .growth:
            guard live.apply(change) else { return .refused }
            if change.entriesBefore < runStart.entries || change.turnsBefore < runStart.turns {
                cut()
                return .rebuilt
            }
            if !historyIDs.isEmpty, change.appended.contains(where: { Self.isContent($0) && historyIDs.contains($0.id) }) {
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

    /// Cuts the history before the first content entry the live model has.
    private mutating func cut() {
        let liveIDs = Set(live.entries[runStart.entries...].lazy.filter(Self.isContent).map(\.id))
        let end = history.entries.firstIndex { Self.isContent($0) && liveIDs.contains($0.id) } ?? history.entries.count
        if end < history.entries.count {
            liveLinesStart = history.entries[end...].first(where: { $0.sourceOffset != nil })?.sourceOffset
                ?? history.entries[..<end].last(where: { $0.sourceOffset != nil })?.sourceOffset
            let removedUnknown = history.entries[end...].filter(Self.isUnknownRecord).count
            // A turn stays while one of its entries does: one that began before the run keeps what it held.
            let kept = Set(history.entries[..<end].map(\.turnID))
            history.entries.removeSubrange(end...)
            history.turns.removeAll { !kept.contains($0.id) }
            history.index = history.index.filter { $0.value < end }
            history.unknownRecordCount = max(0, history.unknownRecordCount - removedUnknown)
        } else {
            liveLinesStart = history.entries.last(where: { $0.sourceOffset != nil })?.sourceOffset
        }
        historyIDs = Set(history.entries.lazy.filter(Self.isContent).map(\.id))
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
