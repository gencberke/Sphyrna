import Foundation
import Testing
@testable import LoomCore

private actor IdleReliabilityGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class LifecycleTestBundleAnchor: NSObject {}

/// Fails the first `failing` calls, then lets them through.
private final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var total = 0
    init(failing: Int) { remaining = failing }
    func next() -> Bool {
        lock.withLock {
            total += 1
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
    var calls: Int { lock.withLock { total } }
}

private final class FailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var isOn: Bool { lock.withLock { on } }
    func turnOff() { lock.withLock { on = false } }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
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
        #expect((await context.supervisor.shutdown(graceSeconds: 0.2)).succeeded)
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
        #expect((await context.supervisor.shutdown(graceSeconds: 0.2)).succeeded)
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

    /// Contract section 5: stale follows time since last use, not how the
    /// conversation ended. A stopped (never idle) conversation ages out; a live
    /// run never does; viewing keeps stale.
    @Test func conversationsEndedByStopAgeIntoStaleButLiveRunsDoNot() async throws {
        let context = try await makeContext(idleAfter: 1, staleAfter: 15)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let ended = ManagedSession(
            provider: .codex, providerConversationID: "thread-ended", workingDirectory: context.root.path
        )
        try await context.supervisor.createSession(ended)
        try await context.catalog.markUsed(
            sessionID: ended.id, at: Date(timeIntervalSince1970: 10), reactivate: true
        )
        let liveID = UUID()
        let live = try await launchSynthetic(sessionID: liveID, mode: "stubborn", context: context)
        _ = try await ready(live.terminal)
        try await context.catalog.markUsed(
            sessionID: liveID, at: Date(timeIntervalSince1970: 10), reactivate: true
        )
        #expect(try await context.catalog.session(id: ended.id)?.lifecycle == .active)

        #expect(try await context.lifecycle.classifyStale(at: Date(timeIntervalSince1970: 30)) == [ended.id])
        #expect(try await context.catalog.session(id: liveID)?.lifecycle == .active)
        try await context.lifecycle.markViewed(sessionID: ended.id, at: Date(timeIntervalSince1970: 40))
        #expect(try await context.catalog.session(id: ended.id)?.lifecycle == .stale)
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
        #expect(Array(codexProfile.arguments.dropFirst(2).prefix(2)) == ["--remote", "unix:///tmp/app.sock"])
        #expect(codexProfile.arguments.suffix(2) == ["--cd", "/tmp/workspace"])

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
        guard case let .ambiguous(candidates, threadID) = decision else {
            Issue.record("Same-cwd /new was not ambiguous")
            return
        }
        #expect(threadID == "new-thread")
        #expect(Set(candidates.map(\.managedRunID))
                == Set(bindings.map(\.managedRunID)))
        try await adapter.markAmbiguous(candidates, threadID: threadID)
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
        let first = bindings[0]
        try await context.supervisor.registerStopHooks(
            runID: first.managedRunID,
            hooks: ManagedRunStopHooks(
                prepare: {
                    try await adapter.verifyAmbiguousStop(runID: first.managedRunID) { id in
                        CodexThreadSnapshot(
                            threadID: id, lastTurnID: "active-turn",
                            lastTurnStartedAt: nil, lastTurnOutcome: nil,
                            lastAssistantMessage: nil, isActive: true,
                            status: .active([])
                        )
                    }
                },
                completed: {}
            )
        )
        let stop = try await context.supervisor.stop(
            sessionID: first.sessionID, graceSeconds: 0.2
        )
        #expect(!stop.succeeded)
        #expect(stop.providerStages?.first?.stage == "prepare")
        #expect(stop.providerStages?.first?.outcome == "failed")
        #expect(stop.providerStages?.first?.errorCategory == "protocolViolation")
        #expect(await context.supervisor.session(id: first.sessionID)?.currentRun != nil)
        #expect((await context.supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    // MARK: O-2 F2: a persistent child must not keep the idle check spinning

    private func descendantContext(
        extraHook: [String: Any]
    ) async throws -> (Context, UUID) {
        let context = try await makeContext(
            idleAfter: 0.05, recheck: .init(initial: 0.02, cap: 0.32)
        )
        let id = UUID()
        let launch = try await launchClaude(
            sessionID: id, conversationID: "claude-child", mode: "spawn-on-input", context: context
        )
        _ = try await ready(launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        try await context.lifecycle.captureProcessBaseline(sessionID: id)
        try await context.catalog.markUsed(sessionID: id, at: Date().addingTimeInterval(-10), reactivate: true)
        _ = try await context.claude.receive(try hook(
            launchSessionID: id, runID: runID, conversationID: "claude-child",
            event: "Stop", fields: extraHook
        ))
        _ = try await launch.terminal.write(Data("spawn\n".utf8))
        try await Task.sleep(for: .milliseconds(80))
        return (context, id)
    }

    @Test func persistentChildAsSoleBlockerIsRecheckedWithBackoffNotEveryInterval() async throws {
        let (context, id) = try await descendantContext(extraHook: [:])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let parked = AsyncStream<SessionEventFrame>.makeStream()
        try await context.lifecycle.startAutomaticEvaluation(stream: parked.stream)
        // 0.6 s at this scale stands for the 5, 10, 20, 40 ... s schedule over
        // a minute: a handful of checks, not one per base interval (~30).
        try await Task.sleep(for: .milliseconds(600))
        let fires = await context.lifecycle.timerFireCount()
        #expect(fires >= 3, "the child must still be re-checked")
        #expect(fires <= 7, "re-checks must back off, got \(fires)")
        #expect(await context.supervisor.session(id: id)?.currentRun != nil)
        await context.lifecycle.stopAutomaticEvaluation()
        parked.continuation.finish()
        #expect((await context.supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func eventDrivenBlockersAreNotRecheckedEvenWithAChildAlive() async throws {
        let (context, _) = try await descendantContext(
            extraHook: ["background_tasks": [["id": "task"]]]
        )
        defer { try? FileManager.default.removeItem(at: context.root) }
        let parked = AsyncStream<SessionEventFrame>.makeStream()
        try await context.lifecycle.startAutomaticEvaluation(stream: parked.stream)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await context.lifecycle.timerFireCount() == 1)
        await context.lifecycle.stopAutomaticEvaluation()
        parked.continuation.finish()
        #expect((await context.supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func recheckScheduleDoublesFromFiveToThreeHundredSeconds() {
        let schedule = SessionLifecycleController.DescendantRecheckSchedule()
        var interval: TimeInterval?
        var seen: [TimeInterval] = []
        for _ in 0..<9 { interval = schedule.next(after: interval); seen.append(interval!) }
        #expect(seen == [5, 10, 20, 40, 80, 160, 300, 300, 300])
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
        #expect((await context.supervisor.shutdown(graceSeconds: 0.2)).succeeded)
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
        #expect((await context.supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    @Test func aCatalogErrorInTheTimerDoesNotEndTheChainTheClassificationIsRetried() async throws {
        let context = try await makeContext(idleAfter: 0.1, staleAfter: 0.25)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let session = ManagedSession(provider: .synthetic, workingDirectory: context.root.path)
        try await context.supervisor.createSession(session)
        let failures = FailureCounter(failing: 1)
        await context.catalog.setReadFailpointForTesting {
            if failures.next() { throw SessionCatalogError.sqlite(operation: "read", code: 5, message: "database is locked") }
        }
        await context.lifecycle.setTimerRetryDelayForTesting(0.05)
        try await context.lifecycle.startAutomaticEvaluation()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var lifecycle = try await context.catalog.session(id: session.id)?.lifecycle
        while lifecycle != .stale, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
            lifecycle = try await context.catalog.session(id: session.id)?.lifecycle
        }
        #expect(lifecycle == .stale)
        #expect(failures.calls >= 2)          // the failed call and the retry
        await context.lifecycle.stopAutomaticEvaluation()
    }

    @Test func coalescedCompletionReopensBlockedIdleAndRepeatedSnapshotsDoNoWork() async throws {
        let context = try await makeContext(idleAfter: 0.05, staleAfter: 3600)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = UUID()
        let launch = try await launchSynthetic(sessionID: id, mode: "stubborn", context: context)
        _ = try await ready(launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        try await context.lifecycle.captureProcessBaseline(sessionID: id)
        try await context.catalog.markUsed(sessionID: id, at: Date().addingTimeInterval(-10), reactivate: true)
        // Keep the controller's consumer parked. The real hub still supplies
        // a newest(1) stream whose status event is overwritten before delivery.
        let parked = AsyncStream<SessionEventFrame>.makeStream()
        try await context.lifecycle.startAutomaticEvaluation(stream: parked.stream)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while await context.lifecycle.automaticEvaluationCompletionCount() == 0,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await context.lifecycle.timerFireCount() == 1)
        #expect(await context.lifecycle.automaticEvaluationCompletionCount() == 1)
        let buffered = await context.supervisor.events.subscribe()
        try await context.supervisor.updateProviderWorkState(runID: runID, state: ProviderWorkState(activity: .turnComplete))
        await context.supervisor.events.publish(sessionID: id, change: .issue("fixture issue"))
        var iterator = buffered.makeAsyncIterator()
        let delivered = try #require(await iterator.next())
        #expect(delivered.change == .issue("fixture issue"))
        let prior = await context.lifecycle.automaticScheduleRevision()
        await context.lifecycle.handle(delivered)
        #expect(await context.lifecycle.automaticScheduleRevision() > prior)
        let stopDeadline = ProcessInfo.processInfo.systemUptime + 2
        // currentRun becomes nil inside evaluateIdle's awaited Stop, before
        // catalog lifecycle publication and the timer's final reschedule. Wait
        // for that complete evaluation, so its legitimate work cannot be
        // attributed to either duplicate snapshot below.
        while await context.lifecycle.automaticEvaluationCompletionCount() < 2,
              ProcessInfo.processInfo.systemUptime < stopDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await context.lifecycle.automaticEvaluationCompletionCount() == 2)
        #expect(await context.supervisor.session(id: id)?.currentRun == nil)
        #expect(try await context.catalog.session(id: id)?.lifecycle == .idle)
        let snapshot = await context.supervisor.events.snapshot()
        await context.lifecycle.handle(snapshot)
        let settled = await context.lifecycle.automaticScheduleRevision()
        let reads = await context.catalog.decodedSessionRows
        await context.lifecycle.handle(snapshot)
        #expect(await context.lifecycle.automaticScheduleRevision() == settled)
        #expect(await context.catalog.decodedSessionRows == reads)
        await context.lifecycle.stopAutomaticEvaluation()
        parked.continuation.finish()
        #expect((await context.supervisor.shutdown()).succeeded)
    }

    @Test func coalescedRunStartInIssueFrameSchedulesWithoutPolling() async throws {
        let context = try await makeContext(idleAfter: 3600)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let parked = AsyncStream<SessionEventFrame>.makeStream()
        try await context.lifecycle.startAutomaticEvaluation(stream: parked.stream)
        let stream = await context.supervisor.events.subscribe()
        let id = UUID()
        let launch = try await launchSynthetic(sessionID: id, mode: "stubborn", context: context)
        _ = try await ready(launch.terminal)
        await context.supervisor.events.publish(sessionID: id, change: .issue("fixture issue"))
        var iterator = stream.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        #expect(frame.change == .issue("fixture issue"))
        let before = await context.lifecycle.automaticScheduleRevision()
        await context.lifecycle.handle(frame)
        #expect(await context.lifecycle.automaticScheduleRevision() > before)
        let revision = await context.lifecycle.automaticScheduleRevision()
        let reads = await context.catalog.decodedSessionRows
        await context.lifecycle.handle(frame)
        #expect(await context.lifecycle.automaticScheduleRevision() == revision)
        #expect(await context.catalog.decodedSessionRows == reads)
        #expect(await context.lifecycle.timerFireCount() == 0)
        await context.lifecycle.stopAutomaticEvaluation()
        parked.continuation.finish()
        #expect((await context.supervisor.shutdown(graceSeconds: 0.02)).succeeded)
    }

    @Test func overflowedAuthorityIngressStaysUnknownBlocksIdleAndRejectsFurtherHooks() async throws {
        let context = try await makeContext(idleAfter: 1)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = UUID()
        let launch = try await launchClaude(sessionID: id, conversationID: "A", mode: "stubborn", context: context)
        _ = try await ready(launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        _ = try await context.claude.receive(try hook(launchSessionID: id, runID: runID, conversationID: "A", event: "SessionStart"))
        try await makeClaudeQuiet(launchSessionID: id, runID: runID, conversationID: "A", adapter: context.claude)
        try await context.lifecycle.captureProcessBaseline(sessionID: id)
        try await context.catalog.markUsed(sessionID: id, at: Date().addingTimeInterval(-10), reactivate: true)
        let ingress = ClaudeHookIngress(adapter: context.claude, capacity: 1)
        // No consumer is running: a newer envelope overwrites the identity
        // delta and the fault must survive independently of that bounded queue.
        ingress.receive(try hook(launchSessionID: id, runID: runID, conversationID: "A", event: "UserPromptSubmit"))
        ingress.receive(try hook(launchSessionID: id, runID: runID, conversationID: "B", event: "SessionStart", fields: ["source": "clear"]))
        #expect(await context.supervisor.providerWorkState(sessionID: id)?.activity == .unknown)
        var iterator = ingress.stream.makeAsyncIterator()
        let latest = try #require(await iterator.next())
        _ = try await context.claude.receive(latest)
        _ = try await context.claude.receive(try hook(launchSessionID: id, runID: runID, conversationID: "B", event: "Stop"))
        #expect(await context.supervisor.activeSessionID(runID: runID) == id)
        #expect(await context.claude.status(sessionID: id)?.activity == .unknown)
        let result = try await context.lifecycle.evaluateIdle(sessionID: id)
        if case let .blocked(reasons) = result { #expect(reasons.contains(.unknownAgentState)) }
        else { Issue.record("Overflow must block automatic idle, even after later completion hooks") }
        let warningDeadline = ProcessInfo.processInfo.systemUptime + 2
        while await context.supervisor.events.snapshot().sessions[id]?.issue == nil,
              ProcessInfo.processInfo.systemUptime < warningDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await context.supervisor.events.snapshot().sessions[id]?.issue != nil)
        #expect((await context.supervisor.shutdown(graceSeconds: 0.02)).succeeded)
    }

    @Test func hookLossDuringIdlePreparationRefusesSignalsButExplicitStopStillWorks() async throws {
        let context = try await makeContext(idleAfter: 1)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = UUID()
        let launch = try await launchClaude(sessionID: id, conversationID: "A", mode: "stubborn", context: context)
        _ = try await ready(launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        try await makeClaudeQuiet(launchSessionID: id, runID: runID, conversationID: "A", adapter: context.claude)
        try await context.lifecycle.captureProcessBaseline(sessionID: id)
        try await context.catalog.markUsed(sessionID: id, at: Date().addingTimeInterval(-10), reactivate: true)
        let gate = IdleReliabilityGate()
        try await context.supervisor.registerStopHooks(runID: runID, hooks: ManagedRunStopHooks(
            prepare: { await gate.wait() }, completed: {}
        ))
        let evaluation = Task { try await context.lifecycle.evaluateIdle(sessionID: id) }
        while !(await gate.entered) { try await Task.sleep(for: .milliseconds(1)) }
        context.claude.noteHookLoss(runID: runID)
        await gate.release()
        let outcome = try await evaluation.value
        if case let .stopFailed(report) = outcome {
            #expect(report.signals.isEmpty)
            #expect(report.errors.contains { $0.contains("unreliable") })
        } else { Issue.record("Late hook loss must refuse the automatic stop") }
        #expect(await context.supervisor.session(id: id)?.currentRun?.id == runID)
        #expect(try await context.supervisor.stop(sessionID: id, graceSeconds: 0.02).succeeded)
        #expect((await context.supervisor.shutdown()).succeeded)
    }

    /// A deletion whose stop could not be verified keeps the conversation's input closed (contract
    /// 8.1). An idle evaluation that also fails to stop must not reopen it.
    @Test func anIdleEvaluationLeavesTheInputClosedThatADeletionClosed() async throws {
        let context = try await makeContext(idleAfter: 1)
        defer { try? FileManager.default.removeItem(at: context.root) }
        let id = UUID()
        let launch = try await launchClaude(sessionID: id, conversationID: "A", mode: "stubborn", context: context)
        _ = try await ready(launch.terminal)
        let runID = try #require(launch.session.currentRun?.id)
        try await makeClaudeQuiet(launchSessionID: id, runID: runID, conversationID: "A", adapter: context.claude)
        try await context.lifecycle.captureProcessBaseline(sessionID: id)
        try await context.catalog.markUsed(sessionID: id, at: Date().addingTimeInterval(-10), reactivate: true)
        let failing = FailureSwitch()
        try await context.supervisor.registerStopHooks(runID: runID, hooks: ManagedRunStopHooks(
            prepare: { if failing.isOn { throw LoomError.message("provider work still running") } }, completed: {}
        ))
        let queue = TerminalInputQueue(endpoint: launch.terminal, onError: { _ in })
        context.gate.register(runID: runID, queue: queue)
        try await context.catalog.beginDeletion(
            sessionID: id,
            plan: CatalogDeletionPlan(provider: .claude, providerIDs: ["A"], configDirectory: nil, workingDirectory: nil))
        context.gate.close(runID: runID, reason: "This conversation is being deleted")
        #expect(!queue.enqueue(Array("typed before".utf8)))

        let outcome = try await context.lifecycle.evaluateIdle(sessionID: id)
        if case .transitioned = outcome { Issue.record("a conversation being deleted must not idle out") }
        #expect(!queue.enqueue(Array("typed after".utf8)))
        #expect(await context.supervisor.session(id: id)?.currentRun?.id == runID)
        failing.turnOff()
        #expect(try await context.supervisor.stop(sessionID: id, graceSeconds: 0.02).succeeded)
        #expect((await context.supervisor.shutdown()).succeeded)
    }

    private struct Context {
        let root: URL
        let catalog: SessionCatalog
        let supervisor: ProcessSupervisor
        let claude: ClaudeSessionAdapter
        let lifecycle: SessionLifecycleController
        let gate: TerminalInputGate
    }

    private func makeContext(
        idleAfter: TimeInterval, staleAfter: TimeInterval = 15 * 24 * 60 * 60,
        stopGrace: Double = 0.05,
        recheck: SessionLifecycleController.DescendantRecheckSchedule = .init()
    ) async throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-lifecycle-\(UUID())", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("sessions.sqlite3"))
        let supervisor = try ProcessSupervisor(
            ledger: OwnershipLedger(),
            catalog: catalog
        )
        let gate = TerminalInputGate()
        return Context(
            root: root, catalog: catalog, supervisor: supervisor,
            claude: ClaudeSessionAdapter(supervisor: supervisor),
            lifecycle: SessionLifecycleController(
                supervisor: supervisor, catalog: catalog,
                policy: SessionIdlePolicy(
                    idleAfter: idleAfter, staleAfter: staleAfter,
                    stopGraceSeconds: stopGrace
                ),
                inputGate: gate,
                recheckSchedule: recheck
            ),
            gate: gate
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
