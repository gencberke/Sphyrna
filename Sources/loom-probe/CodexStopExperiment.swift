import Foundation
import LoomCore

extension Probe {
    static func codexTwoSessionStop(root: URL) async throws -> URL {
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
        }) else { throw LoomError.message("Probe owner identity unavailable") }
        try encoder.encode(owner.identity).write(
            to: directory.appendingPathComponent("owner.json"), options: .atomic
        )
        do {
            let resolution = try await supervisor.terminalEnvironment(origin: .development)
            let home = root.appendingPathComponent("codex-home")
            var capabilityEnvironment = resolution.environment
            capabilityEnvironment["CODEX_HOME"] = home.path
            let version = try capture("codex", ["--version"], environment: capabilityEnvironment)
            let help = try capture("codex", ["--help"], environment: capabilityEnvironment)
            let serverHelp = try capture("codex", ["app-server", "--help"], environment: capabilityEnvironment)
            let capabilities = ProviderCapabilities(
                version: version, help: help, serverHelp: serverHelp
            )
            guard let executable = resolution.environment["PATH"]?.split(separator: ":")
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path })
                .first(where: { access($0, X_OK) == 0 }) else {
                throw LoomError.message("Codex executable not found")
            }
            let socket = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".loom-dev/stop-\(ledger.runID.uuidString.prefix(8)).sock")
            let manager = CodexAppServerManager(
                supervisor: supervisor,
                configuration: CodexAppServerConfiguration(
                    executable: executable, capabilities: capabilities, home: home,
                    baseEnvironment: resolution.environment,
                    workingDirectory: root.appendingPathComponent("workspace").path,
                    socketPath: socket.path, clientVersion: "probe-\(version)"
                )
            )
            let workspace = root.appendingPathComponent("workspace")
            let marker = workspace.appendingPathComponent(
                "single-stop-marker-\(ledger.runID.uuidString)"
            )
            let first = ManagedSession(provider: .codex, workingDirectory: workspace.path)
            let second = ManagedSession(provider: .codex, workingDirectory: workspace.path)
            try await supervisor.createSession(first)
            try await supervisor.createSession(second)
            let client = try await manager.start()
            let adapter = CodexSessionAdapter(supervisor: supervisor)
            let coordinator = CodexSessionCoordinator(
                client: client, supervisor: supervisor, adapter: adapter
            )
            await coordinator.start()
            var terminals: [UUID: TerminalEndpoint] = [:]
            var threads: [UUID: String] = [:]
            var runs: [UUID: UUID] = [:]
            for session in [first, second] {
                let runID = UUID()
                let reservation = await coordinator.reserveNewLaunch(
                    sessionID: session.id, managedRunID: runID,
                    workingDirectory: workspace.path
                )
                let environment = LaunchEnvironment.make(
                    base: resolution.environment,
                    runID: supervisor.ownershipRunID, sessionID: session.id
                )
                let profile = try ProviderLaunchProfile.codex(
                    route: .remote(socket: socket.path, threadID: nil, workingDirectory: workspace.path),
                    capabilities: capabilities, home: home,
                    environment: environment
                )
                let launch = try await supervisor.launch(
                    sessionID: session.id, executable: executable,
                    arguments: profile.arguments + [
                        "-m", "gpt-6-luna", "-c", "model_reasoning_effort=\"low\"",
                        "-s", "workspace-write", "-a", "never",
                    ], environment: profile.environment, rows: 40, columns: 120,
                    managedRunID: runID
                )
                terminals[session.id] = launch.terminal
                runs[session.id] = runID
                threads[session.id] = try await coordinator.waitForNewLaunch(reservation)
                var output = Data(), queryBuffer = ""
                try await pumpCodexTerminal(
                    launch.terminal, seconds: 3,
                    output: &output, queryBuffer: &queryBuffer
                )
                try output.write(to: directory.appendingPathComponent(
                    "\(session.id.uuidString)-startup.txt"
                ))
            }
            let firstThread = try threads[first.id]
                ?? { throw LoomError.message("First thread missing") }()
            let secondThread = try threads[second.id]
                ?? { throw LoomError.message("Second thread missing") }()
            let firstTerminal = try terminals[first.id]
                ?? { throw LoomError.message("First terminal missing") }()
            let prompt = "Run exactly this shell command and wait for it to finish: sleep 12; touch \(marker.path). Then reply DONE."
            _ = try await firstTerminal.write(Data(prompt.utf8))
            try await Task.sleep(for: .milliseconds(300))
            _ = try await firstTerminal.write(Data("\r".utf8))
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            var commandStarted = false
            var firstOutput = Data(), firstQueries = ""
            repeat {
                try await pumpCodexTerminal(
                    firstTerminal, seconds: 0.1,
                    output: &firstOutput, queryBuffer: &firstQueries
                )
                let raw = try await client.request(
                    method: "thread/read",
                    params: .object([
                        "threadId": .string(firstThread),
                        "includeTurns": .bool(true),
                    ])
                )
                let snapshot = try await client.readThread(firstThread)
                let owned = try await supervisor.ownedProcesses()
                commandStarted = snapshot.isActive && owned.contains {
                    ProcessTable.executablePath(pid: $0.identity.pid)?
                        .hasSuffix("/sleep") == true
                }
                if commandStarted {
                    try encoder.encode(raw).write(
                        to: directory.appendingPathComponent("before-stop.json"),
                        options: .atomic
                    )
                    try encoder.encode(owned).write(
                        to: directory.appendingPathComponent("running-processes.json"),
                        options: .atomic
                    )
                    break
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            try firstOutput.write(to: directory.appendingPathComponent("first-terminal.txt"))
            guard commandStarted else {
                throw LoomError.message("Codex command did not begin before stop")
            }
            let report = try await supervisor.stop(
                sessionID: first.id, graceSeconds: 0.2
            )
            try encoder.encode(report).write(
                to: directory.appendingPathComponent("first-stop.json"), options: .atomic
            )
            let after = try await client.request(
                method: "thread/read",
                params: .object([
                    "threadId": .string(firstThread), "includeTurns": .bool(true),
                ])
            )
            try encoder.encode(after).write(
                to: directory.appendingPathComponent("after-stop.json"), options: .atomic
            )
            let terminalsAfter = try await client.backgroundTerminals(threadID: firstThread)
            let other = try await client.readThread(secondThread)
            let serverStayed = await manager.internalSessionID() != nil
            let otherRunning = await supervisor.session(id: second.id)?.currentRun != nil
            try await Task.sleep(for: .seconds(14))
            let markerExists = FileManager.default.fileExists(atPath: marker.path)
            let firstActive = try await client.readThread(firstThread).isActive
            let summary: [String: JSONValue] = [
                "firstSessionID": .string(first.id.uuidString),
                "secondSessionID": .string(second.id.uuidString),
                "firstThreadID": .string(firstThread),
                "secondThreadID": .string(secondThread),
                "commandStarted": .bool(commandStarted),
                "stopSucceeded": .bool(report.succeeded),
                "markerExists": .bool(markerExists),
                "firstActive": .bool(firstActive),
                "backgroundTerminalCount": .number(Double(terminalsAfter.count)),
                "otherRunning": .bool(otherRunning),
                "otherThreadLoaded": .bool(other.threadID == secondThread),
                "serverStayed": .bool(serverStayed),
            ]
            try encoder.encode(summary).write(
                to: directory.appendingPathComponent("summary.json"), options: .atomic
            )
            guard report.succeeded, !markerExists, !firstActive,
                  terminalsAfter.isEmpty, otherRunning, serverStayed,
                  other.threadID == secondThread else {
                throw LoomError.message("Two-session stop acceptance failed")
            }
            if let runID = runs[first.id] { await coordinator.unbind(runID: runID) }
            let secondStop = try await supervisor.stop(sessionID: second.id)
            _ = await manager.stopServer()
            await coordinator.stop()
            let shutdown = await supervisor.shutdown()
            guard secondStop.succeeded, shutdown.succeeded else {
                throw LoomError.message("Two-session cleanup failed")
            }
            try Data().write(to: directory.appendingPathComponent("completed"))
            return directory
        } catch {
            let report = await supervisor.shutdown(graceSeconds: 0.2)
            try? encoder.encode(report).write(
                to: directory.appendingPathComponent("shutdown-error.json"),
                options: .atomic
            )
            throw error
        }
    }
}
