import Foundation
import Testing
@testable import LoomCore

private extension SessionRuntime {
    func hasFirstProofInFlightForTest(runID: UUID) -> Bool {
        taskExpectedInputs[runID]?.proofReadInFlight == true && !taskProofWaiters.isEmpty
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionTaskRoundIntegrationTests {
    private enum FixtureError: Error { case helperTimeout, missingEvent, malformedEvent }

    private static func helper(_ arguments: [String], claim: SessionTaskClaim, socket: String,
                               input: String? = nil) throws -> (Int32, String) {
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-hook")
        process.arguments = ["task"] + arguments
        process.environment = ["SPHYRNA_TASK_SOCKET": socket, "SPHYRNA_TASK_TOKEN": claim.credential,
            "SPHYRNA_TASK_SESSION_ID": claim.sessionID.uuidString, "SPHYRNA_TASK_RUN_ID": claim.managedRunID.uuidString,
            "SPHYRNA_TASK_GENERATION": claim.generation.uuidString]
        process.standardOutput = output; process.standardInput = stdin; process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        guard ended.wait(timeout: .now() + 8) == .success else {
            process.terminate()
            _ = ended.wait(timeout: .now() + 1)
            throw FixtureError.helperTimeout
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func event(_ output: String) throws -> (UUID, String, Int64)? {
        guard let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else { throw FixtureError.malformedEvent }
        guard let event = events.first else { return nil }
        guard let round = (event["round"] as? String).flatMap(UUID.init(uuidString:)),
              let payload = event["payload"] as? String, let cursor = (event["cursor"] as? NSNumber)?.int64Value else {
            throw FixtureError.malformedEvent
        }
        return (round, payload, cursor)
    }

    private static func waitForEvent(task: UUID, coordinator: SessionTaskCoordinator, claim: SessionTaskClaim,
                                     socket: String, cursor: Int64) async throws -> (UUID, String, Int64) {
        for _ in 0..<4 {
            let revision = try await coordinator.status(taskID: task, parent: claim).task.revision
            let read = try helper(["read", "--task", task.uuidString, "--after", String(cursor)], claim: claim, socket: socket)
            guard read.0 == 0 else { throw FixtureError.malformedEvent }
            if let found = try event(read.1) { return found }
            let waited = try helper(["wait", "--task", task.uuidString, "--after", String(cursor),
                                     "--revision", String(revision), "--seconds", "3"], claim: claim, socket: socket)
            guard waited.0 == 0 else { throw FixtureError.malformedEvent }
            if let found = try event(waited.1) { return found }
        }
        throw FixtureError.missingEvent
    }

    @Test(arguments: ["wrong-client", "partial", "missing"])
    func anUnjoinedChildCannotReportWithoutExactPersistedInput(caseName: String) async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: [
            "LOOM_FAKE_TASK_ROUNDS": "1", "LOOM_FAKE_CODEX_JOIN": "blank",
            "LOOM_FAKE_TASK_ROLLOUT": caseName, "LOOM_FAKE_CODEX_DELAY_TASK_RECEIPT": "1"
        ], claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("refused-first-proof", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parentScreen = SessionRuntimeTests.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: parentScreen)
            parentScreen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let taskID = UUID(), operationID = UUID()
            try await parentScreen.send("/fake-sphyrna-task-create \(taskID.uuidString) \(operationID.uuidString) codex")
            #expect(await parentScreen.contains("FAKE-TASK-CREATE-OK"))
            let coordinator = try #require(await context.runtime.taskCoordinator)
            let childScreen = SessionRuntimeTests.Screen(), gate = context.runtime.inputGate
            let child = try await context.runtime.approveOpenRequest(taskID, outputSink: childScreen, expectedProvider: .codex,
                onTerminalReady: { launch in
                    childScreen.attach(launch.terminal)
                    gate.register(runID: launch.runID, queue: TerminalInputQueue(endpoint: launch.terminal, onError: { _ in }))
                })
            #expect(await childScreen.contains("FAKE-TASK-ROUND-REFUSED", timeout: 8))
            let events = try await coordinator.events(taskID: taskID, parent: claim, limit: 10)
            #expect(events.items.isEmpty)
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            #expect(methods.split(separator: "\n").filter { $0 == "turn/start" }.count == 1)
            #expect(try await context.runtime.stopConversation(sessionID: child.sessionID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("invalid first-input proof fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func childStopDuringTheFirstProofJoinCannotAuthorizeTheWaitingHelper() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: [
            "LOOM_FAKE_TASK_ROUNDS": "1", "LOOM_FAKE_CODEX_JOIN": "blank-delay"
        ], claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("stop-during-first-proof", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parentScreen = SessionRuntimeTests.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: parentScreen)
            parentScreen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let taskID = UUID(), operationID = UUID()
            try await parentScreen.send("/fake-sphyrna-task-create \(taskID.uuidString) \(operationID.uuidString) codex")
            #expect(await parentScreen.contains("FAKE-TASK-CREATE-OK"))
            let coordinator = try #require(await context.runtime.taskCoordinator)
            let childScreen = SessionRuntimeTests.Screen(), gate = context.runtime.inputGate
            let child = try await context.runtime.approveOpenRequest(taskID, outputSink: childScreen, expectedProvider: .codex,
                onTerminalReady: { launch in
                    childScreen.attach(launch.terminal)
                    gate.register(runID: launch.runID, queue: TerminalInputQueue(endpoint: launch.terminal, onError: { _ in }))
                })
            #expect(try await SessionRuntimeTests.waitUntil(3) {
                await context.runtime.hasFirstProofInFlightForTest(runID: child.runID)
            })
            #expect(try await context.runtime.stopConversation(sessionID: child.sessionID).succeeded)
            #expect(await context.runtime.taskExpectedInputs[child.runID] == nil)
            #expect(try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).isEmpty)
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            #expect(methods.split(separator: "\n").filter { $0 == "turn/start" }.count == 1)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("first-proof Stop race failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: [ManagedSession.Provider.claude, .codex])
    func threeRoundsUseOneOwnedChildAndItsRealHelperInBothDirections(parentProvider: ManagedSession.Provider) async throws {
        var environment = ["LOOM_FAKE_TASK_ROUNDS": "1"]
        if parentProvider == .claude {
            environment["LOOM_FAKE_CODEX_JOIN"] = "blank"
            environment["LOOM_FAKE_CODEX_DELAY_TASK_RECEIPT"] = "1"
        }
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: environment,
                                                                claudeVersion: "2.0.0")
        defer { context.cleanup() }
        var diagnosticTask: UUID?, diagnosticClaim: SessionTaskClaim?, diagnosticRun: UUID?
        var diagnosticScreen: SessionRuntimeTests.Screen?
        do {
            let folder = context.root.appendingPathComponent("three-round-task", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parentScreen = SessionRuntimeTests.Screen()
            let parent = try await context.runtime.startConversation(provider: parentProvider, projectID: project.id, outputSink: parentScreen)
            parentScreen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            diagnosticClaim = claim
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            let childProvider: ManagedSession.Provider = parentProvider == .claude ? .codex : .claude
            let harness = childProvider == .codex ? "codex" : "claude"
            let taskID = UUID(), firstOperation = UUID()
            diagnosticTask = taskID
            // The parent provider itself starts the helper as a descendant;
            // Codex does this from its owned app-server, as native tools do.
            try await parentScreen.send("/fake-sphyrna-task-create \(taskID.uuidString) \(firstOperation.uuidString) \(harness)")
            #expect(await parentScreen.contains("FAKE-TASK-CREATE-OK"))
            let request = try #require(await context.runtime.openRequestSnapshot().first { $0.id == taskID })
            let childID = try #require(request.task?.childID)
            let childScreen = SessionRuntimeTests.Screen(), gate = context.runtime.inputGate
            diagnosticScreen = childScreen
            let child = try await context.runtime.approveOpenRequest(taskID, outputSink: childScreen, expectedProvider: childProvider,
                onTerminalReady: { launch in
                    childScreen.attach(launch.terminal)
                    gate.register(runID: launch.runID, queue: TerminalInputQueue(endpoint: launch.terminal, onError: { _ in }))
                })
            #expect(child.sessionID == childID && childID != parent.sessionID)
            diagnosticRun = child.runID
            var cursor: Int64 = 0, rounds: Set<UUID> = [], operations: Set<UUID> = [firstOperation]
            for number in 1...3 {
                if number > 1 {
                    let operation = UUID(); operations.insert(operation)
                    let reply = try Self.helper(["reply", "--task", taskID.uuidString, "--operation", operation.uuidString,
                                                 "--message", "-"], claim: claim, socket: socket, input: "fixture-round-\(number)")
                    #expect(reply.0 == 0)
                }
                let result = try await Self.waitForEvent(task: taskID, coordinator: coordinator, claim: claim,
                                                          socket: socket, cursor: cursor)
                rounds.insert(result.0); cursor = result.2
                #expect(result.1 == "fixture-result: fixture-round-\(number)")
            }
            let final = try await coordinator.status(taskID: taskID, parent: claim)
            #expect(rounds.count == 3 && operations.count == 3)
            #expect(final.task.childSessionID == childID && final.task.childBinding?.managedRunID == child.runID)
            #expect(final.task.childInputsUsed == 3 && final.task.parentWakesUsed == 0)
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            let turns = methods.split(separator: "\n").filter { $0 == "turn/start" }.count
            #expect(turns == (childProvider == .codex ? 3 : 1), "reads and waits add no parent model call")
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch {
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            let turns = methods.split(separator: "\n").filter { $0 == "turn/start" }.count
            let status: SessionTaskStatus?
            if let task = diagnosticTask, let claim = diagnosticClaim, let coordinator = await context.runtime.taskCoordinator {
                status = try? await coordinator.status(taskID: task, parent: claim)
            } else { status = nil }
            let expected: SessionTaskExpectedInput?
            if let run = diagnosticRun { expected = await context.runtime.taskExpectedInputs[run] } else { expected = nil }
            let screen = diagnosticScreen?.snapshot ?? ""
            let phases = "native=\(String(describing: status?.nativeStatus)), pending=\(String(describing: status?.pendingRound?.phase)), active=\(String(describing: status?.activeRound?.phase))"
            let proof = "observed=\(String(describing: expected?.observed)), receipt=\(String(describing: expected?.expectedNativeTurn)), effect=\(expected?.effect.hasEffect ?? false)"
            Issue.record("synthetic cross-provider task failed: \(error); turns=\(turns), \(phases), \(proof), fixtureRefused=\(screen.contains("FAKE-TASK-ROUND-REFUSED")), fixtureOK=\(screen.contains("FAKE-TASK-ROUND-OK"))")
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
