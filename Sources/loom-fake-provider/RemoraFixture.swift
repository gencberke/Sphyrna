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
// An optional script file, `remora-fixture.json` in $CLAUDE_CONFIG_DIR (the app's evidence runs set it, and Remora's call passes
// it on), is read when no `LOOM_FAKE_REMORA*` variable says the same thing (the variables win):
//   {"answer":"text","mode":"slow","delayMs":200,"chips":["why"],"drafts":["one line"],"facts":["a fact"]}
//   answer   the visible text only: the closing ```remora block is built here, with real session ids from the pack
//   mode     as LOOM_FAKE_REMORA          delayMs  as LOOM_FAKE_REMORA_DELAY_MS
//   chips    one chip per entry (its "why"), on the pack's sessions in the order its index lists them (default one chip)
//   drafts   one draft per entry, likewise (default one draft)        facts   proposed facts (default none)
// The ids come from the `<sessions>` index, which rides in the system-prompt file `--system-prompt-file` names (the request is
// on stdin); a pack with no index gives a block with no chips or drafts.
// The usage numbers are fixed: input 2, cache creation 1,200, cache read 0, output 64, cost $0.0123.

let remoraDefaultAnswer = """
You left off in the loom project, where session s-one waits for your review.

```remora
{"cited":["s-one"],"chips":[{"session":"s-one","why":"Waits for your review"}],"drafts":[{"session":"s-one","text":"Please run the checks again."}],"facts":[]}
```
"""

/// What `remora-fixture.json` in the config directory says; every field is optional and an unreadable file says nothing.
struct RemoraFixtureScript {
    var answer: String?
    var mode: String?
    var delayMs: Int?
    var chips: [String]?
    var drafts: [String]?
    var facts: [String]?

    static let fileName = "remora-fixture.json"

    init?(configDirectory: String?) {
        guard let configDirectory, !configDirectory.isEmpty,
              let data = FileManager.default.contents(atPath: configDirectory + "/" + Self.fileName),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        answer = object["answer"] as? String
        mode = object["mode"] as? String
        delayMs = object["delayMs"] as? Int
        chips = (object["chips"] as? [Any])?.compactMap { $0 as? String }
        drafts = (object["drafts"] as? [Any])?.compactMap { $0 as? String }
        facts = (object["facts"] as? [Any])?.compactMap { $0 as? String }
    }

    /// The session ids of the pack's `<sessions>` index, in the order it lists them: the first block found in the system-prompt
    /// file the arguments name, else in the request on stdin.
    static func sessionIDs(arguments: [String], stdin: Data) -> [String] {
        var sources: [String] = []
        if let flag = arguments.firstIndex(of: "--system-prompt-file"), flag + 1 < arguments.count,
           let text = try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8) { sources.append(text) }
        sources.append(String(decoding: stdin, as: UTF8.self))
        for text in sources {
            guard let start = text.range(of: "<sessions>\n"), let end = text.range(of: "</sessions>", range: start.upperBound..<text.endIndex)
            else { continue }
            let ids = text[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { row -> String? in
                guard row.hasPrefix("- ") else { return nil }
                let id = row.dropFirst(2).prefix(36)
                return UUID(uuidString: String(id)) == nil ? nil : String(id)
            }
            if !ids.isEmpty { return ids }
        }
        return []
    }

    /// The answer's text and its closing block, with ids out of `sessions`.
    func answerText(sessions: [String]) -> String {
        let text = answer ?? "You left off in the loom project, where a session waits for your review."
        if text.contains("```remora") { return text }
        let why = chips ?? ["Waits for your review"]
        let lines = drafts ?? ["Please run the checks again."]
        let block: [String: Any] = [
            "cited": Array(sessions.prefix(max(3, why.count, lines.count))),
            "chips": zip(sessions, why).map { ["session": $0, "why": $1] },
            "drafts": zip(sessions, lines).map { ["session": $0, "text": $1] },
            "facts": facts ?? [],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return text + "\n\n```remora\n" + json + "\n```"
    }
}

func runFakeRemora(arguments: [String]) -> Never {
    let environment = ProcessInfo.processInfo.environment
    let script = RemoraFixtureScript(configDirectory: environment["CLAUDE_CONFIG_DIR"])
    let mode = environment["LOOM_FAKE_REMORA"] ?? script?.mode ?? "ok"
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
    let answer: String
    if let fixed = environment["LOOM_FAKE_REMORA_ANSWER"] {
        answer = fixed
    } else if let script {
        answer = script.answerText(sessions: RemoraFixtureScript.sessionIDs(arguments: arguments, stdin: pack))
    } else {
        answer = remoraDefaultAnswer
    }
    let delay = max(mode == "slow" ? 400 : 0, Int(environment["LOOM_FAKE_REMORA_DELAY_MS"] ?? "") ?? script?.delayMs ?? 5)
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
