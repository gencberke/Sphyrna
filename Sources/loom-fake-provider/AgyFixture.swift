import Darwin
import Foundation

/// AGY-shaped fixture only. Hooks execute the shipped helper as a real owned
/// child; no provider executable, profile or model is touched.
func runFakeAgy(arguments: [String], stateDirectory: URL?) -> Never {
    func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    func append(_ text: String, to name: String) {
        guard let url = stateDirectory?.appendingPathComponent(name) else { return }
        let prior = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (prior + text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    guard let root = value("--add-dir"), let helper = ProcessInfo.processInfo.environment["SPHYRNA_CLI"],
          let home = ProcessInfo.processInfo.environment["HOME"] else { fail("agy missing fixture setup") }
    let discovery = URL(fileURLWithPath: root)
    guard let data = try? Data(contentsOf: discovery.appendingPathComponent(".agents/hooks.json")),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: [[String: Any]]]],
          let hooks = object["sphyrna-owned-channel"], hooks["SessionStart"] != nil else {
        fail("agy discovery unavailable")
    }
    if let encoded = try? JSONSerialization.data(withJSONObject: arguments), let text = String(data: encoded, encoding: .utf8) {
        append(text, to: "agy-arguments.log")
    }
    let resumed = value("--conversation")
    guard resumed == nil || UUID(uuidString: resumed!) != nil else { fail("agy invalid conversation") }
    let id = (resumed ?? UUID().uuidString).lowercased()
    let cwd = FileManager.default.currentDirectoryPath
    let nativeRoot = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity-cli/brain/\(id)")
    let model = value("--model") ?? "fake-agy"
    func hook(_ event: String, fields: [String: Any] = [:]) {
        guard let command = hooks[event]?.first?["command"] as? String,
              command.hasSuffix(" agy-hook \(event)") else { fail("agy hook missing") }
        var object: [String: Any] = ["conversationId": id, "workspacePaths": [cwd, root],
            "transcriptPath": nativeRoot.appendingPathComponent(".system_generated/logs/transcript.jsonl").path,
            "artifactDirectoryPath": nativeRoot.path, "modelName": model]
        object.merge(fields) { _, new in new }
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { fail("agy hook payload") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["agy-hook", event]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { fail("agy helper start") }
        input.fileHandleForWriting.write(payload)
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        let expected = event == "PreToolUse" ? #"{"decision":"allow"}"# : event == "Stop" ? #"{"decision":""}"# : "{}"
        guard process.terminationStatus == 0, String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
            fail("agy hook decision")
        }
    }
    func turn(_ text: String) {
        append(text, to: "agy-inputs.log")
        hook("PreInvocation", fields: ["invocationNum": 0, "initialNumSteps": 0])
        out("FAKE-AGY INPUT \(text)\r\n")
        hook("Stop", fields: ["executionNum": 0, "terminationReason": "model_stop", "fullyIdle": true])
    }
    hook("SessionStart")
    if let resumed { out("FAKE-AGY RESUMED \(resumed.lowercased())\r\n") }
    else { out("FAKE-AGY STARTED \(id)\r\n") }
    if let prompt = value("-i") { turn(prompt) }
    if ProcessInfo.processInfo.environment["LOOM_FAKE_AGY_CHILD"] == "1",
       let childPath = ProcessInfo.processInfo.environment["LOOM_FAKE_AGY_CHILD_EXECUTABLE"] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: childPath)
        process.arguments = ["escape-exit"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            // The escaped child inherits this pipe. Read the parent's one
            // bounded record before waiting for exit or descendant EOF.
            var ready = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = poll(&ready, 1, 3_000) > 0
                ? bytes.withUnsafeMutableBytes { Darwin.read(ready.fd, $0.baseAddress, $0.count) } : -1
            let data = count > 0 ? Data(bytes.prefix(count)) : Data()
            try? output.fileHandleForReading.close()
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let pid = json["descendantPID"] as? Int {
                append(String(pid), to: "agy-child-pids.log")
                out("FAKE-AGY CHILD-RECORDED\r\n")
            } else { out("FAKE-AGY CHILD-OUTPUT-INVALID\r\n") }
        } else { out("FAKE-AGY CHILD-SPAWN-FAILED\r\n") }
    }
    out("> ")
    while let line = readLine() {
        if line == "/fake-active" {
            hook("PreInvocation", fields: ["invocationNum": 1, "initialNumSteps": 1])
        } else if line == "/fake-tool" {
            hook("PreToolUse", fields: ["toolCall": ["name": "run_command", "args": [:]], "stepIdx": 1])
            out("FAKE-AGY TOOL-POLICY-PENDING\r\n")
        } else if line == "/fake-background" {
            hook("Stop", fields: ["executionNum": 1, "terminationReason": "model_stop", "fullyIdle": false])
        } else if line == "/fake-error" {
            hook("Stop", fields: ["executionNum": 1, "terminationReason": "error", "fullyIdle": true])
        } else if line == "/fake-foreign-id" {
            let foreign = UUID().uuidString.lowercased()
            let foreignRoot = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity-cli/brain/\(foreign)")
            hook("SessionStart", fields: ["conversationId": foreign, "artifactDirectoryPath": foreignRoot.path,
                 "transcriptPath": foreignRoot.appendingPathComponent(".system_generated/logs/transcript.jsonl").path])
            out("FAKE-AGY FOREIGN-ID SENT\r\n")
        } else if line == "/fake-wrong-cwd" {
            hook("PreInvocation", fields: ["workspacePaths": ["/private/tmp/wrong", root],
                                          "invocationNum": 2, "initialNumSteps": 1])
            out("FAKE-AGY WRONG-CWD SENT\r\n")
        } else if line == "/fake-wrong-profile" {
            hook("PreInvocation", fields: ["transcriptPath": "/private/tmp/wrong/transcript.jsonl",
                                          "invocationNum": 2, "initialNumSteps": 1])
            out("FAKE-AGY WRONG-PROFILE SENT\r\n")
        } else { turn(line) }
        out("> ")
    }
    exit(0)
}
