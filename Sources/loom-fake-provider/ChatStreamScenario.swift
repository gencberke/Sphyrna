import Foundation

// `/scenario stream <seconds> <characters per second>`: the resource-measurement stream (Release B evaluation, step 4).
// One turn that streams Markdown text deltas at a fixed rate for a fixed time, with a short tool call every few seconds,
// and ends with a normal `result`.
//   - The rate is clock-driven (a tick every 20 ms sends what is due since the start), so it holds whatever one tick costs.
//     It counts the characters of text deltas only; a tool call's own time is caught up by the next tick.
//   - The text is a fixed-seed sequence of blocks (paragraphs, a heading, a list, a fenced code block now and then). The
//     sequence and the tool calls' place in it depend on the arguments only, never on timing. The text is ASCII, so a
//     character is a byte.
//   - Every few seconds' worth of characters the message ends at a block boundary with a tool call (a Read or a Bash with
//     a short result), and the next message goes on with the text. An interrupt lands within one tick; the text sent so
//     far then becomes an `aborted` message, as for any streamed answer.

/// A deterministic Markdown source: `take` hands out the next characters of an endless sequence of blocks.
struct StreamText {
    private var state: UInt64
    private var bytes: [UInt8] = []
    private var offset = 0
    private var first = true

    init(seed: UInt64) { state = seed }

    /// The block now being handed out has been handed out in full.
    var atBoundary: Bool { offset >= bytes.count }

    /// A new message starts with the next block (no blank line before it).
    mutating func beginMessage() { first = true }

    /// Up to `count` characters of the current block (never across a block).
    mutating func take(_ count: Int) -> String {
        if atBoundary { refill() }
        let end = min(bytes.count, offset + max(1, count))
        defer { offset = end }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }

    private mutating func random() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private mutating func pick(_ count: Int) -> Int { Int(random() % UInt64(count)) }
    private mutating func word(_ list: [String]) -> String { list[pick(list.count)] }

    private static let words = [
        "the", "session", "stream", "coordinator", "buffer", "request", "should", "keep", "every", "update", "before",
        "after", "layout", "row", "cache", "state", "token", "message", "queue", "cancel", "retry", "window", "render",
        "frame", "model", "driver", "path", "file", "result", "check", "small", "stable", "shared", "pending", "visible",
        "hidden", "across", "within", "because", "while", "then", "once", "never", "always", "reads", "writes", "wraps",
        "holds", "drops", "moves", "emits", "applies", "returns", "needs", "keeps", "avoids", "limits", "tracks",
    ]
    private static let names = [
        "SyncCoordinator", "retryCount", "ChatRowStore", "flushPending()", "Package.swift", "makeSnapshot()",
        "Sources/Sync", "maxBatch", "LiveFeed", "applyDelta(_:)", "README.md", "tick()",
    ]
    private static let headings = ["What changed", "Why it fails", "Next steps", "The shared state", "Checking the fix", "Notes"]
    private static let languages = ["swift", "python", "json", "bash"]
    private static let codeLines = [
        "let value = compute(index, limit: 64)", "guard let next = queue.first else { return }",
        "for item in pending where item.isReady {", "    results.append(item.run())", "}",
        "if retries > limit { throw SyncError.exhausted }", "state.flush(into: &buffer)",
        "return buffer.count - offset", "await coordinator.apply(delta)", "defer { lock.unlock() }",
        "let total = rows.reduce(0) { $0 + $1.height }", "cache[key] = rendered", "// keep the newest page only",
    ]

    private mutating func sentence() -> String {
        let count = 7 + pick(10)
        var parts: [String] = []
        for index in 0..<count {
            switch pick(14) {
            case 0: parts.append("`" + word(Self.names) + "`")
            case 1: parts.append("**" + word(Self.words) + "**")
            default: parts.append(word(Self.words))
            }
            if index == 0 { parts[0] = parts[0].prefix(1).uppercased() + String(parts[0].dropFirst()) }
        }
        return parts.joined(separator: " ") + "."
    }

    private mutating func paragraph() -> String {
        (0..<(2 + pick(3))).map { _ in sentence() }.joined(separator: " ")
    }

    private mutating func block() -> String {
        switch pick(10) {
        case 0:
            return "## " + word(Self.headings)
        case 1:
            return (0..<(3 + pick(3))).map { _ in "- " + sentence() }.joined(separator: "\n")
        case 2, 3:
            let lines = (0..<(5 + pick(8))).map { _ in Self.codeLines[pick(Self.codeLines.count)] }
            return "```" + word(Self.languages) + "\n" + lines.joined(separator: "\n") + "\n```"
        default:
            return paragraph()
        }
    }

    private mutating func refill() {
        let text = (first ? "" : "\n\n") + block()
        first = false
        bytes = Array(text.utf8)
        offset = 0
    }
}

extension ChatEngine {
    /// Characters per tick: 50 ticks a second, so 600 characters/s is 12 per delta and 6,000 is 120.
    private static let streamTickMs = 20

