import Darwin
import Foundation
import LoomCore

@main
struct Probe {
    @MainActor static func main() {
        do { try run() } catch { fputs("loom-probe: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func run() throws {
        let root = ProcessInfo.processInfo.environment["LOOM_PROBE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Loom-Dev/probe")
        let args = Array(CommandLine.arguments.dropFirst())
        if ["prepare", "capabilities", "synthetic", "crash-fixture", "recover-stale", "experiment", "codex-core-client", "codex-core-resume", "codex-core-recall", "codex-core-active-quit", "codex-two-stop", "claude-core-q1", "idle-metrics"].contains(args.first ?? "") {
            try recoverStaleRuns(root: root)
        }
        if args.first == "recover-stale" { return }
        if args.first == "codex-observers" {
            guard args.count >= 6, args[1] == "--enable-content-free-diagnostics",
                  let seconds = Double(args[5]), seconds.isFinite, seconds > 0, seconds <= 300,
                  args.count <= 7, args.count != 7 || Int(args[6]) != nil else {
                throw LoomError.message("Usage: codex-observers --enable-content-free-diagnostics <socket> <thread-id> <new-output-directory> <seconds:1..300> [capacity:1..4096]")
            }
            try blockingAwait {
                try await codexObservers(socket: args[2], thread: args[3], directory: URL(fileURLWithPath: args[4]),
                                         seconds: seconds, capacity: args.count == 7 ? Int(args[6])! : 256)
            }
            return
        }
        if args.first == "codex-observer-measure", args.count >= 3, ["optout", "none", "bogus", "edges"].contains(args[1]) {
            try blockingAwait {
                try await codexObserverMeasure(root: root, mode: args[1], approval: args.count == 4 && args[3] == "approval",
                                               outputDirectory: URL(fileURLWithPath: args[2]))
            }
            return
        }
        if args.first == "environment", args.count == 2 {
            try environmentExperiment(directory: URL(fileURLWithPath: args[1]))
            return
        }
        if args.first == "experiment", args.count == 2 {
            let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            guard let script = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LoomError.message("Invalid experiment script") }
            let experiment = try ProviderExperiment(root: root, label: script["label"] as? String ?? "provider")
            try experiment.run(script: script)
            return
        }
        if args.first == "codex-core-client" {
            let result = try blockingAwait { try await codexCoreClient(root: root) }
            print(result.path)
            return
        }
        if args.first == "codex-core-resume", args.count == 2 {
            let result = try blockingAwait {
                try await codexCoreResume(root: root, threadID: args[1])
            }
            print(result.path)
            return
        }
        if args.first == "codex-core-recall", args.count == 2 {
            let result = try blockingAwait {
                try await codexCoreResume(
                    root: root, threadID: args[1],
                    prompt: "What exact all-caps token did you reply with in the completed turn before the interrupted command? Reply only with that token. Do not use tools."
                )
            }
            print(result.path)
            return
        }
        if args.first == "codex-core-active-quit", args.count == 2 {
            let result = try blockingAwait {
                try await codexCoreActiveQuit(root: root, threadID: args[1])
            }
            print(result.path)
            return
        }
        if args.first == "codex-two-stop" {
            let result = try blockingAwait { try await codexTwoSessionStop(root: root) }
            print(result.path)
            return
        }
        if args.first == "claude-core-q1" {
            let result = try blockingAwait { try await claudeCoreQ1(root: root) }
            print(result.path)
            return
        }
        if args.first == "idle-metrics" {
            let result = try blockingAwait { try await idleMetrics(root: root) }
            print(result.path)
            return
        }
        if args.first == "prepare" {
            for name in ["claude-config", "workspace", "runs"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let codexHome = root.appendingPathComponent("codex-home")
            if !FileManager.default.fileExists(atPath: codexHome.path) {
                let shortHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".loom-dev/codex-home")
                try FileManager.default.createDirectory(at: shortHome, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.createSymbolicLink(at: codexHome, withDestinationURL: shortHome)
            }
            let workspace = root.appendingPathComponent("workspace")
            if !FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path) {
                let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                git.arguments = ["init", "--quiet", workspace.path]; try git.run(); git.waitUntilExit()
                guard git.terminationStatus == 0 else { throw LoomError.message("Could not initialize probe workspace") }
            }
            print("Prepared isolated probe directories at \(root.path)")
            return
        }
        if args.first == "capabilities" {
            let directory = root.appendingPathComponent("runs/capabilities-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let supervisor = try ProbeSupervisor()
            defer { _ = supervisor.shutdown() }
            let terminalEnvironment = try resolveTerminalEnvironment(supervisor: supervisor).environment
            var environment = LaunchEnvironment.make(base: terminalEnvironment, runID: UUID(), sessionID: UUID())
            environment["CODEX_HOME"] = root.appendingPathComponent("codex-home").path
            environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("claude-config").path
            for provider in ["codex", "claude"] {
                let version = try capture(provider, ["--version"], environment: environment)
                let help = try capture(provider, ["--help"], environment: environment)
                let server = provider == "codex" ? try capture(provider, ["app-server", "--help"], environment: environment) : ""
                let features = provider == "codex" ? try capture(provider, ["features", "list"], environment: environment) : ""
                let capabilities = ProviderCapabilities(version: version, help: help, serverHelp: server, features: features)
                try encoder.encode(capabilities).write(to: directory.appendingPathComponent("\(provider).json"))
                try (version + help + server + features).write(to: directory.appendingPathComponent("\(provider)-evidence.txt"), atomically: true, encoding: .utf8)
                print(String(decoding: try encoder.encode(capabilities), as: UTF8.self))
            }
            print(directory.path)
            return
        }
        if args.first == "recover", args.count == 2 {
            let url = URL(fileURLWithPath: args[1])
            let supervisor = try ProbeSupervisor(ledger: OwnershipLedger.load(from: url), ledgerURL: url)
            let report = supervisor.shutdown()
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            if !report.succeeded { exit(1) }
            return
        }
        guard args.first == "synthetic" || args.first == "crash-fixture" else {
            print("Usage: loom-probe prepare | capabilities | idle-metrics | codex-core-client | codex-core-resume <thread-id> | experiment <script.json> | recover-stale | synthetic [inspect|stubborn|group|escape|apple-escape] | recover <ledger.json>")
            return
        }
        let mode = args.count > 1 ? args[1] : "inspect"
        guard ["inspect", "stubborn", "group", "escape", "apple-escape"].contains(mode) else {
            throw LoomError.message("Unknown synthetic mode")
        }
        let ledger = OwnershipLedger()
        let directory = root.appendingPathComponent("runs/\(ledger.runID.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let ledgerURL = directory.appendingPathComponent("ledger.json")
        let supervisor = try ProbeSupervisor(ledger: ledger, ledgerURL: ledgerURL)
        guard let owner = try ProcessTable.snapshot().first(where: { $0.identity.pid == getpid() }) else {
            throw LoomError.message("Cannot record probe owner identity")
        }
        try encoder.encode(owner.identity).write(to: directory.appendingPathComponent("owner.json"), options: .atomic)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("loom-test-child").path
        defer { if !supervisor.isStopping { _ = supervisor.shutdown() } }
        let environment = LaunchEnvironment.make(base: try resolveTerminalEnvironment(supervisor: supervisor).environment, runID: ledger.runID, sessionID: UUID())
        do {
            let child = try supervisor.launch(executable: executable, arguments: [mode], environment: environment,
                                               directory: directory.path)
            var output = Data()
            let deadline = Date().addingTimeInterval(0.5)
            repeat {
                output.append(child.readAvailable())
                if args.first != "crash-fixture" && mode != "apple-escape" {
                    _ = try supervisor.sample()
                }
                usleep(10_000)
            } while Date() < deadline
            // The final ownership scan can consume the sampling window after the child writes.
            output.append(child.readAvailable())
            try output.write(to: directory.appendingPathComponent("terminal.txt"))
            if args.first == "crash-fixture" {
                // This internal mode deliberately dies; the next invocation must recover its marked descendants.
                print(ledgerURL.path); fflush(stdout)
                kill(getpid(), SIGKILL)
            }
            // Fixture PID is an independent oracle, never input to the ownership ledger.
            guard let line = String(decoding: output, as: UTF8.self).split(separator: "\n").first,
                  let fixture = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                throw LoomError.message("Fixture did not report readiness; scenario is unverified")
            }
            let oraclePID = fixture["descendantPID"] as? Int32
            let oracle = try ProcessTable.snapshot().first { $0.identity.pid == oraclePID }
            if ["group", "escape", "apple-escape"].contains(mode), oracle == nil {
                throw LoomError.message("Fixture descendant was not observed; scenario is unverified")
            }
            let found = try supervisor.sample()
            try encoder.encode(found).write(to: directory.appendingPathComponent("before-shutdown.json"))
            let report = supervisor.shutdown()
            let oracleRemaining = try ProcessTable.snapshot().filter { $0.identity == oracle?.identity && !$0.zombie }
            let passed = report.succeeded && oracleRemaining.isEmpty
            try encoder.encode(report).write(to: directory.appendingPathComponent("shutdown.json"), options: .atomic)
            try encoder.encode(oracleRemaining).write(to: directory.appendingPathComponent("oracle-remaining.json"), options: .atomic)
            let summary = "\(passed ? "PASS" : "FAIL") \(mode): \(report.remaining.count) owned-set remaining, \(oracleRemaining.count) oracle remaining, \(report.elapsedSeconds)s; \(directory.path)"
            try summary.write(to: directory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            // Only the synthetic oracle authorizes cleanup of the fixture the ledger failed to see.
            for record in oracleRemaining { try ProcessTable.signal(record.identity, SIGKILL) }
            print(String(decoding: output, as: UTF8.self)); print(summary)
            if !passed { exit(1) }
            try Data().write(to: directory.appendingPathComponent("completed"))
        } catch {
            let report = supervisor.shutdown()
            try? encoder.encode(report).write(to: directory.appendingPathComponent("shutdown.json"))
            throw error
        }
    }

    @MainActor static func recoverStaleRuns(root: URL) throws {
        let runs = root.appendingPathComponent("runs")
        guard FileManager.default.fileExists(atPath: runs.path) else { return }
        let snapshot = try ProcessTable.snapshot()
        let identities = Set(snapshot.map(\.identity))
        for directory in try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil) {
            let ownerURL = directory.appendingPathComponent("owner.json")
            guard FileManager.default.fileExists(atPath: ownerURL.path),
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path),
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovered").path) else { continue }
            do {
            let owner = try JSONDecoder().decode(ProcessIdentity.self, from: Data(contentsOf: ownerURL))
            if identities.contains(owner) { continue } // A concurrent, live probe owns this run.
            let ledgerURL = directory.appendingPathComponent("ledger.json")
            let supervisor = try ProbeSupervisor(ledger: OwnershipLedger.load(from: ledgerURL), ledgerURL: ledgerURL)
            let before = try supervisor.sample()
            try encoder.encode(before).write(to: directory.appendingPathComponent("recovery-before.json"), options: .atomic)
            let report = supervisor.shutdown()
            try encoder.encode(report).write(to: directory.appendingPathComponent("recovery.json"), options: .atomic)
            guard report.succeeded else { throw LoomError.message("Recovery incomplete: \(directory.path)") }
            try Data().write(to: directory.appendingPathComponent("recovered"))
            } catch {
                let message = "Recovery incomplete: \(directory.path): \(error)"
                try? message.write(to: directory.appendingPathComponent("recovery-error.txt"), atomically: true, encoding: .utf8)
                fputs(message + "\n", stderr)
            }
        }
    }

    static func capture(_ program: String, _ arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments
        process.environment = environment
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LoomError.message("Capability check failed: \(program) \(arguments)") }
        return String(decoding: data, as: UTF8.self)
    }

