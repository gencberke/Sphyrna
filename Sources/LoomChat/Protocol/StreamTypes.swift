import Foundation
import LoomCore

// The typed shapes of Claude Code's stream-json messages that Loom reads, as spike S1 recorded them on Claude Code
// 2.1.300 (plans/experiments/v2-spikes/S1-wire-20261017.md). Fields are optional where S1 saw them missing. Anything not
// named here stays reachable as `StreamMessage.unknown`.

// MARK: Usage and content

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var cacheReadInputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheCreationInputTokens: Int? = nil,
                cacheReadInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    init?(json: JSONValue?) {
        guard let json, json.object != nil else { return nil }
        self.init(inputTokens: json["input_tokens"]?.int, outputTokens: json["output_tokens"]?.int,
                  cacheCreationInputTokens: json["cache_creation_input_tokens"]?.int,
                  cacheReadInputTokens: json["cache_read_input_tokens"]?.int)
    }

    /// Input + cache creation + cache read + output: the context a message occupied (T3's ring formula).
    public var contextTokens: Int {
        (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0) + (outputTokens ?? 0)
    }
}

/// An image block's summary. `data` is the base64 payload when it was read.
public struct ImageRef: Sendable, Equatable {
    public var mediaType: String?
    /// The base64 text's length.
    public var byteCount: Int
    public var data: String?

    public init(mediaType: String?, byteCount: Int, data: String?) {
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.data = data
    }

    init(json: JSONValue) {
        let source = json["source"]
        let data = source?["data"]?.string
        self.init(mediaType: source?["media_type"]?.string, byteCount: data?.utf8.count ?? 0, data: data)
    }
}

public struct ToolUseBlock: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ToolResultBlock: Sendable, Equatable {
    public var toolUseID: String?
    /// The text parts joined by newlines.
    public var text: String
    public var images: [ImageRef]
    public var isError: Bool

    public init(toolUseID: String?, text: String, images: [ImageRef] = [], isError: Bool = false) {
        self.toolUseID = toolUseID
        self.text = text
        self.images = images
        self.isError = isError
    }
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    /// `text` is empty when the thinking is not shown (display omitted, or only its signature was kept).
    case thinking(text: String, hasSignature: Bool)
    case redactedThinking
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case image(ImageRef)
    case unknown(type: String?, raw: JSONValue)

    init(json: JSONValue) {
        let type = json["type"]?.string
        switch type {
        case "text":
            self = .text(json["text"]?.string ?? "")
        case "thinking":
            self = .thinking(text: json["thinking"]?.string ?? json["text"]?.string ?? "", hasSignature: json["signature"]?.string != nil)
        case "redacted_thinking":
            self = .redactedThinking
        case "tool_use", "server_tool_use", "mcp_tool_use":
            if let id = json["id"]?.string, let name = json["name"]?.string {
                self = .toolUse(ToolUseBlock(id: id, name: name, input: json["input"] ?? .object([:])))
            } else {
                self = .unknown(type: type, raw: json)
            }
        case "tool_result":
            var text = ""
            var images: [ImageRef] = []
            switch json["content"] {
            case let .string(value)?: text = value
            case let .array(parts)?:
                var texts: [String] = []
                for part in parts {
                    switch part["type"]?.string {
                    case "image": images.append(ImageRef(json: part))
                    default: if let value = part["text"]?.string { texts.append(value) }
                    }
                }
                text = texts.joined(separator: "\n")
            default: break
            }
            self = .toolResult(ToolResultBlock(toolUseID: json["tool_use_id"]?.string, text: text, images: images,
                                               isError: json["is_error"]?.bool ?? false))
        case "image":
            self = .image(ImageRef(json: json))
        default:
            self = .unknown(type: type, raw: json)
        }
    }

