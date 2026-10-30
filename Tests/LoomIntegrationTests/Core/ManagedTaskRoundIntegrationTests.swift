import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct ManagedTaskRoundIntegrationTests {
    @Test func codexInterruptReceiptAloneCannotStartAReplacementRound() async throws {
        let context = try await SessionRuntimeRig.makeContext(fakeCodexHasNoSandbox: true, extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1",
            "LOOM_FAKE_TASK_HOLD_FIRST": "1", "LOOM_FAKE_CODEX_INTERRUPT_REPLY_ONLY": "1"],
            scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("managed-interrupt-receipt", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let screen = SessionRuntimeRig.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
            screen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeRig.waitUntil(5) { await context.runtime.authenticateTaskRun(claim) != nil })
            let taskID = UUID()
            try await screen.send("/fake-sphyrna-task-create \(taskID.uuidString) \(UUID().uuidString) codex")
            #expect(await screen.contains("FAKE-TASK-CREATE-OK"))
            _ = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            #expect(try await SessionRuntimeRig.waitUntil(5) {
                let status = try await coordinator.status(taskID: taskID, parent: claim)
                return status.activeRound != nil && status.nativeStatus == .working
            })
            let first = try #require(try await coordinator.status(taskID: taskID, parent: claim).activeRound)
            let receipt = try await coordinator.interruptAndUpdate(taskID: taskID, parent: claim, roundID: first.id,
                operationID: UUID(), nextOperationID: UUID(), message: "must remain queued")
            #expect(receipt.delivery == .unverified)
            let status = try await coordinator.status(taskID: taskID, parent: claim)
            #expect(status.task.lifecycle == .revoked && status.pendingRound?.phase == .queued)
            let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
            #expect(methods.split(separator: "\n").filter { $0 == "turn/start" }.count == 1)
            #expect(methods.split(separator: "\n").filter { $0 == "turn/interrupt" }.count == 1)
        } catch { Issue.record("managed interrupt receipt fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func codexParentUsesOneManagedClaudePipeChildForThreeRounds() async throws {
        let context = try await SessionRuntimeRig.makeContext(fakeCodexHasNoSandbox: true, extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
            scoped: true, durableLedger: true, claudeVersion: "2.0.0", managedClaudeControllerFactory: { run, ingress in
                ManagedClaudeFixtureController(run: run, ingress: ingress)
            })
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("managed-claude-rounds", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let screen = SessionRuntimeRig.Screen()
            let parent = try await context.runtime.startConversation(provider: .codex, projectID: project.id, outputSink: screen)
            screen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeRig.waitUntil(5) { await context.runtime.authenticateTaskRun(claim) != nil })
            let taskID = UUID()
            try await screen.send("/fake-sphyrna-task-create \(taskID.uuidString) \(UUID().uuidString) claude")
            #expect(await screen.contains("FAKE-TASK-CREATE-OK"))
            let childID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .claude)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            #expect(try await SessionRuntimeRig.waitUntil(10) {
                try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).count == 1
            })
            let first = try await coordinator.status(taskID: taskID, parent: claim)
            let binding = try #require(first.task.childBinding)
            #expect(binding.sessionID == childID && UUID(uuidString: binding.nativeSessionID) != nil)
            for round in 2...3 {
                _ = try await coordinator.requestRound(taskID: taskID, parent: claim, operationID: UUID(),
                                                       message: "fixture-round-\(round)")
                await context.runtime.markTaskNeedsDelivery(taskID)
                #expect(try await SessionRuntimeRig.waitUntil(10) {
                    try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).count == round
                })
            }
            let events = try await coordinator.latestEventsForUser(taskID: taskID, limit: 10)
            #expect(events.map(\.payload) == (1...3).map { "fixture-result: fixture-round-\($0)" })
            #expect(Set(events.map(\.roundID)).count == 3 && events.allSatisfy { $0.nativeTurnID == nil })
            #expect((try await coordinator.status(taskID: taskID, parent: claim)).task.childBinding == binding)
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("managed Claude three-round fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func takeoverRejectsStaleRunAndResumesTheSameNativeSession() async throws {
        let context = try await SessionRuntimeRig.makeContext(fakeCodexHasNoSandbox: true, extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
            scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("managed-takeover", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let parentScreen = SessionRuntimeRig.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: parentScreen)
            parentScreen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeRig.waitUntil(5) { await context.runtime.authenticateTaskRun(claim) != nil })
            let taskID = UUID()
            try await parentScreen.send("/fake-sphyrna-task-create \(taskID.uuidString) \(UUID().uuidString) codex")
            #expect(await parentScreen.contains("FAKE-TASK-CREATE-OK"))
            let childID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            #expect(try await SessionRuntimeRig.waitUntil(10) {
                try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).count == 1
            })
            let receivedProgress = try await SessionRuntimeRig.waitUntil(5) {
                await context.runtime.managedTaskPresentation(taskID: taskID)?.progress.isEmpty == false
            }
            try #require(await SessionRuntimeRig.waitUntil(5) {
                await context.runtime.managedTaskPresentation(taskID: taskID)?.status == .ready
            })
            let view = try #require(await context.runtime.managedTaskPresentation(taskID: taskID))
            let binding = try #require(view.binding)
            #expect(receivedProgress, "managed provider progress was not presented")
            let entry = try ManagedTaskProgress(kind: .message, text: "owned fixture progress")
            let seeded = try ManagedTaskPresentation(run: view.run, binding: binding, effectiveSettings: view.effectiveSettings,
                status: view.status, progress: [entry], permissions: view.permissions, canTakeOver: view.canTakeOver)
            await context.runtime.publishManagedTaskPresentation(seeded)
            let lease = try #require(await context.runtime.taskRunPlans[childID]?.lease)
            let client = try #require(await context.runtime.managedTaskFixtureClient(runID: view.run.runID))
            func status(_ active: Bool) async throws {
                _ = try await client.request(method: "fixture/taskStatus", params: .object([
                    "threadId": .string(binding.nativeSessionID), "active": .bool(active),
                ]), timeout: 2)
            }
            func observeWhileIngressIsHeld() async throws -> ManagedTaskPresentation? {
                lease.beginHook()
                defer { lease.finishHook() }
                try await status(true)
                #expect(await SessionRuntimeRig.waitUntil(3) {
                    await context.supervisor.providerWorkState(sessionID: childID)?.activity == .working
                })
                await context.runtime.refreshManagedCodexStatus(taskID: taskID, runID: view.run.runID)
                return await context.runtime.managedTaskPresentation(taskID: taskID)
            }
            let duringIngress = try await observeWhileIngressIsHeld()
            #expect(duringIngress?.status == view.status && duringIngress?.progress == [entry],
                    "before=\(view.status), during=\(String(describing: duringIngress?.status)), progress=\(duringIngress?.progress.count ?? -1)")
            #expect(await SessionRuntimeRig.waitUntil(3) {
                await context.runtime.managedTaskPresentation(taskID: taskID)?.status == .working
            })
            try await status(false)
            #expect(await SessionRuntimeRig.waitUntil(3) {
                await context.runtime.managedTaskPresentation(taskID: taskID)?.status == .ready
            })
            let childSnapshot = try #require(try await context.runtime.managedTaskForChild(sessionID: childID))
            #expect(childSnapshot.task.id == taskID && childSnapshot.presentation?.binding == binding)
            #expect(await context.supervisor.events.snapshot().sessions[childID]?.managedTaskID == taskID)
            await #expect(throws: SessionTaskError.self) {
                _ = try await context.runtime.takeOverManagedTask(taskID: taskID, expectedRunID: view.run.runID,
                    expectedGeneration: UUID())
            }
            #expect((await context.supervisor.session(id: childID))?.currentRun?.id == view.run.runID)
            let screen = SessionRuntimeRig.Screen()
            let takeover = try await context.runtime.takeOverManagedTask(taskID: taskID,
                expectedRunID: view.run.runID, expectedGeneration: view.run.generation, outputSink: screen)
            screen.attach(takeover.terminal)
            #expect(takeover.sessionID == childID && takeover.runID != view.run.runID)
            #expect((await context.supervisor.session(id: childID))?.providerConversationID == binding.nativeSessionID)
            #expect((try await coordinator.projectionForUser(taskID: taskID))?.lifecycle == .revoked)
            #expect(await context.supervisor.events.snapshot().sessions[childID]?.managedTaskID == nil)
            #expect(await context.runtime.managedTaskPresentation(taskID: taskID)?.progress.isEmpty == true)
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch { Issue.record("managed takeover fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func managedCodexPermissionRequiresTheShownLiveOccurrence() async throws {
        let context = try await SessionRuntimeRig.makeContext(fakeCodexHasNoSandbox: true, extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1",
            "LOOM_FAKE_TASK_APPROVAL": "1"], scoped: true, durableLedger: true, claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("managed-approval", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let screen = SessionRuntimeRig.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
            screen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeRig.waitUntil(5) { await context.runtime.authenticateTaskRun(claim) != nil })
            let taskID = UUID()
            try await screen.send("/fake-sphyrna-task-create \(taskID.uuidString) \(UUID().uuidString) codex")
            #expect(await screen.contains("FAKE-TASK-CREATE-OK"))
            _ = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            #expect(try await SessionRuntimeRig.waitUntil(10) {
                await context.runtime.managedTaskPresentation(taskID: taskID)?.permissions.count == 1
            })
            let view = try #require(await context.runtime.managedTaskPresentation(taskID: taskID))
            let request = try #require(view.permissions.first)
            #expect(view.status == .waitingForUser)
            await #expect(throws: SessionTaskError.self) {
                _ = try await context.runtime.respondManagedTask(taskID: taskID, expectedRunID: view.run.runID,
                    expectedGeneration: UUID(), occurrenceID: request.id, decision: .allow)
            }
            let audit = context.state.appendingPathComponent("codex-approvals.log")
            #expect(!FileManager.default.fileExists(atPath: audit.path))
            #expect(try await context.runtime.respondManagedTask(taskID: taskID, expectedRunID: view.run.runID,
                expectedGeneration: view.run.generation, occurrenceID: request.id, decision: .allow) == .submitted)
            #expect(try await SessionRuntimeRig.waitUntil(5) {
                await context.runtime.managedTaskPresentation(taskID: taskID)?.permissions.isEmpty == true
            })
            await #expect(throws: SessionTaskError.self) {
                _ = try await context.runtime.respondManagedTask(taskID: taskID, expectedRunID: view.run.runID,
                    expectedGeneration: view.run.generation, occurrenceID: request.id, decision: .allow)
            }
            #expect(try await SessionRuntimeRig.waitUntil(5) { FileManager.default.fileExists(atPath: audit.path) })
            let entries = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n")
            #expect(entries.count == 1 && entries.first?.hasSuffix(" accept") == true)
        } catch { Issue.record("managed permission fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func claudeParentUsesOneManagedCodexChildForThreeRounds() async throws {
        let context = try await SessionRuntimeRig.makeContext(fakeCodexHasNoSandbox: true, extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                 scoped: true, durableLedger: true,
                                                                 claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("managed-three-rounds", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let screen = SessionRuntimeRig.Screen()
            let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
            screen.attach(parent.terminal)
            let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
            #expect(try await SessionRuntimeRig.waitUntil(5) { await context.runtime.authenticateTaskRun(claim) != nil })
            let taskID = UUID(), operationID = UUID()
            try await screen.send("/fake-sphyrna-task-create \(taskID.uuidString) \(operationID.uuidString) codex")
            #expect(await screen.contains("FAKE-TASK-CREATE-OK"))
            let childID = try await context.runtime.approveManagedTaskRequest(taskID, expectedProvider: .codex)
            let coordinator = try #require(await context.runtime.taskCoordinator)
            #expect(try await SessionRuntimeRig.waitUntil(10) {
                try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).count == 1
            })
            let first = try await coordinator.status(taskID: taskID, parent: claim)
            let binding = try #require(first.task.childBinding)
            #expect(binding.sessionID == childID)
            #expect((await context.supervisor.session(id: childID))?.currentRun?.id == binding.managedRunID)
            #expect((await context.runtime.managedTaskPresentation(taskID: taskID))?.binding == binding)
            for round in 2...3 {
                _ = try await coordinator.requestRound(taskID: taskID, parent: claim, operationID: UUID(),
                                                       message: "fixture-round-\(round)")
                await context.runtime.markTaskNeedsDelivery(taskID)
                #expect(try await SessionRuntimeRig.waitUntil(10) {
                    try await coordinator.latestEventsForUser(taskID: taskID, limit: 10).count == round
                })
            }
            let events = try await coordinator.latestEventsForUser(taskID: taskID, limit: 10)
            #expect(events.map(\.payload) == (1...3).map { "fixture-result: fixture-round-\($0)" })
            #expect(Set(events.map(\.roundID)).count == 3)
            #expect(Set(events.compactMap(\.nativeTurnID)).count == 3)
            let latest = try await coordinator.status(taskID: taskID, parent: claim)
            #expect(latest.task.childBinding == binding)
            #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
            #expect((await context.supervisor.ledgerSnapshot()).managedTaskScopes?.isEmpty == true)
            #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        } catch {
            Issue.record("managed three-round fixture failed: \(error)")
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}

private extension SessionRuntime {
    func managedTaskFixtureClient(runID: UUID) -> CodexAppServerClient? {
        runs[runID]?.server?.client
    }
}
