import Foundation
import LoomCore
@testable import LoomChat

/// Small hand-written records in the shapes of Claude Code's stream-json output and transcripts. Strings are made with
/// `JSONValue` so a fixture cannot have a typo in its quoting.
enum Fixture {
    static func line(_ value: JSONValue) -> String { value.serializedString }

    static func text(_ line: String) -> Data { Data((line + "\n").utf8) }

    static let initMessage = line([
        "type": "system", "subtype": "init", "session_id": "s1", "model": "claude-opus-5-5", "permissionMode": "default",
        "cwd": "/tmp/work", "tools": ["Bash", "Read"], "slash_commands": ["compact", "review"], "skills": ["deploy"],
        "capabilities": ["interrupt_receipt_v1", "interrupt_cancel_queued_v1"],
        "mcp_servers": [["name": "linear", "status": "connected"]],
    ])

    static func echo(_ text: String, uuid: String) -> String {
        line(["type": "user", "uuid": .string(uuid), "session_id": "s1", "isReplay": true,
              "message": ["role": "user", "content": .string(text)]])
    }

    static func assistant(messageID: String, uuid: String, blocks: [JSONValue], parent: String? = nil, usage: JSONValue? = nil) -> String {
        var message: [String: JSONValue] = ["id": .string(messageID), "role": "assistant", "model": "claude-opus-5-5",
                                            "content": .array(blocks), "stop_reason": nil]
        if let usage { message["usage"] = usage }
        return line(["type": "assistant", "uuid": .string(uuid), "session_id": "s1",
                     "parent_tool_use_id": parent.map(JSONValue.string) ?? .null, "message": .object(message)])
    }

    static func textBlock(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }
    static func thinkingBlock(_ text: String) -> JSONValue { ["type": "thinking", "thinking": .string(text), "signature": "sig"] }
    static func toolUse(_ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
        ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
    }

    static func toolResult(id: String, text: String, isError: Bool = false, structured: JSONValue? = nil, parent: String? = nil) -> String {
        var fields: [String: JSONValue] = [
            "type": "user", "uuid": .string("r-" + id), "session_id": "s1",
            "parent_tool_use_id": parent.map(JSONValue.string) ?? .null,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": .string(text),
                                                    "is_error": .bool(isError)]]],
        ]
        if let structured { fields["tool_use_result"] = structured }
        return line(.object(fields))
    }

    static func result(_ subtype: String = "success", isError: Bool = false, durationMs: Double = 4200,
                       terminalReason: String = "completed") -> String {
        line(["type": "result", "subtype": .string(subtype), "is_error": .bool(isError), "result": "done",
              "duration_ms": .number(durationMs), "num_turns": 2, "session_id": "s1", "terminal_reason": .string(terminalReason),
              "total_cost_usd": 0.12, "usage": ["input_tokens": 10, "output_tokens": 20]])
    }

    static func partial(_ event: JSONValue, parent: String? = nil) -> String {
        line(["type": "stream_event", "event": event, "session_id": "s1", "parent_tool_use_id": parent.map(JSONValue.string) ?? .null])
    }

    static func message(_ line: String) -> StreamMessage {
        try! StreamMessage(line: Data(line.utf8))
    }

    // Transcript lines (the shape of the session JSONL).

    static func transcriptUser(_ text: String, uuid: String, time: String = "2026-10-17T10:00:00.000Z", extra: [String: JSONValue] = [:]) -> String {
        var fields: [String: JSONValue] = ["type": "user", "uuid": .string(uuid), "sessionId": "s1", "timestamp": .string(time),
                                           "parentUuid": nil, "isSidechain": false,
                                           "message": ["role": "user", "content": .string(text)]]
        for (key, value) in extra { fields[key] = value }
        return line(.object(fields))
    }

    static func transcriptAssistant(messageID: String, uuid: String, blocks: [JSONValue], time: String = "2026-10-17T10:00:05.000Z") -> String {
        line(["type": "assistant", "uuid": .string(uuid), "sessionId": "s1", "timestamp": .string(time), "isSidechain": false,
              "message": ["id": .string(messageID), "role": "assistant", "model": "claude-opus-5-5", "content": .array(blocks)]])
    }

    static func transcriptToolResult(id: String, text: String, time: String = "2026-10-17T10:00:06.000Z", structured: JSONValue? = nil) -> String {
        var fields: [String: JSONValue] = [
            "type": "user", "uuid": .string("r-" + id), "sessionId": "s1", "timestamp": .string(time), "isSidechain": false,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": .string(text)]]],
        ]
        if let structured { fields["toolUseResult"] = structured }
        return line(.object(fields))
    }
}

extension TurnModel {
    /// The entries of one kind, for assertions.
    var texts: [AssistantText] { entries.compactMap { if case let .assistantText(text) = $0.body { text } else { nil } } }
    var thoughts: [Thinking] { entries.compactMap { if case let .thinking(thinking) = $0.body { thinking } else { nil } } }
    var tools: [ToolCall] { entries.compactMap { if case let .tool(call) = $0.body { call } else { nil } } }
    var prompts: [UserPrompt] { entries.compactMap { if case let .user(prompt) = $0.body { prompt } else { nil } } }
    var raws: [RawRecord] { entries.compactMap { if case let .unknown(raw) = $0.body { raw } else { nil } } }
    var markers: [Marker] { entries.compactMap { if case let .marker(marker) = $0.body { marker } else { nil } } }
}
