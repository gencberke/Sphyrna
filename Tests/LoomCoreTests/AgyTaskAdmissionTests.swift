import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct AgyTaskAdmissionTests {
    @Test func unavailableTaskAndPeerTransportsAreRefusedBeforeOfferingACard() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("agy-task-project", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let (parent, _) = try await SessionRuntimeTests.launchClaude(context, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(await SessionRuntimeTests.waitUntil { await context.runtime.authenticateTaskRun(claim) != nil })
            var create = SessionTaskWireRequest(command: "create", sessionID: claim.sessionID,
                runID: claim.managedRunID, generation: claim.generation, credential: claim.credential)
            create.taskID = UUID(); create.operationID = UUID(); create.name = "AGY worker"
            create.harness = "agy"; create.message = "synthetic request"
            let answer = await context.runtime.submitTaskRequest(create)
            #expect(answer.status == "refused")
            #expect(await context.runtime.openRequestSnapshot().isEmpty)
            let target = ManagedSession(provider: try #require(ManagedSession.Provider(rawValue: "agy")),
                providerConversationID: UUID().uuidString.lowercased(), workingDirectory: context.home.path)
            try await context.supervisor.createSession(target)
            var send = SessionTaskWireRequest(command: "peer-send", sessionID: claim.sessionID,
                runID: claim.managedRunID, generation: claim.generation, credential: claim.credential)
            let sendID = UUID()
            send.operationID = sendID; send.targetSessionID = target.id; send.message = "synthetic peer"
            #expect(await context.runtime.submitPeerSend(send).status == "refused")
            #expect(await context.runtime.openRequestSnapshot().isEmpty)
            let mailbox = try #require(await context.runtime.peerMailbox)
            #expect(try await mailbox.status(id: sendID) == nil)
            #expect(try await mailbox.unread(target: target.id).isEmpty)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