    /// The blocks of a `message.content`, which is a string or a list.
    static func blocks(from content: JSONValue?) -> [ContentBlock] {
        switch content {
        case let .string(text)?: [.text(text)]
        case let .array(items)?: items.map(ContentBlock.init(json:))
        default: []
        }
    }
}

// MARK: Messages

public struct AssistantMessage: Sendable, Equatable {
    public var uuid: String?
    public var sessionID: String?
    /// Set on a subagent's messages: the `tool_use_id` of the Agent call that started it.
    public var parentToolUseID: String?
    /// The API's message id. Several records can share it: the CLI writes one record per finished content block.
    public var messageID: String?
    public var model: String?
    public var content: [ContentBlock]
    public var stopReason: String?
    public var usage: TokenUsage?
    public var error: String?
    public var timestamp: Date?
    /// Set on a subagent's messages; equals the `task_id` of its `system/task_started`.
    public var agentID: String?
    public var subagentType: String?
    /// How long Claude thought (`thinking_duration_ms` on the stream's envelope, `thinkingDurationMs` in transcripts).
    public var thinkingDurationMs: Double?
    public var isSidechain: Bool

    /// Messages the CLI makes itself (an API error, a stop notice) carry the model name `<synthetic>`.
    public var isSynthetic: Bool { model == "<synthetic>" }

    init(json: JSONValue) {
        let message = json["message"]
        uuid = json["uuid"]?.string
        sessionID = json["session_id"]?.string ?? json["sessionId"]?.string
        parentToolUseID = json["parent_tool_use_id"]?.string
        messageID = message?["id"]?.string
        model = message?["model"]?.string
        content = ContentBlock.blocks(from: message?["content"])
        stopReason = message?["stop_reason"]?.string
        usage = TokenUsage(json: message?["usage"])
        error = json["error"]?.string
        timestamp = WireTimestamp.parse(json["timestamp"]?.string)
        agentID = json["agent_id"]?.string ?? json["agentId"]?.string
        subagentType = json["subagent_type"]?.string
        thinkingDurationMs = json["thinking_duration_ms"]?.double ?? json["thinkingDurationMs"]?.double
        isSidechain = json["isSidechain"]?.bool ?? false
    }
}

public struct UserMessage: Sendable, Equatable {
    public var uuid: String?
    public var sessionID: String?
    public var parentToolUseID: String?
    public var content: [ContentBlock]
    /// The content was a plain string rather than a list of blocks.
    public var isPlainText: Bool
    /// The CLI's echo of a message Loom sent (`--replay-user-messages`); its `uuid` is the one Loom chose.
    public var isReplay: Bool
    public var isMeta: Bool
    public var isSidechain: Bool
    /// The structured result of the tool a `tool_result` block answers (`tool_use_result` on the wire, `toolUseResult`
    /// in transcripts).
    public var toolUseResult: JSONValue?
    public var timestamp: Date?
    public var priority: String?
    /// `origin.kind`: `human` for what Loom sent, `task-notification` for a finished background task. Stdout carries
    /// `isReplay` records that are not Loom's sends, so correlate echoes by your own uuids only.
    public var originKind: String?

    init(json: JSONValue) {
        let message = json["message"]
        uuid = json["uuid"]?.string
        sessionID = json["session_id"]?.string ?? json["sessionId"]?.string
        parentToolUseID = json["parent_tool_use_id"]?.string
        content = ContentBlock.blocks(from: message?["content"])
        isPlainText = message?["content"]?.string != nil
        isReplay = json["isReplay"]?.bool ?? false
        isMeta = json["isMeta"]?.bool ?? false
        isSidechain = json["isSidechain"]?.bool ?? false
        toolUseResult = json["tool_use_result"] ?? json["toolUseResult"]
        timestamp = WireTimestamp.parse(json["timestamp"]?.string)
        priority = json["priority"]?.string
        originKind = json["origin"]?["kind"]?.string
    }

