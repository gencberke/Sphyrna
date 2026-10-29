import Foundation
import Testing
@testable import LoomCore

private extension SessionRuntime {
    func injectActiveNativeSnapshotForTaskTest(_ binding: SessionTaskBinding) async throws {
        let sequence = await runs[binding.managedRunID]?.server?.client?.latestSequence() ?? 0
        let snapshot = CodexThreadSnapshot(threadID: binding.nativeSessionID, lastTurnID: nil, lastTurnStartedAt: nil,
            lastTurnOutcome: nil, lastAssistantMessage: nil, isActive: true, status: .active([]))
        _ = try await harnesses.codex.adapter.refresh(snapshot, runID: binding.managedRunID,
                                                      after: sequence + 100, backgroundTerminalCount: 0)
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct SessionTaskRuntimeStatusTests {
    @Test func nativeStatusTracksOnlyTheOwnedLiveRunAndProviderReadiness() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
        let binding = try #require(await context.runtime.authenticateTaskRun(claim))
        let host = SessionTaskRuntimeHost(runtime: context.runtime)
        #expect(try await SessionRuntimeTests.waitUntil(3) { await host.nativeStatus(binding: binding) == .ready })
        try await context.supervisor.setIdentityState(.ambiguous, runID: launch.runID)
        #expect(await context.runtime.authenticateTaskRun(claim) == nil)
        #expect(await host.nativeStatus(binding: binding) == .unknown)
        try await context.supervisor.setIdentityState(.known, runID: launch.runID)
        #expect(await context.runtime.authenticateTaskRun(claim) == binding)
        try await screen.send("/work 700")
        #expect(await screen.contains("WORKING 700"))
        #expect(try await SessionRuntimeTests.waitUntil(2) { await host.nativeStatus(binding: binding) == .working })
        #expect(try await SessionRuntimeTests.waitUntil(3) { await host.nativeStatus(binding: binding) == .ready })
        try await screen.send("/approve")
        #expect(await screen.contains("NEEDS-APPROVAL"))
        #expect(try await SessionRuntimeTests.waitUntil(2) { await host.nativeStatus(binding: binding) == .waitingForUser })
        let stale = SessionTaskBinding(sessionID: binding.sessionID, nativeSessionID: binding.nativeSessionID,
                                       managedRunID: binding.managedRunID, generation: UUID())
        #expect(await host.nativeStatus(binding: stale) == .unknown)
        try await screen.send("n")
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(await host.nativeStatus(binding: binding) == .stopped)
        #expect(await host.nativeStatus(binding: stale) == .unknown)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func codexReadinessRequiresNativeIdleWhenTheWorkSummaryDisagrees() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        do {
            let launch = try await context.runtime.startConversation(provider: .codex, projectID: nil)
            let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
            let binding = try #require(await context.runtime.authenticateTaskRun(claim))
            let host = SessionTaskRuntimeHost(runtime: context.runtime)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await host.nativeStatus(binding: binding) == .ready })
            try await context.runtime.injectActiveNativeSnapshotForTaskTest(binding)
            #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .working)
            #expect(await host.nativeStatus(binding: binding) != .ready)
        } catch { Issue.record("native readiness fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func claudeReadinessFollowsTheOwnedRegistryEvenWithoutANewHook() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_REGISTRY_CONTROL": "1"])
        defer { context.cleanup() }
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
        let binding = try #require(await context.runtime.authenticateTaskRun(claim))
        let host = SessionTaskRuntimeHost(runtime: context.runtime)
        #expect(try await SessionRuntimeTests.waitUntil(3) { await host.nativeStatus(binding: binding) == .ready })
        try await screen.send("/fake-registry-busy")
        #expect(await screen.contains("FAKE-REGISTRY-BUSY"))
        #expect(try await SessionRuntimeTests.waitUntil(3) { await host.nativeStatus(binding: binding) != .ready })
        try await screen.send("/fake-registry-idle")
        #expect(await screen.contains("FAKE-REGISTRY-IDLE"))
        #expect(try await SessionRuntimeTests.waitUntil(3) { await host.nativeStatus(binding: binding) == .ready })
        #expect((await context.runtime.shutdown()).succeeded)
    }

}
