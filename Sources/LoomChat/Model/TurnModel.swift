import Foundation
import LoomCore

/// The chat engine's model: one chronological list of entries and the turns they belong to. Three sources feed the
/// same type, so one renderer serves them all:
///
/// - `.live`: decoded `StreamMessage`s (`apply(_:)`). A turn runs from a user message to the main thread's `result`;
///   a subagent finishing never ends it, and a message sent while Claude works joins the running turn.
/// - `.sessionTranscript` and `.subagentTranscript`: transcript lines (`apply(record:)`). A turn ends at the next human
///   prompt. Records may arrive newest page first (`prepend`) or as the file grows.
///
/// A value type with no UI: every change returns a `ModelDelta` naming the rows it touched. Unknown records are kept
/// raw, and a line over a size limit is marked, never dropped silently.
///
/// The turn rule (a turn ends with the main thread's run, never with a subagent) and the flat entry list follow T3 Code
/// (MIT; see THIRD-PARTY-NOTICES.md): apps/web/src/session-logic.ts (`TimelineEntry`) and
/// apps/web/src/components/chat/MessagesTimeline.logic.ts (`deriveTurnFolds`, which the turn fold of a later slice uses).
public struct TurnModel: Sendable {
    public enum Source: Sendable, Equatable {
        case live
        case sessionTranscript
        /// A subagent's own file: all its records are its main thread, and its first user line is the brief.
        case subagentTranscript
    }

    public let source: Source
    public internal(set) var entries: [ChatEntry] = []
    public internal(set) var turns: [ChatTurn] = []
    /// The newest `system/init`: model, mode, tools, commands, capabilities.
    public internal(set) var latestInit: SystemInit?
    public internal(set) var rateLimit: RateLimitEvent?
    /// The newest main-thread assistant message's usage: the context ring's input. After a compaction, the size after it.
    public internal(set) var contextUsage: TokenUsage?
    /// `compacting` or `requesting` while `system/status` says so.
    public internal(set) var activity: String?
    /// `idle`, `running` or `requires_action`, from `system/session_state_changed`.
    public internal(set) var sessionState: String?
    public internal(set) var conversationID: String?
    /// Records kept raw because their type is unknown (the renderer shows one drift notice per session).
    public internal(set) var unknownRecordCount = 0
    /// The `initialize` answer: the model is Ready, and these are its menus (never the account).
    public internal(set) var ready: InitializeResponse?
    /// Subagents and background tasks by `task_id`; a subagent's `agent_id` (on its messages and on its `can_use_tool`
    /// requests) is its task id.
    public internal(set) var tasks: [String: TaskStarted] = [:]
    var startMarkerPlaced = false
    /// Loom sent an interrupt (or a denial that stops) and the turn's `result` has not come yet: only then is an aborted
    /// turn the user's stop. Live only.
    var interruptSent = false
    /// Messages sent again under a new uuid ("Read now"): the new uuid to the row's id, and the row's id to the newest
    /// uuid. Live only.
    var sentAliases: [String: String] = [:]
    var resentUUIDs: [String: String] = [:]
    /// How background agents ended, by the Agent call's id, for calls that lie before what was read.
    struct SubagentFinish: Sendable {
        var status: SubagentRun.Status
        var time: Date?
    }
    var pendingFinishes: [String: SubagentFinish] = [:]

    var index: [String: Int] = [:]
    /// Blocks of each API message already placed, so the records of one message get consecutive block indexes.
    private var blocksPlaced: [String: Int] = [:]
    /// The API message being streamed on each thread (keyed by the parent tool-use id, "" for the main thread).
    var inflight: [String: Inflight] = [:]
    private var sequence = 0

    struct Inflight {
        var messageID: String
        var blocks: [Int: StreamingBlock] = [:]
    }

    struct StreamingBlock {
        enum Kind { case text, thinking, tool }
        var entryID: String
        var kind: Kind
        var inputJSON = ""
    }

    public init(source: Source) {
        self.source = source
    }

    public func entry(id: String) -> ChatEntry? { index[id].map { entries[$0] } }

    /// The entries of one turn, in order.
    public func entries(in turn: ChatTurn) -> [ChatEntry] {
        entries.filter { $0.turnID == turn.id }
    }

    // MARK: Live

    /// Applies one decoded message of the live stream. Control messages and keep-alives change nothing.
    @discardableResult
    public mutating func apply(_ message: StreamMessage, at now: Date = Date()) -> ModelDelta {
        ingest(message, offset: nil, now: now)
    }

