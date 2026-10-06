import Darwin
import Foundation
import LoomCore

/// Checkpoint driver only. Scripted input is explicit; trust/approval prompts are never answered implicitly.
@MainActor
final class ProviderExperiment {
    let root: URL
    let directory: URL
    let supervisor: ProbeSupervisor
    let terminalEnvironment: [String: String]
    var terminals: [String: ProbeTerminal] = [:]
    var logs: [String: FileHandle] = [:]
    var queryBuffers: [String: String] = [:]
    var clients: [String: ProbeRPCClient] = [:]
    var messages: [String: [[String: Any]]] = [:]
    var variables: [String: String] = [:]
    var hookServer: ClaudeHookServer?
    let hookRecorder: HookRecorder
    let hookAuthenticationToken = UUID().uuidString
    let hookDirectory: URL
    var sequence = 0
    var samples: [[String: Any]] = []
    let baseline: [ProcessRecord]
    let externalBaseline: [ProcessRecord]
    var stopped = false

    init(root: URL, label: String) throws {
        self.root = root
        let ledger = OwnershipLedger()
        directory = root.appendingPathComponent("runs/\(ledger.runID.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        hookDirectory = URL(
            fileURLWithPath: "/tmp/lh-\(ledger.runID.uuidString.prefix(8))",
            isDirectory: true
        )
        hookRecorder = HookRecorder(outputURL: directory.appendingPathComponent("claude-hooks.jsonl"))
        supervisor = try ProbeSupervisor(ledger: ledger, ledgerURL: directory.appendingPathComponent("ledger.json"))
        // Recovery metadata must exist before rc can start any background helpers.
        guard let owner = try ProcessTable.snapshot().first(where: { $0.identity.pid == getpid() }) else {
            throw LoomError.message("Probe identity unavailable")
        }
        try Probe.encoder.encode(owner.identity).write(to: directory.appendingPathComponent("owner.json"))
        do { terminalEnvironment = try Probe.resolveTerminalEnvironment(supervisor: supervisor).environment }
        catch { _ = supervisor.shutdown(); throw error }
        baseline = try ProcessTable.snapshot()
        externalBaseline = baseline.filter { record in
            guard ProcessTable.runID(pid: record.identity.pid) == nil,
                  let executable = ProcessTable.executablePath(pid: record.identity.pid) else { return false }
            return executable.contains("ChatGPT.app") || URL(fileURLWithPath: executable).lastPathComponent == "codex" || URL(fileURLWithPath: executable).lastPathComponent == "claude"
        }
        try Probe.encoder.encode(externalBaseline).write(to: directory.appendingPathComponent("external-before.json"))
        try label.write(to: directory.appendingPathComponent("label.txt"), atomically: true, encoding: .utf8)
        let probe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        variables["probe"] = probe.path
        variables["fixture"] = probe.deletingLastPathComponent().appendingPathComponent("loom-test-child").path
        variables["hookHelper"] = probe.deletingLastPathComponent().appendingPathComponent("loom-hook").path
        variables["hookSocket"] = hookDirectory.appendingPathComponent("events.sock").path
        variables["run"] = directory.path
        variables["workspace"] = root.appendingPathComponent("workspace").path
        // Darwin sockaddr_un paths cannot use the long run directory.
        variables["socket"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".loom-dev/\(ledger.runID.uuidString.prefix(8)).sock").path
        print("RUN \(label) \(directory.path)"); fflush(stdout)
    }

    func run(script: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: script, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("script.json"))
        do {
            guard let actions = script["actions"] as? [[String: Any]] else { throw LoomError.message("Experiment needs actions") }
            for action in actions { try perform(action) }
            if !stopped { try finish() }
        } catch {
            try? String(describing: error).write(to: directory.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
            if !stopped { try? finish() }
            throw error
        }
    }

    func expand(_ value: String) -> String {
        variables.reduce(value) { $0.replacingOccurrences(of: "${\($1.key)}", with: $1.value) }
    }

