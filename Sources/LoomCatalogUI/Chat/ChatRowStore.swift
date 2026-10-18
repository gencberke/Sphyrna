import Foundation
import LoomChat

/// `removed` rows of the stream, from `start`, are replaced by `rows`. `start` counts the rows before any patch of the
/// same change was applied, so the patches of one change are ascending and never overlap.
struct ChatRowsPatch: Equatable {
    var start: Int
    var removed: Int
    var rows: [ChatRow]
}

/// What the stream is told after a change.
enum ChatRowsChange {
    /// All the rows: the first build, or a change that reaches every turn (the view, the working directory).
    case all([ChatRow])
    /// Only the stretches that differ.
    case patches([ChatRowsPatch])
}

/// The rows of the stream, kept between changes. A change costs the turns it touched, not the transcript: the rows of
/// every turn are kept, and the turns a change did not touch keep their rows (the same values, so the same ids and no
/// remount). The result always equals `ChatRowBuilder.rows(input)`, which stays the one place that derives rows.
///
/// What touches a turn: the entries a `ModelDelta` names, the rows whose open state, flags or "Show all" text changed, and
/// the newest turn (the live row, the fold of a turn that just settled) whenever the model grew or the session started or
/// stopped working. The view, the working directory, a replaced model and an unexpected shape of the model rebuild
/// everything. Older turns put in front keep the rows of the turns they did not change.
///
/// The contract with `TurnModel`: a change to an entry or a turn is in the delta it returns, as it is today. A turn the
/// delta does not name and that is not the newest keeps its rows.
struct ChatRowStore {
    enum Cause {
        /// The model grew: a read of the file, or a live message. Its delta names the entries it touched.
        case growth(ModelDelta)
        /// Older turns were put in front of the model.
        case older
        /// The model is as it was; the reader's state (folds, flags, "Show all", working) may differ.
        case state
        /// A model unrelated to the last one: the first build, or a file that was replaced.
        case replaced
    }

    private struct Segment {
        var turnID: String
        var entryStart: Int
        var entryCount: Int
        /// Index of the first row in the whole list.
        var rowStart: Int
        var rows: [ChatRow]
    }

    /// What the rows of the last build depended on besides the entries.
    private struct Inputs: Equatable {
        var mode: ChatViewMode
        var workingDirectory: String?
        var hasOlder: Bool
        var toggled: Set<String>
        var flags: [String: Set<String>]
        var fullOutputs: [String: ChatFullOutput]
        var newest: Newest

        /// What only the newest turn's rows depend on.
        struct Newest: Equatable {
            var id: String?
            var isWorking: Bool
            var liveStart: Date?
            var lastActivity: Date?
            var activity: String?
        }

        init(_ input: ChatBuildInput) {
            mode = input.mode
            workingDirectory = input.workingDirectory
            hasOlder = input.hasOlder
            toggled = input.toggled
            flags = input.flags
            fullOutputs = input.fullOutputs
            let id = input.model.turns.last?.id
            newest = Newest(id: id, isWorking: input.isWorking, liveStart: id.flatMap { input.liveStarts[$0] },
                            lastActivity: input.lastActivity, activity: input.model.activity)
        }
    }

    private var head: [ChatRow] = []
    private var segments: [Segment] = []
    private var byTurn: [String: Int] = [:]
    private var inputs: Inputs?
    private var firstEntryID: String?
    private var entryCount = 0

    /// Every row, in order (tests; the stream keeps its own list).
    var rows: [ChatRow] { head + segments.flatMap(\.rows) }

    // MARK: Update

    /// Brings the rows to `input` and says what differs from the rows the last call returned.
    mutating func update(_ input: ChatBuildInput, cause: Cause) -> ChatRowsChange {
        let now = Inputs(input)
        var touched = Set<String>()
        var reuse = false
        if let before = inputs {
            touched = stateTurns(from: before, to: now, model: input.model)
            let sameView = before.mode == now.mode && before.workingDirectory == now.workingDirectory
            switch cause {
            case .growth, .state:
                if sameView, before.hasOlder == now.hasOlder, let patches = incremental(input, now, before: before, cause: cause, touched: touched) {
                    return .patches(patches)
                }
            case .older:
                reuse = sameView
            case .replaced:
                break
            }
        }
        return rebuild(input, now, reuse: reuse, touched: touched)
    }

    // MARK: Incremental

