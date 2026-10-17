import Foundation
import LoomCore

extension TurnModel {
    /// Types and system subtypes that are known and carry nothing the chat shows. Everything else Loom does not type is
    /// kept as a raw row. Checked on 17 Oct 2026 against the 137 transcripts of the isolated test profile (Claude Code
    /// 2.1.280 to 2.1.300): the first group of each list was seen there, the second comes from the SDK's typings or older
    /// versions and has not been seen in a transcript.
    static let silentTypes: Set<String> = [
        // Seen in transcripts.
        "file-history-snapshot", "file-history-delta", "queue-operation", "attachment", "permission-mode", "custom-title",
        "ai-title", "agent-name", "last-prompt", "mode", "atis-latch", "cost-state", "continued-in", "api-request",
        "api-request-blob", "api-request-shape",
        // Not seen in a transcript.
        "summary", "progress", "pr-link", "tag", "tool_progress", "tool_use_summary", "prompt_suggestion", "auth_status",
        "active_goal",
    ]
    static let silentSystemSubtypes: Set<String> = [
        // Seen in transcripts.
        "stop_hook_summary", "turn_duration", "informational", "model_refusal_no_fallback",
        // Not seen in a transcript (stream events and typings).
        "hook_started", "hook_progress", "hook_response", "task_progress", "task_updated", "task_notification",
        "background_tasks_changed", "notification", "commands_changed", "thinking_tokens", "files_persisted",
        "memory_recall", "plugin_install", "elicitation_complete", "worker_shutting_down", "mirror_error",
        "control_request_progress", "model_refusal_fallback", "permission_denied",
    ]
    /// What `/exit` prints (a different one each time; the four seen), so its output record is not shown.
    static let farewells: Set<String> = ["Catch you later!", "See ya!", "Bye!", "Goodbye!"]

    static let maximumImageBytes = 2 * 1024 * 1024
    static let maximumToolInputStringBytes = 64 * 1024

    // MARK: Session and markers

    mutating func ingestInit(_ info: SystemInit, now: Date, delta: inout ModelDelta) {
        let previous = latestInit
        latestInit = info
        guard source == .live else { return }
        if previous == nil, !startMarkerPlaced {
            startMarkerPlaced = true
            place(id: nextID("start"), thread: .main, timestamp: now, offset: nil, policy: .standalone, delta: &delta,
                  body: .marker(.sessionStart(model: info.model, permissionMode: info.permissionMode)))
            return
        }
        if let model = info.model, previous != nil, model != previous?.model {
            place(id: nextID("model"), thread: .main, timestamp: now, offset: nil, policy: .standalone, delta: &delta,
                  body: .marker(.modelChanged(model)))
        }
        let before = previous?.permissionMode ?? ready?.currentPermissionMode
        if let mode = info.permissionMode, before != nil, mode != before {
            place(id: nextID("mode"), thread: .main, timestamp: now, offset: nil, policy: .standalone, delta: &delta,
                  body: .marker(.modeChanged(mode)))
        }
    }

    mutating func ingestCompaction(_ boundary: CompactBoundary, offset: UInt64?, now: Date, delta: inout ModelDelta) {
        let id = boundary.uuid.map { "compact:\($0)" } ?? offset.map { "compact:@\($0)" } ?? nextID("compact")
        place(id: id, thread: .main, timestamp: boundary.timestamp ?? (source == .live ? now : nil), offset: offset,
              policy: .standalone, delta: &delta,
              body: .marker(.compaction(trigger: boundary.trigger, preTokens: boundary.preTokens, postTokens: boundary.postTokens)))
        contextUsage = boundary.postTokens.map { TokenUsage(inputTokens: $0) }
    }