    /// Applies what the decoder made of a line: a message, an oversized line (marked) or a malformed one (kept raw).
    @discardableResult
    public mutating func apply(_ frame: StreamFrame, at now: Date = Date()) -> ModelDelta {
        switch frame {
        case let .message(message): return apply(message, at: now)
        case let .oversized(byteCount, head): return noteOversized(byteCount: byteCount, head: head, offset: nil, at: now)
        case let .malformed(head, _): return noteMalformed(head: head, offset: nil, at: now)
        }
    }

    /// Records the `initialize` answer: the starting mode is known before any turn. The first one of a live model marks
    /// the start: "Session started" for a new session, "Resumed" when the run resumed one (a model made after a relaunch
    /// has no earlier rows of it, and the session did not start here).
    @discardableResult
    public mutating func apply(ready response: InitializeResponse, resumed: Bool = false, at now: Date = Date()) -> ModelDelta {
        var delta = ModelDelta()
        ready = response
        if source == .live, !startMarkerPlaced {
            startMarkerPlaced = true
            place(id: nextID("start"), thread: .main, timestamp: now, offset: nil, policy: .standalone, delta: &delta,
                  body: .marker(resumed ? .resumed(secondsSinceLastActivity: nil)
                                        : .sessionStart(model: nil, permissionMode: response.currentPermissionMode)))
        }
        return delta
    }

    /// The name of the subagent that owns `agentID`: what its card shows ("reviewer: Review auth").
    public func subagentTask(agentID: String) -> TaskStarted? {
        tasks[agentID].flatMap { $0.taskType == "local_agent" ? $0 : nil }
    }

    /// Shows a message Loom just sent (sent with `uuid`), dimmed until its `isReplay` echo arrives. Starts a turn, or
    /// joins the running one.
    @discardableResult
    public mutating func appendPendingUser(uuid: String, text: String, images: [ImageRef] = [], at now: Date = Date()) -> ModelDelta {
        var delta = ModelDelta()
        guard index[uuid] == nil else { return delta }
        place(id: uuid, thread: .main, timestamp: now, offset: nil, policy: .prompt, delta: &delta,
              body: .user(UserPrompt(text: text, images: images, delivery: .pending, command: nil, isBrief: false)))
        return delta
    }

    /// The process ended before it took these messages: they show "Not delivered". One the CLI already held (`queued`) is
    /// marked too: it will not be read.
    @discardableResult
    public mutating func markNotDelivered(_ uuids: [String]) -> ModelDelta {
        var delta = ModelDelta()
        for uuid in uuids {
            let row = rowID(forSent: uuid)
            guard let i = index[row], case var .user(prompt) = entries[i].body,
                  prompt.delivery == .pending || prompt.delivery == .queued else { continue }
            prompt.delivery = .notDelivered
            entries[i].body = .user(prompt)
            delta.noteUpdated(row)
        }
        return delta
    }

    /// The driver sent an interrupt (Esc, Stop, a face switch, "Deny and stop"): the aborted turn that follows reads "You
    /// stopped". Without this an aborted turn was cut by a `now` send and goes on with the new message.
    public mutating func noteInterruptSent() {
        interruptSent = true
    }

    /// The process ended while a turn ran: the turn ends interrupted, with what streamed so far, and no `result` will
    /// come. A stop Loom asked for reads "You stopped"; any other end says the session ended.
    @discardableResult
    public mutating func endRunningTurn(at now: Date = Date()) -> ModelDelta {
        var delta = ModelDelta()
        guard source == .live, let position = turns.lastIndex(where: { $0.status == .running }) else { return delta }
        let turnID = turns[position].id
        settleTurn(at: position, status: .interrupted, now: now, delta: &delta)
        let body: ChatEntry.Body = interruptSent
            ? .marker(.interrupted(afterMs: nil)) : .marker(.notice("The session ended before this turn finished."))
        interruptSent = false
        place(id: "interrupted:\(turnID)", thread: .main, timestamp: now, offset: nil, policy: .standalone, delta: &delta,
              body: body)
        return delta
    }

