import Foundation
import Testing
@testable import LoomCore

@Suite(.serialized) struct ClaudeLimitResetRuntimeTests {
    private actor Sink {
        var values: [ClaudeLimitResetDelivery] = []
        func append(_ value: ClaudeLimitResetDelivery) { values.append(value) }
    }

    @Test func onlyAuthenticatedAppliedFailureCanReachTheTypedTailAndObserver() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/loom-limit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let profile = root.appendingPathComponent("profile"), work = root.appendingPathComponent("work")
        for folder in [profile, work] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let host = root.appendingPathComponent("host")
        let bundle = try RunScopeLauncher.assembleOwnedBundle(
            executable: RuntimeFixture.binaries.appendingPathComponent("loom-run-host"), in: host)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let supervisor = try await ProcessSupervisor.restoring(catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: root.appendingPathComponent("scope")))
        let sink = Sink()
        let runtime = SessionRuntime(supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(toolchains: { provider in
                ProviderToolchain(provider: provider, executable: RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path,
                    capabilities: ProviderCapabilities(version: "2.1.311", help: "--settings --session-id --resume --permission-mode"),
                    environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], profileDirectory: profile)
            }, hookHelperPath: RuntimeFixture.binaries.appendingPathComponent("loom-hook").path,
            socketDirectory: root.appendingPathComponent("s"), homeDirectory: work.path,
            claudeTemporaryRoot: nil, claudeProfileDirectory: profile, claudeEnvironment: [:], catalogBackupDelay: nil,
            onClaudeLimitReset: .init(receive: { await sink.append($0) })))
        do {
            try await runtime.start()
            let launch = try await runtime.startConversation(provider: .claude, projectID: nil)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var session: ManagedSession?
            repeat {
                session = await supervisor.session(id: launch.sessionID)
                if session?.providerConversationID != nil,
                   await runtime.harnesses.claude.adapter.status(sessionID: launch.sessionID) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            let native = try #require(session?.providerConversationID)
            let working = try #require(session?.workingDirectory)
            let hooks = try #require(await runtime.hookConfiguration)
            let prompt = UUID()
            func envelope(_ name: String) throws -> ClaudeHookEnvelope {
                let fields: [String: Any] = ["hook_event_name": name, "session_id": native,
                    "prompt_id": prompt.uuidString, "cwd": working, "error": "rate_limit"]
                return ClaudeHookEnvelope(sessionID: launch.sessionID, managedRunID: launch.runID,
                    payload: try JSONSerialization.data(withJSONObject: fields))
            }
            let user = try envelope("UserPromptSubmit")
            try await Task.detached {
                try ClaudeHookClient.send(user, socketPath: hooks.socketPath, authenticationToken: hooks.authenticationToken)
            }.value
            let file = profile.appendingPathComponent("projects")
                .appendingPathComponent(ClaudeTranscriptLocator.folderName(forWorkingDirectory: working))
                .appendingPathComponent(native + ".jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let now = Date(), reset = now.addingTimeInterval(3_600)
            let timestamp = ISO8601DateFormatter()
            timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let userRow: [String: Any] = ["type": "user", "uuid": UUID().uuidString,
                "sessionId": native, "promptId": prompt.uuidString, "isSidechain": false,
                "timestamp": timestamp.string(from: now), "message": ["role": "user", "content": "fixture"]]
            let errorRow: [String: Any] = ["type": "assistant", "uuid": UUID().uuidString,
                "sessionId": native, "isSidechain": false, "isApiErrorMessage": true,
                "apiError": "usage_limit_reached", "timestamp": timestamp.string(from: now),
                "apiErrorParams": ["rate_limit_info": ["status": "rejected", "rateLimitType": "five_hour",
                    "resetsAt": Int(reset.timeIntervalSince1970), "isUsingOverage": false]]]
            let bytes = try [userRow, errorRow].reduce(into: Data()) { bytes, row in
                bytes.append(try JSONSerialization.data(withJSONObject: row)); bytes.append(0x0A)
            }
            try bytes.write(to: file)
            let failure = try envelope("StopFailure")
            let rejected = await Task.detached {
                do {
                    try ClaudeHookClient.send(failure, socketPath: hooks.socketPath, authenticationToken: "wrong")
                    return false
                } catch { return true }
            }.value
            let beforeValidFailure = await sink.values
            #expect(rejected && beforeValidFailure.isEmpty)
            try await Task.detached {
                try ClaudeHookClient.send(failure, socketPath: hooks.socketPath, authenticationToken: hooks.authenticationToken)
            }.value
            let delivered = ContinuousClock.now.advanced(by: .seconds(5))
            while await sink.values.isEmpty, ContinuousClock.now < delivered { try await Task.sleep(for: .milliseconds(10)) }
            let values = await sink.values
            #expect(values.count == 1)
            #expect(values.first?.signal.sessionID == launch.sessionID && values.first?.signal.promptID == prompt)
            #expect(values.first?.isCurrent() == true)
            let report = await runtime.shutdown()
            #expect(report.succeeded && report.remainingCountVerified == true)
            #expect(values.first?.isCurrent() == false)
        } catch {
            _ = await runtime.shutdown()
            RunScopeLauncher.removeOwnedBundle(in: host)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        RunScopeLauncher.removeOwnedBundle(in: host)
        try? FileManager.default.removeItem(at: root)
    }
}
