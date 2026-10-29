import Foundation
import Testing
@testable import LoomCore

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionTaskCreateTests {
    private static func create(taskID: UUID, operationID: UUID, claim: SessionTaskClaim,
                               socket: String, message: String) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-hook")
        process.arguments = ["task", "create", "--task", taskID.uuidString, "--operation", operationID.uuidString,
                             "--name", "Review task", "--harness", "codex", "--message", "-"]
        process.environment = ["SPHYRNA_TASK_SOCKET": socket, "SPHYRNA_TASK_TOKEN": claim.credential,
                               "SPHYRNA_TASK_SESSION_ID": claim.sessionID.uuidString,
                               "SPHYRNA_TASK_RUN_ID": claim.managedRunID.uuidString,
                               "SPHYRNA_TASK_GENERATION": claim.generation.uuidString]
        let output = Pipe(), input = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardInput = input; process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(message.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text)
    }

    @Test func realHelperCreatesOneBoundedApprovalAndDenyLeavesNoChild() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("task-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let screen = SessionRuntimeTests.Screen()
        let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
        screen.attach(parent.terminal)
        let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
        #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
        let socket = try #require(await context.runtime.taskSocketPath)
        let taskID = UUID(), operationID = UUID()
        let first = try Self.create(taskID: taskID, operationID: operationID, claim: claim, socket: socket, message: "Review this change")
        #expect(first.0 == 0 && first.1.contains("pending"))
        let request = try #require(await context.runtime.openRequestSnapshot().first { $0.id == taskID })
        let grant = try #require(request.task)
        #expect(grant.childInputLimit == 3 && grant.parentWakeLimit == 6 && grant.lifetimeSeconds == 3_600)
        #expect(request.requesterID == parent.sessionID && request.choices.harness == .codex)
        #expect(try await context.catalog.session(id: grant.childID) == nil)
        let retry = try Self.create(taskID: taskID, operationID: operationID, claim: claim, socket: socket, message: "Review this change")
        let afterRetry = await context.runtime.openRequestSnapshot()
        #expect(retry.0 == 0 && afterRetry.count == 1)
        #expect(try Self.create(taskID: taskID, operationID: operationID, claim: claim, socket: socket, message: "Different text").0 == 1)
        let forged = SessionTaskClaim(sessionID: claim.sessionID, managedRunID: claim.managedRunID,
                                      generation: claim.generation, credential: "wrong")
        #expect(try Self.create(taskID: UUID(), operationID: UUID(), claim: forged, socket: socket, message: "Review").0 == 1)
        try await context.runtime.denyOpenRequest(taskID)
        #expect(await context.runtime.taskChildReservations[taskID] == nil)
        #expect(try await context.catalog.session(id: grant.childID) == nil)
        #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
