import Foundation
import LoomCore

extension Probe {
    static func claudeCoreQ1(root: URL) async throws -> URL {
        let experimentID = UUID()
        let directory = root.appendingPathComponent("runs/\(experimentID.uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let catalog = try SessionCatalog(
            url: directory.appendingPathComponent("sessions.sqlite3")
        )
        let token = "CLAUDE_Q1_\(experimentID.uuidString.prefix(8))"
        let hookDirectory = URL(
            fileURLWithPath: "/tmp/lh-\(experimentID.uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: hookDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("loom-hook").path
        let workspace = root.appendingPathComponent("workspace").path
        let config = root.appendingPathComponent("claude-config")
        let first = ManagedSession(provider: .claude, workingDirectory: workspace)
        var supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            ledgerURL: directory.appendingPathComponent("first-ledger.json"),
            catalog: catalog
        )
        var hookServer: ClaudeHookServer?
        do {
            try await supervisor.createSession(first)
            let resolution = try await supervisor.terminalEnvironment(origin: .development)
            var capabilityEnvironment = resolution.environment
            capabilityEnvironment["CLAUDE_CONFIG_DIR"] = config.path
            let version = try capture("claude", ["--version"], environment: capabilityEnvironment)
            let help = try capture("claude", ["--help"], environment: capabilityEnvironment)
            let capabilities = ProviderCapabilities(version: version, help: help)
            guard let executable = resolution.environment["PATH"]?.split(separator: ":")
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("claude").path })
                .first(where: { access($0, X_OK) == 0 }) else {
                throw LoomError.message("Claude executable not found")
            }
            let firstAdapter = ClaudeSessionAdapter(supervisor: supervisor)
            let firstSocket = hookDirectory.appendingPathComponent("first.sock").path
            let recorder = HookRecorder(
                outputURL: directory.appendingPathComponent("claude-hooks.jsonl")
            )
            let firstHookToken = UUID().uuidString
            hookServer = try ClaudeHookServer(
                socketPath: firstSocket, authenticationToken: firstHookToken
            ) { envelope in
                recorder.receive(envelope)
                Task { _ = try? await firstAdapter.receive(envelope) }
            }
            let firstHooks = ClaudeHookLaunchConfiguration(
                helperPath: helper, socketPath: firstSocket,
                authenticationToken: firstHookToken
            )
            let firstEnvironment = LaunchEnvironment.make(
                base: resolution.environment, runID: supervisor.ownershipRunID,
                sessionID: first.id
            )
            let firstProfile = try ProviderLaunchProfile.claude(
                capabilities: capabilities, config: config,
                sessionID: first.id, environment: firstEnvironment,
                hooks: firstHooks
            )
            let firstLaunch = try await supervisor.launch(
                sessionID: first.id, executable: executable,
                arguments: firstProfile.arguments + [
                    "--model", "haiku", "--effort", "low", "--no-chrome",
                ], environment: firstProfile.environment, rows: 40, columns: 120
            )
            let firstRunID = try firstLaunch.session.currentRun?.id
                ?? { throw LoomError.message("First Claude run missing") }()
            var output = Data(), queries = ""
            try await pumpCodexTerminal(
                firstLaunch.terminal, seconds: 3, output: &output,
                queryBuffer: &queries
            )
            try output.write(to: directory.appendingPathComponent("first-startup.txt"))
            _ = try await firstLaunch.terminal.write(Data("\u{1b}[B\r".utf8))
            try await pumpCodexTerminal(
                firstLaunch.terminal, seconds: 1, output: &output,
                queryBuffer: &queries
            )
            _ = try await firstLaunch.terminal.write(Data(
                "Reply exactly \(token). Do not use tools.".utf8
            ))
            try await Task.sleep(for: .milliseconds(300))
            _ = try await firstLaunch.terminal.write(Data("\r".utf8))
            let firstDeadline = ProcessInfo.processInfo.systemUptime + 30
            var completed = false
            repeat {
                try await pumpCodexTerminal(
                    firstLaunch.terminal, seconds: 0.1, output: &output,
                    queryBuffer: &queries
                )
                let status = await firstAdapter.status(sessionID: first.id)
                completed = status?.lastAssistantMessage?.contains(token) == true
                    && status?.activity == .turnComplete
                if completed { break }
            } while ProcessInfo.processInfo.systemUptime < firstDeadline
            guard completed else {
                throw LoomError.message("Claude initial completed turn missing")
            }
            _ = try await firstLaunch.terminal.write(Data(
                "Use Bash to run touch claude-q1-approval.txt in this workspace. Do not use another tool.".utf8
            ))
            try await Task.sleep(for: .milliseconds(300))
            _ = try await firstLaunch.terminal.write(Data("\r".utf8))
            let activeDeadline = ProcessInfo.processInfo.systemUptime + 25
            var active = false
            repeat {
                try await pumpCodexTerminal(
                    firstLaunch.terminal, seconds: 0.1, output: &output,
                    queryBuffer: &queries
                )
                let status = await firstAdapter.status(sessionID: first.id)
                active = status?.activity == .waitingForApproval
                if active { break }
            } while ProcessInfo.processInfo.systemUptime < activeDeadline
            try output.write(to: directory.appendingPathComponent("first-terminal.txt"))
            guard active else {
                throw LoomError.message("Claude approval turn did not become active")
            }
            let firstStatus = await firstAdapter.status(sessionID: first.id)
            let conversationID = try firstStatus?.providerSessionID
                ?? { throw LoomError.message("Claude conversation identity missing") }()
            let firstQuit = await supervisor.shutdown(graceSeconds: 0.4)
            try encoder.encode(firstQuit).write(
                to: directory.appendingPathComponent("first-quit.json"), options: .atomic
            )
            guard firstQuit.succeeded else {
                throw LoomError.message("Claude active Quit failed")
            }
            hookServer?.stop()
            hookServer = nil
            try await Task.sleep(for: .milliseconds(100))

