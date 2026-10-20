import Foundation

// Development/test fixture, chat mode (`claude -p --input-format stream-json --output-format stream-json ...`).
// Every JSON shape the fake puts on the wire lives in this file, so a correction touches one place.
// Shapes follow the S1 recordings of Claude Code 2.1.300 (plans/experiments/v2-spikes/S1-wire-20261017.md;
// raw files under ~/Library/Application Support/Loom-Dev/probe/v2-spikes/S1/). Account, e-mail and
// organisation values are fake on purpose.
//
// Confirmed by S1 and reproduced here: nothing on stdout until input; `initialize` answered with the mode,
// session state, models, commands, account, pid and capabilities; `system/init` at the start of every turn;
// `command_lifecycle` (queued at accept, started + the `isReplay` echo when Claude reads the message,
// completed or cancelled at the end); task-notification `isReplay` user records; `result` as success with
// `is_error` for API errors; interrupt answering `cancelled[]` before an `error_during_execution` result;
// `can_use_tool` fields (`description`, `agent_id`, `requires_user_interaction`); ExitPlanMode input with
// `plan` and `planFilePath`; Write creating a file with an empty `structuredPatch`; `rate_limit_event` with
// `unifiedWindows`; no `tool_progress`.
//
// Still guessed (S1 could not provoke them):
//   - `rate_limit_event` statuses `allowed_warning` and `rejected`, and what a rejected turn's result is.
//   - `system/api_retry`, `compact_boundary`, `system/status` compacting and `conversation_reset` shapes
//     (from the typings only).
//   - The `later` coalescing rule (the fake never coalesces) and what `completed` covers after a join.
//   - `side_question` / `rewind_conversation` details beyond the recorded response keys.
//   - `system/session_state_changed` is emitted only when CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS or
//     CLAUDE_CODE_SDK_READS_SESSION_STATE is `1` (confirmed: `initialize.session_state` needs no switch).

struct ChatWire {
    typealias Object = [String: Any]

    var session: String
    var model: String