    /// A message Loom sent again under a new uuid ("Read now": unsent, then sent with `priority: now`) keeps its row
    /// and the row's id: the row is pending again, and from now on the CLI's records for `new` (lifecycle, echo) are
    /// the row's, while the old uuid's are not. The change is one updated row, as any other delivery change.
    @discardableResult
    public mutating func rekeyPendingUser(from old: String, to new: String) -> ModelDelta {
        var delta = ModelDelta()
        let row = rowID(forSent: old)
        guard index[new] == nil, sentAliases[new] == nil, let i = index[row],
              case var .user(prompt) = entries[i].body else { return delta }
        prompt.delivery = .pending
        entries[i].body = .user(prompt)
        sentAliases[new] = row
        resentUUIDs[row] = new
        delta.noteUpdated(row)
        return delta
    }

    /// The row of a message Loom sent under `uuid` (its own uuid, or a later one "Read now" gave it).
    public func rowID(forSent uuid: String) -> String { sentAliases[uuid] ?? uuid }

    /// The uuid the CLI knows the message of this row by now: what `rewind_files` and `cancel_async_message` name.
    public func sentUUID(ofRow id: String) -> String { resentUUIDs[id] ?? id }

    /// The interrupt Loom meant to send did not go out (a "Deny and stop" whose answer could not be written).
    public mutating func clearInterruptSent() {
        interruptSent = false
    }

    /// Every message that has not been read (nor cancelled) yet.
    public var pendingUserMessageIDs: [String] {
        entries.compactMap { entry in
            if case let .user(prompt) = entry.body, prompt.delivery == .pending || prompt.delivery == .queued { entry.id } else { nil }
        }
    }

    /// Adds a marker the driver knows about (resumed after days, continued in Terminal, back in Chat).
    @discardableResult
    public mutating func appendMarker(_ marker: Marker, at now: Date = Date()) -> ModelDelta {
        var delta = ModelDelta()
        place(id: nextID("marker"), thread: .main, timestamp: now, offset: nil, policy: .standalone, delta: &delta, body: .marker(marker))
        return delta
    }

    /// Adds the one line the stream keeps of a card the user answered.
    @discardableResult
    public mutating func recordRequest(_ record: RequestRecord, at now: Date = Date()) -> ModelDelta {
        var delta = ModelDelta()
        place(id: nextID("request"), thread: .main, timestamp: now, offset: nil, policy: .work, delta: &delta, body: .request(record))
        return delta
    }

    /// Fills a plan card from the `can_use_tool` request for ExitPlanMode (its input carries `plan` and `planFilePath`), for a
    /// card whose tool call did not.
    @discardableResult
    public mutating func updatePlan(toolUseID: String, markdown: String, filePath: String?) -> ModelDelta {
        var delta = ModelDelta()
        guard let i = index[toolUseID], case var .plan(plan) = entries[i].body else { return delta }
        plan.markdown = markdown
        plan.filePath = filePath ?? plan.filePath
        entries[i].body = .plan(plan)
        delta.noteUpdated(toolUseID)
        return delta
    }

    /// A line over the decoder's (or the reader's) limit: a marked row. `head` is the line's first bytes, when known.
    @discardableResult
    public mutating func noteOversized(byteCount: Int, head: String?, offset: UInt64?, at now: Date = Date()) -> ModelDelta {
        var delta = ModelDelta()
        let raw = RawRecord(reason: .oversized, type: head.flatMap(Self.sniffType), subtype: nil, json: "", byteCount: byteCount, isTruncated: false)
        place(id: rawID("oversized", offset), thread: .main, timestamp: nil, offset: offset, policy: .standalone, delta: &delta, body: .unknown(raw))
        return delta
    }

    @discardableResult
    mutating func noteMalformed(head: String, offset: UInt64?, at now: Date) -> ModelDelta {
        var delta = ModelDelta()
        let raw = RawRecord(reason: .malformed, type: nil, subtype: nil, json: head, byteCount: head.utf8.count, isTruncated: true)
        place(id: rawID("malformed", offset), thread: .main, timestamp: nil, offset: offset, policy: .standalone, delta: &delta, body: .unknown(raw))
        return delta
    }

    // MARK: Transcripts

    /// Applies one transcript line, in file order. An oversized record becomes a marked row.
    @discardableResult
    public mutating func apply(record: TranscriptLineRecord, at now: Date = Date()) -> ModelDelta {
        guard let bytes = record.bytes else {
            return noteOversized(byteCount: record.length, head: nil, offset: record.offset, at: now)
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: bytes), value.object != nil else {
            return noteMalformed(head: String(decoding: bytes.prefix(256), as: UTF8.self), offset: record.offset, at: now)
        }
        return ingest(StreamMessage(json: value), offset: record.offset, now: now)
    }