    /// The growth of the newest turn and the turns that were touched. Nil when the model does not look like the last one
    /// grown at its end; then everything is rebuilt.
    private mutating func incremental(_ input: ChatBuildInput, _ now: Inputs, before: Inputs, cause: Cause, touched: Set<String>) -> [ChatRowsPatch]? {
        let entries = input.model.entries
        guard let lastIndex = segments.indices.last, entries.count >= entryCount, entries.first?.id == firstEntryID,
              segments[lastIndex].entryStart < entries.count, entries[segments[lastIndex].entryStart].turnID == segments[lastIndex].turnID
        else { return nil }
        let runs = ChatRowBuilder.runs(of: entries, from: segments[lastIndex].entryStart)
        guard runs[0].turnID == segments[lastIndex].turnID else { return nil }
        for run in runs.dropFirst() where byTurn[run.turnID] != nil { return nil }
        // The start row waits for the first time stamp.
        if let first = head.first, case .start(nil) = first.kind, ChatRowBuilder.startRow(entries) != first { return nil }

        var dirty = Set<Int>()
        for id in touched { if let index = byTurn[id] { dirty.insert(index) } }
        if case let .growth(delta) = cause {
            let fresh = Set(runs.dropFirst().map(\.turnID))
            for id in delta.inserted + delta.updated {
                // An id that is no entry belongs to no row.
                guard let turn = input.model.entry(id: id)?.turnID else { continue }
                guard let index = byTurn[turn] else {
                    if fresh.contains(turn) { continue }
                    return nil
                }
                dirty.insert(index)
            }
            dirty.insert(lastIndex)
        }
        if now.newest != before.newest { dirty.insert(lastIndex) }
        if runs[0].range.count != segments[lastIndex].entryCount { dirty.insert(lastIndex) }

        let newest = now.newest.id
        func build(_ turnID: String, _ range: Range<Int>) -> [ChatRow] {
            let turn = turnID.isEmpty ? nil : input.model.turns.last { $0.id == turnID }
            return ChatRowBuilder.rows(for: entries[range], turn: turn, isNewest: turnID == newest, input: input)
        }

        // Existing turns that changed, then turns that are new.
        var rebuilt: [Int: [ChatRow]] = [:]
        for index in dirty.sorted() {
            let segment = segments[index]
            let range = index == lastIndex ? runs[0].range : segment.entryStart..<(segment.entryStart + segment.entryCount)
            guard range.upperBound <= entries.count, entries[range.lowerBound].turnID == segment.turnID else { return nil }
            rebuilt[index] = build(segment.turnID, range)
        }
        let appended = runs.dropFirst().map { (run: $0, rows: build($0.turnID, $0.range)) }

        // Patches: neighbouring changed turns, with the new turns after the last one, are one patch.
        var patches: [ChatRowsPatch] = []
        var group: (first: Int, last: Int)?
        func close() {
            guard let open = group else { return }
            group = nil
            let old = (open.first...open.last).flatMap { segments[$0].rows }
            let new = (open.first...open.last).flatMap { rebuilt[$0] ?? segments[$0].rows } + (open.last == lastIndex ? appended.flatMap(\.rows) : [])
            if old != new {
                patches.append(ChatRowsPatch(start: segments[open.first].rowStart, removed: old.count, rows: new))
            }
        }
        for index in dirty.sorted() {
            if let open = group, open.last + 1 == index { group = (open.first, index) } else { close(); group = (index, index) }
        }
        close()
        if !appended.isEmpty, !dirty.contains(lastIndex) {
            // New turns after a last turn that did not change (not seen in practice: the newest turn changes when one follows it).
            patches.append(ChatRowsPatch(start: rowCount, removed: 0, rows: appended.flatMap(\.rows)))
        }

        // Commit.
        for (index, rows) in rebuilt { segments[index].rows = rows }
        if dirty.contains(lastIndex) { segments[lastIndex].entryCount = runs[0].range.count }
        for item in appended {
            byTurn[item.run.turnID] = segments.count
            segments.append(Segment(turnID: item.run.turnID, entryStart: item.run.range.lowerBound, entryCount: item.run.range.count,
                                    rowStart: 0, rows: item.rows))
        }
        if let first = dirty.min() ?? (appended.isEmpty ? nil : lastIndex + 1) { restart(from: first) }
        inputs = now
        entryCount = entries.count
        return patches
    }

    /// Numbers the rows of the turns from `index` on.
    private mutating func restart(from index: Int) {
        var next = index == 0 ? head.count : segments[index - 1].rowStart + segments[index - 1].rows.count
        for position in index..<segments.count {
            segments[position].rowStart = next
            next += segments[position].rows.count
        }
    }

    private var rowCount: Int { segments.last.map { $0.rowStart + $0.rows.count } ?? head.count }

    // MARK: Everything