    static func orNull(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

    func uuid() -> String { UUID().uuidString.lowercased() }

    static func timestamp(_ date: Date = Date()) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: date)
    }

    /// One NDJSON line: sorted keys, no escaped slashes, newline-terminated.
    static func line(_ object: Object) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// Fields every system record carries.
    private func system(_ subtype: String, _ fields: Object = [:]) -> Object {
        var object: Object = ["type": "system", "subtype": subtype, "uuid": uuid(), "session_id": session]
        object.merge(fields) { _, new in new }
        return object
    }

    // MARK: Session

    /// The answer to `initialize`. S1: `capabilities` here is short, `system/init` lists the full set.
    func initializeResponse(
        slashCommands: [String], model: String, permissionMode: String, state: String, pid: Int32, capabilities: [String],
        outputStyle: String = "default", availableStyles: [String] = ["default", "Concise"]
    ) -> Object {
        ["commands": slashCommands.map { ["name": $0, "description": "Fake \($0)", "argumentHint": ""] as Object },
         "agents": [["name": "Explore", "description": "Fake read-only search agent"] as Object],
         "output_style": outputStyle, "available_output_styles": availableStyles,
         // As the CLI lists them: Default, then the aliases, each with the effort levels it takes (Haiku has none).
         "models": [["value": "default", "resolvedModel": model, "displayName": "Default (fake)",
                     "description": "Fake model", "supportsEffort": true,
                     "supportedEffortLevels": ["low", "medium", "high"]] as Object,
                    ["value": "opus", "resolvedModel": "claude-opus-fake-5-1", "displayName": "Opus (fake)",
                     "description": "Fake model", "supportsEffort": true,
                     "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]] as Object,
                    ["value": "sonnet", "resolvedModel": "claude-sonnet-fake-5-1", "displayName": "Sonnet (fake)",
                     "description": "Fake model", "supportsEffort": true,
                     "supportedEffortLevels": ["low", "medium", "high"]] as Object,
                    ["value": "haiku", "resolvedModel": "claude-haiku-fake-4-5", "displayName": "Haiku (fake)",
                     "description": "Fake model", "supportsEffort": false] as Object],
         "account": ["email": "user@example.invalid", "organization": "Example Organization",
                     "subscriptionType": "Fake plan", "apiProvider": "firstParty"],
         "pid": Int(pid), "claude_code_version": "2.1.300-fake", "current_permission_mode": permissionMode,
         "fast_mode_state": "off", "session_state": state, "capabilities": capabilities]
    }

    /// Emitted at the start of every turn, never before the first send.
    func initMessage(
        permissionMode: String, cwd: String, tools: [String], slashCommands: [String], skills: [String],
        capabilities: [String], effort: String?, outputStyle: String = "default"
    ) -> Object {
        var object = system("init", [
            "claude_code_version": "2.1.300-fake", "cwd": cwd, "model": model, "permissionMode": permissionMode,
            "tools": tools, "slash_commands": slashCommands, "terminal_slash_commands": ["doctor", "color", "focus"],
            "skills": skills, "agents": ["general-purpose", "Explore"], "mcp_servers": [] as [Any],
            "plugins": [] as [Any], "output_style": outputStyle, "apiKeySource": "none", "capabilities": capabilities,
        ])
        if let effort { object["effort"] = effort }
        return object
    }

    /// `queued` at accept, `started` when Claude reads the message, then `completed` or `cancelled`.
    func commandLifecycle(uuid commandUUID: String, state: String) -> Object {
        ["type": "command_lifecycle", "command_uuid": commandUUID, "state": state, "uuid": uuid(), "session_id": session]
    }

    /// The `isReplay` echo of a user message: it means Claude READ the message.
    func userEcho(uuid: String, content: Any, origin: Object?) -> Object {
        var object: Object = ["type": "user", "message": ["role": "user", "content": content],
                              "parent_tool_use_id": NSNull(), "session_id": session, "uuid": uuid,
                              "timestamp": Self.timestamp(), "isReplay": true]
        if let origin { object["origin"] = origin }
        return object
    }

    /// A finished background task, told to the model as a user message (also an `isReplay` record).
    func taskNotificationUser(taskID: String, toolUseID: String, summary: String, runID: String) -> Object {
        let body = "<task-notification>\n<task-id>\(taskID)</task-id>\n<tool-use-id>\(toolUseID)</tool-use-id>\n"
            + "<status>completed</status>\n<summary>\(summary)</summary>\n</task-notification>"
        return ["type": "user", "message": ["role": "user", "content": body], "parent_tool_use_id": NSNull(),
                "session_id": session, "uuid": uuid(), "timestamp": Self.timestamp(), "isReplay": true,
                "origin": ["kind": "task-notification", "producer": "session-task", "runId": runID]]
    }

    /// A plain user text record such as "[Request interrupted by user]".
    func userText(_ text: String) -> Object {
        ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text] as Object]],
         "parent_tool_use_id": NSNull(), "session_id": session, "uuid": uuid(), "timestamp": Self.timestamp()]
    }

    func sessionState(_ state: String, hostOnly: Bool) -> Object {
        system("session_state_changed", hostOnly ? ["state": state, "sdk_host_only": true] : ["state": state])
    }

    func statusRequesting(_ userUUIDs: [String]) -> Object {
        system("status", ["status": "requesting", "user_message_uuids": userUUIDs])
    }

    func status(_ status: String?, permissionMode: String? = nil, compactResult: String? = nil) -> Object {
        var fields: Object = ["status": Self.orNull(status)]
        if let permissionMode { fields["permissionMode"] = permissionMode }
        if let compactResult { fields["compact_result"] = compactResult }
        return system("status", fields)
    }

    func compactBoundary(trigger: String, preTokens: Int, postTokens: Int) -> Object {
        system("compact_boundary", ["compact_metadata": [
            "trigger": trigger, "pre_tokens": preTokens, "post_tokens": postTokens, "duration_ms": 1_800]])
    }

    func apiRetry(attempt: Int, maxRetries: Int, delayMs: Int, status: Int, error: String) -> Object {
        system("api_retry", ["attempt": attempt, "max_retries": maxRetries, "retry_delay_ms": delayMs,
                             "error_status": status, "error": error])
    }

    /// `resetsAt` is Unix seconds and `utilization` a fraction.
    func rateLimit(status: String, resetsAt: Int, type: String, utilization: Double) -> Object {
        ["type": "rate_limit_event", "uuid": uuid(), "session_id": session,
         "rate_limit_info": [
            "status": status, "resetsAt": resetsAt, "rateLimitType": type, "overageStatus": "rejected",
            "overageDisabledReason": "org_level_disabled", "isUsingOverage": false,
            "unifiedWindows": [
                "five_hour": ["utilization": utilization, "resetsAt": resetsAt] as Object,
                "seven_day": ["utilization": 0.23, "resetsAt": resetsAt + 303_000] as Object,
            ]]]
    }

    func conversationReset(newID: String, trigger: String) -> Object {
        ["type": "conversation_reset", "new_conversation_id": newID, "trigger": trigger, "session_id": session,
         "uuid": uuid()]
    }

    /// A record type the host has never heard of, and an unknown `system` subtype.
    func unknownRecords() -> [Object] {
        [["type": "hologram", "session_id": session, "uuid": uuid(), "payload": ["shape": "unknown", "depth": 3]],
         system("future_event", ["detail": "later"]),
         ["type": "keep_alive"]]
    }

    // MARK: Tasks (background Bash, subagents)

    func taskStarted(
        taskID: String, runID: String, toolUseID: String, description: String, type: String,
        subagentType: String? = nil, prompt: String? = nil
    ) -> Object {
        var fields: Object = ["task_id": taskID, "run_id": runID, "tool_use_id": toolUseID, "description": description,
                              "is_backgrounded": false, "task_type": type]
        if let subagentType { fields["subagent_type"] = subagentType; fields["spawn_depth"] = 1 }
        if let prompt { fields["prompt"] = prompt }
        return system("task_started", fields)
    }

    func taskUpdated(taskID: String, runID: String, patch: Object) -> Object {
        system("task_updated", ["task_id": taskID, "run_id": runID, "patch": patch])
    }

    func taskNotification(taskID: String, runID: String, toolUseID: String, status: String, summary: String) -> Object {
        system("task_notification", ["task_id": taskID, "run_id": runID, "tool_use_id": toolUseID, "status": status,
                                     "output_file": "", "summary": summary])
    }

    func taskProgress(taskID: String, runID: String, toolUseID: String, description: String, subagentType: String) -> Object {
        system("task_progress", ["task_id": taskID, "run_id": runID, "tool_use_id": toolUseID, "description": description,
                                 "subagent_type": subagentType, "last_tool_name": "Bash",
                                 "usage": ["total_tokens": 1_800, "tool_uses": 1, "duration_ms": 400]])
    }

    func backgroundTasksChanged(_ tasks: [Object]) -> Object {
        system("background_tasks_changed", ["tasks": tasks])
    }

    // MARK: Streaming (`--include-partial-messages`)

    func streamEvent(_ event: Object, parent: String?, apiMessageID: String) -> Object {
        ["type": "stream_event", "event": event, "session_id": session, "uuid": uuid(),
         "parent_tool_use_id": Self.orNull(parent), "api_message_id": apiMessageID]
    }

    func messageStart(id: String) -> Object {
        ["type": "message_start",
         "message": ["id": id, "type": "message", "role": "assistant", "model": model, "content": [] as [Any],
                     "stop_reason": NSNull(), "usage": ["input_tokens": 1_200, "output_tokens": 1]]]
    }

    func blockStart(index: Int, block: Object) -> Object {
        ["type": "content_block_start", "index": index, "content_block": block]
    }

    func blockDelta(index: Int, delta: Object) -> Object {
        ["type": "content_block_delta", "index": index, "delta": delta]
    }

    func blockStop(index: Int) -> Object { ["type": "content_block_stop", "index": index] }

    func messageDelta(stopReason: String, outputTokens: Int) -> Object {
        ["type": "message_delta", "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()],
         "usage": ["output_tokens": outputTokens]]
    }

    func messageStop() -> Object { ["type": "message_stop"] }

    // MARK: Messages

    /// A subagent's records carry its identity next to `parent_tool_use_id`.
    func agentFields(id: String, type: String, description: String) -> Object {
        ["agent_id": id, "subagent_type": type, "task_description": description]
    }

    /// One `assistant` record per completed content block; blocks of one API message share `message.id`.
    func assistant(
        messageID: String, block: Object, stopReason: String?, outputTokens: Int, parent: String?, extra: Object = [:]
    ) -> Object {
        var object: Object = [
            "type": "assistant", "session_id": session, "uuid": uuid(), "parent_tool_use_id": Self.orNull(parent),
            "timestamp": Self.timestamp(),
            "message": ["id": messageID, "type": "message", "role": "assistant", "model": model, "content": [block],
                        "stop_reason": Self.orNull(stopReason), "stop_sequence": NSNull(),
                        "usage": ["input_tokens": 1_200, "output_tokens": outputTokens,
                                  "cache_read_input_tokens": 800, "cache_creation_input_tokens": 0]],
        ]
        object.merge(extra) { _, new in new }
        return object
    }

    /// A synthetic assistant message for an API failure: visible text plus an `error` category.
    func apiErrorAssistant(text: String, category: String, status: Int?) -> Object {
        ["type": "assistant", "session_id": session, "uuid": uuid(), "parent_tool_use_id": NSNull(),
         "timestamp": Self.timestamp(), "error": category, "is_api_error_message": true,
         "api_error_status": status.map { $0 as Any } ?? NSNull(),
         "message": ["id": uuid(), "type": "message", "role": "assistant", "model": "<synthetic>",
                     "stop_reason": "stop_sequence", "stop_sequence": "", "content": [["type": "text", "text": text] as Object],
                     "usage": ["input_tokens": 0, "output_tokens": 0]]]
    }

    /// A tool result as the CLI emits it: a `user` record with the structured output in `tool_use_result`.
    func toolResult(
        toolUseID: String, content: Any, isError: Bool, structured: Any?, parent: String?, extra: Object = [:]
    ) -> Object {
        var block: Object = ["type": "tool_result", "tool_use_id": toolUseID, "content": content]
        if isError { block["is_error"] = true }
        var object: Object = [
            "type": "user", "session_id": session, "uuid": uuid(), "parent_tool_use_id": Self.orNull(parent),
            "timestamp": Self.timestamp(), "message": ["role": "user", "content": [block]],
        ]
        if let structured { object["tool_use_result"] = structured }
        object.merge(extra) { _, new in new }
        return object
    }

    /// `text` nil leaves out `result` (an interrupted turn has none).
    func result(
        subtype: String, isError: Bool, text: String?, durationMs: Int, stopReason: String?, terminalReason: String?,
        apiErrorStatus: Int?, cost: Double, outputTokens: Int, denials: [Object], errors: [String],
        userUUIDs: [String], queued: Int
    ) -> Object {
        let usage: Object = ["input_tokens": 1_200, "output_tokens": outputTokens, "cache_read_input_tokens": 800,
                             "cache_creation_input_tokens": 0]
        var object: Object = [
            "type": "result", "subtype": subtype, "is_error": isError, "duration_ms": durationMs,
            "duration_api_ms": durationMs * 3 / 4, "num_turns": 1, "stop_reason": Self.orNull(stopReason),
            "api_error_status": apiErrorStatus.map { $0 as Any } ?? NSNull(), "session_id": session, "uuid": uuid(),
            "total_cost_usd": cost, "usage": usage,
            "modelUsage": [model: ["inputTokens": 1_200, "outputTokens": outputTokens, "cacheReadInputTokens": 800,
                                   "cacheCreationInputTokens": 0, "webSearchRequests": 0, "costUSD": cost,
                                   "contextWindow": 200_000, "maxOutputTokens": 32_000]],
            "permission_denials": denials, "user_message_uuids": userUUIDs, "queued_turn_count": queued,
            "origin": ["kind": "human"], "fast_mode_state": "off",
        ]
        if let first = userUUIDs.first { object["user_message_uuid"] = first }
        if let text { object["result"] = text }
        if let terminalReason { object["terminal_reason"] = terminalReason }
        if !errors.isEmpty { object["errors"] = errors }
        return object
    }

    // MARK: Control channel

    func controlSuccess(_ requestID: String, _ payload: Object) -> Object {
        ["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": payload]]
    }

    func controlError(_ requestID: String, _ message: String, code: String? = nil) -> Object {
        var response: Object = ["subtype": "error", "request_id": requestID, "error": message]
        if let code { response["error_code"] = code }
        return ["type": "control_response", "response": response]
    }

    func controlCancel(_ requestID: String) -> Object {
        ["type": "control_cancel_request", "request_id": requestID]
    }

    /// Without a permission host, what needs approval is denied and this event says so (S1 Q1).
    func permissionDenied(tool: String, toolUseID: String, message: String, reasonType: String? = nil) -> Object {
        var fields: Object = ["tool_name": tool, "tool_use_id": toolUseID, "message": message]
        if let reasonType { fields["decision_reason_type"] = reasonType }
        return system("permission_denied", fields)
    }

    func controlProgress(_ requestID: String) -> Object {
        system("control_request_progress", ["request_id": requestID, "status": "started"])
    }

    /// `permission_suggestions`, `decision_reason` and `description` are left out when empty, as the CLI does.
    func canUseTool(
        requestID: String, tool: String, input: Object, toolUseID: String, description: String?, suggestions: [Object],
        reason: String?, agentID: String?, requiresInteraction: Bool
    ) -> Object {
        var request: Object = ["subtype": "can_use_tool", "tool_name": tool, "display_name": tool, "input": input,
                               "tool_use_id": toolUseID]
        if let description { request["description"] = description }
        if !suggestions.isEmpty { request["permission_suggestions"] = suggestions }
        if let reason { request["decision_reason"] = reason; request["decision_reason_type"] = "other" }
        if let agentID { request["agent_id"] = agentID }
        if requiresInteraction { request["requires_user_interaction"] = true }
        return ["type": "control_request", "request_id": requestID, "request": request]
    }

    func usageResponse() -> Object {
        ["rate_limits_available": true, "account": ["email": "user@example.invalid"],
         "rate_limits": ["five_hour": ["utilization": 38.0, "resets_at": "2026-10-08T18:00:00.000Z"] as Object,
                         "seven_day": ["utilization": 82.0, "resets_at": "2026-10-12T09:00:00Z"] as Object]]
    }

    func sideQuestionResponse(_ question: String) -> Object {
        ["response": "Fake side answer to: \(question.prefix(100))", "synthetic": false]
    }

    /// `rewind_files`, as S8 saw it: a dry run answers the files and line totals, or `canRewind:false` with the CLI's text
    /// inside a success; a real run answers `skippedLinks` (a refusal is an error frame, `controlError`).
    func rewindFilesDryRun(files: [String], insertions: Int, deletions: Int) -> Object {
        ["canRewind": true, "filesChanged": files, "insertions": insertions, "deletions": deletions]
    }

    func rewindFilesCannot(_ error: String) -> Object { ["canRewind": false, "error": error] }

    func rewindFilesDone() -> Object { ["canRewind": true, "skippedLinks": 0] }

    func rewindConversationResponse(target: String, prefill: String, preceding: String) -> Object {
        ["rewound": true, "targetMessageUuid": target, "prefillText": prefill, "precedingAssistantUuid": preceding]
    }

    // MARK: Transcript (`$CLAUDE_CONFIG_DIR/projects/<folder>/<session>.jsonl`)

    /// The wrapper Claude writes around a message in its transcript file.
    func transcriptRecord(
        type: String, uuid: String, message: Object, parentUUID: String?, cwd: String, agentID: String? = nil,
        extra: Object = [:]
    ) -> Object {
        var record: Object = [
            "type": type, "message": message, "uuid": uuid, "parentUuid": Self.orNull(parentUUID),
            "sessionId": session, "cwd": cwd, "isSidechain": agentID != nil, "userType": "external",
            "entrypoint": "sdk-cli", "version": "2.1.300-fake", "timestamp": Self.timestamp(),
        ]
        if let agentID { record["agentId"] = agentID }
        record.merge(extra) { _, new in new }
        return record
    }
}