    func streamScenario(_ args: [String]) throws {
        let seconds = max(0.1, args.first.flatMap(Double.init) ?? 10)
        let rate = max(1, args.dropFirst().first.flatMap(Int.init) ?? 600)
        let total = max(1, Int((seconds * Double(rate)).rounded()))
        var text = StreamText(seed: 0x4C6F_6F6D_5374_7265)
        var sent = 0
        var calls = 0
        var nextToolAt = Self.toolSpacing(rate: rate, calls: calls)
        let start = Date()
        while sent < total {
            // One API message: a text block streamed at the rate, then (unless the time is up) a tool call.
            let messageID = "msg_fake" + UUID().uuidString.lowercased().prefix(8)
            func stream(_ event: ChatObject) {
                if config.partial { send(wire.streamEvent(event, parent: nil, apiMessageID: messageID)) }
            }
            stream(wire.messageStart(id: messageID))
            stream(wire.blockStart(index: 0, block: ["type": "text", "text": ""]))
            text.beginMessage()
            var message = ""
            do {
                while sent < total {
                    let due = min(total, Int(Date().timeIntervalSince(start) * Double(rate)))
                    while sent < due, !(sent >= nextToolAt && text.atBoundary && !message.isEmpty) {
                        let piece = text.take(due - sent)
                        message += piece
                        sent += piece.count
                        stream(wire.blockDelta(index: 0, delta: ["type": "text_delta", "text": piece]))
                    }
                    if sent >= nextToolAt, text.atBoundary, !message.isEmpty { break }
                    try pause(Self.streamTickMs)
                }
                if sent >= total, message.components(separatedBy: "```").count % 2 == 0 {
                    // The time ended inside a code fence: close it so the message is whole Markdown.
                    let closing = "\n```"
                    message += closing
                    sent += closing.count
                    stream(wire.blockDelta(index: 0, delta: ["type": "text_delta", "text": closing]))
                }
            } catch {
                if !message.isEmpty {
                    finalText = message
                    var aborted = ChatObject()
                    aborted["aborted"] = true
                    emitMessage(wire.assistant(
                        messageID: messageID, block: ["type": "text", "text": message], stopReason: nil,
                        outputTokens: max(1, message.count / 4), parent: nil, extra: aborted))
                }
                throw error
            }
            stream(wire.blockStop(index: 0))
            finalText = message
            let tokens = max(1, message.count / 4)
            outputTokens += tokens
            let wantsTool = sent < total
            emitMessage(wire.assistant(
                messageID: messageID, block: ["type": "text", "text": message], stopReason: wantsTool ? nil : "end_turn",
                outputTokens: tokens, parent: nil))
            guard wantsTool else {
                stream(wire.messageDelta(stopReason: "end_turn", outputTokens: outputTokens))
                stream(wire.messageStop())
                sendRateLimit()
                break
            }
            try streamToolCall(messageID: messageID, number: calls, stream: stream)
            calls += 1
            nextToolAt = sent + Self.toolSpacing(rate: rate, calls: calls)
        }
    }

    /// Three to five seconds of text between two tool calls, by the number of the call (so, by characters, not by time).
    private static func toolSpacing(rate: Int, calls: Int) -> Int {
        rate * (3 + calls % 3)
    }

    /// The message's second block: a short tool call (a Read or a Bash), its result, and the boundary.
    private func streamToolCall(messageID: String, number: Int, stream: (ChatObject) -> Void) throws {
        let id = nextToolID()
        let name: String
        let input: ChatObject
        let content: String
        let structured: Any
        if number % 2 == 0 {
            name = "Read"
            let path = "/tmp/fake-project/Sources/Module\(number % 5)/File\(number).swift"
            input = ["file_path": path]
            content = "     1\timport Foundation\n     2\tstruct Item\(number) {}\n"
            structured = ["type": "text", "file": ["filePath": path, "content": "import Foundation\nstruct Item\(number) {}\n",
                                                     "numLines": 2, "startLine": 1, "totalLines": 2]] as ChatObject
        } else {
            name = "Bash"
            input = ["command": "ls -1 Sources/Module\(number % 5)", "description": "List the module"]
            content = "File\(number - 1).swift\nFile\(number).swift"
            structured = Self.bash(stdout: content)
        }
        stream(wire.blockStart(index: 1, block: ["type": "tool_use", "id": id, "name": name, "input": [:] as ChatObject]))
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        for piece in chunks(json, size: max(1, json.count / 3 + 1)) {
            stream(wire.blockDelta(index: 1, delta: ["type": "input_json_delta", "partial_json": piece]))
            try pause(config.delayMs)
        }
        stream(wire.blockStop(index: 1))
        outputTokens += max(1, json.count / 4)
        emitMessage(wire.assistant(
            messageID: messageID, block: ["type": "tool_use", "id": id, "name": name, "input": input], stopReason: "tool_use",
            outputTokens: max(1, json.count / 4), parent: nil))
        stream(wire.messageDelta(stopReason: "tool_use", outputTokens: outputTokens))
        stream(wire.messageStop())
        sendRateLimit()
        if case let .refuse(reasonType, message) = gate(tool: name, input: input) {
            refuseCall(id: id, tool: name, input: input, reasonType: reasonType, message: message)
            try toolBoundary()
            return
        }
        try runTool(id, name: name, description: input["description"] as? String ?? name, milliseconds: 15)
        toolResult(id, content, structured: structured)
        try toolBoundary()
    }
}
