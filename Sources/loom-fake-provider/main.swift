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

nonisolated(unsafe) var arguments = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
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
    out("--remote <ADDR> --settings <settings> --session-id <id> --effort <level>\n")
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

// The headless plan-limits request (`-p --input-format stream-json`), see UsageFixture.swift.
if arguments.contains("--input-format"), arguments.contains("stream-json") {
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
    let registryStartedAt = Date()
    /// Like Claude: `--effort` or `/effort` hold for this process only. Once set, each reply is
    /// recorded in the profile's transcript with its effort, as Claude records it.
    var effort: String?

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

    mutating func run(resume: Bool) {
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
        while let line = readLine() {
            switch line.split(separator: " ").first.map(String.init) ?? "" {
            case "/exit":
                hook("SessionEnd", ["reason": "prompt_input_exit"])
                out("bye\r\n")
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
                out("echo: \(line)\r\n")
                recordReply()
                hook("Stop", ["last_assistant_message": "echo \(line)"])
            }
            out("> ")
        }
    }
}

switch role {
case "claude":
    let settingsText = take("--settings") ?? "{}"
    let settings = (try? JSONSerialization.jsonObject(with: Data(settingsText.utf8))) as? [String: Any] ?? [:]
    let effort = take("--effort")
    if let resumeID = take("--resume") {
        var claude = FakeClaude(id: resumeID, settings: settings, effort: effort)
        claude.run(resume: true)
    } else {
        var claude = FakeClaude(id: take("--session-id") ?? UUID().uuidString.lowercased(), settings: settings, effort: effort)
        claude.run(resume: false)
    }
case "codex-server":
    guard let listen = take("--listen"), listen.hasPrefix("unix://") else { fail("codex-server needs --listen unix://PATH") }
    runCodexServer(socketPath: String(listen.dropFirst("unix://".count)))
case "codex-tui":
    guard let remote = take("--remote"), remote.hasPrefix("unix://") else { fail("codex-tui needs --remote unix://PATH") }
    var resumeID: String?
    if let index = arguments.firstIndex(of: "resume"), index + 1 < arguments.count { resumeID = arguments[index + 1] }
    runCodexTUI(socketPath: String(remote.dropFirst("unix://".count)), resumeID: resumeID, workingDirectory: take("--cd"))
default:
    fail("unknown role \(role)")
}
