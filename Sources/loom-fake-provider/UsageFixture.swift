import Darwin
import Foundation

// Development/test fixture: answers the Claude CLI's headless `get_usage` control request
// (`claude -p --input-format stream-json ...`) the way the real CLI does, without a model or a
// network. `LOOM_FAKE_USAGE` picks the behavior, the other variables its numbers:
//   ok (default)  one answer with both windows, plus fields Loom must ignore
//   partial       only the weekly window
//   unavailable   rate_limits_available false
//   error         a control_response with an error subtype
//   garbage       noise, unrelated lines and another request's answer, then the real answer
//   stubborn      answers, then ignores the closed input (the caller must terminate it)
//   hang          never answers and never exits (the caller must time out and terminate it)
//   exit          exits non-zero without answering
//   no-account    as ok, but `initialize` is read and never answered
// An `initialize` before the `get_usage` is answered with an account (the real CLI names it there; the log records
// `initialized`).
// LOOM_FAKE_USAGE_FIVE / _WEEK are the used percent, LOOM_FAKE_USAGE_FIVE_RESET / _WEEK_RESET the
// ISO-8601 reset times, LOOM_FAKE_USAGE_LOG a file that receives the arguments, config directory
// and working directory (and, once the request is read, `skipBehaviors` and `scansTranscripts`: whether
// the real CLI would read the transcripts of the last week for this ask), LOOM_FAKE_PIDFILE the
// child's pid.

func runFakeUsageProbe(arguments: [String]) -> Never {
    let environment = ProcessInfo.processInfo.environment
    let mode = environment["LOOM_FAKE_USAGE"] ?? "ok"
    if let path = environment["LOOM_FAKE_PIDFILE"] { try? "\(getpid())".write(toFile: path, atomically: true, encoding: .utf8) }
    var record: [String: Any] = [
        "arguments": arguments, "config": environment["CLAUDE_CONFIG_DIR"] ?? NSNull(),
        "cwd": FileManager.default.currentDirectoryPath,
    ]
    func writeLog() {
        guard let path = environment["LOOM_FAKE_USAGE_LOG"],
              let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? (String(decoding: data, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    writeLog()
    switch mode {
    case "hang":
        sleep(60)
        exit(0)
    case "exit":
        exit(3)
    default:
        break
    }
    // The CLI is asked `initialize` first (it names the account) and `get_usage` after; both are one line each. An `initialize`
    // is answered with the account and the loop reads on for the `get_usage`.
    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
    var usageRequest: [String: Any]?
    while usageRequest == nil, let line = readLine() {
        guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              request["type"] as? String == "control_request", let id = request["request_id"] as? String else { exit(2) }
        switch (request["request"] as? [String: Any])?["subtype"] as? String {
        case "initialize":
            record["initialized"] = true
            writeLog()
            if mode != "no-account" {
                send(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": [
                    "account": ["email": "someone@example.invalid", "organization": "Example", "subscriptionType": "Claude Max",
                                "apiProvider": "firstParty"], "pid": Int(getpid())] as [String: Any]]])
            }
        case "get_usage": usageRequest = request
        default: exit(2)
        }
    }
    guard let request = usageRequest, let id = request["request_id"] as? String else { exit(2) }
    // The real CLI reads every transcript touched in the last seven days (for its behavior statistics)
    // unless the request says `skip_behaviors:true`; the log says whether this one would have.
    let body = request["request"] as? [String: Any]
    record["skipBehaviors"] = body?["skip_behaviors"] as? Bool ?? false
    record["scansTranscripts"] = body?["skip_behaviors"] as? Bool != true
    writeLog()

    func response(_ id: String, subtype: String, payload: [String: Any]) -> [String: Any] {
        let inner: [String: Any] = subtype == "success"
            ? ["subtype": subtype, "request_id": id, "response": payload]
            : ["subtype": subtype, "request_id": id, "error": "get_usage failed"]
        return ["type": "control_response", "response": inner]
    }
    func window(_ percent: String?, _ reset: String?) -> Any {
        guard let percent, let value = Double(percent) else { return NSNull() }
        return ["utilization": value, "resets_at": reset ?? NSNull()] as [String: Any]
    }

    if mode == "garbage" {
        FileHandle.standardOutput.write(Data("this is not json\n{\"type\":\"system\",\"subtype\":\"init\"}\n{broken\n".utf8))
        send(response("some-other-request", subtype: "success", payload: ["rate_limits": ["five_hour": window("99", nil)]]))
    }
    let five = environment["LOOM_FAKE_USAGE_FIVE"] ?? "38"
    let week = environment["LOOM_FAKE_USAGE_WEEK"] ?? "82"
    var limits: [String: Any] = [
        "five_hour": mode == "partial" ? NSNull() : window(five, environment["LOOM_FAKE_USAGE_FIVE_RESET"] ?? "2026-10-08T18:00:00.000Z"),
        "seven_day": window(week, environment["LOOM_FAKE_USAGE_WEEK_RESET"] ?? "2026-10-12T09:00:00Z"),
        "seven_day_opus": window("5", nil),
    ]
    var payload: [String: Any] = [
        "rate_limits_available": mode != "unavailable", "account": ["email": "someone@example.invalid"],
        "spend": ["used_usd": 12.5],
    ]
    if mode == "unavailable" { limits = [:] }
    payload["rate_limits"] = limits
    send(response(id, subtype: mode == "error" ? "error" : "success", payload: payload))

    if mode == "stubborn" { sleep(60); exit(0) }
    while readLine() != nil {} // the real CLI leaves when its input closes
    exit(0)
}