    /// The text blocks joined, or nil when there are none.
    public var text: String? {
        let parts = content.compactMap { block -> String? in if case let .text(text) = block { text } else { nil } }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    public var hasToolResult: Bool { content.contains { if case .toolResult = $0 { true } else { false } } }
}

// MARK: Partial messages

public enum StartedBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case redactedThinking
    case toolUse(id: String, name: String)
    case other(type: String?)
}

public enum BlockDelta: Sendable, Equatable {
    case text(String)
    case thinking(String)
    /// A piece of a tool call's input JSON, which is complete only when the block stops.
    case inputJSON(String)
    case signature
    case other(type: String?)
}

public enum PartialEvent: Sendable, Equatable {
    case messageStart(messageID: String?, model: String?, usage: TokenUsage?)
    case blockStart(index: Int, block: StartedBlock)
    case blockDelta(index: Int, delta: BlockDelta)
    case blockStop(index: Int)
    case messageDelta(stopReason: String?, usage: TokenUsage?)
    case messageStop
    case ping
    case unknown(type: String?, raw: JSONValue)
}

/// A `stream_event`: a raw Messages API event, sent only with `--include-partial-messages`.
public struct StreamEvent: Sendable, Equatable {
    public var event: PartialEvent
    public var parentToolUseID: String?
    public var uuid: String?
    public var sessionID: String?
    public var ttftMs: Double?

    init(json: JSONValue) {
        let raw = json["event"] ?? .null
        parentToolUseID = json["parent_tool_use_id"]?.string
        uuid = json["uuid"]?.string
        sessionID = json["session_id"]?.string
        ttftMs = json["ttft_ms"]?.double
        let index = raw["index"]?.int ?? 0
        switch raw["type"]?.string {
        case "message_start":
            event = .messageStart(messageID: raw["message"]?["id"]?.string, model: raw["message"]?["model"]?.string,
                                  usage: TokenUsage(json: raw["message"]?["usage"]))
        case "content_block_start":
            let block = raw["content_block"] ?? .null
            switch block["type"]?.string {
            case "text": event = .blockStart(index: index, block: .text(block["text"]?.string ?? ""))
            case "thinking": event = .blockStart(index: index, block: .thinking(block["thinking"]?.string ?? ""))
            case "redacted_thinking": event = .blockStart(index: index, block: .redactedThinking)
            case "tool_use", "server_tool_use", "mcp_tool_use":
                if let id = block["id"]?.string, let name = block["name"]?.string {
                    event = .blockStart(index: index, block: .toolUse(id: id, name: name))
                } else {
                    event = .blockStart(index: index, block: .other(type: block["type"]?.string))
                }
            default: event = .blockStart(index: index, block: .other(type: block["type"]?.string))
            }
        case "content_block_delta":
            let delta = raw["delta"] ?? .null
            switch delta["type"]?.string {
            case "text_delta": event = .blockDelta(index: index, delta: .text(delta["text"]?.string ?? ""))
            case "thinking_delta": event = .blockDelta(index: index, delta: .thinking(delta["thinking"]?.string ?? ""))
            case "input_json_delta": event = .blockDelta(index: index, delta: .inputJSON(delta["partial_json"]?.string ?? ""))
            case "signature_delta": event = .blockDelta(index: index, delta: .signature)
            default: event = .blockDelta(index: index, delta: .other(type: delta["type"]?.string))
            }
        case "content_block_stop":
            event = .blockStop(index: index)
        case "message_delta":
            event = .messageDelta(stopReason: raw["delta"]?["stop_reason"]?.string, usage: TokenUsage(json: raw["usage"]))
        case "message_stop":
            event = .messageStop
        case "ping":
            event = .ping
        default:
            event = .unknown(type: raw["type"]?.string, raw: raw)
        }
    }
}

// MARK: System messages

public struct McpServerStatus: Sendable, Equatable {
    public var name: String
    public var status: String?
}

