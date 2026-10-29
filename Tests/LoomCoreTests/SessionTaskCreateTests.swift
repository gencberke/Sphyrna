import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionTaskCreateTests {
    private static func create(taskID: UUID, operationID: UUID, claim: SessionTaskClaim,
                               socket: String, message: String, harness: String = "codex") throws -> (Int32, String) {
        let process = Process()
        process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-hook")
        process.arguments = ["task", "create", "--task", taskID.uuidString, "--operation", operationID.uuidString,
                             "--name", "Review task", "--harness", harness, "--message", "-"]
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

    @Test func approvingATaskStartsTheOwnedChildAndDeliversItsFirstPointerOnlyAfterReady() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
            scoped: true, durableLedger: true, claudeVersion: "2.0.0", managedClaudeControllerFactory: { run, ingress in
                ManagedClaudeFixtureController(run: run, ingress: ingress)
            })
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("approved-task", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parentScreen = SessionRuntimeTests.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: parentScreen)
            parentScreen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath)
            let taskID = UUID(), operationID = UUID()
            #expect(try Self.create(taskID: taskID, operationID: operationID, claim: claim, socket: socket,
                                    message: "fixture-round-1", harness: "claude").0 == 0)
            let request = try #require(await context.runtime.openRequestSnapshot().first { $0.id == taskID })
            let childID = try #require(request.task?.childID)
            let started = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .claude)
            #expect(started == childID)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            #expect(try await SessionRuntimeTests.waitUntil(6) {
                try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).count == 1
            })
            let status = try await coordinator.status(taskID: taskID, parent: claim)
            #expect(status.task.childBinding?.sessionID == childID && status.task.childInputsUsed == 1)
            #expect(try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).first?.payload ==
                    "fixture-result: fixture-round-1")
        } catch {
            Issue.record("approved task did not start and deliver: \(error)")
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func stoppingParentBeforeFirstAdmissionStopsTheEmptyOwnedChild() async throws {
        let inputGate = ManagedClaudeFixtureInputGate()
        let context = try await SessionRuntimeTests.makeContext(scoped: true, durableLedger: true, claudeVersion: "2.0.0",
            managedClaudeControllerFactory: { run, ingress in
                ManagedClaudeFixtureController(run: run, ingress: ingress, inputGate: inputGate)
            })
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("stopped-parent", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath), taskID = UUID()
            #expect(try Self.create(taskID: taskID, operationID: UUID(), claim: claim, socket: socket,
                                    message: "Never admitted", harness: "claude").0 == 0)
            let childID = try #require(await context.runtime.openRequestSnapshot().first?.task?.childID)
            let approval = Task { try? await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .claude) }
            #expect(await SessionRuntimeTests.waitUntil(5) { await inputGate.entered })
            let childRun = try #require(await context.supervisor.session(id: childID)?.currentRun?.id)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
            await inputGate.release()
            _ = await approval.value
            #expect(try await SessionRuntimeTests.waitUntil(3) {
                await context.supervisor.session(id: childID)?.currentRun == nil
            })
            let report = await context.supervisor.lastStopReport(sessionID: childID)
            #expect(report?.runID == childRun && report?.succeeded == true)
            #expect(await context.runtime.taskLaunchContexts[taskID]?.firstInputEffect?.hasEffect != true)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            #expect(try await coordinator.projectionForUser(taskID: taskID)?.lifecycle == .revoked)
        } catch {
            await inputGate.release()
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func parentStopDuringAwaitedChildSpawnNeverSubmitsTheFirstInput() async throws {
        let context = try await SessionRuntimeTests.makeContext(scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("stop-during-spawn", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath), taskID = UUID()
            #expect(try Self.create(taskID: taskID, operationID: UUID(), claim: claim, socket: socket,
                                    message: "Must not run", harness: "codex").0 == 0)
            let childID = try #require(await context.runtime.openRequestSnapshot().first?.task?.childID)
            context.toolchainSwitch.slow(by: 0.7)
            let approval = Task {
                try? await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            }
            #expect(await SessionRuntimeTests.waitUntil(3) { context.toolchainSwitch.resolutionsBegun >= 2 })
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
            let child = await approval.value
            #expect(try await SessionRuntimeTests.waitUntil(5) { await context.supervisor.session(id: childID)?.currentRun == nil })
            if child != nil {
                let report = await context.supervisor.lastStopReport(sessionID: childID)
                #expect(report?.succeeded == true)
            }
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            #expect(!methods.split(separator: "\n").contains("turn/start"))
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: [ManagedSession.Provider.claude, .codex])
    func nativeIdentityChangeRevokesTaskAndStopsAnEmptyChild(parentProvider: ManagedSession.Provider) async throws {
        let inputGate = ManagedClaudeFixtureInputGate()
        let context = try await SessionRuntimeTests.makeContext(scoped: true, durableLedger: true, claudeVersion: "2.0.0",
            managedClaudeControllerFactory: { run, ingress in
                ManagedClaudeFixtureController(run: run, ingress: ingress, inputGate: inputGate)
            })
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("identity-change", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parentScreen = SessionRuntimeTests.Screen()
            let parent = try await context.runtime.startConversation(provider: parentProvider, projectID: project.id, outputSink: parentScreen)
            parentScreen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath), taskID = UUID()
            #expect(try Self.create(taskID: taskID, operationID: UUID(), claim: claim, socket: socket,
                                    message: "Do not retarget", harness: "claude").0 == 0)
            let childID = try #require(await context.runtime.openRequestSnapshot().first?.task?.childID)
            let approval = Task { try? await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .claude) }
            #expect(await SessionRuntimeTests.waitUntil(5) { await inputGate.entered })
            try await parentScreen.send(parentProvider == .claude ? "/clear" : "/new")
            #expect(try await SessionRuntimeTests.waitUntil(3) {
                await context.supervisor.activeSessionID(runID: parent.runID) != parent.sessionID
            })
            let coordinator = try #require(await context.runtime.taskCoordinator)
            #expect(try await SessionRuntimeTests.waitUntil(3) {
                try await coordinator.projectionForUser(taskID: taskID)?.lifecycle == .identityChanged
            })
            await inputGate.release()
            _ = await approval.value
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.supervisor.session(id: childID)?.currentRun == nil })
            #expect(await context.runtime.authenticateTaskRun(claim) == nil)
            #expect(await context.runtime.taskLaunchContexts[taskID]?.firstInputEffect?.hasEffect != true)
        } catch {
            await inputGate.release()
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func taskStopNeverFollowsAChildThatMovedWhileStopWaited() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1",
            "LOOM_FAKE_TASK_HOLD_FIRST": "1"], scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        let hold = TaskDeletionTransitionGate()
        defer { hold.release() }
        do {
            let folder = context.root.appendingPathComponent("task-stop-move", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath), taskID = UUID()
            #expect(try Self.create(taskID: taskID, operationID: UUID(), claim: claim, socket: socket,
                                    message: "Do not follow a moved child", harness: "codex").0 == 0)
            let childID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            let childRun = try #require(await context.supervisor.session(id: childID)?.currentRun?.id)
            #expect(try await SessionRuntimeTests.waitUntil(5) {
                try await context.runtime.sessionTaskProjection(id: taskID)?.childBinding != nil
            })
            let projection = try #require(try await context.runtime.sessionTaskProjection(id: taskID))
            let binding = try #require(projection.childBinding)
            let blocked = Task.detached { await context.catalog.holdTaskDeletionTransition(hold) }
            #expect(await SessionRuntimeTests.waitUntil(3) { hold.entered })
            let adoption = Task { try await context.supervisor.adoptConversation(runID: childRun,
                                                        conversationID: UUID().uuidString, transition: .new) }
            #expect(await SessionRuntimeTests.waitUntil(3) { await context.supervisor.pendingConversationTransitionCount() > 0 })
            let stop = Task { await context.runtime.stopTaskChild(taskID: taskID, childSessionID: childID, binding: binding) }
            #expect(await SessionRuntimeTests.waitUntil(3) { await context.supervisor.pendingStopCount() > 0 })
            hold.release()
            await blocked.value
            let moved = try await adoption.value
            let result = await stop.value
            if case .unknown = result {} else { Issue.record("a moved run must not be reported as the stopped task child") }
            #expect(await context.supervisor.session(id: moved)?.currentRun?.id == childRun)
        } catch { Issue.record("task stop/move race failed: \(error)") }
        hold.release()
        let shutdown = await context.runtime.shutdown()
        #expect(shutdown.succeeded, "shutdown errors=\(shutdown.errors); remaining=\(shutdown.remaining)")
    }

    @Test func removingParentStopsItsOwnedChildAndForgetsOnlyTheRelationship() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1",
            "LOOM_FAKE_TASK_HOLD_FIRST": "1"], scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("task-deletion", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath), taskID = UUID()
            #expect(try Self.create(taskID: taskID, operationID: UUID(), claim: claim, socket: socket,
                                    message: "Retain until stopped", harness: "codex").0 == 0)
            let childID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            #expect(try await SessionRuntimeTests.waitUntil(3) {
                await context.runtime.taskLaunchContexts[taskID]?.firstInputEffect?.hasEffect == true
            })
            let pendingTask = UUID()
            #expect(try Self.create(taskID: pendingTask, operationID: UUID(), claim: claim, socket: socket,
                                    message: "A pending request is also forgotten", harness: "codex").0 == 0)
            #expect(await context.runtime.openRequestSnapshot().contains { $0.id == pendingTask })
            try await context.runtime.removeFromLoomOnly(id: parent.sessionID)
            #expect(!(await context.runtime.openRequestSnapshot()).contains { $0.id == pendingTask })
            #expect(await context.supervisor.session(id: childID)?.currentRun == nil)
            #expect((await context.supervisor.lastStopReport(sessionID: childID))?.succeeded == true)
            #expect(try await context.catalog.session(id: parent.sessionID) == nil)
            #expect(try await context.catalog.session(id: childID) != nil)
            #expect(try await context.runtime.sessionTaskProjection(id: taskID) == nil)
        } catch { Issue.record("parent deletion failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func deletingParentAfterTheManagedFactoryFailsBeforeSpawn() async throws {
        let context = try await SessionRuntimeTests.makeContext(scoped: true, durableLedger: true, claudeVersion: "2.0.0",
            managedClaudeControllerFactory: { _, _ in throw LoomError.message("synthetic factory refusal") })
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("task-factory-refused", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath), taskID = UUID()
            #expect(try Self.create(taskID: taskID, operationID: UUID(), claim: claim, socket: socket,
                                    message: "No process is started", harness: "claude").0 == 0)
            let childID = try #require(await context.runtime.openRequestSnapshot().first?.task?.childID)
            await #expect(throws: SessionTaskError.self) {
                _ = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .claude)
            }
            #expect(await context.runtime.taskLaunchContexts[taskID]?.managedRun == nil)
            #expect(await context.supervisor.session(id: childID)?.currentRun == nil)
            #expect((await context.supervisor.ledgerSnapshot()).managedTaskScopes?.isEmpty != false)
            do { try await context.runtime.removeFromLoomOnly(id: parent.sessionID) }
            catch { Issue.record("Never-spawned managed child blocked parent deletion: \(error)") }
            #expect(try await context.catalog.session(id: parent.sessionID) == nil)
            #expect(try await context.runtime.sessionTaskProjection(id: taskID) == nil)
        } catch { Issue.record("Factory refusal deletion fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: [ManagedSession.Provider.claude, .codex])
    func parentDeletionWaitsForAnOpeningManagedScope(provider: ManagedSession.Provider) async throws {
        let gate = ManagedClaudeFixtureInputGate()
        let context = try await SessionRuntimeTests.makeContext(scoped: true, durableLedger: true, claudeVersion: "2.0.0",
            managedClaudeControllerFactory: { run, ingress in ManagedClaudeFixtureController(run: run, ingress: ingress) })
        defer { context.cleanup() }
        do {
            await context.runtime.observeManagedScopeOpenedForTesting { _ in await gate.hold() }
            let folder = context.root.appendingPathComponent("task-opening-scope", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath), taskID = UUID()
            let harness = provider == .claude ? "claude" : "codex"
            #expect(try Self.create(taskID: taskID, operationID: UUID(), claim: claim, socket: socket,
                                    message: "No child input is admitted", harness: harness).0 == 0)
            let childID = try #require(await context.runtime.openRequestSnapshot().first?.task?.childID)
            let approval = Task { try? await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: provider) }
            try #require(await SessionRuntimeTests.waitUntil(5) { await gate.entered })
            await #expect(throws: SessionRuntimeError.self) {
                try await context.runtime.removeFromLoomOnly(id: parent.sessionID)
            }
            let held = try #require(try await context.runtime.sessionTaskProjection(id: taskID))
            #expect(held.lifecycle != .stopped && held.childBinding == nil)
            #expect(try await context.runtime.pendingDeletions().contains { $0.id == parent.sessionID })
            #expect(await context.supervisor.session(id: childID)?.currentRun == nil)
            await gate.release()
            _ = await approval.value
            try await context.runtime.removeFromLoomOnly(id: parent.sessionID)
            #expect(try await context.runtime.sessionTaskProjection(id: taskID) == nil)
            #expect(await context.supervisor.session(id: childID)?.currentRun == nil)
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            #expect(!methods.split(separator: "\n").contains("turn/start"))
        } catch {
            await gate.release()
            Issue.record("Opening scope deletion fixture failed: \(error)")
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func unverifiedChildStopKeepsTaskUntilDeletionRetry() async throws {
        let context = try await SessionRuntimeTests.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1",
            "LOOM_FAKE_TASK_HOLD_FIRST": "1"], scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        let failure = TaskDeletionFailure()
        do {
            let folder = context.root.appendingPathComponent("task-delete-retry", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
            let socket = try #require(await context.runtime.taskSocketPath), taskID = UUID()
            #expect(try Self.create(taskID: taskID, operationID: UUID(), claim: claim, socket: socket,
                                    message: "Keep this task on stop failure", harness: "codex").0 == 0)
            let childID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            let childRun = try #require(await context.supervisor.session(id: childID)?.currentRun?.id)
            #expect(try await SessionRuntimeTests.waitUntil(3) {
                await context.runtime.taskLaunchContexts[taskID]?.firstInputEffect?.hasEffect == true
            })
            try await context.supervisor.registerStopHooks(runID: childRun, hooks: ManagedRunStopHooks(
                prepare: { if failure.isOn { throw LoomError.message("synthetic stop failure") } }, completed: {}))
            await #expect(throws: SessionRuntimeError.self) {
                try await context.runtime.removeFromLoomOnly(id: parent.sessionID)
            }
            #expect(await context.supervisor.session(id: childID)?.currentRun?.id == childRun)
            #expect(try await context.runtime.sessionTaskProjection(id: taskID)?.lifecycle == .stopUnverified)
            #expect(try await context.runtime.pendingDeletions().contains { $0.id == parent.sessionID })
            failure.clear()
            try await context.runtime.removeFromLoomOnly(id: parent.sessionID)
            #expect(await context.supervisor.session(id: childID)?.currentRun == nil)
            #expect(try await context.catalog.session(id: childID) != nil)
            #expect(try await context.runtime.sessionTaskProjection(id: taskID) == nil)
        } catch { Issue.record("task deletion retry failed: \(error)") }
        failure.clear()
        #expect((await context.runtime.shutdown()).succeeded)
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

private final class TaskDeletionFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    var isOn: Bool { lock.withLock { enabled } }
    func clear() { lock.withLock { enabled = false } }
}

private final class TaskDeletionTransitionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false
    var entered: Bool { condition.withLock { waiting } }
    func hold() {
        condition.lock()
        waiting = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private extension SessionCatalog {
    func holdTaskDeletionTransition(_ gate: TaskDeletionTransitionGate) { gate.hold() }
}