    /// Puts an older fragment (read from the transcript before what this model holds, ending where it begins) in front
    /// of the entries. Rows keep their ids and order; a turn the older read cut in two becomes one again.
    ///
    /// The lens cuts at a clean boundary, so ids do not collide. If a read still ended between a tool call and its
    /// result, the result sits here without its call (an empty-named tool row); the older call takes it in. Any other id
    /// held by both keeps the row of this model, so ids stay unique.
    public mutating func prepend(_ older: TurnModel) {
        var olderTurns = older.turns
        var olderEntries = older.entries
        var mine = turns
        var droppedHere = Set<Int>()
        var droppedThere = Set<Int>()
        for (position, entry) in entries.enumerated() {
            guard let twin = older.index[entry.id] else { continue }
            if let merged = Self.joined(call: olderEntries[twin].body, result: entry.body) {
                olderEntries[twin].body = merged
                droppedHere.insert(position)
            } else {
                droppedThere.insert(twin)
            }
        }
        for position in olderEntries.indices {
            guard case var .subagent(run) = olderEntries[position].body, run.status == .running,
                  let finish = pendingFinishes.removeValue(forKey: run.toolUseID) else { continue }
            run.status = finish.status
            run.endedAt = finish.time
            olderEntries[position].body = .subagent(run)
        }
        pendingFinishes.merge(older.pendingFinishes) { mine, _ in mine }
        if !droppedHere.isEmpty { entries = entries.enumerated().filter { !droppedHere.contains($0.offset) }.map(\.element) }
        if !droppedThere.isEmpty { olderEntries = olderEntries.enumerated().filter { !droppedThere.contains($0.offset) }.map(\.element) }
        if let first = mine.first, !first.hasUserPrompt, let last = olderTurns.last {
            // The older read ended inside this turn: they are one.
            for i in entries.indices where entries[i].turnID == first.id { entries[i].turnID = last.id }
            var joined = last
            joined.status = first.status
            joined.endedAt = first.endedAt ?? last.endedAt
            joined.result = first.result
            olderTurns[olderTurns.count - 1] = joined
            mine.removeFirst()
        } else if let last = olderTurns.indices.last, olderTurns[last].status == .open {
            // What the older read ends with ended at the first prompt after it.
            olderTurns[last].status = .ended
        }
        // Dividers that stood before any turn here (the read began on one) belong to the turn the older read ends in.
        if let last = olderTurns.last {
            for i in entries.indices where entries[i].turnID.isEmpty { entries[i].turnID = last.id }
        }
        entries = olderEntries + entries
        turns = olderTurns + mine
        index = [:]
        for (position, entry) in entries.enumerated() { index[entry.id] = position }
        unknownRecordCount += older.unknownRecordCount
    }

    /// The call's row with the result of a result-only row (see `prepend`), or nil when `result` is not one.
    private static func joined(call: ChatEntry.Body, result: ChatEntry.Body) -> ChatEntry.Body? {
        guard case let .tool(orphan) = result, orphan.name.isEmpty else { return nil }
        switch call {
        case var .tool(call):
            call.status = orphan.status
            call.output = orphan.output
            call.images = orphan.images
            call.exitCode = orphan.exitCode
            call.changes = orphan.changes
            call.endedAt = orphan.endedAt
            return .tool(call)
        case var .subagent(run):
            run.status = orphan.status == .succeeded ? .succeeded : orphan.status == .interrupted ? .interrupted : .failed
            run.result = orphan.output
            run.endedAt = orphan.endedAt
            return .subagent(run)
        case var .plan(plan):
            plan.status = orphan.status == .succeeded ? .approved : .rejected
            return .plan(plan)
        default:
            return nil
        }
    }

    // MARK: Message routing