    mutating func ingestUnknown(_ unknown: UnknownMessage, offset: UInt64?, now: Date, delta: inout ModelDelta) {
        if let type = unknown.type {
            if type == "system" {
                if unknown.subtype == "local_command_output" {
                    if let text = unknown.raw["content"]?.string, !text.isEmpty {
                        place(id: rawID("notice", offset), thread: .main, timestamp: source == .live ? now : nil, offset: offset,
                              policy: .standalone, delta: &delta, body: .marker(.notice(text.clipped(toBytes: 4096))))
                    }
                    return
                }
                if unknown.subtype == "local_command" {
                    // 2.1.280-2.1.284 wrote a local command and its output as system records, in the user records' wrappers.
                    if let text = unknown.raw["content"]?.string, let inner = Self.tagContent(text, "local-command-stdout"),
                       !inner.isEmpty, !Self.farewells.contains(inner) {
                        place(id: rawID("notice", offset), thread: .main, timestamp: source == .live ? now : nil, offset: offset,
                              policy: .standalone, delta: &delta, body: .marker(.notice(inner.clipped(toBytes: 4096))))
                    }
                    return
                }
                if unknown.subtype == "api_error", source != .live {
                    // The transcript's form of `system/api_retry`.
                    let error = unknown.raw["error"]
                    place(id: "retry:\(turns.last?.id ?? "")", thread: .main, timestamp: nil, offset: offset, policy: .standalone,
                          delta: &delta, body: .marker(.retry(attempt: unknown.raw["retryAttempt"]?.int,
                                                              maxRetries: unknown.raw["maxRetries"]?.int,
                                                              error: error?["message"]?.string)))
                    return
                }
                if let subtype = unknown.subtype, Self.silentSystemSubtypes.contains(subtype) { return }
            } else if Self.silentTypes.contains(type) {
                return
            }
        }
        let json = unknown.raw.serializedString
        let size = json.utf8.count
        let raw = RawRecord(reason: .unknownType, type: unknown.type, subtype: unknown.subtype,
                            json: json.clipped(toBytes: RawRecord.maximumJSONBytes), byteCount: size,
                            isTruncated: size > RawRecord.maximumJSONBytes)
        unknownRecordCount += 1
        place(id: rawID("unknown", offset), thread: .main, timestamp: nil, offset: offset, policy: .standalone, delta: &delta,
              body: .unknown(raw))
    }

    // MARK: Assistant

    mutating func ingestAssistant(_ message: AssistantMessage, offset: UInt64?, now: Date, delta: inout ModelDelta) {
        let thread = threadOf(parent: message.parentToolUseID, sidechain: message.isSidechain, agentID: message.agentID)
        let time = message.timestamp ?? (source == .live ? now : nil)
        if thread == .main, !message.isSynthetic, let usage = message.usage { contextUsage = usage }
        // The CLI writes one record per finished content block, all with one API message id; block indexes follow the
        // order they arrive in, which is the order a stream_event used for the same block.
        let base = message.messageID ?? message.uuid ?? "line:\(offset.map(String.init) ?? String(entries.count))"
        let first = reserveBlocks(of: base, count: message.content.count)
        for (position, block) in message.content.enumerated() {
            let rowID = "\(base)#\(first + position)"
            switch block {
            case let .text(text):
                guard !text.allSatisfy(\.isWhitespace) else { continue }
                place(id: rowID, thread: thread, timestamp: time, offset: offset, policy: .work, delta: &delta,
                      body: .assistantText(AssistantText(text: text, isStreaming: false)))
                if case let .subagent(parent) = thread {
                    updateEntry(parent, delta: &delta) { body in
                        if case var .subagent(run) = body {
                            run.latestProgress = text.clipped(toBytes: 1024)
                            body = .subagent(run)
                        }
                    }
                }
            case let .thinking(text, _):
                place(id: rowID, thread: thread, timestamp: time, offset: offset, policy: .work, delta: &delta,
                      body: .thinking(Thinking(text: text, isStreaming: false, isHidden: text.isEmpty,
                                               durationMs: message.thinkingDurationMs)))
            case .redactedThinking:
                place(id: rowID, thread: thread, timestamp: time, offset: offset, policy: .work, delta: &delta,
                      body: .thinking(Thinking(text: "", isStreaming: false, isHidden: true, durationMs: nil)))
            case let .toolUse(use):
                placeToolUse(use, thread: thread, time: time, offset: offset, delta: &delta)
            case .toolResult, .image:
                continue
            case let .unknown(type, raw):
                let json = raw.serializedString
                unknownRecordCount += 1
                place(id: rowID, thread: thread, timestamp: time, offset: offset, policy: .work, delta: &delta,
                      body: .unknown(RawRecord(reason: .unknownType, type: "content_block:" + (type ?? "?"), subtype: nil,
                                               json: json.clipped(toBytes: RawRecord.maximumJSONBytes),
                                               byteCount: json.utf8.count, isTruncated: json.utf8.count > RawRecord.maximumJSONBytes)))
            }
        }
    }

