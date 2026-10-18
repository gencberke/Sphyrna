import AppKit
import Foundation
import LoomChat
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// Hand-written transcript lines in the shapes Claude Code writes, and a window the stream is laid out in.
/// Strings are made with `JSONValue` so a fixture cannot have a typo in its quoting.
enum ChatFixture {
    static func line(_ value: JSONValue) -> String { value.serializedString }

    static func time(_ second: Int) -> String {
        String(format: "2026-10-17T10:%02d:%02d.000Z", second / 60, second % 60)
    }

    static func user(_ text: String, uuid: String, at second: Int = 0) -> String {
        line(["type": "user", "uuid": .string(uuid), "sessionId": "s1", "timestamp": .string(time(second)), "isSidechain": false,
              "message": ["role": "user", "content": .string(text)]])
    }

    static func assistant(_ message: String, uuid: String, blocks: [JSONValue], at second: Int = 0) -> String {
        line(["type": "assistant", "uuid": .string(uuid), "sessionId": "s1", "timestamp": .string(time(second)), "isSidechain": false,
              "message": ["id": .string(message), "role": "assistant", "model": "claude-opus-5-5", "content": .array(blocks)]])
    }

    static func text(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }
    static func thinking(_ text: String) -> JSONValue { ["type": "thinking", "thinking": .string(text), "signature": "sig"] }
    static func tool(_ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
        ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
    }

    static func result(_ id: String, _ text: String, isError: Bool = false, at second: Int = 0, structured: JSONValue? = nil) -> String {
        var fields: [String: JSONValue] = [
            "type": "user", "uuid": .string("r-" + id), "sessionId": "s1", "timestamp": .string(time(second)), "isSidechain": false,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": .string(text),
                                                    "is_error": .bool(isError)]]],
        ]
        if let structured { fields["toolUseResult"] = structured }
        return line(.object(fields))
    }

    /// The model of lines that start `firstOffset` bytes into the file (a lens that read only the newest turns).
    static func model(_ lines: [String], firstOffset: UInt64 = 0) -> TurnModel {
        var model = TurnModel(source: .sessionTranscript)
        var offset = firstOffset
        for line in lines {
            let bytes = Data(line.utf8)
            model.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
            offset += UInt64(bytes.count + 1)
        }
        return model
    }

    /// A turn with tools and an answer: a prompt, thinking, `tools` calls with results, the answer.
    static func turn(_ index: Int, tools: [(name: String, input: JSONValue, output: String)] = [],
                     answer: String = "Done.", thought: String? = nil, start: Int = 0) -> [String] {
        var lines = [user("prompt \(index)", uuid: "u\(index)", at: start)]
        var second = start + 1
        if let thought {
            lines.append(assistant("m\(index)t", uuid: "t\(index)", blocks: [thinking(thought)], at: second))
            second += 1
        }
        for (position, call) in tools.enumerated() {
            let id = "toolu_\(index)_\(position)"
            lines.append(assistant("m\(index)c\(position)", uuid: "c\(index)-\(position)", blocks: [tool(id, call.name, call.input)], at: second))
            lines.append(result(id, call.output, at: second + 1))
            second += 2
        }
        lines.append(assistant("m\(index)a", uuid: "a\(index)", blocks: [text(answer)], at: second))
        return lines
    }
}

/// A stream hosted in a window that is never ordered front (nothing appears on screen).
@MainActor
struct ChatHostedStream {
    let controller: ChatStreamController
    let window: NSWindow

    init(width: CGFloat = 900, height: CGFloat = 700, context: ChatRowContext = ChatRowContext()) {
        controller = ChatStreamController(context: context)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        controller.scrollView.frame = window.contentView!.bounds
        controller.scrollView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(controller.scrollView)
        window.contentView!.layoutSubtreeIfNeeded()
    }

    /// Lets the run loop and the layout settle, so rows are drawn and heights measured.
    func settle(_ rounds: Int = 6) async {
        for _ in 0..<rounds {
            controller.scrollView.layoutSubtreeIfNeeded()
            controller.table.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    var visibleOffset: CGFloat { controller.scrollView.contentView.bounds.origin.y }

    func scroll(to y: CGFloat) {
        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    }
}

extension ChatFixture {
    static func bash(_ command: String, output: String = "ok") -> (name: String, input: JSONValue, output: String) {
        ("Bash", ["command": .string(command)], output)
    }

    static func read(_ path: String) -> (name: String, input: JSONValue, output: String) {
        ("Read", ["file_path": .string(path)], "1\tline")
    }

    static func rows(_ lines: [String], mode: ChatViewMode = .normal, isWorking: Bool = false, toggled: Set<String> = [],
                     hasOlder: Bool = false, workingDirectory: String? = nil, firstOffset: UInt64 = 0) -> [ChatRow] {
        ChatRowBuilder.rows(ChatBuildInput(model: model(lines, firstOffset: firstOffset), mode: mode, toggled: toggled, isWorking: isWorking, hasOlder: hasOlder,
                                           workingDirectory: workingDirectory))
    }

    /// The tool calls of a transcript, in order.
    static func calls(_ lines: [String]) -> [ToolCall] {
        model(lines).entries.compactMap { entry in
            if case let .tool(call) = entry.body { call } else { nil }
        }
    }
}

extension ChatFixture {
    /// The bytes the lines take in a file (each followed by a newline).
    static func size(of lines: [String]) -> UInt64 { lines.reduce(0) { $0 + UInt64($1.utf8.count + 1) } }
}

/// The suites that host views or follow files share `ChatRenderProbe` and the session memory, so they run one at a time
/// (a nested suite takes its parent's `.serialized`).
@Suite(.serialized, .timeLimit(.minutes(5)))
enum ChatHosted {}

extension ChatFixture {
    /// A live-source model whose first turn has a message you sent while Claude worked, and then ended: your prompt, a
    /// tool, your second message (it joined the running turn), the answer.
    static func settledTurnWithAMidTurnMessage() -> TurnModel {
        func message(_ value: JSONValue) -> StreamMessage { try! StreamMessage(line: Data(line(value).utf8)) }
        var model = TurnModel(source: .live)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        model.appendPendingUser(uuid: "u1", text: "refactor the parser", at: start)
        _ = model.apply(message(["type": "assistant", "uuid": "a1", "session_id": "s1", "parent_tool_use_id": .null,
                                 "message": ["id": "m1", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": .null,
                                             "content": [tool("t1", "Bash", ["command": "swift build"])]]]), at: start)
        _ = model.apply(message(["type": "user", "uuid": "r-t1", "session_id": "s1", "parent_tool_use_id": .null,
                                 "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1",
                                                                           "content": "ok", "is_error": false]]]]), at: start)
        model.appendPendingUser(uuid: "u2", text: "also keep the old API", at: start.addingTimeInterval(3))
        _ = model.apply(message(["type": "assistant", "uuid": "a2", "session_id": "s1", "parent_tool_use_id": .null,
                                 "message": ["id": "m2", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": .null,
                                             "content": [text("Done, and the old API stays.")]]]), at: start.addingTimeInterval(4))
        _ = model.apply(message(["type": "result", "subtype": "success", "is_error": false, "result": "done", "duration_ms": 5000,
                                 "num_turns": 2, "session_id": "s1", "terminal_reason": "completed", "total_cost_usd": 0.1,
                                 "usage": ["input_tokens": 1, "output_tokens": 1]]), at: start.addingTimeInterval(5))
        return model
    }
}
