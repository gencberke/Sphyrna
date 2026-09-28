import Foundation
import LoomCore

extension Probe {
    static func codexCoreActiveQuit(root: URL, threadID: String) async throws -> URL {
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
                .appendingPathComponent(".loom-dev/q1-\(ledger.runID.uuidString.prefix(8)).sock")
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
            let client = try await manager.acquire(for: session.id)
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
            var output = Data(), queries = ""
            try await pumpCodexTerminal(
                launch.terminal, seconds: 3, output: &output, queryBuffer: &queries
            )
            try output.write(to: directory.appendingPathComponent("startup.txt"))
            let previous = try await client.request(
                method: "thread/read", params: .object([
                    "threadId": .string(threadID), "includeTurns": .bool(true),
                ])
            )
            let previousCompleted = (previous.object?["thread"]?.object?["turns"]?
                .array ?? []).contains { turn in
                guard let object = turn.object,
                      object["status"]?.string == "completed" else { return false }
                return (object["items"]?.array ?? []).contains { item in
                    item.object?["type"]?.string == "agentMessage"
                        && item.object?["text"]?.string?
                            .contains("CODEX_CORE_OK") == true
                }
            }
            guard previousCompleted else {
                throw LoomError.message("Completed Codex turn was not in provider history")
            }
            let prompt = "Run exactly this read-only shell command and wait for it to finish: sleep 12. Then reply DONE."
            _ = try await launch.terminal.write(Data(prompt.utf8))
            try await Task.sleep(for: .milliseconds(300))
            _ = try await launch.terminal.write(Data("\r".utf8))
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            var active = false
            var commandProcesses: [ProcessIdentity] = []
            repeat {
                try await pumpCodexTerminal(
                    launch.terminal, seconds: 0.1,
                    output: &output, queryBuffer: &queries
                )
                let status = try await client.readThread(threadID)
                let owned = try await supervisor.ownedProcesses()
                commandProcesses = owned.filter {
                    ProcessTable.executablePath(pid: $0.identity.pid)?
                        .hasSuffix("/sleep") == true
                }.map(\.identity)
                active = status.isActive && !commandProcesses.isEmpty
                if active { break }
            } while ProcessInfo.processInfo.systemUptime < deadline
            try output.write(to: directory.appendingPathComponent("terminal.txt"))
            guard active else {
                throw LoomError.message("Codex active command did not start")
            }
            let quit = await supervisor.shutdown(graceSeconds: 0.4)
            try encoder.encode(quit).write(
                to: directory.appendingPathComponent("quit.json"), options: .atomic
            )
            await coordinator.stop()
            let survivors = try ProcessTable.snapshot().filter {
                commandProcesses.contains($0.identity) && !$0.zombie
            }
            let sleepProcessesGone = survivors.isEmpty
            let summary: [String: JSONValue] = [
                "sessionID": .string(session.id.uuidString),
                "runID": .string(runID.uuidString),
                "threadID": .string(threadID),
                "previousCompletedTurnPresent": .bool(previousCompleted),
                "activeAtQuit": .bool(active),
                "quitSucceeded": .bool(quit.succeeded),
                "sleepProcessesGone": .bool(sleepProcessesGone),
            ]
            try encoder.encode(summary).write(
                to: directory.appendingPathComponent("summary.json"), options: .atomic
            )
            guard quit.succeeded, sleepProcessesGone else {
                throw LoomError.message("Codex active Quit was not clean")
            }
            try Data().write(to: directory.appendingPathComponent("completed"))
            return directory
        } catch {
            let report = await supervisor.shutdown(graceSeconds: 0.4)
            try? encoder.encode(report).write(
                to: directory.appendingPathComponent("shutdown-error.json"),
                options: .atomic
            )
            throw error
        }
    }
}
