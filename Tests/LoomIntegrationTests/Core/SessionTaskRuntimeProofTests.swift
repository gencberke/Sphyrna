import CryptoKit
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

private extension SessionRuntime {
    func taskServerIDForTest(runID: UUID) -> UUID? { runs[runID]?.server?.id }
}

private final class QuiescenceBurstProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = 0
    private var nativeStatus = 0
    private var displayedStatus = 0
    func publish(_ value: Int) { lock.withLock { nativeStatus = value } }
    func notify() { lock.withLock { scheduled += 1 } }
    func consume() -> Int { lock.withLock { displayedStatus = nativeStatus; return displayedStatus } }
    var notifications: Int { lock.withLock { scheduled } }
    var currentDisplay: Int { lock.withLock { displayedStatus } }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct SessionTaskRuntimeProofTests {
    @Test func quiescenceBurstKeepsOnePendingCallbackAndRechecksTheFinalStatus() throws {
        let lease = SessionTaskRunLease(), probe = QuiescenceBurstProbe()
        lease.observeQuiescence { probe.notify() }
        let before = try #require(lease.admit { $0 })
        lease.beginHook(); probe.publish(1); lease.finishHook()
        #expect(probe.notifications == 1)
        let firstObserved = probe.consume()
        for index in 2...1_000 {
            lease.beginHook()
            lease.beginCodexEvent(UInt64(index))
            probe.publish(index)
            lease.finishHook()
            lease.finishCodexEvent(UInt64(index))
        }
        #expect(probe.notifications == 1, "a held consumer must not accumulate callbacks")
        #expect(!lease.permits(revision: before), "coalescing must not weaken input admission")
        // If another input is arriving when the consumer finishes, its final
        // drain must still schedule the one recheck for the latest state.
        lease.beginHook()
        lease.finishQuiescenceNotification()
        #expect(probe.notifications == 1)
        lease.finishHook()
        #expect(probe.notifications == 2)
        _ = probe.consume()
        #expect(firstObserved == 1 && probe.currentDisplay == 1_000)
        lease.finishQuiescenceNotification()
        #expect(probe.notifications == 2)
    }

    @Test func aDeferredFollowupRestoresOnlyThePriorProvedExecution() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        do {
            let screen = SessionRuntimeRig.Screen()
            let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
            screen.attach(launch.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
            #expect(try await SessionRuntimeRig.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let binding = try #require(await context.runtime.authenticateTaskRun(claim))
            let task = UUID(), round = UUID(), operation = UUID()
            let oldPurpose = SessionTaskExpectedInput.Purpose.child(taskID: task, roundID: round, operationID: operation)
            let target = SessionTaskRoundTarget(taskID: task, roundID: round, inputOperationID: operation,
                                               binding: binding, nativeTurnID: nil, execution: nil)
            let oldEffect = SessionTaskInputEffectMarker(); _ = oldEffect.write { 1 }
            let oldDigest = Data(SHA256.hash(data: Data("first owned pointer".utf8)))
            #expect(await context.runtime.prepareTaskInput(purpose: oldPurpose, binding: binding,
                                                           digest: oldDigest, effect: oldEffect))
            try await screen.send("first owned pointer")
            let host = SessionTaskRuntimeHost(runtime: context.runtime)
            #expect(try await SessionRuntimeRig.waitUntil(3) { await host.observedChildExecution(target) != nil })
            let old = try #require(await host.observedChildExecution(target))
            let next = SessionTaskExpectedInput.Purpose.child(taskID: task, roundID: UUID(), operationID: UUID())
            let nextDigest = Data(SHA256.hash(data: Data("second owned pointer".utf8)))
            let deferred = SessionTaskInputEffectMarker()
            #expect(await context.runtime.prepareTaskInput(purpose: next, binding: binding, digest: nextDigest, effect: deferred))
            #expect(await host.observedChildExecution(target) == nil)
            await context.runtime.clearTaskExpectation(next, binding: binding)
            #expect(await host.observedChildExecution(target) == old)
            let admitted = SessionTaskInputEffectMarker()
            #expect(await context.runtime.prepareTaskInput(purpose: next, binding: binding, digest: nextDigest, effect: admitted))
            _ = admitted.write { 1 }
            await context.runtime.clearTaskExpectation(next, binding: binding)
            #expect(await host.observedChildExecution(target) == nil)
        } catch { Issue.record("follow-up proof fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func takeoverRevocationCannotCrossAProviderIngress() throws {
        let lease = SessionTaskRunLease()
        let shown = try #require(lease.admit { $0 })
        lease.beginHook()
        #expect(!lease.revokeIfCurrent(revision: shown))
        lease.finishHook()
        #expect(!lease.revokeIfCurrent(revision: shown), "a consumed event still invalidates the old view")
        let current = try #require(lease.admit { $0 })
        #expect(lease.revokeIfCurrent(revision: current))
        #expect(lease.admit { _ in true } == nil)
    }
    @Test func matchingPromptBeforeTheGuardedWriteCannotProveConsumption() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let screen = SessionRuntimeRig.Screen()
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(try await SessionRuntimeRig.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
        let binding = try #require(await context.runtime.authenticateTaskRun(claim))
        let purpose = SessionTaskExpectedInput.Purpose.child(taskID: UUID(), roundID: UUID(), operationID: UUID())
        let effect = SessionTaskInputEffectMarker()
        let digest = Data(SHA256.hash(data: Data("matching text before write".utf8)))
        #expect(await context.runtime.prepareTaskInput(purpose: purpose, binding: binding, digest: digest, effect: effect))
        try await screen.send("matching text before write")
        #expect(await screen.contains("echo: matching text before write"))
        #expect(try await SessionRuntimeRig.waitUntil(2) { await context.runtime.taskExpectedInputs[binding.managedRunID] == nil })
        #expect(await context.runtime.taskRunPlans[launch.sessionID]?.lease.hasUnclassifiedInput == true)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func keyBeforeNativeProofKeepsExecutionButNotTheEditorClean() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let screen = SessionRuntimeRig.Screen()
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(try await SessionRuntimeRig.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
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
        #expect(await host.observedChildExecution(target) != nil)
        #expect(context.runtime.inputGate.reserveAutomaticInput(runID: launch.runID) == nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func codexInputObservationMustMatchTheOwnedTurnStartReceipt() async throws {
        let context = try await SessionRuntimeRig.makeContext()
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
        #expect(try await SessionRuntimeRig.waitUntil(2) { await context.runtime.taskProofWaiters.count == 1 })
        #expect(await context.runtime.confirmCodexTaskTurn("other-turn", purpose: purpose, binding: binding) == false)
        #expect(await context.runtime.taskExpectedInputs[binding.managedRunID]?.confirmedObservation == nil)
        #expect(await context.runtime.confirmCodexTaskTurn("real-turn", purpose: purpose, binding: binding))
        #expect(await proof.value == .nativeTurn("real-turn"))
        #expect((await context.runtime.shutdown()).succeeded)
    }
    @Test func claudeAcceptedPromptProvesOnlyTheExactLiveTaskInput() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let screen = SessionRuntimeRig.Screen()
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(try await SessionRuntimeRig.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
        let binding = try #require(await context.runtime.authenticateTaskRun(claim))
        let queue = TerminalInputQueue(endpoint: launch.terminal, onError: { _ in })
        context.runtime.inputGate.register(runID: launch.runID, queue: queue)
        #expect(context.runtime.inputGate.establishFreshCleanInput(runID: launch.runID))
        let ticket = try #require(context.runtime.inputGate.reserveAutomaticInput(runID: launch.runID))
        let task = UUID(), round = UUID(), operation = UUID()
        let target = SessionTaskRoundTarget(taskID: task, roundID: round, inputOperationID: operation,
                                            binding: binding, nativeTurnID: nil, execution: nil)
        let digest = Data(SHA256.hash(data: Data("owned synthetic pointer".utf8)))
        let effect = SessionTaskInputEffectMarker()
        _ = effect.write { 1 }
        #expect(await context.runtime.prepareTaskInput(purpose: .child(taskID: task, roundID: round, operationID: operation),
                                                       binding: binding, digest: digest, effect: effect, ticket: ticket))
        try await screen.send("owned synthetic pointer")
        #expect(await screen.contains("echo: owned synthetic pointer"))
        let host = SessionTaskRuntimeHost(runtime: context.runtime)
        #expect(try await SessionRuntimeRig.waitUntil(2) { await host.observedChildExecution(target) != nil })
        let proof = await host.observedChildExecution(target)
        if case let .providerPrompt(id) = proof { #expect(!id.isEmpty) }
        else { Issue.record("An accepted fake Claude hook must supply its native prompt ID") }
        context.runtime.inputGate.noteUnclassifiedInput(runID: launch.runID)
        #expect(await host.observedChildExecution(target) == proof)
        #expect(context.runtime.inputGate.reserveAutomaticInput(runID: launch.runID) == nil)
        let stale = SessionTaskRoundTarget(taskID: task, roundID: UUID(), inputOperationID: operation,
                                           binding: binding, nativeTurnID: nil, execution: nil)
        #expect(await host.observedChildExecution(stale) == nil)
        try await screen.send("different user input")
        #expect(await screen.contains("echo: different user input"))
        #expect(try await SessionRuntimeRig.waitUntil(2) { await host.observedChildExecution(target) == nil })
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(await host.observedChildExecution(target) == nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
