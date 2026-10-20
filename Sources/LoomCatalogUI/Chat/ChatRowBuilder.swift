import Foundation
import LoomChat

/// What `ChatRowBuilder` needs: the model and the state of the view. Everything is a value, so the derivation is a pure
/// function that tests call directly.
struct ChatBuildInput {
    var model: TurnModel
    var mode: ChatViewMode = .normal
    /// Rows whose open state differs from their default (the session's one set of open folds, groups and bodies).
    var toggled: Set<String> = []
    var flags: [String: Set<String>] = [:]
    /// Whole tool results that "Show all" read, by tool id.
    var fullOutputs: [String: ChatFullOutput] = [:]
    /// The session is working now: its newest turn is live, never folded, and ends in the live row.
    var isWorking = false
    /// Older turns exist before the first row, so no "Session started" line.
    var hasOlder = false
    var workingDirectory: String?
    /// When the live turn was first seen, for a turn whose prompt carries no timestamp.
    var liveStarts: [String: Date] = [:]
    var lastActivity: Date?
}

/// Derives the rows of the stream from the entries and the turns: the work rows and their groups, the turn fold, the live
/// row and the dividers. The fold (everything between your message and the final answer, once the turn settled), the
/// group summary and the live row's place follow T3 Code (MIT, Copyright 2026 T3 Tools Inc.):
/// apps/web/src/components/chat/MessagesTimeline.logic.ts (`deriveTurnFolds`) and
/// packages/client-runtime/src/work-log/presentation.ts; no code is copied.
enum ChatRowBuilder {
    static func foldID(_ turnID: String) -> String { "fold:" + turnID }
    static func liveID(_ turnID: String) -> String { "live:" + turnID }
    static func groupID(_ firstToolID: String) -> String { "group:" + firstToolID }
    static func changesID(_ turnID: String) -> String { "changes:" + turnID }

    /// All the rows, derived from scratch. `ChatRowStore` keeps them between changes and rebuilds only what changed; this is
    /// the reference it must equal.
    static func rows(_ input: ChatBuildInput) -> [ChatRow] {
        let entries = input.model.entries
        guard !entries.isEmpty else { return [emptyRow] }
        var out: [ChatRow] = []
        out.reserveCapacity(entries.count)
        out += head(input)
        let turns = turnsByID(input.model)
        let newest = input.model.turns.last?.id
        for run in runs(of: entries, from: 0) {
            out += rows(for: entries[run.range], turn: turns[run.turnID], isNewest: run.turnID == newest, input: input)
        }
        return out
    }

