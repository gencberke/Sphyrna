import Foundation
import Testing
@testable import LoomCore

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
        let context = try await SessionRuntimeTests.makeContext(claudeVersion: "2.0.0")
        defer { context.cleanup() }
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
                                message: "Check the synthetic change", harness: "claude").0 == 0)
        let request = try #require(await context.runtime.openRequestSnapshot().first { $0.id == taskID })
        let childID = try #require(request.task?.childID)
        let screen = SessionRuntimeTests.Screen(), gate = context.runtime.inputGate
        do {
            let launch = try await context.runtime.approveOpenRequest(taskID, outputSink: screen, expectedProvider: .claude,
                onTerminalReady: { launch in
                    screen.attach(launch.terminal)
                    gate.register(runID: launch.runID, queue: TerminalInputQueue(endpoint: launch.terminal, onError: { _ in }))
                })
            #expect(launch.sessionID == childID)
            #expect(await screen.contains("FAKE-CLAUDE READY"))
            #expect(await screen.contains("Sphyrna task:"))
            let coordinator = try #require(await context.runtime.taskCoordinator)
            let status = try await coordinator.status(taskID: taskID, parent: claim)
            #expect(status.task.childBinding?.sessionID == childID && status.task.childInputsUsed == 1)
            #expect(status.activeRound?.operationID == operationID)
        } catch {
            Issue.record("approved task did not start and deliver: \(error)")
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func stoppingParentBeforeFirstAdmissionStopsTheEmptyOwnedChild() async throws {
        let context = try await SessionRuntimeTests.makeContext(claudeVersion: "2.0.0")
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("stopped-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
        #expect(try await SessionRuntimeTests.waitUntil(3) { await context.runtime.authenticateTaskRun(claim) != nil })
        let socket = try #require(await context.runtime.taskSocketPath), taskID = UUID()
        #expect(try Self.create(taskID: taskID, operationID: UUID(), claim: claim, socket: socket,
                                message: "Never admitted", harness: "claude").0 == 0)
        let screen = SessionRuntimeTests.Screen()
        let child = try await context.runtime.approveOpenRequest(taskID, outputSink: screen, expectedProvider: .claude,
            onTerminalReady: { screen.attach($0.terminal) }) // No input queue is registered yet.
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        #expect(try await SessionRuntimeTests.waitUntil(3) {
            await context.supervisor.session(id: child.sessionID)?.currentRun == nil
        })
        let report = await context.supervisor.lastStopReport(sessionID: child.sessionID)
        #expect(report?.runID == child.runID && report?.succeeded == true)
        #expect(!screen.snapshot.contains("Sphyrna task:"))
        let coordinator = try #require(await context.runtime.taskCoordinator)
        #expect(try await coordinator.projectionForUser(taskID: taskID)?.lifecycle == .revoked)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func parentStopDuringAwaitedChildSpawnNeverSubmitsTheFirstInput() async throws {
        let context = try await SessionRuntimeTests.makeContext(claudeVersion: "2.0.0")
        defer { context.cleanup() }
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
        let screen = SessionRuntimeTests.Screen(), gate = context.runtime.inputGate
        context.toolchainSwitch.slow(by: 0.7)
        let approval = Task {
            try? await context.runtime.approveOpenRequest(taskID, outputSink: screen, expectedProvider: .codex,
                onTerminalReady: { launch in
                    screen.attach(launch.terminal)
                    gate.register(runID: launch.runID, queue: TerminalInputQueue(endpoint: launch.terminal, onError: { _ in }))
                })
        }
        #expect(await SessionRuntimeTests.waitUntil(3) { context.toolchainSwitch.resolutionsBegun >= 2 })
        #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        let child = await approval.value
        #expect(try await SessionRuntimeTests.waitUntil(5) { await context.supervisor.session(id: childID)?.currentRun == nil })
        if let child {
            let report = await context.supervisor.lastStopReport(sessionID: childID)
            #expect(report?.runID == child.runID && report?.succeeded == true)
        }
        let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
        #expect(!methods.split(separator: "\n").contains("turn/start"))
        #expect(!screen.snapshot.contains("Sphyrna task:"))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test(arguments: [ManagedSession.Provider.claude, .codex])
    func nativeIdentityChangeRevokesTaskAndStopsAnEmptyChild(parentProvider: ManagedSession.Provider) async throws {
        let context = try await SessionRuntimeTests.makeContext(claudeVersion: "2.0.0")
        defer { context.cleanup() }
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
        let screen = SessionRuntimeTests.Screen()
        let child = try await context.runtime.approveOpenRequest(taskID, outputSink: screen, expectedProvider: .claude,
                                                                 onTerminalReady: { screen.attach($0.terminal) })
        try await parentScreen.send(parentProvider == .claude ? "/clear" : "/new")
        #expect(try await SessionRuntimeTests.waitUntil(3) {
            await context.supervisor.activeSessionID(runID: parent.runID) != parent.sessionID
        })
        let coordinator = try #require(await context.runtime.taskCoordinator)
        #expect(try await SessionRuntimeTests.waitUntil(3) {
            try await coordinator.projectionForUser(taskID: taskID)?.lifecycle == .identityChanged
        })
        #expect(try await SessionRuntimeTests.waitUntil(3) { await context.supervisor.session(id: child.sessionID)?.currentRun == nil })
        #expect(await context.runtime.authenticateTaskRun(claim) == nil)
        #expect(!screen.snapshot.contains("Sphyrna task:"))
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
