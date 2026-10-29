import Darwin
import Foundation

// Development/test fixture: behaves like a provider TUI without any model.
// `--fake-role claude` emits the same hook events the real Claude does, so the
// production runtime can be exercised end to end. Never bundled.

func out(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("loom-fake-provider: \(message)\n".utf8))
    exit(code)
}

/// Fixture-only descendant probe. It records no environment or credential
/// and the helper itself only requests this run's authenticated identity.
func fakeSphyrnaTaskProbe() -> Bool {
    guard let helper = ProcessInfo.processInfo.environment["SPHYRNA_CLI"] else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: helper)
    process.arguments = ["task", "identity"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let ended = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in ended.signal() }
    guard (try? process.run()) != nil else { return false }
    guard ended.wait(timeout: .now() + 4) == .success else {
        process.terminate()
        _ = ended.wait(timeout: .now() + 1)
        return false
    }
    return process.terminationStatus == 0
}

/// Opt-in synthetic task fixture. Helpers run as provider descendants, use
/// the real task socket, and never log their inherited environment.
func fakeSphyrnaTaskCommand(_ arguments: [String], input: String? = nil) -> (Int32, String)? {
    guard ProcessInfo.processInfo.environment["LOOM_FAKE_TASK_ROUNDS"] == "1",
          let helper = ProcessInfo.processInfo.environment["SPHYRNA_CLI"] else { return nil }
    let process = Process(), output = Pipe(), stdin = Pipe()
    process.executableURL = URL(fileURLWithPath: helper)
    process.arguments = arguments
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let ended = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in ended.signal() }
    guard (try? process.run()) != nil else { return nil }
    if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
    try? stdin.fileHandleForWriting.close()
    guard ended.wait(timeout: .now() + 8) == .success else {
        process.terminate()
        _ = ended.wait(timeout: .now() + 1)
        return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard data.count <= 16 * 1024 + 512, let text = String(data: data, encoding: .utf8) else { return nil }
    return (process.terminationStatus, text)
}

func fakeSphyrnaTaskCreate(_ command: String) -> Bool {
    let words = command.split(separator: " ").map(String.init)
    guard words.count == 4, words[0] == "/fake-sphyrna-task-create",
          let task = UUID(uuidString: words[1]), let operation = UUID(uuidString: words[2]),
          ["claude", "codex"].contains(words[3]) else { return false }
    let result = fakeSphyrnaTaskCommand(["task", "create", "--task", task.uuidString.lowercased(),
        "--operation", operation.uuidString.lowercased(), "--name", "Fixture child", "--harness", words[3], "--message", "-"],
        input: "fixture-round-1")
    return result?.0 == 0 && result?.1.contains("pending") == true
}

func fakeSphyrnaTaskRound(_ pointer: String, report: Bool = true) -> Bool {
    guard ProcessInfo.processInfo.environment["LOOM_FAKE_TASK_ROUNDS"] == "1" else { return false }
    let words = pointer.split(separator: " ").map(String.init)
    guard words.count == 16, Array(words.prefix(7)) == ["Sphyrna", "task:", "run", "\"$SPHYRNA_CLI\"", "task", "input", "--task"],
          words[8] == "--round", words[10] == "--operation", words[11].hasSuffix(";"),
          Array(words.suffix(4)) == ["report", "using", "task", "--help."],
          let task = UUID(uuidString: words[7]), let round = UUID(uuidString: words[9]),
          let operation = UUID(uuidString: String(words[11].dropLast())) else { return false }

    let taskID = task.uuidString.lowercased(), roundID = round.uuidString.lowercased()
    guard let received = fakeSphyrnaTaskCommand(["task", "input", "--task", taskID, "--round", roundID,
                                                 "--operation", operation.uuidString.lowercased()]), received.0 == 0 else { return false }
    let message = received.1.trimmingCharacters(in: .whitespacesAndNewlines)
    guard message.hasPrefix("fixture-round-"), message.utf8.count <= 64 else { return false }
    if !report { return true }
    let result = fakeSphyrnaTaskCommand(["task", "report", "--task", taskID, "--round", roundID,
        "--operation", UUID().uuidString.lowercased(), "--kind", "completed", "--message", "-"],
        input: "fixture-result: \(message)")
    return result?.0 == 0
}

nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func takeCodexConfig() -> [String: String] {
    var result: [String: String] = [:]
    while let entry = take("-c") {
        let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
    }
    return result
}

