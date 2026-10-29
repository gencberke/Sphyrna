import CryptoKit
import Foundation
import Testing
@testable import LoomCore

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct SessionTaskRuntimeProofTests {
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
        #expect(await context.runtime.prepareTaskInput(purpose: .child(taskID: task, roundID: round, operationID: operation),
                                                       binding: binding, digest: digest))
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
