import Foundation
import LoomCore

// Control requests and responses of the stream-json channel, in both directions. Envelopes (from the protocol brief):
//   request   {"type":"control_request","request_id":"…","request":{"subtype":"…",…}}
//   success   {"type":"control_response","response":{"subtype":"success","request_id":"…","response":{…}}}
//   error     {"type":"control_response","response":{"subtype":"error","request_id":"…","error":"…"}}
//   cancel    {"type":"control_cancel_request","request_id":"…"}   (either side; no reply)

// MARK: Permissions

public struct PermissionMode: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let `default` = PermissionMode(rawValue: "default")
    public static let acceptEdits = PermissionMode(rawValue: "acceptEdits")
    /// Needs `--allow-dangerously-skip-permissions` at launch.
    public static let bypassPermissions = PermissionMode(rawValue: "bypassPermissions")
    public static let plan = PermissionMode(rawValue: "plan")
    public static let dontAsk = PermissionMode(rawValue: "dontAsk")
    public static let auto = PermissionMode(rawValue: "auto")
}

/// One `PermissionUpdate` of the SDK: `addRules`, `replaceRules`, `removeRules`, `setMode`, `addDirectories` or
/// `removeDirectories`, with a `destination` (`userSettings`, `projectSettings`, `localSettings`, `session`,
/// `cliArg`). Kept as the wire fields so an update Loom does not know survives a round trip.
public struct PermissionUpdate: Sendable, Equatable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) { self.fields = fields }

    public var type: String? { fields["type"]?.string }

    public var destination: String? {
        get { fields["destination"]?.string }
        set { fields["destination"] = newValue.map(JSONValue.string) }
    }

    /// `setMode` with the destination `session`.
    public static func setMode(_ mode: PermissionMode, destination: String = "session") -> PermissionUpdate {
        PermissionUpdate(fields: ["type": "setMode", "mode": .string(mode.rawValue), "destination": .string(destination)])
    }

    /// `addRules` allowing a tool (optionally one rule content), for `destination`.
    public static func allowRule(toolName: String, ruleContent: String? = nil, destination: String = "session") -> PermissionUpdate {
        var rule: [String: JSONValue] = ["toolName": .string(toolName)]
        if let ruleContent { rule["ruleContent"] = .string(ruleContent) }
        return PermissionUpdate(fields: ["type": "addRules", "rules": .array([.object(rule)]), "behavior": "allow",
                                         "destination": .string(destination)])
    }

    var json: JSONValue { .object(fields) }
}

/// `can_use_tool`: Claude asks to run a tool.
public struct ToolPermissionRequest: Sendable, Equatable {
    public var toolName: String
    public var input: JSONValue
    public var toolUseID: String?
    public var permissionSuggestions: [PermissionUpdate]
    public var blockedPath: String?
    /// Plain text ("This command requires approval"); sometimes absent.
    public var decisionReason: String?
    public var decisionReasonType: String?
    public var title: String?
    public var displayName: String?
    /// Claude's own words about the call; present on every Bash request.
    public var description: String?
    public var mcpServerName: String?
    /// The subagent that asked (absent on main-thread requests). It equals the `task_id` of that subagent's
    /// `system/task_started`, which carries its `subagent_type` and `description`: the request has no name of its own.
    public var agentID: String?
    public var requiresUserInteraction: Bool?

    init?(json: JSONValue) {
        guard let toolName = json["tool_name"]?.string else { return nil }
        self.toolName = toolName
        input = json["input"] ?? .object([:])
        toolUseID = json["tool_use_id"]?.string
        permissionSuggestions = (json["permission_suggestions"]?.array ?? []).compactMap {
            $0.object.map(PermissionUpdate.init(fields:))
        }
        blockedPath = json["blocked_path"]?.string
        decisionReason = json["decision_reason"]?.string
        decisionReasonType = json["decision_reason_type"]?.string
        title = json["title"]?.string
        displayName = json["display_name"]?.string
        description = json["description"]?.string
        mcpServerName = json["mcp_server"]?["name"]?.string
        agentID = json["agent_id"]?.string
        requiresUserInteraction = json["requires_user_interaction"]?.bool
    }
}

/// The host's answer to a `can_use_tool` request.
public enum PermissionDecision: Sendable, Equatable {
    /// `updatedInput` set to the original input allows it as asked; a question's answers go in it.
    case allow(updatedInput: JSONValue, updatedPermissions: [PermissionUpdate] = [], toolUseID: String? = nil)
    case deny(message: String, interrupt: Bool = false)

    var payload: JSONValue {
        switch self {
        case let .allow(updatedInput, updatedPermissions, toolUseID):
            var fields: [String: JSONValue] = ["behavior": "allow", "updatedInput": updatedInput]
            if !updatedPermissions.isEmpty { fields["updatedPermissions"] = .array(updatedPermissions.map(\.json)) }
            if let toolUseID { fields["toolUseID"] = .string(toolUseID) }
            return .object(fields)
        case let .deny(message, interrupt):
            return .object(["behavior": "deny", "message": .string(message), "interrupt": .bool(interrupt)])
        }
    }
}