    /// All the turns, from the entries. With `reuse`, a turn that was not touched, holds the same entries and is not the
    /// newest keeps its rows, and the change is a set of patches.
    private mutating func rebuild(_ input: ChatBuildInput, _ now: Inputs, reuse: Bool, touched: Set<String>) -> ChatRowsChange {
        let entries = input.model.entries
        let newHead: [ChatRow] = entries.isEmpty ? [ChatRowBuilder.emptyRow] : (input.hasOlder ? [] : [ChatRowBuilder.startRow(entries)])
        let turns = ChatRowBuilder.turnsByID(input.model)
        let newest = now.newest.id
        var made: [Segment] = []
        var sources: [Int?] = []
        var next = newHead.count
        for run in ChatRowBuilder.runs(of: entries, from: 0) {
            var rows: [ChatRow]
            var source: Int?
            if reuse, let index = byTurn[run.turnID], segments[index].entryCount == run.range.count,
               !touched.contains(run.turnID), run.turnID != newest {
                rows = segments[index].rows
                source = index
            } else {
                rows = ChatRowBuilder.rows(for: entries[run.range], turn: turns[run.turnID], isNewest: run.turnID == newest, input: input)
            }
            made.append(Segment(turnID: run.turnID, entryStart: run.range.lowerBound, entryCount: run.range.count, rowStart: next, rows: rows))
            sources.append(source)
            next += rows.count
        }

        var change = ChatRowsChange.all(newHead + made.flatMap(\.rows))
        if reuse, let between = patchesBetween(newHead: newHead, made: made, sources: sources) { change = .patches(between) }
        head = newHead
        segments = made
        byTurn = Dictionary(made.enumerated().map { ($1.turnID, $0) }, uniquingKeysWith: { _, later in later })
        inputs = now
        firstEntryID = entries.first?.id
        entryCount = entries.count
        return change
    }

    /// The stretches between the kept turns (the old list is still `head` and `segments`). Nil when the kept turns are not
    /// in their old order.
    private func patchesBetween(newHead: [ChatRow], made: [Segment], sources: [Int?]) -> [ChatRowsPatch]? {
        var patches: [ChatRowsPatch] = []
        var oldNext = 0
        var regionStart = 0
        var pending: [ChatRow] = []
        if newHead == head { regionStart = head.count } else { pending = newHead }
        func flush(until end: Int) {
            if end > regionStart || !pending.isEmpty {
                patches.append(ChatRowsPatch(start: regionStart, removed: end - regionStart, rows: pending))
            }
            pending = []
        }
        for (position, segment) in made.enumerated() {
            guard let source = sources[position] else {
                pending += segment.rows
                continue
            }
            guard source >= oldNext else { return nil }
            flush(until: segments[source].rowStart)
            regionStart = segments[source].rowStart + segments[source].rows.count
            oldNext = source + 1
        }
        flush(until: rowCount)
        return patches
    }

    // MARK: What the reader's state touched

    /// The turns whose rows depend on a row id, open state or "Show all" text that changed.
    private func stateTurns(from before: Inputs, to now: Inputs, model: TurnModel) -> Set<String> {
        var ids = Set<String>()
        if before.toggled != now.toggled { ids = before.toggled.symmetricDifference(now.toggled) }
        if before.flags != now.flags {
            for key in Set(before.flags.keys).union(now.flags.keys) where before.flags[key] != now.flags[key] { ids.insert(key) }
        }
        if before.fullOutputs != now.fullOutputs {
            for key in Set(before.fullOutputs.keys).union(now.fullOutputs.keys) where before.fullOutputs[key] != now.fullOutputs[key] { ids.insert(key) }
        }
        var turns = Set<String>()
        for id in ids {
            // An id no entry or turn has belongs to no row (it was remembered from a turn that is not loaded).
            if let turn = Self.turn(ofRow: id, in: model) { turns.insert(turn) }
        }
        if before.newest != now.newest {
            if let id = now.newest.id { turns.insert(id) }
            if let id = before.newest.id { turns.insert(id) }
        }
        return turns
    }

    /// The turn a row id belongs to: an entry's id, `fold:`, `live:`, `thought:` or `changes:` and a turn id, or `group:` and
    /// the id of the group's first tool.
    static func turn(ofRow id: String, in model: TurnModel) -> String? {
        for prefix in ["fold:", "live:", "thought:", "changes:"] where id.hasPrefix(prefix) {
            let turn = String(id.dropFirst(prefix.count))
            return model.turns.lastIndex { $0.id == turn } != nil ? turn : nil
        }
        if id.hasPrefix("group:") { return model.entry(id: String(id.dropFirst("group:".count)))?.turnID }
        return model.entry(id: id)?.turnID
    }
}