    mutating func ingest(_ message: StreamMessage, offset: UInt64?, now: Date) -> ModelDelta {
        var delta = ModelDelta()
        switch message {
        case let .systemInit(info): ingestInit(info, now: now, delta: &delta)
        case let .streamEvent(event): ingestStream(event, now: now, delta: &delta)
        case let .assistant(assistant): ingestAssistant(assistant, offset: offset, now: now, delta: &delta)
        case let .user(user): ingestUser(user, offset: offset, now: now, delta: &delta)
        case let .result(result): ingestResult(result, now: now, delta: &delta)
        case let .rateLimit(event): rateLimit = event
        case let .apiRetry(retry):
            let turnID = turns.last?.id ?? ""
            place(id: "retry:\(turnID)", thread: .main, timestamp: now, offset: offset, policy: .standalone, delta: &delta,
                  body: .marker(.retry(attempt: retry.attempt, maxRetries: retry.maxRetries, error: retry.error)))
        case let .status(status): activity = status.status
        case let .compactBoundary(boundary): ingestCompaction(boundary, offset: offset, now: now, delta: &delta)
        case let .sessionState(change): sessionState = change.state
        case let .commandLifecycle(lifecycle): ingestLifecycle(lifecycle, delta: &delta)
        case let .taskStarted(task): ingestTask(task, delta: &delta)
        case let .conversationReset(reset):
            conversationID = reset.newConversationID ?? conversationID
            place(id: nextID("reset"), thread: .main, timestamp: now, offset: offset, policy: .standalone, delta: &delta,
                  body: .marker(.reset(trigger: reset.trigger)))
        case .controlRequest, .controlResponse, .controlCancel, .controlProgress, .keepAlive: break
        case let .unknown(unknown): ingestUnknown(unknown, offset: offset, now: now, delta: &delta)
        }
        return delta
    }

    // MARK: Placement

    enum TurnPolicy {
        /// A human prompt: it starts a turn (live: unless one is running).
        case prompt
        /// Work: it belongs to the current turn (live: one is opened if none runs).
        case work
        /// A divider: it joins the newest turn, if any, and never opens one.
        case standalone
    }

    /// Inserts a new entry, or replaces the body of the one with this id. Returns its index.
    @discardableResult
    mutating func place(id: String, thread: ChatThread, timestamp: Date?, offset: UInt64?, policy: TurnPolicy,
                        delta: inout ModelDelta, body: ChatEntry.Body) -> Int {
        if let existing = index[id] {
            entries[existing].body = body
            delta.noteUpdated(id)
            return existing
        }
        let turnID = assignTurn(entryID: id, policy: policy, timestamp: timestamp, delta: &delta)
        entries.append(ChatEntry(id: id, turnID: turnID, thread: thread, timestamp: timestamp, sourceOffset: offset, body: body))
        index[id] = entries.count - 1
        delta.noteInserted(id)
        if let timestamp, let last = turns.indices.last, turns[last].id == turnID {
            turns[last].endedAt = max(turns[last].endedAt ?? timestamp, timestamp)
        }
        return entries.count - 1
    }

    private mutating func assignTurn(entryID: String, policy: TurnPolicy, timestamp: Date?, delta: inout ModelDelta) -> String {
        if policy == .standalone { return turns.last?.id ?? "" }
        if let current = turns.last {
            if source == .live {
                if current.status == .running { return current.id }
            } else if policy != .prompt {
                return current.id
            }
        }
        if source != .live, let last = turns.indices.last, turns[last].status == .open {
            turns[last].status = .ended
        }
        // A new turn: an interrupt sent for an earlier one (an Esc right at its end) says nothing about this one.
        if source == .live { interruptSent = false }
        turns.append(ChatTurn(id: "turn:" + entryID, status: source == .live ? .running : .open, startedAt: timestamp, endedAt: nil,
                              hasUserPrompt: policy == .prompt, firstEntryID: entryID, result: nil))
        delta.turnsChanged = true
        return "turn:" + entryID
    }

    mutating func nextID(_ prefix: String) -> String {
        sequence += 1
        return "\(prefix):\(sequence)"
    }

    func rawID(_ prefix: String, _ offset: UInt64?) -> String {
        offset.map { "\(prefix):@\($0)" } ?? "\(prefix):\(entries.count)"
    }

    func threadOf(parent: String?, sidechain: Bool, agentID: String? = nil) -> ChatThread {
        if let parent { return .subagent(parent) }
        if sidechain, source == .sessionTranscript { return .subagent(agentID ?? "sidechain") }
        return .main
    }

    mutating func updateEntry(_ id: String, delta: inout ModelDelta, _ change: (inout ChatEntry.Body) -> Void) {
        guard let i = index[id] else { return }
        change(&entries[i].body)
        delta.noteUpdated(id)
    }

    /// The position in `blocksPlaced` order of the next block of API message `messageID`, then reserves `count` of them.
    mutating func reserveBlocks(of messageID: String, count: Int) -> Int {
        let start = blocksPlaced[messageID, default: 0]
        blocksPlaced[messageID] = start + count
        return start
    }

    static func sniffType(_ head: String) -> String? {
        guard let range = head.range(of: #""type"\s*:\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let match = head[range]
        return match.split(separator: "\"").dropFirst(2).first.map(String.init)
    }
}
