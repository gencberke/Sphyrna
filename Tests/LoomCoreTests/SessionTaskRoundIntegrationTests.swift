import Foundation
import Testing
@testable import LoomCore

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
    func managedCreatorUsesItsLiveSubscriptionWithoutRolloutFallback(caseName: String) async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: [
            "LOOM_FAKE_TASK_ROUNDS": "1", "LOOM_FAKE_CODEX_JOIN": "blank",
            "LOOM_FAKE_TASK_ROLLOUT": caseName, "LOOM_FAKE_CODEX_DELAY_TASK_RECEIPT": "1"
        ], scoped: true, durableLedger: true, claudeVersion: "2.0.0")
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
            let childID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            #expect(try await SessionRuntimeTests.waitUntil(8) {
                try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).count == 1
            })
            let events = try await coordinator.events(taskID: taskID, parent: claim, limit: 10)
            #expect(events.items.first?.payload == "fixture-result: fixture-round-1")
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            #expect(methods.split(separator: "\n").filter { $0 == "turn/start" }.count == 1)
            #expect(!methods.split(separator: "\n").contains("thread/resume"))
            #expect(!methods.split(separator: "\n").contains("thread/read"))
            #expect(!methods.split(separator: "\n").contains("thread/turns/list"))
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("invalid first-input proof fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func childStopBeforeTheFirstHelperCannotAuthorizeItsReport() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: [
            "LOOM_FAKE_TASK_ROUNDS": "1", "LOOM_FAKE_TASK_WAIT_REPORT": "1"
        ], scoped: true, durableLedger: true, claudeVersion: "2.0.0")
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
            let childID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            let childRun = try #require(await context.supervisor.session(id: childID)?.currentRun?.id)
            let waiting = context.state.appendingPathComponent("task-report-waiting")
            #expect(try await SessionRuntimeTests.waitUntil(5) { FileManager.default.fileExists(atPath: waiting.path) })
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(await context.runtime.taskExpectedInputs[childRun] == nil)
            #expect(try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).isEmpty)
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            #expect(methods.split(separator: "\n").filter { $0 == "turn/start" }.count == 1)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("first-proof Stop race failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func interruptUpdatesOnlyTheExactCodexRoundAndReusesItsChild() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: [
            "LOOM_FAKE_TASK_ROUNDS": "1", "LOOM_FAKE_CODEX_JOIN": "blank", "LOOM_FAKE_TASK_HOLD_FIRST": "1"
        ], scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        var trackedTask: UUID?, trackedClaim: SessionTaskClaim?, trackedChild: UUID?
        do {
            let folder = context.root.appendingPathComponent("interrupt-task-round", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parentScreen = SessionRuntimeTests.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: parentScreen)
            parentScreen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            trackedClaim = claim
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let taskID = UUID(), operationID = UUID()
            trackedTask = taskID
            try await parentScreen.send("/fake-sphyrna-task-create \(taskID.uuidString) \(operationID.uuidString) codex")
            #expect(await parentScreen.contains("FAKE-TASK-CREATE-OK"))
            let coordinator = try #require(await context.runtime.taskCoordinator)
            let socket = try #require(await context.runtime.taskSocketPath)
            let childID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            let childRun = try #require(await context.supervisor.session(id: childID)?.currentRun?.id)
            trackedChild = childRun
            #expect(try await SessionRuntimeTests.waitUntil(4) {
                let status = try await coordinator.status(taskID: taskID, parent: claim)
                return status.activeRound != nil && status.nativeStatus == .working
            })
            let initial = try await coordinator.status(taskID: taskID, parent: claim)
            let round = try #require(initial.activeRound?.id), nextOperation = UUID()
            let interrupt = try Self.helper(["interrupt", "--task", taskID.uuidString, "--round", round.uuidString,
                "--operation", UUID().uuidString, "--next-operation", nextOperation.uuidString, "--message", "-"],
                claim: claim, socket: socket, input: "fixture-round-2")
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(interrupt.1.utf8)) as? [String: Any])
            #expect(interrupt.0 == 0 && (payload["receipt"] as? [String: Any])?["delivery"] as? String == "verified")
            let result = try await Self.waitForEvent(task: taskID, coordinator: coordinator, claim: claim, socket: socket, cursor: 0)
            #expect(result.1 == "fixture-result: fixture-round-2" && result.0 != round)
            let after = try await coordinator.status(taskID: taskID, parent: claim)
            #expect(after.task.childSessionID == childID && after.task.childBinding?.managedRunID == childRun)
            let old = try await coordinator.interruptAndUpdate(taskID: taskID, parent: claim, roundID: round,
                operationID: UUID(), nextOperationID: UUID(), message: "must not run")
            #expect(old.delivery == .alreadySettled)
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            #expect(methods.split(separator: "\n").filter { $0 == "turn/interrupt" }.count == 1)
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch {
            let status: SessionTaskStatus?
            if let taskID = trackedTask, let claim = trackedClaim, let coordinator = await context.runtime.taskCoordinator {
                status = try? await coordinator.status(taskID: taskID, parent: claim)
            } else { status = nil }
            let expected: SessionTaskExpectedInput?
            if let run = trackedChild { expected = await context.runtime.taskExpectedInputs[run] } else { expected = nil }
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            let turns = methods.split(separator: "\n").filter { $0 == "turn/start" }.count
            let interrupts = methods.split(separator: "\n").filter { $0 == "turn/interrupt" }.count
            Issue.record("exact task interrupt fixture failed: \(error); lifecycle=\(String(describing: status?.task.lifecycle)), native=\(String(describing: status?.nativeStatus)), pending=\(String(describing: status?.pendingRound?.phase)), active=\(String(describing: status?.activeRound?.phase)), observed=\(String(describing: expected?.observed)), receipt=\(String(describing: expected?.expectedNativeTurn)), turns=\(turns), interrupts=\(interrupts)")
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: [true, false])
    func managedClaudeInterruptRequiresItsExactTurnToEnd(providerStops: Bool) async throws {
        var environment = ["LOOM_FAKE_TASK_ROUNDS": "1", "LOOM_FAKE_CLAUDE_TASK_INTERRUPT": "1"]
        if !providerStops { environment["LOOM_FAKE_CHAT_IGNORE_INTERRUPT"] = "1" }
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: environment,
            scoped: true, durableLedger: true, claudeVersion: "2.0.0", managedClaudeControllerFactory: { run, ingress in
                ManagedClaudeFixtureController(run: run, ingress: ingress)
            })
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("claude-task-interrupt", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parentScreen = SessionRuntimeTests.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: parentScreen)
            parentScreen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath)
            let coordinator = try #require(await context.runtime.taskCoordinator), task = UUID()
            let create = try Self.helper(["create", "--task", task.uuidString, "--operation", UUID().uuidString,
                "--name", "Claude child", "--harness", "claude", "--message", "-"],
                claim: claim, socket: socket, input: "fixture-round-1")
            #expect(create.0 == 0)
            let childID = try await context.runtime.approveManagedTaskRequest(task, expectedProvider: .claude)
            try #require(try await SessionRuntimeTests.waitUntil(5) {
                let status = try await coordinator.status(taskID: task, parent: claim)
                return status.activeRound != nil && status.nativeStatus == .working &&
                    FileManager.default.fileExists(atPath: context.state.appendingPathComponent("managed-claude-task-accepted").path)
            })
            let before = try await coordinator.status(taskID: task, parent: claim)
            let first = try #require(before.activeRound?.id)
            #expect(before.nativeStatus == .working)
            let reply = try Self.helper(["interrupt", "--task", task.uuidString, "--round", first.uuidString,
                "--operation", UUID().uuidString, "--next-operation", UUID().uuidString, "--message", "-"],
                claim: claim, socket: socket, input: "fixture-round-2")
            let value = try #require(try JSONSerialization.jsonObject(with: Data(reply.1.utf8)) as? [String: Any])
            let delivery = (value["receipt"] as? [String: Any])?["delivery"] as? String
            #expect(reply.0 == 0 && delivery == (providerStops ? "verified" : "unverified"),
                    "providerStops=\(providerStops), exit=\(reply.0), delivery=\(delivery ?? "nil")")
            if providerStops {
                let result = try await Self.waitForEvent(task: task, coordinator: coordinator, claim: claim, socket: socket, cursor: 0)
                #expect(result.0 != first && result.1 == "fixture-result: fixture-round-2")
            } else {
                let status = try await coordinator.status(taskID: task, parent: claim)
                #expect(status.task.lifecycle == .revoked && status.pendingRound?.phase == .queued,
                        "lifecycle=\(status.task.lifecycle), pending=\(String(describing: status.pendingRound?.phase))")
                #expect(try await coordinator.latestEventsForUser(taskID: task, limit: 10).isEmpty)
            }
            let stale = try await coordinator.interruptAndUpdate(taskID: task, parent: claim, roundID: first,
                operationID: UUID(), nextOperationID: UUID(), message: "must not run")
            #expect(stale.delivery == .alreadySettled)
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("managed Claude task interrupt fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func reportedResultWakesACleanReadyParentWithOnlyATaskPointer() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("task-wake", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parentScreen = SessionRuntimeTests.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: parentScreen)
            parentScreen.attach(parent.terminal)
            let gate = context.runtime.inputGate
            gate.register(runID: parent.runID, queue: TerminalInputQueue(endpoint: parent.terminal, onError: { _ in }))
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            let task = UUID()
            let create = try Self.helper(["create", "--task", task.uuidString, "--operation", UUID().uuidString,
                "--name", "Fixture child", "--harness", "codex", "--message", "-"],
                claim: claim, socket: socket, input: "fixture-round-1")
            #expect(create.0 == 0 && create.1.contains("pending"))
            let childID = try await context.runtime.approveManagedTaskRequest(task, expectedProvider: .codex)
            #expect(await parentScreen.contains("Sphyrna updates:", timeout: 6))
            #expect(try await SessionRuntimeTests.waitUntil(4) {
                let status = try await coordinator.status(taskID: task, parent: claim)
                return status.task.parentWakesUsed == 1 && status.task.parentWakesConsumed == 1
            })
            #expect(!parentScreen.snapshot.contains("fixture-result: fixture-round-1"))
            let read = try Self.helper(["read", "--task", task.uuidString], claim: claim, socket: socket)
            #expect(read.0 == 0 && read.1.contains("fixture-result: fixture-round-1"))
            let final = try await coordinator.status(taskID: task, parent: claim)
            #expect(final.task.parentWakesUsed == 1 && final.task.parentWakesConsumed == 1)
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("task wake fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func manuallySubmittedParentRequestCanReceiveItsDelegatedResult() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("manual-task-wake", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let screen = SessionRuntimeTests.Screen(), gate = context.runtime.inputGate
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
            screen.attach(parent.terminal)
            let queue = TerminalInputQueue(endpoint: parent.terminal, onError: { _ in })
            gate.register(runID: parent.runID, queue: queue)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let coordinator = try #require(await context.runtime.taskCoordinator), task = UUID()
            let line = "/fake-sphyrna-task-create \(task.uuidString) \(UUID().uuidString) codex\r"
            #expect(queue.enqueue(Data(line.utf8)))
            #expect(await screen.contains("FAKE-TASK-CREATE-OK"))
            let childID = try await context.runtime.approveManagedTaskRequest(task, expectedProvider: .codex)
            #expect(await screen.contains("Sphyrna updates:", timeout: 6))
            #expect(try await SessionRuntimeTests.waitUntil(4) {
                let status = try await coordinator.status(taskID: task, parent: claim)
                return status.task.parentWakesUsed == 1 && status.task.parentWakesConsumed == 1
            })
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("manual parent task wake fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aLiveWaitReturnsAndAcknowledgesTheResultWithoutAnotherParentInput() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: [
            "LOOM_FAKE_TASK_ROUNDS": "1", "LOOM_FAKE_TASK_WAIT_REPORT": "1"
        ], scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("task-wait", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let screen = SessionRuntimeTests.Screen(), gate = context.runtime.inputGate
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
            screen.attach(parent.terminal)
            gate.register(runID: parent.runID, queue: TerminalInputQueue(endpoint: parent.terminal, onError: { _ in }))
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            let task = UUID()
            let create = try Self.helper(["create", "--task", task.uuidString, "--operation", UUID().uuidString,
                "--name", "Fixture child", "--harness", "codex", "--message", "-"],
                claim: claim, socket: socket, input: "fixture-round-1")
            #expect(create.0 == 0)
            let childID = try await context.runtime.approveManagedTaskRequest(task, expectedProvider: .codex)
            let waiting = context.state.appendingPathComponent("task-report-waiting")
            #expect(try await SessionRuntimeTests.waitUntil(4) { FileManager.default.fileExists(atPath: waiting.path) })
            let revision = try await coordinator.status(taskID: task, parent: claim).task.revision
            let waiter = Task.detached {
                try Self.helper(["wait", "--task", task.uuidString, "--revision", String(revision), "--seconds", "6"],
                                claim: claim, socket: socket)
            }
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.taskReadFence?.hasReader(taskID: task) == true })
            try "release".write(to: context.state.appendingPathComponent("task-report-release"), atomically: true, encoding: .utf8)
            let answer = try await waiter.value
            #expect(answer.0 == 0 && answer.1.contains("fixture-result: fixture-round-1"))
            let status = try await coordinator.status(taskID: task, parent: claim)
            #expect(status.task.parentWakesUsed == 0 && status.task.parentWakesConsumed == 0)
            #expect(!screen.snapshot.contains("Sphyrna updates:"))
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("task wait fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func managedParentReadsNestedResultWithoutAnUnprovedWake() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: [
            "LOOM_FAKE_TASK_ROUNDS": "1", "LOOM_FAKE_CODEX_TASK_YIELD": "1", "LOOM_FAKE_CODEX_JOIN": "blank"
        ], scoped: true, durableLedger: true, claudeVersion: "2.0.0", managedClaudeControllerFactory: { run, ingress in
            ManagedClaudeFixtureController(run: run, ingress: ingress)
        })
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("nested-task-wake", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let topScreen = SessionRuntimeTests.Screen()
            let top = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: topScreen)
            topScreen.attach(top.terminal)
            let topClaim = try #require(await context.runtime.taskRunPlans[top.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(topClaim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            let outer = UUID()
            let outerCreate = try Self.helper(["create", "--task", outer.uuidString, "--operation", UUID().uuidString,
                "--name", "Middle", "--harness", "codex", "--message", "-"],
                claim: topClaim, socket: socket, input: "fixture-round-1")
            #expect(outerCreate.0 == 0)
            let middleID = try await context.runtime.approveManagedTaskRequest(outer, expectedProvider: .codex)
            #expect(try await SessionRuntimeTests.waitUntil(5) {
                let status = try await coordinator.status(taskID: outer, parent: topClaim)
                return status.activeRound != nil && status.nativeStatus == .ready
            })
            let original = try #require(try await coordinator.status(taskID: outer, parent: topClaim).activeRound)
            let middleClaim = try #require(await context.runtime.taskRunPlans[middleID]?.claim)
            let inner = UUID()
            let innerCreate = try Self.helper(["create", "--task", inner.uuidString, "--operation", UUID().uuidString,
                "--name", "Leaf", "--harness", "claude", "--message", "-"],
                claim: middleClaim, socket: socket, input: "fixture-round-1")
            #expect(innerCreate.0 == 0)
            let leafID = try await context.runtime.approveManagedTaskRequest(inner, expectedProvider: .claude)
            #expect(try await SessionRuntimeTests.waitUntil(6) {
                try await coordinator.latestEventsForUser(taskID: inner, limit: 10).count == 1
            })
            let nested = try await coordinator.status(taskID: inner, parent: middleClaim)
            #expect(nested.task.parentWakesUsed == 0 && nested.task.parentWakesConsumed == 0)
            let innerRead = try Self.helper(["read", "--task", inner.uuidString], claim: middleClaim, socket: socket)
            #expect(innerRead.0 == 0 && innerRead.1.contains("fixture-result: fixture-round-1"))
            let report = try Self.helper(["report", "--task", outer.uuidString, "--round", original.id.uuidString,
                "--operation", UUID().uuidString, "--kind", "completed", "--message", "-"],
                claim: middleClaim, socket: socket, input: "nested result")
            #expect(report.0 == 0)
            let result = try Self.helper(["read", "--task", outer.uuidString], claim: topClaim, socket: socket)
            #expect(result.0 == 0 && result.1.contains("nested result"))
            let middleBinding = try #require(await context.runtime.authenticateTaskRun(middleClaim))
            let target = SessionTaskRoundTarget(taskID: outer, roundID: original.id, inputOperationID: original.operationID,
                                                binding: middleBinding, nativeTurnID: original.nativeTurnID, execution: nil)
            let host = SessionTaskRuntimeHost(runtime: context.runtime)
            #expect(await host.observedChildExecution(target) != nil)
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            #expect(methods.split(separator: "\n").filter { $0 == "turn/start" }.count == 1)
            #expect(try await context.runtime.stopConversation(sessionID: leafID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: middleID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: top.sessionID).succeeded)
        } catch { Issue.record("nested task wake fixture failed: \(error)") }
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
            scoped: true, durableLedger: true, claudeVersion: "2.0.0", managedClaudeControllerFactory: { run, ingress in
                ManagedClaudeFixtureController(run: run, ingress: ingress)
            })
        defer { context.cleanup() }
        var diagnosticTask: UUID?, diagnosticClaim: SessionTaskClaim?, diagnosticRun: UUID?
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
            let startedID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: childProvider)
            let childRun = try #require(await context.supervisor.session(id: childID)?.currentRun?.id)
            #expect(startedID == childID && childID != parent.sessionID)
            diagnosticRun = childRun
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
            #expect(final.task.childSessionID == childID && final.task.childBinding?.managedRunID == childRun)
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
            let phases = "native=\(String(describing: status?.nativeStatus)), pending=\(String(describing: status?.pendingRound?.phase)), active=\(String(describing: status?.activeRound?.phase))"
            let proof = "observed=\(String(describing: expected?.observed)), receipt=\(String(describing: expected?.expectedNativeTurn)), effect=\(expected?.effect.hasEffect ?? false)"
            Issue.record("synthetic cross-provider task failed: \(error); turns=\(turns), \(phases), \(proof)")
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
