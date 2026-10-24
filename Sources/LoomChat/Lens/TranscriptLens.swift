import Foundation
import LoomCore

/// Builds a `TurnModel` from a transcript file, a bounded part at a time: the newest turns first, older ones on demand,
/// and whatever the file gains afterwards. It serves stopped sessions, terminal sessions (a live-tailing view) and
/// subagent transcripts alike. Nothing here watches the file; the owner calls `readGrowth()` when it changes.
///
/// - **Cold open**: pages are read backward until the model holds the last `coldOpenTurns` human prompts (and what
///   follows them), or `coldOpenBytes` have been read, whichever comes first. A 100 MB transcript opens by reading
///   about 1.5 MiB.
/// - **Older**: `loadOlder()` reads back `olderTurns` more prompts and prepends them, so a view that holds its anchor row
///   does not move.
/// - **Oversized lines** (over `maximumLineBytes`) are not read: their row says how long they are and where they are.
public actor TranscriptLens {
    public struct Limits: Sendable, Equatable {
        /// The last 10 user turns, as T3 Code does (apps/server/src/orchestration-v2/threadHistoryPaging.ts, MIT; see THIRD-PARTY-NOTICES.md).
        public var coldOpenTurns = 10
        public var coldOpenBytes = 1_572_864
        public var olderTurns = 20
        // The brief sets no byte cap for older pages; this keeps one page from reading a whole huge file.
        public var olderBytes = 8 * 1024 * 1024
        public var pageBytes = ClaudeTranscriptReader.defaultPageBytes
        public var maximumLineBytes = 4 * 1024 * 1024

        public init() {}
    }

    public struct Update: Sendable {
        public var model: TurnModel
        /// What this call changed; a cold open lists every row as inserted.
        public var delta: ModelDelta
        /// Older turns exist before the first row of the model.
        public var hasOlder: Bool
        /// The file shrank or was replaced, and the model was read again from its tail.
        public var restarted: Bool
        /// Bytes read from the file since the lens was made.
        public var bytesRead: Int
    }

    private let reader: ClaudeTranscriptReader
    private let source: TurnModel.Source
    private let limits: Limits
    private var model: TurnModel
    /// The changes handed out as `ModelChange`s so far (see `readGrowthChange()`).
    private var sequence = 0

    public init?(file: ClaudeTranscriptFile, limits: Limits = Limits()) {
        guard let reader = ClaudeTranscriptReader(file: file) else { return nil }
        self.reader = reader
        source = .sessionTranscript
        self.limits = limits
        model = TurnModel(source: .sessionTranscript)
    }

    public init?(subagent file: SubagentTranscriptFile, limits: Limits = Limits()) {
        guard let reader = ClaudeTranscriptReader(file: file) else { return nil }
        self.reader = reader
        source = .subagentTranscript
        self.limits = limits
        model = TurnModel(source: .subagentTranscript)
    }

    public func close() { reader.close() }

    /// Reads the newest turns. Call it once, first (it is called again by `readGrowth()` when the file was replaced).
    public func coldOpen() -> Update {
        update(delta: openNewest(), restarted: false)
    }

    /// The next older turns, or nil when the model already starts at the file's start.
    public func loadOlder() -> Update? {
        readOlder().map { update(delta: $0, restarted: false) }
    }

    /// The lines the file gained since the last call.
    public func readGrowth() -> Update {
        let growth = reader.readGrowth()
        if growth.restarted {
            var restarted = coldOpen()
            restarted.restarted = true
            return restarted
        }
        var delta = ModelDelta()
        for record in growth.records { delta.merge(model.apply(record: record)) }
        return update(delta: delta, restarted: false)
    }

    // MARK: Changes

    // The same reads, handed out as `ModelChange`s: a growth carries the entries and turns it touched and nothing else, so the
    // receiver (the chat view's own copy of the model) and this lens never share the buffers of a model that grows.

    /// `coldOpen()` as a `.replaced` change.
    public func coldOpenChange() -> ModelChange {
        _ = openNewest()
        return snapshotChange()
    }

    /// `loadOlder()` as an `.older` change, or nil when the model already starts at the file's start.
    public func loadOlderChange() -> ModelChange? {
        guard readOlder() != nil else { return nil }
        sequence += 1
        return model.snapshot(sequence: sequence, kind: .older, hasOlder: reader.historyOffset > 0)
    }

    /// `readGrowth()` as a change: `.growth` with what the new lines touched, or `.replaced` when the file was replaced. A growth
    /// that touched nothing keeps the sequence number (`isEmpty`), so its number tells a receiver whether it missed a change.
    public func readGrowthChange() -> ModelChange {
        let growth = reader.readGrowth()
        if growth.restarted { return coldOpenChange() }
        let entriesBefore = model.entries.count, turnsBefore = model.turns.count, activityBefore = model.activity
        var delta = ModelDelta()
        for record in growth.records { delta.merge(model.apply(record: record)) }
        let change = model.growth(sequence: sequence + 1, entriesBefore: entriesBefore, turnsBefore: turnsBefore, delta: delta,
                                  hasOlder: reader.historyOffset > 0, activityChanged: model.activity != activityBefore)
        if change.isEmpty { return ModelChange(kind: .growth, sequence: sequence, hasOlder: change.hasOlder) }
        sequence += 1
        return change
    }

    /// The model as it is, as a `.replaced` change that takes the next sequence number: what a receiver that lost track asks for.
    public func snapshotChange() -> ModelChange {
        sequence += 1
        return model.snapshot(sequence: sequence, hasOlder: reader.historyOffset > 0)
    }

    private func openNewest() -> ModelDelta {
        model = TurnModel(source: source)
        var delta = ModelDelta()
        for record in collectBackward(targetPrompts: limits.coldOpenTurns, byteBudget: limits.coldOpenBytes) {
            delta.merge(model.apply(record: record))
        }
        return delta
    }

    private func readOlder() -> ModelDelta? {
        guard reader.historyOffset > 0 else { return nil }
        var fragment = TurnModel(source: source)
        var delta = ModelDelta()
        for record in collectBackward(targetPrompts: limits.olderTurns, byteBudget: limits.olderBytes) {
            delta.merge(fragment.apply(record: record))
        }
        model.prepend(fragment)
        delta.turnsChanged = true
        return delta
    }

    /// The whole line an entry came from (`ChatEntry.sourceOffset`): "Show all" for a clipped tool result, or a line that
    /// was too long to read.
    public func line(at offset: UInt64, maximumLineBytes: Int = 256 * 1024 * 1024) -> Data? {
        reader.readLine(at: offset, maximumLineBytes: maximumLineBytes)
    }

    // MARK: Private

    private func update(delta: ModelDelta, restarted: Bool) -> Update {
        Update(model: model, delta: delta, hasOlder: reader.historyOffset > 0, restarted: restarted, bytesRead: reader.bytesRead)
    }

    /// Reads pages backward until `targetPrompts` human prompts were seen or `byteBudget` bytes were read; returns the
    /// records in file order, starting at the earliest prompt when the target was reached. Leaves the reader's cursor at
    /// the first returned record, so the next call continues from there.
    ///
    /// - The bytes of an oversized line (over `maximumLineBytes`) do not count: it is scanned for its place but never kept,
    ///   and it must not use up the budget of the turns around it.
    /// - A normal line that does not fit what is left of the budget is left for the next call, unless nothing has been
    ///   collected yet (then it is the page).
    /// - When the budget ends the read, the records start at a clean boundary (`cleanStart`), never between a tool call and
    ///   its result or inside one API message, so what `loadOlder` adds in front never repeats a row. If the budget is spent
    ///   and there is none yet, the read goes on up to twice the budget; if there is still none, the records are kept as
    ///   they are (a transcript of one huge message).
    private func collectBackward(targetPrompts: Int, byteBudget: Int) -> [TranscriptLineRecord] {
        let startBytes = reader.bytesRead
        var skipped = 0
        var collected: [Scanned] = []
        var prompts = 0
        var cut: Int?
        while true {
            let used = reader.bytesRead - startBytes - skipped
            guard reader.historyOffset > 0 else { break }
            // Past the budget the read goes on only while no clean start exists, and never past twice the budget.
            let limit = used < byteBudget ? byteBudget : byteBudget * 2
            guard used < limit, used < byteBudget || Self.cleanStart(in: collected) == nil else { break }
            let remaining = limit - used
            let before = reader.historyOffset
            let page = reader.readBackward(pageBytes: min(limits.pageBytes, remaining), maximumLineBytes: limits.maximumLineBytes)
            if !collected.isEmpty, page.records.contains(where: { !$0.isOversized && $0.length > remaining }) {
                reader.setHistoryOffset(before)
                break
            }
            let scanned = page.records.map { Scanned(record: $0, kind: Self.kind(of: $0, source: source)) }
            collected.insert(contentsOf: scanned, at: 0)
            skipped += page.records.filter(\.isOversized).reduce(0) { $0 + $1.length }
            for position in scanned.indices.reversed() where scanned[position].kind == .prompt {
                prompts += 1
                if prompts == targetPrompts {
                    cut = position
                    break
                }
            }
            if cut != nil || page.reachedStart { break }
        }
        if let cut {
            collected.removeFirst(cut)
        } else if reader.historyOffset > 0, let start = Self.cleanStart(in: collected) {
            collected.removeFirst(start)
        } else {
            return collected.map(\.record)
        }
        if let first = collected.first { reader.setHistoryOffset(first.record.offset) }
        return collected.map(\.record)
    }

    /// A record and what it is, for choosing where a read starts.
    private struct Scanned {
        enum Kind: Equatable {
            /// A human prompt: it begins a turn.
            case prompt
            /// An assistant record, with the id its rows are named after (the API message id).
            case assistant(String)
            case other
        }

        let record: TranscriptLineRecord
        let kind: Kind
    }

    /// Where a read cut by its byte budget may start: at a human prompt, or at the first record of an API message that no
    /// earlier record of the read belongs to. A user record that answers a tool call never qualifies, and nor does an
    /// assistant record before the read has shown one (the message may have begun in the part not read). Nil when none does.
    private static func cleanStart(in records: [Scanned]) -> Int? {
        var seen = Set<String>()
        for (position, item) in records.enumerated() {
            switch item.kind {
            case .prompt:
                return position
            case let .assistant(messageID):
                if !seen.isEmpty, !seen.contains(messageID) { return position }
                seen.insert(messageID)
            case .other:
                break
            }
        }
        return nil
    }

    private static func kind(of record: TranscriptLineRecord, source: TurnModel.Source) -> Scanned.Kind {
        guard let bytes = record.bytes, bytes.count > 0 else { return .other }
        // A cheap test first: only lines that mention "user" or "assistant" can be those records.
        func mentions(_ needle: StaticString) -> Bool {
            bytes.withUnsafeBytes { buffer in
                memmem(buffer.baseAddress, buffer.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
            }
        }
        guard mentions("\"user\"") || mentions("\"assistant\""),
              let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { return .other }
        switch StreamMessage(json: value) {
        case let .user(message):
            return isHumanPrompt(message, source: source) ? .prompt : .other
        case let .assistant(message):
            return .assistant(message.messageID ?? message.uuid ?? "line:\(record.offset)")
        default:
            return .other
        }
    }

    /// True for a user record that is a human prompt (the user's own message, or a slash command they ran): it begins a
    /// turn. The same test as the model's: main thread only, `origin` human or absent, and not a wrapper or notice.
    static func isHumanPrompt(_ message: UserMessage, source: TurnModel.Source) -> Bool {
        guard message.parentToolUseID == nil, source == .subagentTranscript || !message.isSidechain else { return false }
        if let origin = message.originKind, origin != "human" { return false }
        if case .prompt = TurnModel.promptKind(of: message) { return true }
        return false
    }

    /// What the person typed in one session-transcript line: the text of a human prompt by `isHumanPrompt`'s own test (a slash
    /// command reads as it was typed), or nil for any other line, a prompt with only images included. For a reader outside the
    /// lens that wants the last ask (the sidebar's Peek) and must not keep a rule of its own.
    public static func humanPromptText(in line: Data) -> String? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              case let .user(message) = StreamMessage(json: value),
              isHumanPrompt(message, source: .sessionTranscript),
              case let .prompt(text, _) = TurnModel.promptKind(of: message), !text.isEmpty else { return nil }
        return text
    }
}
