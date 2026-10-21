import Darwin
import Foundation

// Development/test fixture: Remora's one-shot call (`claude -p --output-format stream-json --verbose
// --include-partial-messages ...` with the pack on stdin and no `--input-format`; spike S10). It reads the pack to
// EOF, then streams a scripted answer without a model or a network: an init, a thinking block, the answer's text in
// small deltas, the assistant message and a result with usage. Scripted by the environment:
//   LOOM_FAKE_REMORA          ok (default)   the answer, then a successful result
//                             error          the CLI's API error: is_error true, terminal_reason api_error
//                             refusal        the classifier refusal of S10: stop_reason refusal, is_error true with
//                                            subtype "success", tokens billed and no output
//                             login          "Not logged in": assistant error authentication_failed
//                             silent         an init, then nothing and no exit (the caller must time out)
//                             slow           the answer, a delay between deltas of at least 400 ms
//                             crash          an init, then exit 3 without a result
//                             flood          endless text deltas (the caller must stop at its output bound)
//   LOOM_FAKE_REMORA_ANSWER   the answer text, block included (default: a short answer ending in a valid block)
//   LOOM_FAKE_REMORA_DELAY_MS pause between text deltas (default 5)
//   LOOM_FAKE_REMORA_LOG      a file that receives one JSON object: the arguments, the pack's length in bytes, the
//                             working directory, the environment's key names (never values) and the pid
//   LOOM_FAKE_REMORA_MODEL    the model id in `system/init` (default claude-sonnet-5-5)
//   LOOM_FAKE_PIDFILE         receives the pid, as for the other modes
// The usage numbers are fixed: input 2, cache creation 1,200, cache read 0, output 64, cost $0.0123.

let remoraDefaultAnswer = """
You left off in the loom project, where session s-one waits for your review.

```remora
{"cited":["s-one"],"chips":[{"session":"s-one","why":"Waits for your review"}],"drafts":[{"session":"s-one","text":"Please run the checks again."}],"facts":[]}
```
"""

func runFakeRemora(arguments: [String]) -> Never {
    let environment = ProcessInfo.processInfo.environment
    let mode = environment["LOOM_FAKE_REMORA"] ?? "ok"
    if let path = environment["LOOM_FAKE_PIDFILE"] { try? "\(getpid())".write(toFile: path, atomically: true, encoding: .utf8) }
    let pack = FileHandle.standardInput.readDataToEndOfFile()
    if let path = environment["LOOM_FAKE_REMORA_LOG"] {
        let record: [String: Any] = [
            "arguments": arguments, "packBytes": pack.count, "cwd": FileManager.default.currentDirectoryPath,
            "environmentKeys": environment.keys.sorted(), "pid": getpid(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? (String(decoding: data, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    let model = environment["LOOM_FAKE_REMORA_MODEL"] ?? "claude-sonnet-5-5"
    let wire = ChatWire(session: UUID().uuidString.lowercased(), model: model)
    let answer = environment["LOOM_FAKE_REMORA_ANSWER"] ?? remoraDefaultAnswer
    let delay = max(mode == "slow" ? 400 : 0, Int(environment["LOOM_FAKE_REMORA_DELAY_MS"] ?? "") ?? 5)
    let began = Date()

    func send(_ object: ChatWire.Object) { FileHandle.standardOutput.write(ChatWire.line(object)) }
    func pause(_ milliseconds: Int) { if milliseconds > 0 { usleep(UInt32(milliseconds) * 1_000) } }
    func event(_ inner: ChatWire.Object, _ messageID: String) -> ChatWire.Object {
        wire.streamEvent(inner, parent: nil, apiMessageID: messageID)
    }

    send(wire.initMessage(permissionMode: "auto", cwd: FileManager.default.currentDirectoryPath, tools: [],
                          slashCommands: [], skills: [], capabilities: [], effort: "low"))
    switch mode {
    case "silent":
        sleep(60)
        exit(0)
    case "crash":
        exit(3)
    default:
        break
    }

    let messageID = "msg_" + UUID().uuidString.prefix(8).lowercased()
    send(event(wire.messageStart(id: messageID), messageID))
    func failureResult(text: String, billed: Bool, terminal: String = "api_error") {
        var object = wire.result(
            subtype: "success", isError: true, text: text, durationMs: 40, stopReason: nil, terminalReason: terminal,
            apiErrorStatus: nil, cost: billed ? 0.0123 : 0, outputTokens: 0, denials: [], errors: [], userUUIDs: [], queued: 0)
        object["usage"] = ["input_tokens": billed ? 4 : 0, "cache_creation_input_tokens": billed ? 2_400 : 0,
                           "cache_read_input_tokens": 0, "output_tokens": 0]
        send(object)
        exit(1)
    }
    switch mode {
    case "login":
        send(wire.apiErrorAssistant(text: "Not logged in · Please run /login", category: "authentication_failed", status: nil))
        failureResult(text: "Not logged in · Please run /login", billed: false)
    case "error":
        send(wire.apiErrorAssistant(text: "API Error: the fake provider failed on request", category: "unknown", status: 500))
        failureResult(text: "API Error: the fake provider failed on request", billed: false)
    case "refusal":
        send(event(wire.messageDelta(stopReason: "refusal", outputTokens: 0), messageID))
        send(event(wire.messageStop(), messageID))
        failureResult(text: "API Error: the fake provider can't help with this", billed: true)
    default:
        break
    }

    send(event(wire.blockStart(index: 0, block: ["type": "thinking", "thinking": "", "signature": ""]), messageID))
    send(event(wire.blockDelta(index: 0, delta: ["type": "thinking_delta", "thinking": "Reading the pack."]), messageID))
    send(event(wire.blockStop(index: 0), messageID))
    send(event(wire.blockStart(index: 1, block: ["type": "text", "text": ""]), messageID))
    if mode == "flood" {
        let line = String(repeating: "x", count: 4_000)
        while true { send(event(wire.blockDelta(index: 1, delta: ["type": "text_delta", "text": line]), messageID)) }
    }
    // Small deltas, so the caller's fence stripping sees the block arrive in pieces.
    var rest = Substring(answer)
    while !rest.isEmpty {
        let piece = rest.prefix(7)
        rest = rest.dropFirst(piece.count)
        send(event(wire.blockDelta(index: 1, delta: ["type": "text_delta", "text": String(piece)]), messageID))
        pause(delay)
    }
    send(event(wire.blockStop(index: 1), messageID))
    send(event(wire.messageDelta(stopReason: "end_turn", outputTokens: 64), messageID))
    send(event(wire.messageStop(), messageID))
    send(wire.assistant(messageID: messageID, block: ["type": "text", "text": answer], stopReason: "end_turn",
                        outputTokens: 64, parent: nil))
    var result = wire.result(
        subtype: "success", isError: false, text: answer, durationMs: Int(Date().timeIntervalSince(began) * 1_000),
        stopReason: "end_turn", terminalReason: "completed", apiErrorStatus: nil, cost: 0.0123, outputTokens: 64,
        denials: [], errors: [], userUUIDs: [], queued: 0)
    result["usage"] = ["input_tokens": 2, "cache_creation_input_tokens": 1_200, "cache_read_input_tokens": 0,
                       "output_tokens": 64]
    send(result)
    exit(0)
}