    private mutating func placeToolUse(_ use: ToolUseBlock, thread: ChatThread, time: Date?, offset: UInt64?, delta: inout ModelDelta) {
        let input = use.input.clippingStrings(toBytes: Self.maximumToolInputStringBytes)
        if let i = index[use.id] {
            // Streamed before this record: take the final input and keep what the result already filled in.
            switch entries[i].body {
            case var .tool(call):
                call.name = use.name
                call.input = input
                entries[i].body = .tool(call)
            case var .subagent(run):
                Self.fill(&run, from: input)
                entries[i].body = .subagent(run)
            case var .plan(plan):
                Self.fill(&plan, from: input)
                entries[i].body = .plan(plan)
            default:
                break
            }
            delta.noteUpdated(use.id)
            return
        }
        place(id: use.id, thread: thread, timestamp: time, offset: offset, policy: .work, delta: &delta,
              body: Self.newToolBody(id: use.id, name: use.name, input: input, time: time))
    }

    static func newToolBody(id: String, name: String, input: JSONValue, time: Date?) -> ChatEntry.Body {
        switch name {
        case "Agent", "Task":
            var run = SubagentRun(toolUseID: id, description: "", subagentType: nil, prompt: "", status: .running,
                                  result: nil, latestProgress: nil, agentID: nil, startedAt: time, endedAt: nil)
            fill(&run, from: input)
            return .subagent(run)
        case "ExitPlanMode":
            var plan = PlanDocument(toolUseID: id, markdown: "", filePath: nil, status: .proposed)
            fill(&plan, from: input)
            return .plan(plan)
        default:
            return .tool(ToolCall(id: id, name: name, input: input, status: .running, output: nil, images: [], exitCode: nil,
                                  changes: nil, startedAt: time, endedAt: nil))
        }
    }

    private static func fill(_ run: inout SubagentRun, from input: JSONValue) {
        run.description = input["description"]?.string ?? run.description
        run.subagentType = input["subagent_type"]?.string ?? run.subagentType
        run.prompt = input["prompt"]?.string?.clipped(toBytes: 4096) ?? run.prompt
    }

    private static func fill(_ plan: inout PlanDocument, from input: JSONValue) {
        if let markdown = input["plan"]?.string, !markdown.isEmpty { plan.markdown = markdown }
        plan.filePath = input["planFilePath"]?.string ?? plan.filePath
    }

    // MARK: User

    /// What a user-role record is.
    enum PromptKind: Equatable {
        case prompt(text: String, command: UserPrompt.Command?)
        /// "[Request interrupted by user]": the user stopped the turn.
        case interruptNotice
        /// Output of a local command, or a system notice.
        case notice(String)
        /// Nothing to show (meta records, caveats, empty messages).
        case silent
    }