// Hold a real Stop hook's wrapper after delivery, until the test releases it.
// This makes the otherwise brief helper lifetime overlap the idle decision.
if arguments.first == "--hold-stop-hook", arguments.count == 2 {
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: arguments[1])
    let input = Pipe()
    helper.standardInput = input
    try helper.run()
    input.fileHandleForWriting.write(payload)
    try input.fileHandleForWriting.close()
    helper.waitUntilExit()
    let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
    if object?["hook_event_name"] as? String == "Stop",
       let state = ProcessInfo.processInfo.environment["LOOM_FAKE_STATE"] {
        try "\(getpid())".write(toFile: state + "/held-hook-pid", atomically: true, encoding: .utf8)
        while !FileManager.default.fileExists(atPath: state + "/release-hook") { usleep(10_000) }
    }
    exit(helper.terminationStatus)
}

// Capability queries, as the real CLIs answer them (the runtime reads these).
let environmentForQueries = ProcessInfo.processInfo.environment
if arguments == ["--version"] {
    out("fake-provider 1 codex_home=\(environmentForQueries["CODEX_HOME"] ?? "unset") "
        + "claude_config=\(environmentForQueries["CLAUDE_CONFIG_DIR"] ?? "unset")\n")
    exit(0)
}
if arguments == ["--help"] {
    out("--remote <ADDR> --settings <settings> --session-id <id> --fork-session --forward-subagent-text --effort <level> --permission-mode <mode> --model <model>\n")
    exit(0)
}
if arguments == ["app-server", "--help"] {
    out("--listen <URL>\n")
    exit(0)
}
// Helper commands that misbehave, for the probe bounds (LOOM_FAKE_PROBE=...).
if arguments == ["--probe-hold-pipe"] {
    // Leader exits at once; a child keeps stdout/stderr open.
    // Like a shell background job: same process group, inherited pipes.
    var pid: pid_t = 0
    let path = CommandLine.arguments[0]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("--probe-sleep"), nil]
    posix_spawn(&pid, path, nil, nil, argv, environ)
    if let file = environmentForQueries["LOOM_FAKE_PIDFILE"] {
        try? "\(pid)".write(toFile: file, atomically: true, encoding: .utf8)
    }
    exit(0)
}
if arguments == ["--probe-sleep"] { sleep(60); exit(0) }
if arguments == ["--probe-slow"] {
    if let path = environmentForQueries["LOOM_FAKE_PIDFILE"] {
        try? "\(getpid())".write(toFile: path, atomically: true, encoding: .utf8)
    }
    sleep(60)
    exit(0)
}
if arguments == ["--probe-flood"] {
    let chunk = [UInt8](repeating: 0x78, count: 65_536)
    for _ in 0..<160 { FileHandle.standardOutput.write(Data(chunk)) }
    exit(0)
}

// Remora's one-shot call: `-p --output-format stream-json` with the pack on stdin and no `--input-format`. See
// RemoraFixture.swift. Any other run without `--input-format` falls through to the roles below, as before.
if arguments.contains("-p"), !arguments.contains("--input-format"),
   let outputFormat = arguments.firstIndex(of: "--output-format"), outputFormat + 1 < arguments.count,
   arguments[outputFormat + 1] == "stream-json" {
    runFakeRemora(arguments: arguments)
}

// Stream-json mode, as the real CLI gets it. A chat session (`--session-id`/`--resume`, partial messages,
// replayed user messages or a permission host: Loom's Chat face) is the scripted chat engine, see
// ChatEngine.swift. The bare headless request (`-p --input-format stream-json`, the plan-limits ask) is the
// usage probe, see UsageFixture.swift.
if arguments.contains("--input-format"), arguments.contains("stream-json") {
    let chatFlags = ["--session-id", "--resume", "--include-partial-messages", "--replay-user-messages",
                     "--permission-prompt-tool"]
    if chatFlags.contains(where: arguments.contains) { runFakeChat(arguments: arguments) }
    runFakeUsageProbe(arguments: arguments)
}

// The role follows the real command line: `app-server --listen` is the Codex
// server, `--remote` the Codex TUI, `--session-id`/`--resume` Claude.
let explicitRole = take("--fake-role")
let stateDirectory = (take("--fake-state") ?? ProcessInfo.processInfo.environment["LOOM_FAKE_STATE"])
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
let role: String = explicitRole
    ?? (arguments.contains("app-server") ? "codex-server"
        : arguments.contains("--remote") ? "codex-tui" : "claude")

