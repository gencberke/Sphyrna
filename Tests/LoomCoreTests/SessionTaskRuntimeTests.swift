import Foundation
import Testing
@testable import LoomCore

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionTaskRuntimeTests {
    @Test func approvedClaudeChildStartsEmptyBeforeAnyTaskInput() async throws {
        let context = try await SessionRuntimeTests.makeContext(claudeVersion: "2.0.0")
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("owned-claude-task", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let parentScreen = SessionRuntimeTests.Screen()
        let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: parentScreen)
        parentScreen.attach(parent.terminal)
        #expect(try await SessionRuntimeTests.waitUntil(3) {
            await context.supervisor.runContext(runID: parent.runID)?.session.providerConversationID != nil
        })
        let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
        let coordinator = try #require(await context.runtime.taskCoordinator)
        let taskID = UUID(), childID = UUID()
        let choices = HarnessLaunchChoices(harness: .claude, effort: "high", mode: .askBeforeEdits)
        try await context.runtime.reserveTaskChild(taskID: taskID, childID: childID, parent: claim)
        let task = try await coordinator.createApproved(taskID: taskID, parent: claim, childID: childID,
            harness: .claude, childName: "Owned Claude task", choices: choices)
        let childScreen = SessionRuntimeTests.Screen()
        let child = try await context.runtime.startConversation(provider: .claude, projectID: project.id,
            outputSink: childScreen, opening: SessionOpening(approvedTask: task, firstMessage: "UNEXPECTED FIRST INPUT"))
        childScreen.attach(child.terminal)
        #expect(child.sessionID == childID)
        #expect(await childScreen.contains("FAKE-CLAUDE READY"))
        // The fake handles any positional first message before it reads this explicit input.
        try await childScreen.send("manual probe")
        #expect(await childScreen.contains("echo: manual probe"))
        #expect(!childScreen.snapshot.contains("echo: UNEXPECTED FIRST INPUT"))
        #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
        #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func approvedCodexChildStartsEmptyWithItsOwnedIdentityAndChoices() async throws {
        let model = ModelCatalogEntry(harness: .codex, id: "fake-codex-alpha", title: "Fake Codex",
                                      efforts: ["low", "high"], defaultEffort: "low", isDefault: true)
        let context = try await SessionRuntimeTests.makeContext(openedModels: { _ in [model] })
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("owned-task", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let parentScreen = SessionRuntimeTests.Screen()
        let parent = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: parentScreen)
        parentScreen.attach(parent.terminal)
        #expect(try await SessionRuntimeTests.waitUntil(3) {
            await context.supervisor.runContext(runID: parent.runID)?.session.providerConversationID != nil
        })
        let claim = try #require(await context.runtime.taskRunPlans[parent.sessionID]?.claim)
        let coordinator = try #require(await context.runtime.taskCoordinator)
        let taskID = UUID(), childID = UUID()
        let choices = HarnessLaunchChoices(harness: .codex, model: model.id, effort: "high", mode: .acceptEdits)
        try await context.runtime.reserveTaskChild(taskID: taskID, childID: childID, parent: claim)
        let task = try await coordinator.createApproved(taskID: taskID, parent: claim, childID: childID,
            harness: .codex, childName: "Owned task", choices: choices)
        let opening = SessionOpening(approvedTask: task, firstMessage: "UNEXPECTED FIRST INPUT")
        let childScreen = SessionRuntimeTests.Screen()
        let child = try await context.runtime.startConversation(provider: .codex, projectID: project.id,
            outputSink: childScreen, opening: opening)
        childScreen.attach(child.terminal)
        #expect(child.sessionID == childID)
        #expect(try await context.catalog.session(id: childID)?.session.providerConversationID != nil)
        let arguments = try String(contentsOf: context.state.appendingPathComponent("codex-tui-arguments.log"), encoding: .utf8)
        let argv = try #require(JSONSerialization.jsonObject(with: Data(arguments.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String])
        #expect(!argv.contains("UNEXPECTED FIRST INPUT"))
        #expect(argv.contains("fake-codex-alpha") && argv.contains("model_reasoning_effort=\"high\""))
        let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? ""
        #expect(!methods.split(separator: "\n").contains("turn/start"))
        do {
            _ = try await context.runtime.startConversation(provider: .codex, projectID: project.id, opening: opening)
            Issue.record("A task child cannot adopt an existing row")
        } catch { #expect(error as? SessionTaskError == .unauthorized) }
        #expect(try await context.runtime.stopConversation(sessionID: childID).succeeded)
        #expect(try await context.runtime.stopConversation(sessionID: parent.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