    /// The turns by id. When an id is there twice (reads that overlapped), the later one wins: `ChatRowStore` looks a turn up from
    /// the end of the model, so both agree.
    static func turnsByID(_ model: TurnModel) -> [String: ChatTurn] {
        Dictionary(model.turns.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
    }

    static let emptyRow = ChatRow(id: "empty", kind: .empty)

    /// The rows before the first turn: "Session started", unless older turns come first or the session opens with its own
    /// start marker (a chat driver's run places one: the model's line says "Session started" itself).
    static func head(_ input: ChatBuildInput) -> [ChatRow] {
        let entries = input.model.entries
        guard let first = entries.first else { return [emptyRow] }
        if input.hasOlder { return [] }
        if case .marker(.sessionStart) = first.body { return [] }
        return [startRow(entries)]
    }

    /// "Session started", dated by the first entry that has a time.
    static func startRow(_ entries: [ChatEntry]) -> ChatRow {
        ChatRow(id: "start", kind: .start(entries.first(where: { $0.timestamp != nil })?.timestamp))
    }

    /// A stretch of entries of one turn (the entries of a turn lie together).
    struct Run {
        var turnID: String
        var range: Range<Int>
    }

    /// The runs from `start` (the first entry of a run) to the end.
    static func runs(of entries: [ChatEntry], from start: Int) -> [Run] {
        var out: [Run] = []
        var start = start
        while start < entries.count {
            let turnID = entries[start].turnID
            var end = start + 1
            while end < entries.count, entries[end].turnID == turnID { end += 1 }
            out.append(Run(turnID: turnID, range: start..<end))
            start = end
        }
        return out
    }

    // MARK: One turn

    /// The rows of one turn's entries.
    static func rows(for run: ArraySlice<ChatEntry>, turn: ChatTurn?, isNewest: Bool, input: ChatBuildInput) -> [ChatRow] {
        let mode = input.mode
        let live = turn.map { $0.status == .running || (input.isWorking && isNewest && $0.status == .open) } ?? false
        var visible = run.filter { entry in
            guard entry.thread == .main else { return false }
            if case let .tool(call) = entry.body, ChatWork.isHidden(call) { return false }
            return true
        }
        // Work that never finished in a turn that is not live (a transcript has no result to say so) was stopped.
        if !live { visible = visible.map(settledCopy) }
        guard let turn else { return emit(visible, turn: nil, input: input, finalAnswerID: nil, settled: false) }

        let interrupted = turn.status == .interrupted || visible.contains { if case .marker(.interrupted) = $0.body { true } else { false } }
        var failed = false
        if case .failed = turn.status { failed = true }
        let settled = !live && !interrupted && !failed

        // The final answer: the turn's last finished prose of the main thread.
        let finalIndex = visible.lastIndex { entry in
            if case let .assistantText(text) = entry.body, !text.isStreaming { return true }
            return false
        }
        let finalAnswerID = settled ? finalIndex.map { visible[$0].id } : nil

        var out: [ChatRow] = []
        var fold: PlannedFold?
        if settled, let finalIndex, let planned = planFold(visible: visible, finalIndex: finalIndex, turn: turn, input: input) {
            fold = planned
        }

        if let fold {
            // Your message, then the fold; folded entries only when it is open; what stays visible after it.
            var pending: [ChatEntry] = []
            for (index, entry) in visible.enumerated() {
                if index == fold.range.lowerBound {
                    out += emit(pending, turn: turn, input: input, finalAnswerID: finalAnswerID, settled: settled)
                    pending = []
                    let id = foldID(turn.id)
                    let open = isOpen(id, default: mode.opensFoldsAndGroups, input)
                    out.append(ChatRow(id: id, kind: .turnFold(fold.fold), open: open))
                    if open { out += emit(fold.folded, turn: turn, input: input, finalAnswerID: nil, settled: settled) }
                }
                if fold.range.contains(index) {
                    if fold.keeps(entry) { pending.append(entry) }
                    continue
                }
                pending.append(entry)
            }
            out += emit(pending, turn: turn, input: input, finalAnswerID: finalAnswerID, settled: settled)
        } else if live {
            out += liveRows(visible, turn: turn, input: input)
        } else {
            out += emit(visible, turn: turn, input: input, finalAnswerID: finalAnswerID, settled: settled)
        }

        // The card also shows for a turn that was interrupted or failed after editing files.
        if !live {
            let calls = visible.compactMap { entry -> ToolCall? in if case let .tool(call) = entry.body { call } else { nil } }
            let files = EditScan.changedFiles(in: calls, workingDirectory: input.workingDirectory)
            if !files.isEmpty {
                out.append(ChatRow(id: changesID(turn.id), kind: .changedFiles(
                    ChangedFiles(turnID: turn.id, files: files, lines: ChatWork.tree(of: files)))))
            }
        }
        return out
    }

    private static func settledCopy(_ entry: ChatEntry) -> ChatEntry {
        var copy = entry
        switch entry.body {
        case var .tool(call) where call.status == .running:
            call.status = .interrupted
            copy.body = .tool(call)
        case var .subagent(run) where run.status == .running:
            run.status = .interrupted
            copy.body = .subagent(run)
        case var .assistantText(text) where text.isStreaming:
            text.isStreaming = false
            copy.body = .assistantText(text)
        default:
            break
        }
        return copy
    }

    // MARK: Fold

    private struct PlannedFold {
        var range: Range<Int>
        var fold: TurnFold
        var folded: [ChatEntry]

        /// Plan cards, dividers and your own messages stay visible (CHAT-SPEC → Turn fold); everything else folds. A message
        /// sent while Claude works joins the running turn, so it lies between your first message and the answer.
        func keeps(_ entry: ChatEntry) -> Bool {
            switch entry.body {
            case .plan, .marker, .user: true
            default: false
            }
        }
    }

    private static func planFold(visible: [ChatEntry], finalIndex: Int, turn: ChatTurn, input: ChatBuildInput) -> PlannedFold? {
        let first = visible.firstIndex { if case .user = $0.body { true } else { false } }
            .flatMap { $0 < finalIndex ? $0 + 1 : nil } ?? 0
        guard first < finalIndex else { return nil }
        let range = first..<finalIndex
        let folded = visible[range].filter { entry in
            switch entry.body {
            case .plan, .marker, .user: false
            default: true
            }
        }
        guard !folded.isEmpty else { return nil }
        var calls: [ToolCall] = []
        var agents = 0
        var thinking = 0
        for entry in folded {
            switch entry.body {
            case let .tool(call): calls.append(call)
            case .subagent: agents += 1
            case .thinking: thinking += 1
            default: break
            }
        }
        let failedCount = calls.filter { $0.status == .failed }.count
        let title = turn.durationMs.map { $0 >= 1000 ? "Worked for \(ChatTime.duration(milliseconds: $0))" : "Worked" } ?? "Worked"
        let detail = (calls.isEmpty && agents == 0)
            ? (thinking > 0 ? "thought" : "")
            : ChatWork.summary(of: calls, agents: agents, capitalized: false)
        return PlannedFold(range: range, fold: TurnFold(turnID: turn.id, title: title, detail: detail, failedCount: failedCount),
                           folded: Array(folded))
    }

    // MARK: Live turn

    private static func liveRows(_ visible: [ChatEntry], turn: ChatTurn, input: ChatBuildInput) -> [ChatRow] {
        let mode = input.mode
        var cut = visible.count
        if !mode.opensFoldsAndGroups {
            // The trailing tools collapse into the live row; thinking blocks between them do not break the run in Normal.
            var index = visible.count
            while index > 0 {
                switch visible[index - 1].body {
                case .tool: index -= 1; cut = index
                case .thinking where !mode.showsThinkingBlocks: index -= 1
                default: index = 0
                }
            }
        }
        let head = Array(visible[..<cut])
        let tail = visible[cut...].compactMap { entry -> ChatEntry? in if case .tool = entry.body { entry } else { nil } }
        var out = emit(head, turn: turn, input: input, finalAnswerID: nil, settled: false)

        let id = liveID(turn.id)
        let open = isOpen(id, default: false, input)
        if open { out += emit(tail, turn: turn, input: input, finalAnswerID: nil, settled: false) }
        if mode == .normal, let thought = input.model.thoughtLine(in: turn) {
            out.append(ChatRow(id: "thought:" + turn.id, kind: .thought(thought)))
        }
        let start = turn.startedAt ?? input.liveStarts[turn.id]
        out.append(ChatRow(id: id, kind: .live(LiveRow(
            turnID: turn.id, label: liveLabel(visible, model: input.model, workingDirectory: input.workingDirectory),
            startedAt: start, lastActivity: input.lastActivity, hiddenTools: tail)), open: open))
        return out
    }

    static func liveLabel(_ visible: [ChatEntry], model: TurnModel, workingDirectory: String?) -> String {
        if model.activity == "compacting" { return "Compacting" }
        for entry in visible.reversed() {
            switch entry.body {
            case let .tool(call) where call.status == .running:
                return ChatWork.sentence(ChatWork.label(for: call, workingDirectory: workingDirectory), running: true)
            case let .subagent(run) where run.status == .running:
                return "Waiting for \(run.subagentType ?? "an agent")"
            case .thinking:
                return "Thinking"
            case .user:
                return "Working"
            case .assistantText:
                return "Writing"
            default:
                continue
            }
        }
        return "Working"
    }

    // MARK: Rows of entries

    /// The rows of a list of entries: consecutive tools form a group, thinking shows only outside Normal.
    private static func emit(_ entries: [ChatEntry], turn: ChatTurn?, input: ChatBuildInput, finalAnswerID: String?, settled: Bool) -> [ChatRow] {
        let mode = input.mode
        var out: [ChatRow] = []
        var tools: [ChatEntry] = []

        func flushTools() {
            guard !tools.isEmpty else { return }
            defer { tools = [] }
            if tools.count == 1 {
                out.append(toolRow(tools[0], input: input))
                return
            }
            let calls = tools.compactMap { entry -> ToolCall? in if case let .tool(call) = entry.body { call } else { nil } }
            let id = groupID(tools[0].id)
            let group = ToolGroup(id: id, members: tools, summary: ChatWork.summary(of: calls),
                                  status: groupStatus(calls), failedCount: calls.filter { $0.status == .failed }.count)
            let open = isOpen(id, default: mode.opensFoldsAndGroups, input)
            out.append(ChatRow(id: id, kind: .group(group), open: open))
            if open { out += tools.map { toolRow($0, input: input, indent: 1) } }
        }

        for entry in entries {
            switch entry.body {
            case .tool:
                tools.append(entry)
            case .thinking:
                guard mode.showsThinkingBlocks else { continue }
                flushTools()
                out.append(ChatRow(id: entry.id, kind: .thinking(entry), open: isOpen(entry.id, default: true, input)))
            case .user:
                flushTools()
                out.append(ChatRow(id: entry.id, kind: .user(entry), open: isOpen(entry.id, default: false, input)))
            case .assistantText:
                flushTools()
                out.append(ChatRow(id: entry.id, kind: .prose(entry, settled: settled && entry.id == finalAnswerID),
                                   flags: input.flags[entry.id] ?? []))
            case .subagent:
                flushTools()
                out.append(ChatRow(id: entry.id, kind: .subagent(entry)))
            case .plan:
                flushTools()
                out.append(ChatRow(id: entry.id, kind: .plan(entry), open: isOpen(entry.id, default: false, input),
                                   flags: input.flags[entry.id] ?? []))
            case .request:
                flushTools()
                out.append(ChatRow(id: entry.id, kind: .request(entry)))
            case .unknown:
                flushTools()
                out.append(ChatRow(id: entry.id, kind: .raw(entry), open: isOpen(entry.id, default: false, input)))
            case let .marker(marker):
                flushTools()
                if case let .interrupted(afterMs) = marker {
                    out.append(ChatRow(id: entry.id, kind: .divider(interruptedText(afterMs: afterMs, at: entry.timestamp, turn: turn))))
                } else {
                    out.append(ChatRow(id: entry.id, kind: .marker(marker, entry.timestamp)))
                }
            }
        }
        flushTools()
        return out
    }

    private static func toolRow(_ entry: ChatEntry, input: ChatBuildInput, indent: Int = 0) -> ChatRow {
        var defaultOpen = false
        if case let .tool(call) = entry.body, call.status == .failed || call.status == .denied { defaultOpen = true }
        return ChatRow(id: entry.id, kind: .tool(entry), open: isOpen(entry.id, default: defaultOpen, input),
                       flags: input.flags[entry.id] ?? [], indent: indent, fullOutput: input.fullOutputs[entry.id])
    }

    private static func groupStatus(_ calls: [ToolCall]) -> ToolCall.Status {
        if calls.contains(where: { $0.status == .running }) { return .running }
        return calls.last?.status ?? .succeeded
    }

    static func interruptedText(afterMs: Double?, at time: Date?, turn: ChatTurn?) -> String {
        var milliseconds = afterMs
        if milliseconds == nil, let time, let start = turn?.startedAt { milliseconds = time.timeIntervalSince(start) * 1000 }
        guard let milliseconds, milliseconds >= 1000 else { return "You stopped" }
        return "You stopped after \(ChatTime.duration(milliseconds: milliseconds))"
    }

    static func isOpen(_ id: String, default defaultOpen: Bool, _ input: ChatBuildInput) -> Bool {
        defaultOpen != input.toggled.contains(id)
    }
}