            supervisor = try await ProcessSupervisor.restoring(
                ledger: OwnershipLedger(),
                ledgerURL: directory.appendingPathComponent("second-ledger.json"),
                catalog: catalog
            )
            let secondAdapter = ClaudeSessionAdapter(supervisor: supervisor)
            let secondSocket = hookDirectory.appendingPathComponent("second.sock").path
            let secondHookToken = UUID().uuidString
            hookServer = try ClaudeHookServer(
                socketPath: secondSocket, authenticationToken: secondHookToken
            ) { envelope in
                recorder.receive(envelope)
                Task { _ = try? await secondAdapter.receive(envelope) }
            }
            let secondHooks = ClaudeHookLaunchConfiguration(
                helperPath: helper, socketPath: secondSocket,
                authenticationToken: secondHookToken
            )
            let restored = try await supervisor.session(id: first.id)
                ?? { throw LoomError.message("Restored Claude session missing") }()
            let secondResolution = try await supervisor.terminalEnvironment(
                origin: .development
            )
            let secondEnvironment = LaunchEnvironment.make(
                base: secondResolution.environment,
                runID: supervisor.ownershipRunID, sessionID: first.id
            )
            let secondProfile = try ProviderResumePlanner.claude(
                session: restored, capabilities: capabilities,
                config: config, environment: secondEnvironment, hooks: secondHooks
            )
            let secondLaunch = try await supervisor.launch(
                sessionID: first.id, executable: executable,
                arguments: secondProfile.arguments + [
                    "--model", "haiku", "--effort", "low", "--no-chrome",
                ], environment: secondProfile.environment, rows: 40, columns: 120
            )
            let secondRunID = try secondLaunch.session.currentRun?.id
                ?? { throw LoomError.message("Second Claude run missing") }()
            var secondOutput = Data(), secondQueries = ""
            try await pumpCodexTerminal(
                secondLaunch.terminal, seconds: 3,
                output: &secondOutput, queryBuffer: &secondQueries
            )
            _ = try await secondLaunch.terminal.write(Data("\r".utf8))
            try await pumpCodexTerminal(
                secondLaunch.terminal, seconds: 1,
                output: &secondOutput, queryBuffer: &secondQueries
            )
            _ = try await secondLaunch.terminal.write(Data(
                "What exact all-caps token did you reply with in the completed turn before the interrupted tool turn? Reply with only that token. Do not use tools.".utf8
            ))
            try await Task.sleep(for: .milliseconds(300))
            _ = try await secondLaunch.terminal.write(Data("\r".utf8))
            let secondDeadline = ProcessInfo.processInfo.systemUptime + 30
            var recovered = false
            repeat {
                try await pumpCodexTerminal(
                    secondLaunch.terminal, seconds: 0.1,
                    output: &secondOutput, queryBuffer: &secondQueries
                )
                let status = await secondAdapter.status(sessionID: first.id)
                recovered = status?.lastAssistantMessage?.contains(token) == true
                    && status?.activity == .turnComplete
                if recovered { break }
            } while ProcessInfo.processInfo.systemUptime < secondDeadline
            try secondOutput.write(to: directory.appendingPathComponent("second-terminal.txt"))
            let secondQuit = await supervisor.shutdown(graceSeconds: 0.4)
            hookServer?.stop()
            hookServer = nil
            try? FileManager.default.removeItem(at: hookDirectory)
            try encoder.encode(secondQuit).write(
                to: directory.appendingPathComponent("second-quit.json"), options: .atomic
            )
            let summary: [String: JSONValue] = [
                "sessionID": .string(first.id.uuidString),
                "firstRunID": .string(firstRunID.uuidString),
                "secondRunID": .string(secondRunID.uuidString),
                "conversationID": .string(conversationID),
                "completedBeforeQuit": .bool(completed),
                "activeAtQuit": .bool(active),
                "recoveredCompletedTurn": .bool(recovered),
                "firstQuitSucceeded": .bool(firstQuit.succeeded),
                "secondQuitSucceeded": .bool(secondQuit.succeeded),
            ]
            try encoder.encode(summary).write(
                to: directory.appendingPathComponent("summary.json"), options: .atomic
            )
            guard recovered, secondQuit.succeeded else {
                throw LoomError.message("Claude Q1 resume did not recover prior turn")
            }
            try Data().write(to: directory.appendingPathComponent("completed"))
            return directory
        } catch {
            hookServer?.stop()
            try? FileManager.default.removeItem(at: hookDirectory)
            let report = await supervisor.shutdown(graceSeconds: 0.4)
            try? encoder.encode(report).write(
                to: directory.appendingPathComponent("shutdown-error.json"),
                options: .atomic
            )
            throw error
        }
    }
}