/// `system/init`: emitted at the start of every turn, after the first send (never before it), so the newest one wins.
/// It is not a Ready signal; the `initialize` response is.
public struct SystemInit: Sendable, Equatable {
    public var sessionID: String?
    public var claudeCodeVersion: String?
    public var cwd: String?
    public var model: String?
    public var permissionMode: String?
    public var tools: [String]
    public var slashCommands: [String]
    public var terminalSlashCommands: [String]
    public var skills: [String]
    public var agents: [String]
    public var mcpServers: [McpServerStatus]
    public var outputStyle: String?
    public var apiKeySource: String?
    public var effort: String?
    public var fastModeState: String?
    /// Known so far: `interrupt_receipt_v1`, `interrupt_cancel_queued_v1`, `queued_notifications`,
    /// `interrupt_send_now_v1`, `msg_lifecycle_v1`, `request_marker_lists_v1`, `mcp_read_resource_v1`, `ui_surface_v1`, and
    /// more (ten on 2.1.300). This list is the one to gate on: the `initialize` response lists only `ui_surface_v1`.
    /// Nil when the field is absent, which is not the same as an empty list: nothing may be refused on its account.
    public var capabilities: [String]?

    init(json: JSONValue) {
        func strings(_ key: String) -> [String] {
            (json[key]?.array ?? []).compactMap { $0.string ?? $0["name"]?.string }
        }
        sessionID = json["session_id"]?.string
        claudeCodeVersion = json["claude_code_version"]?.string
        cwd = json["cwd"]?.string
        model = json["model"]?.string
        permissionMode = json["permissionMode"]?.string ?? json["permission_mode"]?.string
        tools = strings("tools")
        slashCommands = strings("slash_commands")
        terminalSlashCommands = strings("terminal_slash_commands")
        skills = strings("skills")
        agents = strings("agents")
        mcpServers = (json["mcp_servers"]?.array ?? []).compactMap { server in
            server["name"]?.string.map { McpServerStatus(name: $0, status: server["status"]?.string) }
        }
        outputStyle = json["output_style"]?.string
        apiKeySource = json["apiKeySource"]?.string
        effort = json["effort"]?.string
        fastModeState = json["fast_mode_state"]?.string
        capabilities = json["capabilities"]?.array?.compactMap(\.string)
    }
}

/// `system/status`: `compacting` or `requesting` while it lasts, nil when it ends.
public struct SystemStatus: Sendable, Equatable {
    public var status: String?
    public var permissionMode: String?
    public var compactResult: String?
    public var compactError: String?

    init(json: JSONValue) {
        status = json["status"]?.string
        permissionMode = json["permissionMode"]?.string ?? json["permission_mode"]?.string
        compactResult = json["compact_result"]?.string
        compactError = json["compact_error"]?.string
    }
}

public struct CompactBoundary: Sendable, Equatable {
    /// `manual` or `auto`.
    public var trigger: String?
    public var preTokens: Int?
    public var postTokens: Int?
    public var durationMs: Double?
    public var uuid: String?
    public var timestamp: Date?

    init(json: JSONValue) {
        // The stream says `compact_metadata`. The transcript spelling `compactMetadata` is a guess: none of the 137 transcripts of
        // the test profile (17 Oct 2026) holds a compact boundary.
        let metadata = json["compact_metadata"] ?? json["compactMetadata"]
        trigger = metadata?["trigger"]?.string
        preTokens = (metadata?["pre_tokens"] ?? metadata?["preTokens"])?.int
        postTokens = (metadata?["post_tokens"] ?? metadata?["postTokens"])?.int
        durationMs = (metadata?["duration_ms"] ?? metadata?["durationMs"])?.double
        uuid = json["uuid"]?.string
        timestamp = WireTimestamp.parse(json["timestamp"]?.string)
    }
}