    static func codexCoreClient(root: URL) async throws -> URL {
        let ledger = OwnershipLedger()
        let directory = root.appendingPathComponent("runs/\(ledger.runID.uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let supervisor = try ProcessSupervisor(
            ledger: ledger, ledgerURL: directory.appendingPathComponent("ledger.json")
        )
        guard let owner = try ProcessTable.snapshot().first(where: {
            $0.identity.pid == getpid()
        }) else { throw LoomError.message("Cannot record probe owner identity") }
        try encoder.encode(owner.identity).write(
            to: directory.appendingPathComponent("owner.json"), options: .atomic
        )
        do {
            let resolution = try await supervisor.terminalEnvironment(origin: .development)
            var capabilityEnvironment = resolution.environment
            capabilityEnvironment["CODEX_HOME"] = root.appendingPathComponent("codex-home").path
            let version = try capture("codex", ["--version"], environment: capabilityEnvironment)
            let help = try capture("codex", ["--help"], environment: capabilityEnvironment)
            let serverHelp = try capture(
                "codex", ["app-server", "--help"], environment: capabilityEnvironment
            )
            let capabilities = ProviderCapabilities(
                version: version, help: help, serverHelp: serverHelp
            )
            guard let executable = resolution.environment["PATH"]?.split(separator: ":")
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path })
                .first(where: { access($0, X_OK) == 0 }) else {
                throw LoomError.message("Codex executable not found")
            }
            let socket = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".loom-dev/core-\(ledger.runID.uuidString.prefix(8)).sock")
            let manager = CodexAppServerManager(
                supervisor: supervisor,
                configuration: CodexAppServerConfiguration(
                    executable: executable, capabilities: capabilities,
                    home: root.appendingPathComponent("codex-home"),
                    baseEnvironment: resolution.environment,
                    workingDirectory: root.appendingPathComponent("workspace").path,
                    socketPath: socket.path, clientVersion: "probe-\(version)"
                )
            )
            let client = try await manager.start()
            let result = try await client.request(method: "thread/loaded/list")
            try encoder.encode(result).write(
                to: directory.appendingPathComponent("loaded-threads.json"), options: .atomic
            )
            let serverSessionID = await manager.internalSessionID()
            let visibleSessions = await supervisor.managedSessions()
            let release = await manager.stop(graceSeconds: 0.2)
            let shutdown = await supervisor.shutdown(graceSeconds: 0.2)
            let summary: [String: JSONValue] = [
                "serverSessionID": serverSessionID.map { .string($0.uuidString) } ?? .null,
                "visibleSessionCount": .number(Double(visibleSessions.count)),
                "releaseSucceeded": .bool(release?.succeeded == true),
                "shutdownSucceeded": .bool(shutdown.succeeded),
            ]
            try encoder.encode(summary).write(
                to: directory.appendingPathComponent("summary.json"), options: .atomic
            )
            guard release?.succeeded == true, shutdown.succeeded,
                  visibleSessions.isEmpty else {
                throw LoomError.message("Core Codex app-server lifecycle failed")
            }
            try Data().write(to: directory.appendingPathComponent("completed"))
            return directory
        } catch {
            let report = await supervisor.shutdown(graceSeconds: 0.2)
            try? encoder.encode(report).write(
                to: directory.appendingPathComponent("shutdown-error.json"), options: .atomic
            )
            throw error
        }
    }

    static func codexCoreResume(
        root: URL, threadID: String,
        prompt: String = "Reply exactly CODEX_CORE_OK. Do not use tools."
    ) async throws -> URL {
        let ledger = OwnershipLedger()
        let directory = root.appendingPathComponent("runs/\(ledger.runID.uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let catalog = try SessionCatalog(
            url: directory.appendingPathComponent("sessions.sqlite3")
        )
        let supervisor = try ProcessSupervisor(
            ledger: ledger, ledgerURL: directory.appendingPathComponent("ledger.json"),
            catalog: catalog
        )
        guard let owner = try ProcessTable.snapshot().first(where: {
            $0.identity.pid == getpid()
        }) else { throw LoomError.message("Cannot record probe owner identity") }
        try encoder.encode(owner.identity).write(
            to: directory.appendingPathComponent("owner.json"), options: .atomic
        )
        do {
            let resolution = try await supervisor.terminalEnvironment(origin: .development)
            var capabilityEnvironment = resolution.environment
            let home = root.appendingPathComponent("codex-home")
            capabilityEnvironment["CODEX_HOME"] = home.path
            let version = try capture("codex", ["--version"], environment: capabilityEnvironment)
            let help = try capture("codex", ["--help"], environment: capabilityEnvironment)
            let serverHelp = try capture(
                "codex", ["app-server", "--help"], environment: capabilityEnvironment
            )
            let capabilities = ProviderCapabilities(
                version: version, help: help, serverHelp: serverHelp
            )
            guard let executable = resolution.environment["PATH"]?.split(separator: ":")
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path })
                .first(where: { access($0, X_OK) == 0 }) else {
                throw LoomError.message("Codex executable not found")
            }
            let socket = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".loom-dev/core-\(ledger.runID.uuidString.prefix(8)).sock")
            let manager = CodexAppServerManager(
                supervisor: supervisor,
                configuration: CodexAppServerConfiguration(
                    executable: executable, capabilities: capabilities, home: home,
                    baseEnvironment: resolution.environment,
                    workingDirectory: root.appendingPathComponent("workspace").path,
                    socketPath: socket.path, clientVersion: "probe-\(version)"
                )
            )
            let session = ManagedSession(
                provider: .codex, providerConversationID: threadID,
                workingDirectory: root.appendingPathComponent("workspace").path
            )
            try await supervisor.createSession(session)
            let client = try await manager.start()
            let adapter = CodexSessionAdapter(supervisor: supervisor)
            let coordinator = CodexSessionCoordinator(
                client: client, supervisor: supervisor, adapter: adapter
            )
            await coordinator.start()
            let environment = LaunchEnvironment.make(
                base: resolution.environment, runID: supervisor.ownershipRunID,
                sessionID: session.id
            )
            let profile = try ProviderResumePlanner.codex(
                session: session, socketPath: socket.path,
                capabilities: capabilities, home: home, environment: environment
            )
            let launch = try await supervisor.launch(
                sessionID: session.id, executable: executable,
                arguments: profile.arguments + [
                    "-m", "gpt-6-luna", "-c", "model_reasoning_effort=\"low\"",
                ], environment: profile.environment, rows: 40, columns: 120
            )
            let runID = try launch.session.currentRun?.id
                ?? { throw LoomError.message("Codex run identity missing") }()
            try await coordinator.bindResume(
                sessionID: session.id, managedRunID: runID,
                threadID: threadID, workingDirectory: session.workingDirectory
            )
            var terminalOutput = Data()
            var queryBuffer = ""
            try await pumpCodexTerminal(
                launch.terminal, seconds: 4, output: &terminalOutput,
                queryBuffer: &queryBuffer
            )
            _ = try await launch.terminal.write(
                Data(prompt.utf8)
            )
            try await Task.sleep(for: .milliseconds(300))
            _ = try await launch.terminal.write(Data("\r".utf8))
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            var status = await adapter.status(sessionID: session.id)
            repeat {
                try await pumpCodexTerminal(
                    launch.terminal, seconds: 0.1, output: &terminalOutput,
                    queryBuffer: &queryBuffer
                )
                status = await adapter.status(sessionID: session.id)
                if status?.lastAssistantMessage?.contains("CODEX_CORE_OK") == true { break }
            } while ProcessInfo.processInfo.systemUptime < deadline
            try terminalOutput.write(to: directory.appendingPathComponent("terminal.txt"))
            let issues = await coordinator.issues()
            let statusObject: [String: JSONValue] = [
                "threadID": .string(status?.providerThreadID ?? ""),
                "lastAssistantMessage": status?.lastAssistantMessage.map(JSONValue.string) ?? .null,
                "backgroundTerminalCount": .number(Double(status?.backgroundTerminalCount ?? -1)),
                "issues": .array(issues.map(JSONValue.string)),
            ]
            try encoder.encode(statusObject).write(
                to: directory.appendingPathComponent("status.json"), options: .atomic
            )
            await coordinator.stop()
            let tuiStop = try await supervisor.stop(
                sessionID: session.id, graceSeconds: 0.2
            )
            let serverStop = await manager.stop(graceSeconds: 0.2)
            let shutdown = await supervisor.shutdown(graceSeconds: 0.2)
            guard status?.providerThreadID == threadID,
                  status?.lastAssistantMessage?.contains("CODEX_CORE_OK") == true,
                  issues.isEmpty, tuiStop.succeeded,
                  serverStop?.succeeded == true, shutdown.succeeded else {
                throw LoomError.message("Core Codex resume/status verification failed")
            }
            try Data().write(to: directory.appendingPathComponent("completed"))
            return directory
        } catch {
            let report = await supervisor.shutdown(graceSeconds: 0.2)
            try? encoder.encode(report).write(
                to: directory.appendingPathComponent("shutdown-error.json"), options: .atomic
            )
            throw error
        }
    }

    static func pumpCodexTerminal(
        _ terminal: TerminalEndpoint, seconds: Double,
        output: inout Data, queryBuffer: inout String
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            let chunk = terminal.readAvailable()
            if !chunk.isEmpty {
                output.append(chunk)
                queryBuffer += String(decoding: chunk, as: UTF8.self)
                let responses = [
                    ("\u{1b}[6n", "\u{1b}[1;1R"),
                    ("\u{1b}[c", "\u{1b}[?1;2c"),
                    ("\u{1b}[>0c", "\u{1b}[>0;0;0c"),
                    ("\u{1b}[?u", "\u{1b}[?0u"),
                    ("\u{1b}]10;?\u{7}", "\u{1b}]10;rgb:ffff/ffff/ffff\u{7}"),
                    ("\u{1b}]11;?\u{7}", "\u{1b}]11;rgb:0000/0000/0000\u{7}"),
                ]
                for (query, response) in responses {
                    while let range = queryBuffer.range(of: query) {
                        _ = try await terminal.write(Data(response.utf8))
                        queryBuffer.removeSubrange(range)
                    }
                }
                queryBuffer = String(queryBuffer.suffix(32))
            }
            try await Task.sleep(for: .milliseconds(5))
        } while ProcessInfo.processInfo.systemUptime < deadline
    }

    static func idleMetrics(root: URL) async throws -> URL {
        let ledger = OwnershipLedger()
        let directory = root.appendingPathComponent("runs/\(ledger.runID.uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let catalog = try SessionCatalog(
            url: directory.appendingPathComponent("sessions.sqlite3")
        )
        let supervisor = try ProcessSupervisor(
            ledger: ledger, ledgerURL: directory.appendingPathComponent("ledger.json"),
            catalog: catalog
        )
        let lifecycle = SessionLifecycleController(
            supervisor: supervisor, catalog: catalog,
            policy: SessionIdlePolicy(idleAfter: 3_600)
        )
        guard let owner = try ProcessTable.snapshot().first(where: {
            $0.identity.pid == getpid()
        }) else { throw LoomError.message("Cannot record probe owner identity") }
        try encoder.encode(owner.identity).write(
            to: directory.appendingPathComponent("owner.json"), options: .atomic
        )
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("loom-test-child").path
        do {
            let resolution = try await supervisor.terminalEnvironment(origin: .development)
            let emptyUsage = try ProcessTable.resourceUsage(pid: getpid())
                ?? { throw LoomError.message("Process usage unavailable") }()
            var terminals: [TerminalEndpoint] = []
            for _ in 0..<10 {
                let session = ManagedSession(
                    provider: .synthetic, workingDirectory: directory.path
                )
                try await supervisor.createSession(session)
                let environment = LaunchEnvironment.make(
                    base: resolution.environment, runID: supervisor.ownershipRunID,
                    sessionID: session.id
                )
                terminals.append(try await supervisor.launch(
                    sessionID: session.id, executable: executable,
                    arguments: ["stubborn", "--silent"], environment: environment
                ).terminal)
            }
            try await lifecycle.startAutomaticEvaluation()
            try await Task.sleep(for: .milliseconds(250))
            let before = try ProcessTable.resourceUsage(pid: getpid())
                ?? { throw LoomError.message("Process usage unavailable") }()
            let intervalStart = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(2))
            let elapsed = ProcessInfo.processInfo.systemUptime - intervalStart
            let after = try ProcessTable.resourceUsage(pid: getpid())
                ?? { throw LoomError.message("Process usage unavailable") }()
            let cpuNanoseconds = (after.userTimeNanoseconds - before.userTimeNanoseconds)
                + (after.systemTimeNanoseconds - before.systemTimeNanoseconds)
            let result: [String: JSONValue] = [
                "sessionCount": .number(10),
                "measurementSeconds": .number(elapsed),
                "cpuMilliseconds": .number(Double(cpuNanoseconds) / 1_000_000),
                "averageCPUPercent": .number(
                    Double(cpuNanoseconds) / 1_000_000_000 / elapsed * 100
                ),
                "packageIdleWakeups": .number(Double(
                    after.packageIdleWakeups - before.packageIdleWakeups
                )),
                "interruptWakeups": .number(Double(
                    after.interruptWakeups - before.interruptWakeups
                )),
                "footprintIncreaseBytes": .number(Double(
                    before.physicalFootprintBytes >= emptyUsage.physicalFootprintBytes
                        ? before.physicalFootprintBytes - emptyUsage.physicalFootprintBytes : 0
                )),
                "scrollbackAllocatedBytes": .number(Double(
                    terminals.reduce(0) { $0 + ($1.scrollback?.allocatedByteCount ?? 0) }
                )),
                "idleTimerFires": .number(Double(
                    await lifecycle.timerFireCount()
                )),
            ]
            try encoder.encode(result).write(
                to: directory.appendingPathComponent("idle-metrics.json"), options: .atomic
            )
            await lifecycle.stopAutomaticEvaluation()
            let shutdown = await supervisor.shutdown(graceSeconds: 0.05)
            try encoder.encode(shutdown).write(
                to: directory.appendingPathComponent("shutdown.json"), options: .atomic
            )
            guard shutdown.succeeded else {
                throw LoomError.message("Idle metrics cleanup failed")
            }
            try Data().write(to: directory.appendingPathComponent("completed"))
            return directory
        } catch {
            let report = await supervisor.shutdown(graceSeconds: 0.05)
            try? encoder.encode(report).write(
                to: directory.appendingPathComponent("shutdown-error.json"), options: .atomic
            )
            throw error
        }
    }

    static var encoder: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value }
}