    func perform(_ action: [String: Any]) throws {
        guard let op = action["op"] as? String else { throw LoomError.message("Missing experiment op") }
        let slot = action["slot"] as? String ?? "main"
        switch op {
        case "launch": try launch(action, slot: slot)
        case "fixture":
            guard terminals[slot] == nil else { throw LoomError.message("Duplicate fixture slot") }
            let environment = LaunchEnvironment.make(base: terminalEnvironment, runID: supervisor.ownershipRunID, sessionID: UUID())
            terminals[slot] = try supervisor.launch(executable: variables["fixture"]!, arguments: [action["mode"] as? String ?? "escape"], environment: environment, directory: root.appendingPathComponent("workspace").path)
            let url = directory.appendingPathComponent("\(slot)-terminal.txt")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logs[slot] = try FileHandle(forWritingTo: url)
        case "wait": try pump(seconds: action["seconds"] as? Double ?? 1)
        case "control":
            let file = directory.appendingPathComponent("control.jsonl")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let deadline = Date().addingTimeInterval(min(300, action["seconds"] as? Double ?? 120))
            var consumed = 0
            while Date() < deadline && !stopped {
                let text = try String(contentsOf: file, encoding: .utf8)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                let complete = text.hasSuffix("\n") ? lines.count : max(0, lines.count - 1)
                while consumed < complete && !stopped {
                    guard let command = try JSONSerialization.jsonObject(with: Data(lines[consumed].utf8)) as? [String: Any] else { throw LoomError.message("Invalid control command") }
                    consumed += 1
                    try perform(command)
                }
                if !stopped { try pump(seconds: 0.05) }
            }
        case "write":
            guard let terminal = terminals[slot], let value = action["text"] as? String else { throw LoomError.message("write needs terminal and text") }
            try write(Data(expand(value).utf8), to: terminal)
        case "resize":
            guard let terminal = terminals[slot] else { throw LoomError.message("Missing terminal") }
            try terminal.resize(rows: UInt16(action["rows"] as? Int ?? 32), columns: UInt16(action["columns"] as? Int ?? 100))
        case "snapshot": try snapshot(label: action["label"] as? String ?? "snapshot")
        case "hook-expect": try expectHooks(action, slot: slot)
        case "rpc-connect":
            let client = try ProbeRPCClient(socketPath: expand(action["socket"] as? String ?? "${socket}"))
            clients[slot] = client; messages[slot] = []
            _ = try request(slot: slot, method: "initialize", params: ["clientInfo": ["name": "loom_probe", "version": "0.1"], "capabilities": ["experimentalApi": true]])
            try client.send(["method": "initialized", "params": [:]])
        case "rpc-request":
            guard let method = action["method"] as? String else { throw LoomError.message("Missing RPC method") }
            let params = try expandedJSON(action["params"] ?? [:])
            let result = try request(slot: slot, method: method, params: params)
            if let thread = (result["thread"] as? [String: Any])?["id"] as? String { variables["thread"] = thread }
            if let save = action["save"] as? String {
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(save + ".json"))
            }
        case "rpc-send":
            guard let client = clients[slot], let object = try expandedJSON(action["message"] ?? [:]) as? [String: Any] else { throw LoomError.message("Missing RPC client/message") }
            try client.send(object)
        case "signal":
            guard let terminal = terminals[slot], let record = try ProcessTable.snapshot().first(where: { $0.identity.pid == terminal.pid }) else { throw LoomError.message("Missing signal target") }
            try ProcessTable.signal(record.identity, Int32(action["signal"] as? Int ?? Int(SIGHUP)))
        case "quit": try finish()
        case "crash":
            try snapshot(label: "before-crash")
            print("CRASH \(directory.path)"); fflush(stdout)
            kill(getpid(), SIGKILL)
        default: throw LoomError.message("Unknown experiment op \(op)")
        }
    }

    func expandedJSON(_ value: Any) throws -> Any {
        if let text = value as? String { return expand(text) }
        if let values = value as? [Any] { return try values.map(expandedJSON) }
        if let values = value as? [String: Any] { return try values.mapValues(expandedJSON) }
        return value
    }

    func launch(_ action: [String: Any], slot: String) throws {
        guard terminals[slot] == nil else { throw LoomError.message("Duplicate terminal slot") }
        let provider = action["provider"] as? String ?? "codex"
        let sessionID = UUID()
        let base = LaunchEnvironment.make(base: terminalEnvironment, runID: supervisor.ownershipRunID, sessionID: sessionID)
        var isolated = base
        isolated["CODEX_HOME"] = root.appendingPathComponent("codex-home").resolvingSymlinksInPath().path
        isolated["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("claude-config").path
        let version = try Probe.capture(provider, ["--version"], environment: isolated)
        let help = try Probe.capture(provider, ["--help"], environment: isolated)
        let serverHelp = provider == "codex" ? try Probe.capture(provider, ["app-server", "--help"], environment: isolated) : ""
        let features = provider == "codex" ? try Probe.capture(provider, ["features", "list"], environment: isolated) : ""
        let capabilities = ProviderCapabilities(version: version, help: help, serverHelp: serverHelp, features: features)
        let profile: ProviderLaunchProfile
        if provider == "codex" {
            let route: ProviderLaunchProfile.CodexRoute
            switch action["route"] as? String ?? "direct" {
            case "baseline": route = .baseline
            case "disable-auto-start": route = .disableAutoStart
            case "server": route = .server(socket: variables["socket"]!)
            case "remote":
                let explicit = (action["threadID"] as? String).map(expand)
                route = .remote(
                    socket: variables["socket"]!,
                    threadID: explicit ?? variables["thread"],
                    workingDirectory: root.appendingPathComponent("workspace").path
                )
            case "direct": route = .direct
            default: throw LoomError.message("Unknown Codex route")
            }
            profile = try .codex(route: route, capabilities: capabilities, home: URL(fileURLWithPath: isolated["CODEX_HOME"]!), environment: base)
        } else if provider == "claude" {
            var hooks: ClaudeHookLaunchConfiguration?
            if action["hooks"] as? Bool == true {
                if hookServer == nil {
                    hookServer = try ClaudeHookServer(
                        socketPath: variables["hookSocket"]!,
                        authenticationToken: hookAuthenticationToken,
                        handler: hookRecorder.receive
                    )
                }
                hooks = ClaudeHookLaunchConfiguration(
                    helperPath: variables["hookHelper"]!,
                    socketPath: variables["hookSocket"]!,
                    authenticationToken: hookAuthenticationToken
                )
            }
            if let resumeSessionID = (action["resumeSessionID"] as? String).map(expand) {
                profile = try .claude(
                    route: .resume(resumeSessionID), capabilities: capabilities,
                    config: root.appendingPathComponent("claude-config"),
                    environment: base, hooks: hooks
                )
            } else {
                profile = try .claude(
                    capabilities: capabilities,
                    config: root.appendingPathComponent("claude-config"),
                    sessionID: sessionID, environment: base, hooks: hooks
                )
            }
        } else { throw LoomError.message("Unknown provider") }
        var environment = profile.environment
        if action["agentView"] as? Bool == true { environment.removeValue(forKey: "CLAUDE_CODE_DISABLE_AGENT_VIEW") }
        let arguments = profile.arguments + ((action["arguments"] as? [String]) ?? []).map(expand)
        let executable = try resolve(provider)
        let child = try supervisor.launch(executable: executable, arguments: arguments, environment: environment,
            directory: root.appendingPathComponent("workspace").path,
            provider: provider == "codex" ? .codex : .claude, rows: 40, columns: 120)
        terminals[slot] = child
        let logURL = directory.appendingPathComponent("\(slot)-terminal.txt")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logs[slot] = try FileHandle(forWritingTo: logURL)
        let metadata: [String: Any] = ["provider": provider, "version": version, "pid": child.pid, "sessionID": sessionID.uuidString,
            "arguments": arguments, "executable": executable, "profile": provider == "codex" ? environment["CODEX_HOME"]! : environment["CLAUDE_CONFIG_DIR"]!]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("\(slot)-launch.json"))
    }

    func resolve(_ program: String) throws -> String {
        for entry in (terminalEnvironment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent(program).path
            if access(candidate, X_OK) == 0 { return candidate }
        }
        throw LoomError.message("Executable not found: \(program)")
    }

    func write(_ data: Data, to terminal: ProbeTerminal) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(3)
        while offset < data.count {
            offset += try terminal.write(data.subdata(in: offset..<data.count))
            if Date() > deadline { throw LoomError.message("PTY input stalled") }
            if offset < data.count { usleep(1_000) }
        }
    }

    func expectHooks(_ action: [String: Any], slot: String) throws {
        guard let terminal = terminals[slot],
              let required = action["events"] as? [String], !required.isEmpty else {
            throw LoomError.message("hook-expect needs a terminal and event names")
        }
        let deadline = Date().addingTimeInterval(min(30, action["seconds"] as? Double ?? 5))
        var observed: Set<String> = []
        repeat {
            try pump(seconds: 0.02)
            observed = hookRecorder.eventNames(runID: terminal.managedRunID)
            if Set(required).isSubset(of: observed) { return }
        } while Date() < deadline
        throw LoomError.message(
            "Missing Claude hook events \(Set(required).subtracting(observed).sorted()); observed \(observed.sorted())"
        )
    }

    func pump(seconds: Double) throws {
        guard seconds >= 0, seconds <= 120 else { throw LoomError.message("Invalid wait duration") }
        let deadline = Date().addingTimeInterval(seconds)
        var nextSample = Date.distantPast
        repeat {
            for (slot, terminal) in terminals {
                let output = terminal.readAvailable()
                if !output.isEmpty {
                    try logs[slot]?.write(contentsOf: output)
                    var queries = (queryBuffers[slot] ?? "") + String(decoding: output, as: UTF8.self)
                    let responses = [("\u{1b}[6n", "\u{1b}[1;1R"), ("\u{1b}[c", "\u{1b}[?1;2c"),
                                     ("\u{1b}[>0c", "\u{1b}[>0;0;0c"), ("\u{1b}[?u", "\u{1b}[?0u"),
                                     ("\u{1b}]10;?\u{7}", "\u{1b}]10;rgb:ffff/ffff/ffff\u{7}"),
                                     ("\u{1b}]11;?\u{7}", "\u{1b}]11;rgb:0000/0000/0000\u{7}")]
                    for (query, response) in responses {
                        while let range = queries.range(of: query) {
                            try write(Data(response.utf8), to: terminal)
                            queries.removeSubrange(range)
                        }
                    }
                    queryBuffers[slot] = String(queries.suffix(32))
                }
            }
            for (slot, client) in clients {
                let batch = try client.drain()
                if !batch.isEmpty {
                    messages[slot, default: []].append(contentsOf: batch)
                    let url = directory.appendingPathComponent("\(slot)-rpc.jsonl")
                    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                    let file = try FileHandle(forWritingTo: url); try file.seekToEnd()
                    for message in batch { try file.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10])) }
                    try file.close()
                }
            }
            if Date() >= nextSample {
                _ = try supervisor.sample()
                nextSample = Date().addingTimeInterval(0.05)
            }
            usleep(5_000)
        } while Date() < deadline
    }

    func request(slot: String, method: String, params: Any) throws -> [String: Any] {
        guard let client = clients[slot] else { throw LoomError.message("Missing RPC connection") }
        sequence += 1; let id = sequence
        try client.send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(20)
        repeat {
            try pump(seconds: 0.02)
            if let message = messages[slot]?.first(where: { $0["id"] as? Int == id && $0["method"] == nil }) {
                if let error = message["error"] { throw LoomError.message("RPC \(method): \(error)") }
                return message["result"] as? [String: Any] ?? [:]
            }
        } while Date() < deadline
        throw LoomError.message("RPC timeout: \(method)")
    }

    func snapshot(label: String) throws {
        let records = try supervisor.sample()
        let encoded = try JSONSerialization.jsonObject(with: Probe.encoder.encode(records)) as! [[String: Any]]
        let evidence: [[String: Any]] = zip(records, encoded).map { record, object in
            var entry = object
            entry["executable"] = ProcessTable.executablePath(pid: record.identity.pid)
            entry["physicalFootprint"] = ProcessTable.physicalFootprint(pid: record.identity.pid)
            entry["marked"] = ProcessTable.runID(pid: record.identity.pid) == supervisor.ownershipRunID.uuidString
            return entry
        }
        let sample: [String: Any] = ["label": label, "processes": evidence, "time": Date().timeIntervalSince1970]
        samples.append(sample)
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("samples.json"), options: .atomic)
        print("SNAPSHOT \(label): \(records.count) owned processes"); fflush(stdout)
    }

    func finish() throws {
        guard !stopped else { return }
        try snapshot(label: "before-quit")
        let report = supervisor.shutdown(graceSeconds: 0.4)
        stopped = true
        // SessionEnd is synchronous, but its socket handler completes on a
        // separate queue after the provider process exits.
        usleep(50_000)
        hookServer?.stop()
        hookServer = nil
        try? FileManager.default.removeItem(at: hookDirectory)
        try Probe.encoder.encode(report).write(to: directory.appendingPathComponent("shutdown.json"))
        let after = try ProcessTable.snapshot()
        let missingExternal = externalBaseline.filter { record in
            !after.contains(where: { $0.identity == record.identity })
        }
        try Probe.encoder.encode(missingExternal).write(to: directory.appendingPathComponent("missing-external.json"))
        for log in logs.values { try log.close() }
        guard report.succeeded else { throw LoomError.message("Shutdown incomplete: \(report.remaining.count) remaining; \(report.errors)") }
        try Data().write(to: directory.appendingPathComponent("completed"))
        print("CLEAN \(report.elapsedSeconds)s \(directory.path)")
    }
}