/// `system/api_retry`: the API call failed and is tried again.
public struct APIRetry: Sendable, Equatable {
    public var attempt: Int?
    public var maxRetries: Int?
    public var retryDelayMs: Double?
    public var errorStatus: Int?
    /// `rate_limit`, `overloaded`, `server_error`, `authentication_failed`, `billing_error`, and others.
    public var error: String?

    init(json: JSONValue) {
        attempt = json["attempt"]?.int
        maxRetries = json["max_retries"]?.int
        retryDelayMs = json["retry_delay_ms"]?.double
        errorStatus = json["error_status"]?.int
        error = json["error"]?.string
    }
}

/// `system/session_state_changed`: the authoritative idle, running or requires-action signal.
public struct SessionStateChange: Sendable, Equatable {
    public var state: String?

    init(json: JSONValue) { state = json["state"]?.string }
}

/// `conversation_reset`: `/clear` or a plan exit with a clear changed the conversation id mid-process.
public struct ConversationReset: Sendable, Equatable {
    public var newConversationID: String?
    /// `clear`, `plan_mode_exit`, `fresh_session` or `onboarding`.
    public var trigger: String?

    init(json: JSONValue) {
        newConversationID = json["new_conversation_id"]?.string
        trigger = json["trigger"]?.string
    }
}

public struct RateLimitEvent: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// A fraction: 0.41 is 41 %.
        public var utilization: Double?
        /// Seconds since 1970.
        public var resetsAt: Double?
    }

    /// `allowed`, `allowed_warning` or `rejected`. Only `allowed` was seen.
    public var status: String?
    /// Seconds since 1970: when the limiting window resets.
    public var resetsAt: Double?
    /// `five_hour`, `seven_day`, and others.
    public var rateLimitType: String?
    public var isUsingOverage: Bool?
    /// Every window, by name (`five_hour`, `seven_day`).
    public var windows: [String: Window]

    /// The limiting window's utilization.
    public var utilization: Double? { rateLimitType.flatMap { windows[$0]?.utilization } }

    init(json: JSONValue) {
        let info = json["rate_limit_info"] ?? json
        status = info["status"]?.string
        resetsAt = info["resetsAt"]?.double ?? info["resets_at"]?.double
        rateLimitType = info["rateLimitType"]?.string ?? info["rate_limit_type"]?.string
        isUsingOverage = info["isUsingOverage"]?.bool
        var windows: [String: Window] = [:]
        for (name, value) in info["unifiedWindows"]?.object ?? [:] {
            windows[name] = Window(utilization: value["utilization"]?.double, resetsAt: value["resetsAt"]?.double)
        }
        self.windows = windows
    }
}

/// `command_lifecycle`: what became of a message Loom sent. `command_uuid` is the client uuid. Gate on
/// `msg_lifecycle_v1`. `queued` means the CLI has it (delivered); the `isReplay` echo and `started` mean Claude read it;
/// `cancelled` means it was dropped unread; `completed` closes it with the turn.
public struct CommandLifecycle: Sendable, Equatable {
    public enum State: String, Sendable {
        case queued, started, completed, cancelled
    }

    public var commandUUID: String
    public var state: State?
    /// The raw state, for one this build does not know.
    public var rawState: String?

    init?(json: JSONValue) {
        guard let id = json["command_uuid"]?.string else { return nil }
        commandUUID = id
        rawState = json["state"]?.string
        state = rawState.flatMap(State.init(rawValue:))
    }
}

/// `system/task_started`: a background task or subagent began. For a subagent (`task_type == "local_agent"`) `taskID`
/// equals the `agent_id` of its messages and of its `can_use_tool` requests, which carry no name of their own.
public struct TaskStarted: Sendable, Equatable {
    public var taskID: String
    public var taskType: String?
    public var toolUseID: String?
    public var description: String?
    public var subagentType: String?
    /// `is_backgrounded`: the task runs in the background (it outlives the turn).
    public var isBackgrounded: Bool

