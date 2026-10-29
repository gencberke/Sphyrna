import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

private final class ManagedParentScreen: TerminalOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var content = ""
    func receive(_ data: Data) {
        lock.withLock { content = String((content + String(decoding: data, as: UTF8.self)).suffix(64 * 1_024)) }
    }
    func contains(_ text: String) -> Bool { lock.withLock { content.contains(text) } }
}

/// Actual production protocol controller composed with the real runtime and owned fake-provider processes.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct ManagedClaudeRuntimeIntegrationTests {
    @Test func productionControllerUsesTheSameOwnedChildForThreeReportedRounds() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_TASK_ROUNDS": "1"], version: "2.1.311",
            managedClaudeControllerFactory: { run, ingress in
                try ManagedClaudeTaskController(run: run, ingress: ingress)
            })
        do {
            let work = rig.home.appendingPathComponent("managed-work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let project = try await rig.catalog.addProject(path: work.path).project
            let screen = ManagedParentScreen()
            let parent = try await rig.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
            let claim = try #require(await rig.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(await waitUntil { await rig.runtime.authenticateTaskRun(claim) != nil })
            let taskID = UUID()
            let create = "/fake-sphyrna-task-create \(taskID.uuidString) \(UUID().uuidString) claude\r"
            _ = try await parent.terminal.write(Data(create.utf8))
            #expect(await waitUntil { screen.contains("FAKE-TASK-CREATE-OK") })
            let childID = try await rig.runtime.approveManagedTaskRequest(taskID, expectedProvider: .claude)
            let coordinator = try #require(await rig.runtime.taskCoordinator)
            #expect(await waitUntil {
                (try? await coordinator.latestEventsForUser(taskID: taskID, limit: 10).count) == 1
            })
            let first = try await coordinator.status(taskID: taskID, parent: claim)
            let binding = try #require(first.task.childBinding)
            #expect(binding.sessionID == childID && UUID(uuidString: binding.nativeSessionID) != nil)
            #expect(await rig.supervisor.session(id: childID)?.currentRun?.id == binding.managedRunID)
            for round in 2...3 {
                _ = try await coordinator.requestRound(taskID: taskID, parent: claim, operationID: UUID(),
                                                       message: "fixture-round-\(round)")
                await rig.runtime.markTaskNeedsDelivery(taskID)
                #expect(await waitUntil {
                    (try? await coordinator.latestEventsForUser(taskID: taskID, limit: 10).count) == round
                })
            }
            let events = try await coordinator.latestEventsForUser(taskID: taskID, limit: 10)
            #expect(events.map(\.payload) == (1...3).map { "fixture-result: fixture-round-\($0)" })
            #expect(Set(events.map(\.roundID)).count == 3)
            #expect((try await coordinator.status(taskID: taskID, parent: claim)).task.childBinding == binding)
            let child = try #require(try await rig.runtime.managedTaskForChild(sessionID: childID))
            #expect(child.presentation?.binding == binding)
            #expect(child.presentation?.run.requestedChoices.harness == .claude)
            #expect(try await rig.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await rig.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("Production managed Claude runtime integration failed: \(error)") }
        await rig.finish()
    }
}
