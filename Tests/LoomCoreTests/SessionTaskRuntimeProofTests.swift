import CryptoKit
import Foundation
import Testing
@testable import LoomCore

private extension SessionRuntime {
    func taskServerIDForTest(runID: UUID) -> UUID? { runs[runID]?.server?.id }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct SessionTaskRuntimeProofTests {
    @Test func matchingPromptBeforeTheGuardedWriteCannotProveConsumption() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
        let binding = try #require(await context.runtime.authenticateTaskRun(claim))
        let purpose = SessionTaskExpectedInput.Purpose.child(taskID: UUID(), roundID: UUID(), operationID: UUID())
        let effect = SessionTaskInputEffectMarker()
        let digest = Data(SHA256.hash(data: Data("matching text before write".utf8)))
        #expect(await context.runtime.prepareTaskInput(purpose: purpose, binding: binding, digest: digest, effect: effect))
        try await screen.send("matching text before write")
        #expect(await screen.contains("echo: matching text before write"))
        #expect(try await SessionRuntimeTests.waitUntil(2) { await context.runtime.taskExpectedInputs[binding.managedRunID] == nil })
        #expect(await context.runtime.taskRunPlans[launch.sessionID]?.lease.hasUnclassifiedInput == true)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func laterUserInputPreventsTheEarlierTicketFromProvingACleanInput() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
        let binding = try #require(await context.runtime.authenticateTaskRun(claim))
        let queue = TerminalInputQueue(endpoint: launch.terminal, onError: { _ in })
        context.runtime.inputGate.register(runID: launch.runID, queue: queue)
        #expect(context.runtime.inputGate.establishFreshCleanInput(runID: launch.runID))
        let ticket = try #require(context.runtime.inputGate.reserveAutomaticInput(runID: launch.runID))
        let task = UUID(), round = UUID(), operation = UUID()
        let target = SessionTaskRoundTarget(taskID: task, roundID: round, inputOperationID: operation,
                                            binding: binding, nativeTurnID: nil, execution: nil)
        let purpose = SessionTaskExpectedInput.Purpose.child(taskID: task, roundID: round, operationID: operation)
        let effect = SessionTaskInputEffectMarker(); _ = effect.write { 1 }
        let digest = Data(SHA256.hash(data: Data("owned synthetic pointer".utf8)))
        #expect(await context.runtime.prepareTaskInput(purpose: purpose, binding: binding, digest: digest,
                                                       effect: effect, ticket: ticket))
        context.runtime.inputGate.noteUnclassifiedInput(runID: launch.runID)
        try await screen.send("owned synthetic pointer")
        #expect(await screen.contains("echo: owned synthetic pointer"))
        let host = SessionTaskRuntimeHost(runtime: context.runtime)
        #expect(await host.observedChildExecution(target) == nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func codexInputObservationMustMatchTheOwnedTurnStartReceipt() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let launch = try await context.runtime.startConversation(provider: .codex, projectID: nil)
        let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        let binding = try #require(await context.runtime.authenticateTaskRun(claim))
        let serverID = try #require(await context.runtime.taskServerIDForTest(runID: launch.runID))
        let task = UUID(), round = UUID(), operation = UUID()
        let purpose = SessionTaskExpectedInput.Purpose.child(taskID: task, roundID: round, operationID: operation)
        let target = SessionTaskRoundTarget(taskID: task, roundID: round, inputOperationID: operation,
                                            binding: binding, nativeTurnID: nil, execution: nil)
        let digest = Data(SHA256.hash(data: Data("owned pointer".utf8))), effect = SessionTaskInputEffectMarker()
        _ = effect.write { 1 }
        #expect(await context.runtime.prepareTaskInput(purpose: purpose, binding: binding, digest: digest,
                                                       effect: effect, requiresNativeReceipt: true))
        await context.runtime.observeCodexTaskInput(serverID: serverID,
            observation: CodexTaskInputObservation(sequence: 1, threadID: binding.nativeSessionID,
                                                    turnID: "real-turn", digest: digest))
        let host = SessionTaskRuntimeHost(runtime: context.runtime)
        let proof = Task { await host.observedChildExecution(target) }
        #expect(try await SessionRuntimeTests.waitUntil(2) { await context.runtime.taskProofWaiters.count == 1 })
        #expect(await context.runtime.confirmCodexTaskTurn("other-turn", purpose: purpose, binding: binding) == false)
        #expect(await context.runtime.taskExpectedInputs[binding.managedRunID]?.confirmedObservation == nil)
        #expect(await context.runtime.confirmCodexTaskTurn("real-turn", purpose: purpose, binding: binding))
        #expect(await proof.value == .nativeTurn("real-turn"))
        #expect((await context.runtime.shutdown()).succeeded)
    }
    @Test func claudeAcceptedPromptProvesOnlyTheExactLiveTaskInput() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
        let binding = try #require(await context.runtime.authenticateTaskRun(claim))
        let task = UUID(), round = UUID(), operation = UUID()
        let target = SessionTaskRoundTarget(taskID: task, roundID: round, inputOperationID: operation,
                                            binding: binding, nativeTurnID: nil, execution: nil)
        let digest = Data(SHA256.hash(data: Data("owned synthetic pointer".utf8)))
        let effect = SessionTaskInputEffectMarker()
        _ = effect.write { 1 }
        #expect(await context.runtime.prepareTaskInput(purpose: .child(taskID: task, roundID: round, operationID: operation),
                                                       binding: binding, digest: digest, effect: effect))
        try await screen.send("owned synthetic pointer")
        #expect(await screen.contains("echo: owned synthetic pointer"))
        let host = SessionTaskRuntimeHost(runtime: context.runtime)
        #expect(try await SessionRuntimeTests.waitUntil(2) { await host.observedChildExecution(target) != nil })
        let proof = await host.observedChildExecution(target)
        if case let .providerPrompt(id) = proof { #expect(!id.isEmpty) }
        else { Issue.record("An accepted fake Claude hook must supply its native prompt ID") }
        let stale = SessionTaskRoundTarget(taskID: task, roundID: UUID(), inputOperationID: operation,
                                           binding: binding, nativeTurnID: nil, execution: nil)
        #expect(await host.observedChildExecution(stale) == nil)
        try await screen.send("different user input")
        #expect(await screen.contains("echo: different user input"))
        #expect(try await SessionRuntimeTests.waitUntil(2) { await host.observedChildExecution(target) == nil })
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(await host.observedChildExecution(target) == nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
