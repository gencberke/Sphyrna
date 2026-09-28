import Foundation
import Testing
@testable import LoomCore

private final class LifecycleTestBundleAnchor: NSObject {}

@Suite(.serialized)
struct SessionLifecycleTests {
    private var childPath: String {
        Bundle(for: LifecycleTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
    }

    @Test func quietSessionIdlesWithoutStoppingAnotherAndResumesSameConversation() async throws {
        let context = try await makeContext(idleAfter: 10)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let firstID = UUID(), secondID = UUID()
        let first = try await launchClaude(
            sessionID: firstID, conversationID: "claude-conversation",
            mode: "stubborn", context: context
        )
        _ = try await ready(first.terminal)
        let second = try await launchSynthetic(
            sessionID: secondID, mode: "stubborn", context: context
        )
        _ = try await ready(second.terminal)
        try await makeClaudeQuiet(
            launchSessionID: firstID,
            runID: try #require(first.session.currentRun?.id),
            conversationID: "claude-conversation", adapter: context.claude
        )
        try await context.lifecycle.captureProcessBaseline(sessionID: firstID)
        try await context.catalog.markUsed(
            sessionID: firstID, at: Date(timeIntervalSince1970: 100),
            reactivate: true
        )

        let result = try await context.lifecycle.evaluateIdle(
            sessionID: firstID, at: Date(timeIntervalSince1970: 200)
        )
        guard case let .transitioned(report) = result else {
            Issue.record("Quiet session did not transition to idle")
            return
        }
        #expect(report.succeeded)
        #expect(try await context.catalog.session(id: firstID)?.lifecycle == .idle)
        #expect(try await context.catalog.runs().first {
            $0.id == first.session.currentRun?.id
        }?.endReason == .idle)
        #expect(try await context.supervisor.sample(sessionID: secondID).contains {
            $0.identity.pid == second.terminal.pid
        })

        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: context.supervisor.ownershipRunID,
            sessionID: firstID
        )
        let resumed = try await context.lifecycle.resume(
            sessionID: firstID, executable: childPath,
            profile: ProviderLaunchProfile(
                arguments: ["stubborn"], environment: environment
            ), at: Date(timeIntervalSince1970: 210)
        )
        _ = try await ready(resumed.terminal)
        #expect(resumed.session.id == firstID)
        #expect(resumed.session.providerConversationID == "claude-conversation")
        #expect(resumed.session.workingDirectory == context.root.path)
        #expect(try await context.catalog.session(id: firstID)?.lifecycle == .active)
        #expect((await context.supervisor.shutdown(graceSeconds: 0.05)).succeeded)
    }

    @Test func approvalBackgroundWorkAndLateDescendantBlockIdle() async throws {
        let context = try await makeContext(idleAfter: 1)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let sessionID = UUID()
        let launch = try await launchClaude(
            sessionID: sessionID, conversationID: "claude-busy",
            mode: "spawn-on-input", context: context
        )
        _ = try await ready(launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        try await context.lifecycle.captureProcessBaseline(sessionID: sessionID)
        try await context.catalog.markUsed(
            sessionID: sessionID, at: Date(timeIntervalSince1970: 10),
            reactivate: true
        )
        _ = try await context.claude.receive(try hook(
            launchSessionID: sessionID, runID: runID,
            conversationID: "claude-busy", event: "Stop",
            fields: ["background_tasks": [["id": "task"]]]
        ))
        _ = try await launch.terminal.write(Data("spawn\n".utf8))
        try await Task.sleep(for: .milliseconds(80))

        let result = try await context.lifecycle.evaluateIdle(
            sessionID: sessionID, at: Date(timeIntervalSince1970: 20)
        )
        guard case let .blocked(blockers) = result else {
            Issue.record("Busy session was stopped")
            return
        }
        #expect(blockers.contains(.pendingProviderWork(1)))
        #expect(blockers.contains { blocker in
            if case .nonBaselineDescendants = blocker { return true }
            return false
        })
        #expect(await context.supervisor.session(id: sessionID)?.currentRun != nil)

        _ = try await context.claude.receive(try hook(
            launchSessionID: sessionID, runID: runID,
            conversationID: "claude-busy", event: "PermissionRequest"
        ))
        let approval = try await context.lifecycle.evaluateIdle(
            sessionID: sessionID, at: Date(timeIntervalSince1970: 20)
        )
        guard case let .blocked(approvalBlockers) = approval else {
            Issue.record("Approval wait was not an idle blocker")
            return
        }
        #expect(approvalBlockers.contains(.waitingForApproval))
        #expect((await context.supervisor.shutdown(graceSeconds: 0.05)).succeeded)
    }

    @Test func promptRegisteredDuringStopIsRetainedForResumeWithoutSecondProcess() async throws {
        let context = try await makeContext(idleAfter: 1, stopGrace: 0.08)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let sessionID = UUID()
        let launch = try await launchClaude(
            sessionID: sessionID, conversationID: "claude-race",
            mode: "stubborn", context: context
        )
        _ = try await ready(launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        try await makeClaudeQuiet(
            launchSessionID: sessionID, runID: runID,
            conversationID: "claude-race", adapter: context.claude
        )
        try await context.lifecycle.captureProcessBaseline(sessionID: sessionID)
        try await context.catalog.markUsed(
            sessionID: sessionID, at: Date(timeIntervalSince1970: 10),
            reactivate: true
        )

        let evaluation = Task {
            try await context.lifecycle.evaluateIdle(
                sessionID: sessionID, at: Date(timeIntervalSince1970: 20)
            )
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while await context.supervisor.session(id: sessionID)?.currentRun?.state != .stopping,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let promptID = await context.lifecycle.registerPendingPrompt(sessionID: sessionID)
        let result = try await evaluation.value
        guard case let .interruptedByNewWork(report, pending) = result else {
            Issue.record("Prompt/idle race was not surfaced")
            return
        }
        #expect(report.succeeded)
        #expect(pending == [promptID])
        #expect(await context.lifecycle.pendingPromptIDs(sessionID: sessionID) == [promptID])
        #expect(await context.supervisor.session(id: sessionID)?.currentRun == nil)
        #expect(try await context.catalog.session(id: sessionID)?.lifecycle == .active)
        #expect((await context.supervisor.shutdown()).succeeded)
    }

    @Test func staleClassificationDoesNotReviveOnView() async throws {
        let context = try await makeContext(idleAfter: 1, staleAfter: 15)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let session = ManagedSession(
            provider: .codex, providerConversationID: "thread-old",
            workingDirectory: context.root.path
        )
        try await context.supervisor.createSession(session)
        try await context.catalog.markUsed(
            sessionID: session.id, at: Date(timeIntervalSince1970: 10),
            reactivate: true
        )
        try await context.catalog.updateLifecycle(sessionID: session.id, lifecycle: .idle)

        #expect(try await context.lifecycle.classifyStale(
            at: Date(timeIntervalSince1970: 30)
        ) == [session.id])
        try await context.lifecycle.markViewed(
            sessionID: session.id, at: Date(timeIntervalSince1970: 40)
        )
        #expect(try await context.catalog.session(id: session.id)?.lifecycle == .stale)
        try await context.lifecycle.reactivate(
            sessionID: session.id, at: Date(timeIntervalSince1970: 50)
        )
        #expect(try await context.catalog.session(id: session.id)?.lifecycle == .active)
        #expect((await context.supervisor.shutdown()).succeeded)
    }

    @Test func resumeProfilesKeepProviderIdentityAndMissingHistoryIsTyped() throws {
        let capabilities = ProviderCapabilities(
            version: "test",
            help: "--remote <ADDR> --session-id <id> --settings <settings>"
        )
        let claude = ManagedSession(
            provider: .claude, providerConversationID: "claude-id",
            workingDirectory: "/tmp/workspace"
        )
        let claudeProfile = try ProviderResumePlanner.claude(
            session: claude, capabilities: capabilities,
            config: URL(fileURLWithPath: "/tmp/config"), environment: [:]
        )
        #expect(Array(claudeProfile.arguments.prefix(2)) == ["--resume", "claude-id"])
        let codex = ManagedSession(
            provider: .codex, providerConversationID: "thread-id",
            workingDirectory: "/tmp/workspace"
        )
        let codexProfile = try ProviderResumePlanner.codex(
            session: codex, socketPath: "/tmp/app.sock",
            capabilities: capabilities, home: URL(fileURLWithPath: "/tmp/home"),
            environment: [:]
        )
        #expect(Array(codexProfile.arguments.prefix(2)) == ["resume", "thread-id"])
        #expect(codexProfile.arguments.suffix(2) == ["--remote", "unix:///tmp/app.sock"])

        let error = ProviderResumeDiagnostics.error(
            provider: .claude, conversationID: "missing",
            output: "No conversation found with session ID missing", exitStatus: 1
        )
        guard let loomError = error as? LoomError,
              case let .providerHistoryUnavailable(provider, conversationID) = loomError else {
            Issue.record("Missing provider history was not typed")
            return
        }
        #expect(provider == .claude)
        #expect(conversationID == "missing")

        let codexError = ProviderResumeDiagnostics.error(
            provider: .codex, conversationID: "missing",
            output: "ERROR: No saved session found with ID missing.", exitStatus: 1
        )
        guard let codexLoomError = codexError as? LoomError,
              case let .providerHistoryUnavailable(codexProvider, codexID) = codexLoomError else {
            Issue.record("Missing Codex provider history was not typed")
            return
        }
        #expect(codexProvider == .codex)
        #expect(codexID == "missing")
    }

    @Test func ambiguousNewThreadBlocksBothSameDirectorySessions() async throws {
        let context = try await makeContext(idleAfter: 1)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let adapter = CodexSessionAdapter(supervisor: context.supervisor)
        let router = CodexSessionRouter()
        var bindings: [CodexRunBinding] = []
        for index in 0..<2 {
            let plannedRunID = UUID(uuidString: [
                "22222222-2222-4222-8222-000000000001",
                "22222222-2222-4222-8222-000000000002",
            ][index])!
            let session = ManagedSession(
                provider: .codex, workingDirectory: context.root.path
            )
            try await context.supervisor.createSession(session)
            let environment = LaunchEnvironment.make(
                path: "/usr/bin:/bin",
                runID: context.supervisor.ownershipRunID, sessionID: session.id
            )
            let launch = try await context.supervisor.launch(
                sessionID: session.id, executable: childPath,
                arguments: ["stubborn"], environment: environment,
                managedRunID: plannedRunID
            )
            _ = try await ready(launch.terminal)
            let runID = try #require(launch.session.currentRun?.id)
            let binding = CodexRunBinding(
                sessionID: session.id, managedRunID: runID,
                threadID: "old-\(index)", workingDirectory: context.root.path
            )
            bindings.append(binding)
            try await adapter.bind(
                sessionID: session.id, runID: runID,
                threadID: binding.threadID, after: 0
            )
            try await context.supervisor.updateProviderWorkState(
                runID: runID, state: ProviderWorkState(activity: .turnComplete)
            )
            try await context.lifecycle.captureProcessBaseline(sessionID: session.id)
            try await context.catalog.markUsed(
                sessionID: session.id, at: Date(timeIntervalSince1970: 10),
                reactivate: true
            )
            await router.register(binding)
        }
        let decision = await router.route(.event(
            sequence: 10,
            .threadStarted(CodexThreadIdentity(
                id: "new-thread", workingDirectory: context.root.path,
                originator: "loom", source: "vscode"
            ))
        ))
        guard case let .ambiguous(candidates) = decision else {
            Issue.record("Same-cwd /new was not ambiguous")
            return
        }
        #expect(Set(candidates.map(\.managedRunID))
                == Set(bindings.map(\.managedRunID)))
        try await adapter.markAmbiguous(candidates)
        for binding in bindings {
            #expect(await context.supervisor.identityState(
                sessionID: binding.sessionID
            ) == .ambiguous)
            let result = try await context.lifecycle.evaluateIdle(
                sessionID: binding.sessionID,
                at: Date(timeIntervalSince1970: 20)
            )
            guard case let .blocked(blockers) = result else {
                Issue.record("Ambiguous session was stopped")
                continue
            }
            #expect(blockers.contains(.ambiguousIdentity))
            #expect(await context.supervisor.session(id: binding.sessionID)?
                    .currentRun != nil)
        }
        let snapshot = await context.supervisor.events.snapshot()
        #expect(bindings.allSatisfy {
            snapshot.sessions[$0.sessionID]?.identity == .ambiguous
        })
        #expect((await context.supervisor.shutdown(graceSeconds: 0.05)).succeeded)
    }

    @Test func tenFutureIdleDeadlinesUseOneSleepingTimer() async throws {
        let context = try await makeContext(idleAfter: 3_600)
        defer { try? FileManager.default.removeItem(at: context.root) }
        for _ in 0..<10 {
            let session = ManagedSession(
                provider: .synthetic, workingDirectory: context.root.path
            )
            try await context.supervisor.createSession(session)
            let environment = LaunchEnvironment.make(
                path: "/usr/bin:/bin",
                runID: context.supervisor.ownershipRunID, sessionID: session.id
            )
            let launch = try await context.supervisor.launch(
                sessionID: session.id, executable: childPath,
                arguments: ["stubborn"], environment: environment
            )
            _ = try await ready(launch.terminal)
            try await context.lifecycle.captureProcessBaseline(sessionID: session.id)
        }
        try await context.lifecycle.startAutomaticEvaluation()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await context.lifecycle.timerFireCount() == 0)
        await context.lifecycle.stopAutomaticEvaluation()
        #expect((await context.supervisor.shutdown(graceSeconds: 0.05)).succeeded)
    }

    @Test func automaticTimerTransitionsIdleThenStale() async throws {
        let context = try await makeContext(idleAfter: 0.1, staleAfter: 0.25)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let session = ManagedSession(
            provider: .synthetic, workingDirectory: context.root.path
        )
        try await context.supervisor.createSession(session)
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: context.supervisor.ownershipRunID,
            sessionID: session.id
        )
        let launch = try await context.supervisor.launch(
            sessionID: session.id, executable: childPath,
            arguments: ["stubborn"], environment: environment
        )
        _ = try await ready(launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        try await context.supervisor.updateProviderWorkState(
            runID: runID, state: ProviderWorkState(activity: .turnComplete)
        )
        try await context.lifecycle.captureProcessBaseline(sessionID: session.id)
        try await context.lifecycle.startAutomaticEvaluation()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var lifecycle = try await context.catalog.session(id: session.id)?.lifecycle
        while lifecycle != .stale,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
            lifecycle = try await context.catalog.session(id: session.id)?.lifecycle
        }
        #expect(lifecycle == .stale)
        #expect(await context.supervisor.session(id: session.id)?.currentRun == nil)
        #expect(await context.lifecycle.timerFireCount() >= 1)
        await context.lifecycle.stopAutomaticEvaluation()
        #expect((await context.supervisor.shutdown(graceSeconds: 0.05)).succeeded)
    }

    private struct Context {
        let root: URL
        let catalog: SessionCatalog
        let supervisor: ProcessSupervisor
        let claude: ClaudeSessionAdapter
        let lifecycle: SessionLifecycleController
    }

    private func makeContext(
        idleAfter: TimeInterval, staleAfter: TimeInterval = 15 * 24 * 60 * 60,
        stopGrace: Double = 0.05
    ) async throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-lifecycle-\(UUID())", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(coalition: .probe(forceFailure: true)),
            catalog: catalog
        )
        return Context(
            root: root, catalog: catalog, supervisor: supervisor,
            claude: ClaudeSessionAdapter(supervisor: supervisor),
            lifecycle: SessionLifecycleController(
                supervisor: supervisor, catalog: catalog,
                policy: SessionIdlePolicy(
                    idleAfter: idleAfter, staleAfter: staleAfter,
                    stopGraceSeconds: stopGrace
                )
            )
        )
    }

    private func launchClaude(
        sessionID: UUID, conversationID: String, mode: String, context: Context
    ) async throws -> ManagedSessionLaunch {
        try await context.supervisor.createSession(ManagedSession(
            id: sessionID, provider: .claude,
            providerConversationID: conversationID,
            workingDirectory: context.root.path
        ))
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: context.supervisor.ownershipRunID,
            sessionID: sessionID
        )
        return try await context.supervisor.launch(
            sessionID: sessionID, executable: childPath,
            arguments: [mode], environment: environment
        )
    }

    private func launchSynthetic(
        sessionID: UUID, mode: String, context: Context
    ) async throws -> ManagedSessionLaunch {
        try await context.supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic,
            workingDirectory: context.root.path
        ))
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: context.supervisor.ownershipRunID,
            sessionID: sessionID
        )
        return try await context.supervisor.launch(
            sessionID: sessionID, executable: childPath,
            arguments: [mode], environment: environment
        )
    }

    private func ready(_ terminal: TerminalEndpoint) async throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var output = Data()
        repeat {
            output.append(terminal.readAvailable())
            if let line = String(data: output, encoding: .utf8)?.split(separator: "\n").first {
                return String(line)
            }
            try await Task.sleep(for: .milliseconds(5))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LoomError.message("Fixture did not become ready")
    }

    private func makeClaudeQuiet(
        launchSessionID: UUID, runID: UUID, conversationID: String,
        adapter: ClaudeSessionAdapter
    ) async throws {
        _ = try await adapter.receive(try hook(
            launchSessionID: launchSessionID, runID: runID,
            conversationID: conversationID, event: "Stop"
        ))
    }

    private func hook(
        launchSessionID: UUID, runID: UUID, conversationID: String,
        event: String, fields: [String: Any] = [:]
    ) throws -> ClaudeHookEnvelope {
        var object: [String: Any] = [
            "session_id": conversationID, "hook_event_name": event,
            "cwd": "/tmp/workspace",
        ]
        object.merge(fields) { _, new in new }
        return ClaudeHookEnvelope(
            sessionID: launchSessionID, managedRunID: runID,
            payload: try JSONSerialization.data(withJSONObject: object)
        )
    }
}