    init?(json: JSONValue) {
        guard let id = json["task_id"]?.string else { return nil }
        taskID = id
        taskType = json["task_type"]?.string
        toolUseID = json["tool_use_id"]?.string
        description = json["description"]?.string
        subagentType = json["subagent_type"]?.string
        isBackgrounded = json["is_backgrounded"]?.bool ?? false
    }
}

// MARK: Result

public struct ResultSubtype: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let success = ResultSubtype(rawValue: "success")
    public static let errorDuringExecution = ResultSubtype(rawValue: "error_during_execution")
    public static let errorMaxTurns = ResultSubtype(rawValue: "error_max_turns")
    public static let errorMaxBudgetUSD = ResultSubtype(rawValue: "error_max_budget_usd")
    public static let errorMaxStructuredOutputRetries = ResultSubtype(rawValue: "error_max_structured_output_retries")
}

/// `result`: one per turn, the main thread's turn-complete signal. Judge success by `isError` and `terminalReason`, never by
/// `subtype` alone: a failed API call (auth, unknown model) is `subtype: "success"` with `is_error: true` and
/// `terminal_reason: "api_error"` (its category is on the preceding `assistant.error`), and an interrupt is
/// `error_during_execution` with `is_error: true`, `terminal_reason: "aborted_tools"` and no text.
public struct TurnResult: Sendable, Equatable {
    public var subtype: ResultSubtype
    public var isError: Bool
    public var result: String?
    public var durationMs: Double?
    public var durationAPIMs: Double?
    public var numTurns: Int?
    public var stopReason: String?
    public var totalCostUSD: Double?
    public var usage: TokenUsage?
    public var permissionDenialCount: Int
    /// More turns follow when this is above zero.
    public var queuedTurnCount: Int?
    /// `completed`, `aborted_streaming`, `aborted_tools`, `blocking_limit`, `prompt_too_long`, `max_turns`,
    /// `budget_exhausted`, and others.
    public var terminalReason: String?
    public var errors: [String]
    public var apiErrorStatus: Int?
    public var sessionID: String?
    public var uuid: String?
    /// `modelUsage.<model>.contextWindow` of every model the turn used, keyed as the CLI names the model: the context
    /// ring's denominator (S1: 1,000,000 for Haiku 5.5).
    public var contextWindows: [String: Int]

    /// The user stopped the turn (an interrupt ends it with an aborted terminal reason).
    public var wasInterrupted: Bool { terminalReason?.hasPrefix("aborted") == true }

    init(json: JSONValue) {
        subtype = ResultSubtype(rawValue: json["subtype"]?.string ?? "")
        isError = json["is_error"]?.bool ?? (subtype != .success)
        result = json["result"]?.string
        durationMs = json["duration_ms"]?.double
        durationAPIMs = json["duration_api_ms"]?.double
        numTurns = json["num_turns"]?.int
        stopReason = json["stop_reason"]?.string
        totalCostUSD = json["total_cost_usd"]?.double
        usage = TokenUsage(json: json["usage"])
        permissionDenialCount = json["permission_denials"]?.array?.count ?? 0
        queuedTurnCount = json["queued_turn_count"]?.int
        terminalReason = json["terminal_reason"]?.string
        errors = (json["errors"]?.array ?? []).compactMap { $0.string ?? $0["message"]?.string }
        apiErrorStatus = json["api_error_status"]?.int
        sessionID = json["session_id"]?.string
        uuid = json["uuid"]?.string
        var windows: [String: Int] = [:]
        for (model, usage) in json["modelUsage"]?.object ?? [:] {
            if let window = usage["contextWindow"]?.int, window > 0 { windows[model] = window }
        }
        contextWindows = windows
    }
}

// MARK: Passed through

/// A message of a type or subtype this build does not type. It is kept whole, never an error.
public struct UnknownMessage: Sendable, Equatable {
    public var type: String?
    public var subtype: String?
    public var raw: JSONValue
}

enum WireTimestamp {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