    /// Classifies a user record that carries no tool result. Claude Code writes several things as user records that are
    /// not what the person typed; only `.prompt` is a human prompt, and only it starts a turn in a transcript.
    ///
    /// The wrappers seen in the 137 transcripts of the isolated test profile (17 Oct 2026): `<local-command-caveat>` (an
    /// `isMeta` record, also a "Caveat: ..." text that is `isMeta`), `<command-name>` / `<command-message>` /
    /// `<command-args>` (a slash command; `/exit` is not shown, S2), `<local-command-stdout>` (its output; `/exit` prints
    /// one of four farewells), `<system-reminder>` (`isMeta`), `<task-notification>` (origin `task-notification`) and
    /// `[Request interrupted by user]` / `[Request interrupted by user for tool use]`. `<local-command-stderr>`,
    /// `<bash-input>`, `<bash-stdout>` and `<bash-stderr>` (the `!` command) have not been seen in a transcript. A user
    /// record with origin `peer` (a subagent's hand-back) is handled before this, by origin.
    static func promptKind(of message: UserMessage) -> PromptKind {
        guard !message.hasToolResult, !message.isMeta else { return .silent }
        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = message.content.contains { if case .image = $0 { true } else { false } }
        if text.isEmpty { return hasImages ? .prompt(text: "", command: nil) : .silent }
        if text.hasPrefix("[Request interrupted by user") { return .interruptNotice }
        if text.hasPrefix("<local-command-caveat>") || text.hasPrefix("<system-reminder>") { return .silent }
        for tag in ["local-command-stdout", "local-command-stderr", "bash-stdout", "bash-stderr"] where text.hasPrefix("<\(tag)>") {
            let inner = tagContent(text, tag) ?? ""
            return inner.isEmpty || farewells.contains(inner) ? .silent : .notice(inner.clipped(toBytes: 4096))
        }
        if text.hasPrefix("<task-notification") { return .notice(text.clipped(toBytes: 1024)) }
        if text.hasPrefix("<command-name>") {
            let name = tagContent(text, "command-name") ?? ""
            if name == "/exit" { return .silent }
            let arguments = tagContent(text, "command-args") ?? ""
            let shown = arguments.isEmpty ? name : name + " " + arguments
            return .prompt(text: shown, command: UserPrompt.Command(name: name, arguments: arguments))
        }
        if text.hasPrefix("<bash-input>") { return .prompt(text: "!" + (tagContent(text, "bash-input") ?? ""), command: nil) }
        return .prompt(text: text, command: nil)
    }