// MARK: CLI to host

/// A control request the CLI sends to the host.
public struct IncomingControlRequest: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case canUseTool(ToolPermissionRequest)
        /// Any other subtype (`request_user_dialog`, `elicitation`, `hook_callback`, `mcp_message`, …), whole.
        case other(subtype: String?, payload: JSONValue)
    }

    public var requestID: String
    public var kind: Kind

    init?(json: JSONValue) {
        guard let requestID = json["request_id"]?.string else { return nil }
        self.requestID = requestID
        let request = json["request"] ?? .null
        if request["subtype"]?.string == "can_use_tool", let permission = ToolPermissionRequest(json: request) {
            kind = .canUseTool(permission)
        } else {
            kind = .other(subtype: request["subtype"]?.string, payload: request)
        }
    }
}

/// A control response from the CLI, to a request the host sent.
public struct ControlResponse: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case success(JSONValue)
        case error(String)
    }

    public var requestID: String
    public var outcome: Outcome

    init?(json: JSONValue) {
        let response = json["response"] ?? .null
        guard let requestID = response["request_id"]?.string else { return nil }
        self.requestID = requestID
        if response["subtype"]?.string == "error" {
            outcome = .error(response["error"]?.string ?? "error")
        } else {
            // The account's e-mail, organisation and plan ride on `initialize` and `get_usage` answers; nothing downstream
            // needs them, so no response keeps them, whoever asked and whenever it arrives.
            var payload = response["response"] ?? .object([:])
            if var fields = payload.object, fields.removeValue(forKey: "account") != nil { payload = .object(fields) }
            outcome = .success(payload)
        }
    }
}

// MARK: Host to CLI

public enum ContextDetail: String, Sendable {
    case summary
    case full
}

/// The `settings` object of `apply_flag_settings`; a `null` value clears a key.
public struct FlagSettings: Sendable, Equatable {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue]) { self.values = values }

    /// `low`, `medium`, `high`, `xhigh` or `max` (`max` lasts for the session only); nil clears it.
    public static func effortLevel(_ level: String?) -> FlagSettings {
        FlagSettings(["effortLevel": level.map(JSONValue.string) ?? .null])
    }

    public static func model(_ model: String?) -> FlagSettings {
        FlagSettings(["model": model.map(JSONValue.string) ?? .null])
    }
}

/// A control request the host sends to the CLI.
public enum OutgoingControlRequest: Sendable, Equatable {
    /// With `cancelQueued`, messages the CLI has queued but not read are cancelled and listed in the reply.
    case interrupt(cancelQueued: Bool)
    case setPermissionMode(PermissionMode)
    /// Nil resets to the default model.
    case setModel(String?)
    case applyFlagSettings(FlagSettings)
    case getContextUsage(ContextDetail)
    case getUsage(skipBehaviors: Bool)
    /// The first request Loom sends. Its answer is the Ready signal (`system/init` only comes after the first send).
    case initialize
    /// Unsends one message the CLI holds unread (`{cancelled: true}`; `false` for an unknown uuid).
    case cancelAsyncMessage(messageUUID: String)
    /// Moves running Bash and subagents to the background (the Ctrl+B equivalent); answers `{}`.
    case backgroundTasks(toolUseID: String?)
    /// Needs `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` and `--replay-user-messages`; the id is the `uuid` of a
    /// message Loom sent.
    case rewindFiles(userMessageID: String, dryRun: Bool)
    /// Answers `{rewound, targetMessageUuid, prefillText, precedingAssistantUuid}`.
    case rewindConversation(targetMessageUUID: String)
    /// A question answered from the conversation without a turn: no transcript record, no `result`.
    case sideQuestion(String)
    /// Any other subtype (`initialize`, `rewind_files`, `mcp_status`, `stop_task`, …) with its fields.
    case other(subtype: String, fields: [String: JSONValue])

    public var subtype: String {
        switch self {
        case .interrupt: "interrupt"
        case .setPermissionMode: "set_permission_mode"
        case .setModel: "set_model"
        case .applyFlagSettings: "apply_flag_settings"
        case .getContextUsage: "get_context_usage"
        case .getUsage: "get_usage"
        case .initialize: "initialize"
        case .cancelAsyncMessage: "cancel_async_message"
        case .backgroundTasks: "background_tasks"
        case .rewindFiles: "rewind_files"
        case .rewindConversation: "rewind_conversation"
        case .sideQuestion: "side_question"
        case let .other(subtype, _): subtype
        }
    }

    /// The `system/init` capability the request needs, if any. A CLI whose `init` lists capabilities without it cannot
    /// do what the request means, and is not asked.
    public var requiredCapability: String? {
        if case .interrupt(cancelQueued: true) = self { return "interrupt_cancel_queued_v1" }
        return nil
    }