// MARK: Claude role

struct FakeClaude {
    var id: String
    let settings: [String: Any]
    let environment = ProcessInfo.processInfo.environment
    var promptCount = 0
    var currentPrompt: String?
    let registryStartedAt = Date()
    /// Like Claude: `--effort` or `/effort` hold for this process only. Once set, each reply is
    /// recorded in the profile's transcript with its effort, as Claude records it.
    var effort: String?
    /// Keeps the SIGHUP source alive in `LOOM_FAKE_ALT_SCREEN` mode.
    var altHangup: (any DispatchSourceSignal)?

    func registry(_ status: String) {
        guard let config = environment["CLAUDE_CONFIG_DIR"] else { return }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &process, &length, nil, 0) == 0 else { return }
        let birth = process.kp_proc.p_starttime
        let date = Date(timeIntervalSince1970: Double(birth.tv_sec))
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let now = floor(Date().timeIntervalSince1970 * 1_000)
        let directory = URL(fileURLWithPath: config).appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let object: [String: Any] = ["kind": "interactive", "pidDomain": "darwin", "procStart": format.string(from: date),
            "startedAt": floor(registryStartedAt.timeIntervalSince1970 * 1_000), "sessionId": id,
            "cwd": FileManager.default.currentDirectoryPath, "status": status, "statusUpdatedAt": now]
        guard let bytes = try? JSONSerialization.data(withJSONObject: object) else { return }
        let path = directory.appendingPathComponent("\(getpid()).json").path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }


    var helper: String? {
        let hooks = settings["hooks"] as? [String: Any]
        let entry = (hooks?["SessionStart"] as? [[String: Any]])?.first
        return ((entry?["hooks"] as? [[String: Any]])?.first?["command"]) as? String
    }

    func history(for id: String) -> URL? {
        stateDirectory?.appendingPathComponent("claude-\(id).log")
    }

    func lines(for id: String) -> [String] {
        guard let url = history(for: id), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    func recordReply() {
        guard let effort, let config = environment["CLAUDE_CONFIG_DIR"] else { return }
        let folder = String(FileManager.default.currentDirectoryPath.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let directory = URL(fileURLWithPath: config).appendingPathComponent("projects/\(folder)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).jsonl")
        let record: [String: Any] = ["type": "assistant", "sessionId": id, "effort": effort]
        guard var line = try? JSONSerialization.data(withJSONObject: record) else { return }
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line); try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// `/subagent <ms>`: a subagent that works for about `milliseconds`, as the real one does. It starts (the hook),
    /// gets its `meta.json`, appends transcript lines one at a time (the brief, thinking, text, tool calls and
    /// their results, an attachment line, an error) the way Claude's flush does, and stops (the hook). It
    /// writes under `CLAUDE_CONFIG_DIR` only: without one the hooks still run and no file is written.
    func subagent(milliseconds: Int) {
        let agent = "fake" + UUID().uuidString.lowercased().prefix(8)
        let folder = String(FileManager.default.currentDirectoryPath.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let project = environment["CLAUDE_CONFIG_DIR"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("projects/\(folder)", isDirectory: true)
        }
        let parent = project?.appendingPathComponent("\(id).jsonl").path
        let directory = project?.appendingPathComponent("\(id)/subagents", isDirectory: true)
        let transcript = directory?.appendingPathComponent("agent-\(agent).jsonl")
        func append(_ object: [String: Any]) {
            guard let transcript, var line = try? JSONSerialization.data(withJSONObject: object) else { return }
            line.append(UInt8(ascii: "\n"))
            let descriptor = open(transcript.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard descriptor >= 0 else { return }
            line.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
            close(descriptor)
        }
        func assistant(_ block: [String: Any], thinking: Int? = nil) -> [String: Any] {
            var object: [String: Any] = ["type": "assistant", "agentId": agent, "isSidechain": true,
                                         "message": ["role": "assistant", "content": [block]]]
            if let thinking { object["thinkingDurationMs"] = thinking }
            return object
        }
        func result(_ content: Any, error: Bool = false) -> [String: Any] {
            var block: [String: Any] = ["type": "tool_result", "tool_use_id": "toolu_fake", "content": content]
            if error { block["is_error"] = true }
            return ["type": "user", "agentId": agent, "isSidechain": true,
                    "message": ["role": "user", "content": [block]],
                    "toolUseResult": ["stdout": String(repeating: "bulk ", count: 40)]]
        }
        let steps: [[String: Any]] = [
            ["type": "user", "agentId": agent, "isSidechain": true,
             "message": ["role": "user", "content": "Map the fake module and write what you find to notes.md."]],
            ["type": "attachment", "agentId": agent, "attachment": ["type": "skill_listing", "content": "ignored"]],
            assistant(["type": "thinking", "thinking": "", "signature": "fake"], thinking: 1_500),
            assistant(["type": "text", "text": "I'll map the module first, then write the summary."]),
            assistant(["type": "tool_use", "id": "toolu_fake", "name": "Bash",
                       "input": ["command": "rg -n \"class .*Service\" fake-module\nls fake-module", "description": "Find services"]]),
            result([["type": "text", "text": "fake-module/A.swift:3:class AService\nfake-module/B.swift:9:class BService\nA.swift"]]),
            assistant(["type": "tool_use", "id": "toolu_fake", "name": "Read", "input": ["file_path": "fake-module/Missing.swift"]]),
            result("File does not exist.", error: true),
            assistant(["type": "text", "text": "Done. The map is in notes.md."]),
        ]
        hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
        var started: [String: Any] = ["agent_id": agent, "agent_type": "implementer"]
        if let parent { started["transcript_path"] = parent }
        hook("SubagentStart", started)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let meta = #"{"agentType":"implementer","description":"map the fake module","spawnDepth":1,"requestShape":"foreground"}"#
            try? meta.write(to: directory.appendingPathComponent("agent-\(agent).meta.json"), atomically: true, encoding: .utf8)
        }
        let pause = useconds_t(max(0, milliseconds) * 1_000 / steps.count)
        for step in steps {
            append(step)
            usleep(pause)
        }
        var stopped = started
        if let transcript { stopped["agent_transcript_path"] = transcript.path }
        hook("SubagentStop", stopped)
        hook("Stop", ["last_assistant_message": "subagent done"])
    }

    func remember(_ line: String) {
        guard let url = history(for: id) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Sends one hook event through the real helper, like the CLI does.
    func hook(_ event: String, _ fields: [String: Any] = [:]) {
        guard let helper else { return }
        if event == "UserPromptSubmit" { registry("busy") }
        var payload: [String: Any] = [
            "session_id": id, "hook_event_name": event,
            "cwd": FileManager.default.currentDirectoryPath,
        ]
        payload.merge(fields) { _, new in new }
        if event == "UserPromptSubmit", payload["prompt"] == nil, let currentPrompt { payload["prompt"] = currentPrompt }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let process = Process()
        if environment["LOOM_FAKE_HOLD_STOP_HOOK"] == "1" {
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--hold-stop-hook", helper]
        } else {
            process.executableURL = URL(fileURLWithPath: helper)
        }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        if event == "Stop" { registry("idle") }
    }

    /// `LOOM_FAKE_ALT_SCREEN=1`: draws like the user's `"tui": "fullscreen"` Claude, in the alternate screen.
    /// On `/exit` and on SIGHUP (Loom's Stop) it leaves the screen with `?1049l`, which clears it, and then
    /// prints the resume hint to the main buffer, as the real one does. With `clear`, SIGHUP also erases the
    /// alternate screen first (unknown for the real CLI).
    var altScreen: Bool { ["1", "clear"].contains(environment["LOOM_FAKE_ALT_SCREEN"] ?? "") }

    func leaveAltScreen() {
        guard altScreen else { return }
        out("\u{1B}[?1049l")
        out("Resume this session with:\r\nclaude --resume \(id)\r\n")
    }

    mutating func run(resume: Bool, firstMessage: String? = nil) {
        if altScreen {
            out("\u{1B}[?1049h\u{1B}[2J\u{1B}[H")
            out("ALT-SCREEN-DRAWN \(id)\r\n")
            // Stop sends SIGHUP: leave the screen the way the real CLI does, then go.
            signal(SIGHUP, SIG_IGN)
            let hangup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
            let sessionID = id
            let clearsFirst = environment["LOOM_FAKE_ALT_SCREEN"] == "clear"
            hangup.setEventHandler {
                if clearsFirst { out("\u{1B}[2J\u{1B}[H") }
                out("\u{1B}[?1049l")
                out("Resume this session with:\r\nclaude --resume \(sessionID)\r\n")
                exit(0)
            }
            hangup.resume()
            altHangup = hangup
        }
        if resume {
            if id.hasPrefix("missing") {
                out("No conversation found with session ID: \(id)\r\n")
                exit(1)
            }
            out("RESUMED \(id) remembered=\(lines(for: id).count)\r\n")
        }
        registry("idle")
        hook("SessionStart", ["source": resume ? "resume" : "startup"])
        out("FAKE-CLAUDE READY \(id) cwd=\(FileManager.default.currentDirectoryPath) "
            + "profile=\(environment["CLAUDE_CONFIG_DIR"] ?? "default") effort=\(effort ?? "default")\r\n> ")
        if let firstMessage { handle(firstMessage) }
        while let line = readLine() { handle(line) }
    }

    private mutating func handle(_ line: String) {
        currentPrompt = line
        defer { currentPrompt = nil }
        switch line.split(separator: " ").first.map(String.init) ?? "" {
            case "/fake-registry-busy" where environment["LOOM_FAKE_TASK_REGISTRY_CONTROL"] == "1":
                registry("busy")
                out("FAKE-REGISTRY-BUSY\r\n")
            case "/fake-registry-idle" where environment["LOOM_FAKE_TASK_REGISTRY_CONTROL"] == "1":
                registry("idle")
                out("FAKE-REGISTRY-IDLE\r\n")
            case "/fake-sphyrna-task-create" where environment["LOOM_FAKE_TASK_ROUNDS"] == "1":
                hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
                out(fakeSphyrnaTaskCreate(line) ? "FAKE-TASK-CREATE-OK\r\n" : "FAKE-TASK-CREATE-REFUSED\r\n")
                hook("Stop", ["last_assistant_message": "fixture create finished"])
            case "/fake-sphyrna-task-probe":
                hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
                out(fakeSphyrnaTaskProbe() ? "TASK-HELPER-OK\r\n" : "TASK-HELPER-REFUSED\r\n")
                hook("Stop", ["last_assistant_message": "fixture probe finished"])
            case "/exit":
                hook("SessionEnd", ["reason": "prompt_input_exit"])
                if altScreen { leaveAltScreen() } else { out("bye\r\n") }
                exit(0)
            case "/clear":
                id = UUID().uuidString.lowercased()
                out("CLEARED \(id)\r\n")
                registry("idle")
                hook("SessionStart", ["source": "clear"])
            case "/effort":
                effort = line.split(separator: " ").dropFirst().first.map(String.init)
                out("Set effort level to \(effort ?? "default") (this session only)\r\n")
            case "/fail":
                hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
                hook("StopFailure", ["error": "fixture failure"])
            case "/approve":
                registry("busy")
                hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
                registry("waiting")
                hook("PermissionRequest", ["tool_name": "Bash"])
                out("NEEDS-APPROVAL (type y)\r\n")
                let answer = readLine()
                registry("busy")
                // Native manual No has no Stop; metadata alone resolves it.
                if answer != "n" { hook("Stop", ["last_assistant_message": "approved"]) }
                usleep(2_000)
                registry("idle")
            case "/interrupt-work":
                hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
                out("WORKING-UNTIL-INTERRUPT\r\n")
                _ = readLine()
                usleep(2_000)
                registry("idle")
                out("INTERRUPTED-WORK\r\n")
            case "/idle-prompt":
                // A turn, then Claude's own reminder a minute after it (here at once): `Notification` with
                // `notification_type` `idle_prompt`. The session rests at its prompt; it asks for nothing.
                promptCount += 1
                hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
                out("IDLE-PROMPT\r\n")
                hook("Stop", ["last_assistant_message": "done"])
                hook("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])
            case "/work":
                let milliseconds = Int(line.split(separator: " ").last.map(String.init) ?? "") ?? 300
                hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
                out("WORKING \(milliseconds)\r\n")
                usleep(useconds_t(milliseconds) * 1_000)
                hook("Stop", ["last_assistant_message": "worked"])
            case "/stream":
                // `/stream <seconds>`: heavy terminal output (about 1 MiB/s) while the turn is working.
                let seconds = Int(line.split(separator: " ").last.map(String.init) ?? "") ?? 5
                hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
                let text = String(repeating: "stream output line 0123456789 abcdefghijklmnopqrstuvwxyz 0123456789\r\n", count: 220)
                let end = Date().addingTimeInterval(Double(seconds))
                while Date() < end { out(text); usleep(15_000) }
                hook("Stop", ["last_assistant_message": "streamed"])
            case "/subagent":
                let milliseconds = Int(line.split(separator: " ").last.map(String.init) ?? "") ?? 1_500
                out("SUBAGENT \(milliseconds)\r\n")
                subagent(milliseconds: milliseconds)
            case "/background", "/hidden", "/delayed-background", "/delayed-hidden":
                // Exercise both delivery orders of the asynchronous prompt hook.
                // In the delayed case the helper runs only after user work starts.
                let delayed = line.hasPrefix("/delayed-")
                if !delayed { hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"]) }
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                    .deletingLastPathComponent().appendingPathComponent("loom-test-child")
                child.arguments = ["stubborn", "--silent"]
                child.standardOutput = FileHandle.nullDevice
                try? child.run()
                if delayed { hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"]) }
                var stop: [String: Any] = ["last_assistant_message": "started background"]
                if line.hasSuffix("background") { stop["background_tasks"] = [["id": "1"]] }
                hook("Stop", stop)
                out("BACKGROUND \(child.processIdentifier)\r\n")
            default:
                promptCount += 1
                remember(line)
                hook("UserPromptSubmit", ["prompt_id": "p\(promptCount)"])
                if line.hasPrefix("Sphyrna task:") && environment["LOOM_FAKE_TASK_ROUNDS"] == "1" {
                    out(fakeSphyrnaTaskRound(line) ? "FAKE-TASK-ROUND-OK\r\n" : "FAKE-TASK-ROUND-REFUSED\r\n")
                } else { out("echo: \(line)\r\n") }
                recordReply()
                hook("Stop", ["last_assistant_message": "echo \(line)"])
        }
        out("> ")
    }
}

switch role {
case "claude":
    let firstMessage = arguments.firstIndex(of: "--").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    let settingsText = take("--settings") ?? "{}"
    let settings = (try? JSONSerialization.jsonObject(with: Data(settingsText.utf8))) as? [String: Any] ?? [:]
    let effort = take("--effort")
    if let resumeID = take("--resume") {
        var claude = FakeClaude(id: resumeID, settings: settings, effort: effort)
        claude.run(resume: true, firstMessage: firstMessage)
    } else {
        var claude = FakeClaude(id: take("--session-id") ?? UUID().uuidString.lowercased(), settings: settings, effort: effort)
        claude.run(resume: false, firstMessage: firstMessage)
    }
case "codex-server":
    if let stateDirectory, let bytes = try? JSONSerialization.data(withJSONObject: Array(CommandLine.arguments.dropFirst())),
       let line = String(data: bytes, encoding: .utf8) {
        let file = stateDirectory.appendingPathComponent("codex-server-arguments.log")
        let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (previous + line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    guard let listen = take("--listen"), listen.hasPrefix("unix://") else { fail("codex-server needs --listen unix://PATH") }
    runCodexServer(socketPath: String(listen.dropFirst("unix://".count)), config: takeCodexConfig())
case "codex-tui":
    if let stateDirectory, let bytes = try? JSONSerialization.data(withJSONObject: Array(CommandLine.arguments.dropFirst())),
       let line = String(data: bytes, encoding: .utf8) {
        let file = stateDirectory.appendingPathComponent("codex-tui-arguments.log")
        let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (previous + line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    guard let remote = take("--remote"), remote.hasPrefix("unix://") else { fail("codex-tui needs --remote unix://PATH") }
    var resumeID: String?
    if let index = arguments.firstIndex(of: "resume"), index + 1 < arguments.count { resumeID = arguments[index + 1] }
    let directory = take("--cd")
    let model = take("-m")
    let sandbox = take("-s")
    let approval = take("-a")
    let config = takeCodexConfig()
    let rawEffort = config["model_reasoning_effort"]
    let effort = rawEffort.flatMap { $0.hasPrefix("\"") && $0.hasSuffix("\"") ? String($0.dropFirst().dropLast()) : nil }
    let prompt = arguments.firstIndex(of: "--").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    if resumeID != nil && (model != nil || effort != nil || sandbox != nil || approval != nil) {
        fail("Permission overrides are not supported when resuming a remote task.")
    }
    runCodexTUI(socketPath: String(remote.dropFirst("unix://".count)), resumeID: resumeID, workingDirectory: directory,
                model: model, effort: effort, sandbox: sandbox, approval: approval, firstMessage: prompt, config: config)
default:
    fail("unknown role \(role)")
}
