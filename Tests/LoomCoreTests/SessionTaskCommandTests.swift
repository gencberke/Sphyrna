import Foundation
import Testing
@testable import LoomCore

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct SessionTaskCommandTests {
    private func helper(_ args: [String], claim: SessionTaskClaim, socket: String,
                        input: String = "") throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-hook")
        process.arguments = ["task"] + args
        process.environment = ["SPHYRNA_TASK_SOCKET": socket, "SPHYRNA_TASK_TOKEN": claim.credential,
                               "SPHYRNA_TASK_SESSION_ID": claim.sessionID.uuidString,
                               "SPHYRNA_TASK_RUN_ID": claim.managedRunID.uuidString,
                               "SPHYRNA_TASK_GENERATION": claim.generation.uuidString]
        let output = Pipe(), error = Pipe(), stdin = Pipe()
        process.standardOutput = output; process.standardError = error; process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func bundledHelperShowsTaskCommandsWithoutAProviderOrCredential() throws {
        let process = Process()
        process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-hook")
        process.arguments = ["task", "--help"]
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(text.contains("task") && text.contains("wait") && text.contains("report"))
    }

    @Test func helperUsesScopedSocketAndAcknowledgesOnlyReadEvents() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let socketDir = URL(fileURLWithPath: "/tmp/lt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: socketDir) }
        let socket = socketDir.appendingPathComponent("task.sock").path
        let router = SessionTaskWireRouter(coordinator: f.coordinator)
        let server = try SessionTaskSocket(path: socket, handler: router.handle)
        defer { server.stop() }
        let operation = UUID()
        let round = try #require(try await f.input("scoped child message", operationID: operation).roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let id = f.taskID.uuidString, roundID = round.uuidString, inputOperation = operation.uuidString
        let input = try helper(["input", "--task", id, "--round", roundID, "--operation", inputOperation],
                               claim: f.child, socket: socket)
        #expect(input.0 == 0 && input.1 == "scoped child message\n")
        let forged = SessionTaskClaim(sessionID: f.child.sessionID, managedRunID: f.child.managedRunID,
                                      generation: f.child.generation, credential: "other-run-token")
        #expect(try helper(["input", "--task", id, "--round", roundID, "--operation", inputOperation],
                           claim: forged, socket: socket).0 == 1)
        #expect(try helper(["input", "--task", id, "--round", roundID, "--operation", UUID().uuidString],
                           claim: f.child, socket: socket).0 == 1)
        await f.host.replaceObservedInputOperation(round, operationID: UUID())
        #expect(try helper(["input", "--task", id, "--round", roundID, "--operation", inputOperation],
                           claim: f.child, socket: socket).0 == 1)
        await f.host.replaceObservedInputOperation(round, operationID: operation)
        let reported = try helper(["report", "--task", id, "--round", roundID, "--kind", "needsParentInput",
                                   "--message", "-", "--operation", UUID().uuidString],
                                  claim: f.child, socket: socket, input: "please review")
        #expect(reported.0 == 0)
        #expect(try helper(["input", "--task", id, "--round", roundID, "--operation", inputOperation],
                           claim: f.child, socket: socket).0 == 1)
        let read = try helper(["read", "--task", id], claim: f.parent, socket: socket)
        #expect(read.0 == 0 && read.1.contains("please review"))
        await #expect(throws: SessionTaskError.notReady) {
            try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID())
        }
        #expect(try await f.coordinator.status(taskID: f.taskID, parent: f.parent).task.parentWakesUsed == 0)
        server.stop()
        #expect(try await SessionRuntimeTests.waitUntil(2) { !FileManager.default.fileExists(atPath: socket) })
    }

    @Test(arguments: [ManagedSession.Provider.claude, .codex])
    func liveProviderDescendantCanIdentifyItsOwnTerminalRun(provider: ManagedSession.Provider) async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let screen = SessionRuntimeTests.Screen()
        let launch = try await context.runtime.startConversation(provider: provider, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        #expect(try await SessionRuntimeTests.waitUntil(3) {
            await context.supervisor.runContext(runID: launch.runID)?.session.providerConversationID != nil
        })
        try await screen.send("/fake-sphyrna-task-probe")
        #expect(await screen.contains("TASK-HELPER-OK", timeout: 3))
        let socket = try #require(await context.runtime.taskSocketPath)
        let original = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(try helper(["identity"], claim: original, socket: socket).0 == 0)
        let forged = SessionTaskClaim(sessionID: original.sessionID, managedRunID: original.managedRunID,
                                      generation: original.generation, credential: "wrong-run-secret")
        #expect(try helper(["identity"], claim: forged, socket: socket).0 == 1)
        let native = try #require(await context.supervisor.runContext(runID: launch.runID)?.session.providerConversationID)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(try helper(["identity"], claim: original, socket: socket).0 == 1)
        let resumedScreen = SessionRuntimeTests.Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID, outputSink: resumedScreen)
        resumedScreen.attach(resumed.terminal)
        let current = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(current.managedRunID == resumed.runID && current.managedRunID != original.managedRunID)
        #expect(current.generation != original.generation && current.credential != original.credential)
        #expect(try await SessionRuntimeTests.waitUntil(3) {
            await context.supervisor.runContext(runID: resumed.runID)?.session.providerConversationID == native
        })
        #expect(try helper(["identity"], claim: current, socket: socket).0 == 0)
        #expect(try helper(["identity"], claim: original, socket: socket).0 == 1)
        #expect(try await context.runtime.stopConversation(sessionID: resumed.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