    static func tagContent(_ text: String, _ tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func ingestUser(_ message: UserMessage, offset: UInt64?, now: Date, delta: inout ModelDelta) {
        let thread = threadOf(parent: message.parentToolUseID, sidechain: message.isSidechain)
        let time = message.timestamp ?? (source == .live ? now : nil)
        if message.hasToolResult {
            let results = message.content.compactMap { block -> ToolResultBlock? in
                if case let .toolResult(result) = block { result } else { nil }
            }
            for result in results {
                applyToolResult(result, structured: results.count == 1 ? message.toolUseResult : nil, thread: thread, time: time,
                                offset: offset, delta: &delta)
            }
            return
        }
        // A subagent's own prompt is kept on its card, not as a message.
        guard thread == .main else { return }
        // Stdout also carries `isReplay` records that are not Loom's sends (a finished background task starts a turn with a
        // `task-notification` record). They are notices, never prompts.
        if let origin = message.originKind, origin != "human" {
            let text = message.text ?? ""
            if origin == "task-notification" { finishSubagent(fromNotification: text, time: time, delta: &delta) }
            place(id: message.uuid ?? rawID("notice", offset), thread: .main, timestamp: time, offset: offset, policy: .standalone,
                  delta: &delta, body: .marker(.notice(Self.tagContent(text, "summary") ?? origin)))
            return
        }
        switch Self.promptKind(of: message) {
        case .silent:
            break
        case .interruptNotice:
            if source == .live {
                guard let turn = turns.last else { break }
                place(id: "interrupted:\(turn.id)", thread: .main, timestamp: time, offset: offset, policy: .standalone, delta: &delta,
                      body: .marker(.interrupted(afterMs: nil)))
            } else {
                // Named after its own record, not the turn: the turn's id depends on where a read began.
                place(id: "interrupted:\(message.uuid ?? rawID("record", offset))", thread: .main, timestamp: time, offset: offset,
                      policy: .standalone, delta: &delta, body: .marker(.interrupted(afterMs: nil)))
                if let last = turns.indices.last {
                    turns[last].status = .interrupted
                    delta.turnsChanged = true
                }
            }
        case let .notice(text):
            place(id: rawID("notice", offset), thread: .main, timestamp: time, offset: offset, policy: .standalone, delta: &delta,
                  body: .marker(.notice(text)))
        case let .prompt(text, command):
            let id = message.uuid ?? rawID("user", offset)
            let images = message.content.compactMap { block -> ImageRef? in
                if case let .image(image) = block { Self.bounded(image) } else { nil }
            }
            if let i = index[id], case var .user(existing) = entries[i].body {
                // The echo of a message Loom sent: Claude read it.
                existing.delivery = .read
                entries[i].body = .user(existing)
                delta.noteUpdated(id)
                break
            }
            place(id: id, thread: .main, timestamp: time, offset: offset, policy: .prompt, delta: &delta,
                  body: .user(UserPrompt(text: text, images: images, delivery: .read, command: command,
                                         isBrief: source == .subagentTranscript)))
        }
    }

    /// A finished background agent: its call got only "async_launched" as a result, so the notice that follows says how it
    /// ended (`<tool-use-id>` names the Agent call, `<status>` is completed, failed or killed).
    private mutating func finishSubagent(fromNotification text: String, time: Date?, delta: inout ModelDelta) {
        guard let callID = Self.tagContent(text, "tool-use-id"), let status = Self.tagContent(text, "status") else { return }
        let ended: SubagentRun.Status = status == "completed" ? .succeeded : status == "killed" || status == "stopped" ? .interrupted : .failed
        guard index[callID] != nil else {
            // The call lies before what was read; `prepend` applies this when the older part arrives.
            pendingFinishes[callID] = SubagentFinish(status: ended, time: time)
            return
        }
        updateEntry(callID, delta: &delta) { body in
            guard case var .subagent(run) = body, run.status == .running else { return }
            run.status = ended
            run.endedAt = time
            body = .subagent(run)
        }
    }

    private static func bounded(_ image: ImageRef) -> ImageRef {
        var copy = image
        if copy.byteCount > maximumImageBytes { copy.data = nil }
        return copy
    }

    private mutating func applyToolResult(_ result: ToolResultBlock, structured: JSONValue?, thread: ChatThread, time: Date?,
                                          offset: UInt64?, delta: inout ModelDelta) {
        guard let id = result.toolUseID else { return }
        let images = result.images.map(Self.bounded)
        let (status, exitCode) = Self.classify(result)
        guard let i = index[id] else {
            // The call lies before what was read: keep the result, with no call.
            place(id: id, thread: thread, timestamp: time, offset: offset, policy: .work, delta: &delta,
                  body: .tool(ToolCall(id: id, name: "", input: .null, status: status,
                                       output: result.text.isEmpty ? nil : ClippedText(result.text), images: images,
                                       exitCode: exitCode, changes: Self.lineChanges(from: structured), startedAt: nil,
                                       endedAt: time)))
            return
        }
        switch entries[i].body {
        case var .tool(call):
            call.status = status
            call.output = result.text.isEmpty ? nil : ClippedText(result.text)
            call.images = images
            call.exitCode = exitCode
            call.changes = Self.lineChanges(from: structured)
            call.endedAt = time
            entries[i].body = .tool(call)
        case var .subagent(run):
            run.agentID = structured?["agentId"]?.string ?? structured?["agent_id"]?.string ?? run.agentID
            run.result = result.text.isEmpty ? nil : ClippedText(result.text)
            // A background agent's immediate result has launched it, not finished it.
            let launched = structured?["isAsync"]?.bool == true || structured?["status"]?.string == "async_launched"
            if launched {
                run.status = .running
            } else {
                run.status = result.isError ? .failed : .succeeded
                run.endedAt = time
            }
            entries[i].body = .subagent(run)
        case var .plan(plan):
            plan.status = result.isError ? .rejected : .approved
            entries[i].body = .plan(plan)
        default:
            break
        }
        delta.noteUpdated(id)
    }

    static func classify(_ result: ToolResultBlock) -> (ToolCall.Status, exitCode: Int?) {
        guard result.isError else { return (.succeeded, nil) }
        // A denial's tool result: "User rejected tool use" (an interrupt), or the message the host gave with `deny`.
        let text = result.text
        if text.hasPrefix("The user doesn't want to proceed") || text.hasPrefix("Permission to use")
            || text.hasPrefix("User rejected tool use")
            || text.hasPrefix("The user rejected") || text.hasPrefix("The user doesn't want to take this action") {
            return (.denied, nil)
        }
        var exitCode: Int?
        if text.hasPrefix("Exit code ") {
            exitCode = Int(text.dropFirst("Exit code ".count).prefix(while: { $0.isNumber || $0 == "-" }))
        }
        return (.failed, exitCode)
    }

    /// Lines added and removed, from a result's `structuredPatch` (or the content of a created file).
    static func lineChanges(from result: JSONValue?) -> LineChanges? {
        guard let result else { return nil }
        if result["type"]?.string == "create", let content = result["content"]?.string {
            // An empty file has no lines (splitting "" still yields one piece).
            let lines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count - (content.hasSuffix("\n") ? 1 : 0)
            return LineChanges(added: lines, removed: 0)
        }
        guard let hunks = result["structuredPatch"]?.array else { return nil }
        var added = 0
        var removed = 0
        for hunk in hunks {
            for line in hunk["lines"]?.array ?? [] {
                guard let text = line.string else { continue }
                if text.hasPrefix("+") { added += 1 } else if text.hasPrefix("-") { removed += 1 }
            }
        }
        return LineChanges(added: added, removed: removed)
    }

    // MARK: Delivery and tasks

    mutating func ingestLifecycle(_ lifecycle: CommandLifecycle, delta: inout ModelDelta) {
        guard let i = index[lifecycle.commandUUID], case var .user(prompt) = entries[i].body else { return }
        let before = prompt.delivery
        switch lifecycle.state {
        case .queued: if prompt.delivery == .pending { prompt.delivery = .queued }
        case .started: prompt.delivery = .read
        case .cancelled: if prompt.delivery != .read { prompt.delivery = .cancelled }
        case .completed, nil: break
        }
        guard prompt.delivery != before else { return }
        entries[i].body = .user(prompt)
        delta.noteUpdated(lifecycle.commandUUID)
    }

    mutating func ingestTask(_ task: TaskStarted, delta: inout ModelDelta) {
        tasks[task.taskID] = task
        guard task.taskType == "local_agent", let callID = task.toolUseID else { return }
        updateEntry(callID, delta: &delta) { body in
            if case var .subagent(run) = body {
                run.agentID = task.taskID
                run.subagentType = run.subagentType ?? task.subagentType
                if run.description.isEmpty { run.description = task.description ?? "" }
                body = .subagent(run)
            }
        }
    }

    // MARK: Result

    mutating func ingestResult(_ result: TurnResult, now: Date, delta: inout ModelDelta) {
        guard source == .live else { return }
        if !turns.contains(where: { $0.status == .running }) {
            // A result with no turn: a failure before any work (a startup failure, a refusal). Keep what it says.
            guard result.isError else { return }
            place(id: nextID("failure"), thread: .main, timestamp: now, offset: nil, policy: .work, delta: &delta,
                  body: .marker(.notice(result.result ?? result.errors.first ?? result.subtype.rawValue)))
        }
        guard let position = turns.lastIndex(where: { $0.status == .running }) else { return }
        let status: ChatTurn.Status
        if result.wasInterrupted {
            status = .interrupted
        } else if result.isError || result.subtype != .success {
            // `subtype` alone says nothing: a failed API call is "success" with `is_error`.
            status = .failed(result.subtype != .success ? result.subtype.rawValue : result.terminalReason ?? "error")
        } else {
            status = .succeeded
        }
        turns[position].status = status
        turns[position].result = result
        turns[position].endedAt = now
        delta.turnsChanged = true
        let turnID = turns[position].id
        // Whatever was still streaming has stopped; work that never finished in a stopped or failed turn is interrupted.
        // (Work that goes on after a successful turn, like a background agent, keeps running.)
        let unfinished = status != .succeeded
        let start = index[turns[position].firstEntryID] ?? 0
        for i in start..<entries.count where entries[i].turnID == turnID {
            var changed = false
            switch entries[i].body {
            case var .assistantText(text) where text.isStreaming:
                text.isStreaming = false
                entries[i].body = .assistantText(text)
                changed = true
            case var .thinking(thinking) where thinking.isStreaming:
                thinking.isStreaming = false
                entries[i].body = .thinking(thinking)
                changed = true
            case var .tool(call) where call.status == .running && unfinished:
                call.status = .interrupted
                call.endedAt = now
                entries[i].body = .tool(call)
                changed = true
            case var .subagent(run) where run.status == .running && unfinished:
                run.status = .interrupted
                run.endedAt = now
                entries[i].body = .subagent(run)
                changed = true
            default:
                break
            }
            if changed { delta.noteUpdated(entries[i].id) }
        }
        inflight.removeAll()
        if status == .interrupted {
            place(id: "interrupted:\(turnID)", thread: .main, timestamp: now, offset: nil, policy: .standalone, delta: &delta,
                  body: .marker(.interrupted(afterMs: result.durationMs)))
        }
    }

    // MARK: Partial messages

    mutating func ingestStream(_ event: StreamEvent, now: Date, delta: inout ModelDelta) {
        let key = event.parentToolUseID ?? ""
        let thread: ChatThread = event.parentToolUseID.map(ChatThread.subagent) ?? .main
        switch event.event {
        case let .messageStart(messageID, _, _):
            inflight[key] = Inflight(messageID: messageID ?? nextID("stream"))
        case let .blockStart(blockIndex, block):
            let messageID: String
            if let known = inflight[key]?.messageID {
                messageID = known
            } else {
                messageID = nextID("stream")
                inflight[key] = Inflight(messageID: messageID)
            }
            let rowID = "\(messageID)#\(blockIndex)"
            var id = rowID
            var kind = StreamingBlock.Kind.text
            var body = ChatEntry.Body.assistantText(AssistantText(text: "", isStreaming: true))
            switch block {
            case let .text(text):
                body = .assistantText(AssistantText(text: text, isStreaming: true))
            case let .thinking(text):
                kind = .thinking
                body = .thinking(Thinking(text: text, isStreaming: true, isHidden: false, durationMs: nil))
            case .redactedThinking:
                kind = .thinking
                body = .thinking(Thinking(text: "", isStreaming: true, isHidden: true, durationMs: nil))
            case let .toolUse(toolID, name):
                id = toolID
                kind = .tool
                body = Self.newToolBody(id: toolID, name: name, input: .object([:]), time: now)
            case .other:
                return
            }
            if index[id] == nil {
                place(id: id, thread: thread, timestamp: now, offset: nil, policy: .work, delta: &delta, body: body)
            }
            inflight[key]?.blocks[blockIndex] = StreamingBlock(entryID: id, kind: kind)
        case let .blockDelta(blockIndex, piece):
            guard let block = inflight[key]?.blocks[blockIndex] else { return }
            switch piece {
            case let .text(added):
                updateEntry(block.entryID, delta: &delta) { body in
                    if case var .assistantText(text) = body {
                        text.text += added
                        body = .assistantText(text)
                    }
                }
            case let .thinking(added):
                updateEntry(block.entryID, delta: &delta) { body in
                    if case var .thinking(thinking) = body {
                        thinking.text += added
                        body = .thinking(thinking)
                    }
                }
            case let .inputJSON(added):
                inflight[key]?.blocks[blockIndex]?.inputJSON += added
            case .signature, .other:
                break
            }
        case let .blockStop(blockIndex):
            guard let block = inflight[key]?.blocks[blockIndex] else { return }
            let json = block.inputJSON
            updateEntry(block.entryID, delta: &delta) { body in
                switch body {
                case var .assistantText(text):
                    text.isStreaming = false
                    body = .assistantText(text)
                case var .thinking(thinking):
                    thinking.isStreaming = false
                    body = .thinking(thinking)
                case var .tool(call):
                    if !json.isEmpty, let input = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) {
                        call.input = input.clippingStrings(toBytes: Self.maximumToolInputStringBytes)
                        body = .tool(call)
                    }
                default:
                    break
                }
            }
        case .messageStop:
            inflight[key] = nil
        case .messageDelta, .ping, .unknown:
            break
        }
    }
}