    var fields: [String: JSONValue] {
        switch self {
        case let .interrupt(cancelQueued): cancelQueued ? ["cancel_queued": true] : [:]
        case let .setPermissionMode(mode): ["mode": .string(mode.rawValue)]
        case let .setModel(model): ["model": model.map(JSONValue.string) ?? .null]
        case let .applyFlagSettings(settings): ["settings": .object(settings.values)]
        case let .getContextUsage(detail): ["detail": .string(detail.rawValue)]
        case let .getUsage(skip): skip ? ["skip_behaviors": true] : [:]
        case .initialize: [:]
        case let .cancelAsyncMessage(uuid): ["message_uuid": .string(uuid)]
        case let .backgroundTasks(id): id.map { ["tool_use_id": .string($0)] } ?? [:]
        case let .rewindFiles(id, dryRun): ["user_message_id": .string(id), "dry_run": .bool(dryRun)]
        case let .rewindConversation(id): ["target_message_uuid": .string(id)]
        case let .sideQuestion(question): ["question": .string(question)]
        case let .other(_, fields): fields
        }
    }
}

/// The reply to an interrupt: `{still_queued:[uuid], cancelled?:[uuid]}`, which arrives before the interrupted turn's
/// `result`.
public struct InterruptReceipt: Sendable, Equatable {
    public var stillQueued: [String]
    public var cancelled: [String]

    public init(json: JSONValue) {
        stillQueued = (json["still_queued"]?.array ?? []).compactMap(\.string)
        cancelled = (json["cancelled"]?.array ?? []).compactMap(\.string)
    }
}

public struct ModelOption: Sendable, Equatable {
    /// The alias or id to pass to `set_model` (`default`, `opus`, `sonnet`, …).
    public var value: String
    public var resolvedModel: String?
    public var displayName: String?
    public var supportedEffortLevels: [String]
}

public struct CommandInfo: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var argumentHint: String?
}

/// The answer to `initialize`: Ready. It carries what the picker menus need before any turn. The reply holds the
/// account's e-mail, organisation and plan: this type reads none of them, and `ControlResponse` removes `account` from the
/// payload, so nothing here is fit to log or keep.
public struct InitializeResponse: Sendable, Equatable {
    public var currentPermissionMode: String?
    /// `idle` before the first turn.
    public var sessionState: String?
    public var claudeCodeVersion: String?
    public var pid: Int?
    public var fastModeState: String?
    public var outputStyle: String?
    /// The styles the CLI found (`plugin:Name` for a plugin's). Nil when the answer does not say.
    public var availableOutputStyles: [String]?
    public var models: [ModelOption]
    public var commands: [CommandInfo]
    /// Only `ui_surface_v1` on 2.1.300; gate on the capabilities of `system/init` instead.
    public var capabilities: [String]

    public init(json: JSONValue) {
        currentPermissionMode = json["current_permission_mode"]?.string
        sessionState = json["session_state"]?.string
        claudeCodeVersion = json["claude_code_version"]?.string
        pid = json["pid"]?.int
        fastModeState = json["fast_mode_state"]?.string
        outputStyle = json["output_style"]?.string
        availableOutputStyles = json["available_output_styles"]?.array.map { $0.compactMap(\.string) }
        capabilities = (json["capabilities"]?.array ?? []).compactMap(\.string)
        models = (json["models"]?.array ?? []).compactMap { model in
            model["value"]?.string.map {
                ModelOption(value: $0, resolvedModel: model["resolvedModel"]?.string, displayName: model["displayName"]?.string,
                            supportedEffortLevels: (model["supportedEffortLevels"]?.array ?? []).compactMap(\.string))
            }
        }
        commands = (json["commands"]?.array ?? []).compactMap { command in
            command["name"]?.string.map {
                CommandInfo(name: $0, description: command["description"]?.string, argumentHint: command["argumentHint"]?.string)
            }
        }
    }
}

/// The wire lines of the control channel (each ends with a newline).
public enum ControlWire {
    public static func requestLine(id: String, _ request: OutgoingControlRequest) -> Data {
        var inner = request.fields
        inner["subtype"] = .string(request.subtype)
        return line(["type": "control_request", "request_id": .string(id), "request": .object(inner)])
    }

    public static func successLine(id: String, _ payload: JSONValue) -> Data {
        line(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": payload]])
    }

    public static func errorLine(id: String, _ message: String) -> Data {
        line(["type": "control_response", "response": ["subtype": "error", "request_id": .string(id), "error": .string(message)]])
    }

    public static func cancelLine(id: String) -> Data {
        line(["type": "control_cancel_request", "request_id": .string(id)])
    }

    static func line(_ value: JSONValue) -> Data {
        var data = value.serialized()
        data.append(0x0A)
        return data
    }
}
