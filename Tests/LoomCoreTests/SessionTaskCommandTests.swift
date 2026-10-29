import Foundation
import Testing
@testable import LoomCore

private final class TaskWakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1)))
struct SessionTaskCommandTests {
    private static func helper(_ args: [String], claim: SessionTaskClaim, socket: String,
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
        let input = try Self.helper(["input", "--task", id, "--round", roundID, "--operation", inputOperation],
                               claim: f.child, socket: socket)
        #expect(input.0 == 0 && input.1 == "scoped child message\n")
        let forged = SessionTaskClaim(sessionID: f.child.sessionID, managedRunID: f.child.managedRunID,
                                      generation: f.child.generation, credential: "other-run-token")
        #expect(try Self.helper(["input", "--task", id, "--round", roundID, "--operation", inputOperation],
                           claim: forged, socket: socket).0 == 1)
        #expect(try Self.helper(["input", "--task", id, "--round", roundID, "--operation", UUID().uuidString],
                           claim: f.child, socket: socket).0 == 1)
        await f.host.replaceObservedInputOperation(round, operationID: UUID())
        #expect(try Self.helper(["input", "--task", id, "--round", roundID, "--operation", inputOperation],
                           claim: f.child, socket: socket).0 == 1)
        await f.host.replaceObservedInputOperation(round, operationID: operation)
        let reported = try Self.helper(["report", "--task", id, "--round", roundID, "--kind", "needsParentInput",
                                   "--message", "-", "--operation", UUID().uuidString],
                                  claim: f.child, socket: socket, input: "please review")
        #expect(reported.0 == 0)
        #expect(try Self.helper(["input", "--task", id, "--round", roundID, "--operation", inputOperation],
                           claim: f.child, socket: socket).0 == 1)
        let read = try Self.helper(["read", "--task", id], claim: f.parent, socket: socket)
        #expect(read.0 == 0 && read.1.contains("please review"))
        await #expect(throws: SessionTaskError.notReady) {
            try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID())
        }
        #expect(try await f.coordinator.status(taskID: f.taskID, parent: f.parent).task.parentWakesUsed == 0)
        server.stop()
        #expect(try await SessionRuntimeTests.waitUntil(2) { !FileManager.default.fileExists(atPath: socket) })
    }

    @Test func blockingWaitReceivesReportWithoutASeparateWake() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let socketDir = URL(fileURLWithPath: "/tmp/lt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: socketDir) }
        let socket = socketDir.appendingPathComponent("task.sock").path
        let coordinator = f.coordinator
        let router = SessionTaskWireRouter(coordinator: coordinator, reported: { taskID in
            _ = try? await coordinator.wakePending(taskID: taskID, operationID: UUID())
        })
        let server = try SessionTaskSocket(path: socket, handler: router.handle)
        defer { server.stop() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await coordinator.deliverPending(taskID: f.taskID)
        let revision = try await coordinator.status(taskID: f.taskID, parent: f.parent).task.revision
        let id = f.taskID.uuidString, parent = f.parent
        let waiting = Task.detached {
            try Self.helper(["wait", "--task", id, "--revision", String(revision), "--seconds", "3"],
                            claim: parent, socket: socket)
        }
        #expect(try await SessionRuntimeTests.waitUntil(2) { router.readFence.hasReader(taskID: f.taskID) })
        let reported = try Self.helper(["report", "--task", id, "--round", round.uuidString,
                                        "--kind", "completed", "--message", "-", "--operation", UUID().uuidString],
                                       claim: f.child, socket: socket, input: "finished")
        #expect(reported.0 == 0)
        let answer = try await waiting.value
        #expect(answer.0 == 0 && answer.1.contains("finished"))
        #expect(await f.host.counts().1 == 0)
        #expect(try await coordinator.status(taskID: f.taskID, parent: f.parent).task.parentWakesUsed == 0)
        server.stop()
        #expect(try await SessionRuntimeTests.waitUntil(2) { !FileManager.default.fileExists(atPath: socket) })
    }

    @Test func pendingReadHoldsWakeUntilItsExactPageIsAcknowledged() throws {
        let counter = TaskWakeCounter()
        let fence = SessionTaskReadFence { _ in counter.add() }
        let task = UUID()
        let claim = SessionTaskClaim(sessionID: UUID(), managedRunID: UUID(), generation: UUID(), credential: "synthetic")
        let lease = try fence.begin(taskID: task, claim: claim)
        fence.scheduleWake(taskID: task)
        #expect(counter.value == 0)
        let event = UUID()
        fence.delivered(lease, eventIDs: [event])
        fence.acknowledge(lease, taskID: task, claim: claim, eventIDs: [UUID()])
        #expect(counter.value == 0)
        fence.acknowledge(lease, taskID: task, claim: claim, eventIDs: [event])
        #expect(counter.value == 1)
        fence.stop()
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
        #expect(try Self.helper(["identity"], claim: original, socket: socket).0 == 0)
        let forged = SessionTaskClaim(sessionID: original.sessionID, managedRunID: original.managedRunID,
                                      generation: original.generation, credential: "wrong-run-secret")
        #expect(try Self.helper(["identity"], claim: forged, socket: socket).0 == 1)
        let native = try #require(await context.supervisor.runContext(runID: launch.runID)?.session.providerConversationID)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect(try Self.helper(["identity"], claim: original, socket: socket).0 == 1)
        let resumedScreen = SessionRuntimeTests.Screen()
        let resumed = try await context.runtime.resumeConversation(sessionID: launch.sessionID, outputSink: resumedScreen)
        resumedScreen.attach(resumed.terminal)
        let current = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
        #expect(current.managedRunID == resumed.runID && current.managedRunID != original.managedRunID)
        #expect(current.generation != original.generation && current.credential != original.credential)
        #expect(try await SessionRuntimeTests.waitUntil(3) {
            await context.supervisor.runContext(runID: resumed.runID)?.session.providerConversationID == native
        })
        #expect(try Self.helper(["identity"], claim: current, socket: socket).0 == 0)
        #expect(try Self.helper(["identity"], claim: original, socket: socket).0 == 1)
        #expect(try await context.runtime.stopConversation(sessionID: resumed.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
