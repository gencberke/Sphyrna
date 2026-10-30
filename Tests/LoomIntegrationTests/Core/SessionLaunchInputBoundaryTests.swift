import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// A first message given to the CLI as a launch argument is the run's first clean submission: the session takes its
/// mailbox pointer on its first Ready edge. A submission no recorded input explains still holds automatic input back
/// until a later submission proves a clean boundary.
// serialized: each test runs fake Claude and Codex CLIs with hook servers, as the peer suites do
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionLaunchInputBoundaryTests {
    @Test(arguments: [ManagedSession.Provider.claude, .codex])
    func aRunStartedWithAFirstMessageTakesAPointerOnItsFirstReadyEdge(provider: ManagedSession.Provider) async throws {
        let hold = FileManager.default.temporaryDirectory.appendingPathComponent("loom-first-message-\(UUID())")
        let environment = ["LOOM_FAKE_TASK_ROUNDS": "1", "LOOM_FAKE_CODEX_USER_ITEMS": "1",
                           "LOOM_FAKE_HOLD_FIRST_MESSAGE": hold.path]
        let rig = try await SessionRuntimeRig.makeContext(extraEnvironment: environment, claudeVersion: "2.0.0")
        defer { rig.cleanup(); try? FileManager.default.removeItem(at: hold) }
        do {
            let folder = rig.root.appendingPathComponent("first-message", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await rig.catalog.addProject(path: folder.path).project
            let first = "first message \(UUID().uuidString.prefix(8))"
            let choices = provider == .codex ? HarnessLaunchChoices(harness: .codex) : HarnessLaunchChoices()
            let screen = SessionRuntimeRig.Screen()
            let launch = try await rig.runtime.startConversation(provider: provider, projectID: project.id, outputSink: screen,
                draft: NewSessionLaunch(firstMessage: first, choices: choices))
            screen.attach(launch.terminal)
            // As the app's surface: the terminal is attached before the CLI reads its first prompt.
            let queue = TerminalInputQueue(endpoint: launch.terminal, onError: { _ in })
            rig.runtime.inputGate.register(runID: launch.runID, queue: queue)
            try Data().write(to: hold)
            let echo = provider == .codex ? "CODEX-TURN-DONE completed echo \(first)" : "echo: \(first)"
            #expect(await screen.contains(echo), "the first message ran: \(screen.snapshot.suffix(300))")
            let claim = try #require(await rig.runtime.taskRunPlans[launch.sessionID]?.claim)
            #expect(await SessionRuntimeRig.waitUntil(5) {
                guard let binding = await rig.runtime.authenticateTaskRun(claim) else { return false }
                return await rig.runtime.taskNativeStatus(binding) == .ready
            })
            _ = try await rig.runtime.sendUserMessage("comments \(UUID().uuidString)", to: launch.sessionID,
                                                      senderTitle: "Changes")
            let pointer = provider == .codex ? "FAKE-PEER-WAKE" : "Sphyrna: message"
            #expect(await screen.contains(pointer, timeout: 6),
                    "no keystroke was typed, yet the pointer came on the first Ready edge: \(screen.snapshot.suffix(300))")
            #expect(try await rig.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        } catch { Issue.record("first-message fixture failed: \(error)") }
        #expect((await rig.runtime.shutdown()).succeeded)
    }

    @Test func anUnclassifiedSubmissionDefersUntilALaterCleanBoundary() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                claudeVersion: "2.0.0")
        defer { context.cleanup() }
        do {
            let folder = context.root.appendingPathComponent("unclassified", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let screen = SessionRuntimeRig.Screen()
            let launch = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
            screen.attach(launch.terminal)
            let queue = TerminalInputQueue(endpoint: launch.terminal, onError: { _ in })
            context.runtime.inputGate.register(runID: launch.runID, queue: queue)
            let claim = try #require(await context.runtime.taskRunPlans[launch.sessionID]?.claim)
            @Sendable func ready() async -> Bool {
                guard let binding = await context.runtime.authenticateTaskRun(claim) else { return false }
                return await context.runtime.taskNativeStatus(binding) == .ready
            }
            #expect(await SessionRuntimeRig.waitUntil(5) { await ready() })
            // An edit key: the submitted line is not the bytes the queue saw, so it proves no clean boundary.
            #expect(queue.enqueue(Data("/work 300\u{7f}0\r".utf8)))
            #expect(await screen.contains("WORKING 300"))
            #expect(await SessionRuntimeRig.waitUntil(5) { await ready() })
            _ = try await context.runtime.sendUserMessage("held comments", to: launch.sessionID, senderTitle: "Changes")
            #expect(await SessionRuntimeRig.waitUntil(5) {
                let needed = await context.runtime.peersNeedingDelivery.contains(launch.sessionID)
                let running = await context.runtime.peerDeliveriesInFlight.contains(launch.sessionID)
                return needed && !running
            }, "the delivery pass ended deferred")
            #expect(!screen.snapshot.contains("Sphyrna: message"), "an unknown submission still holds automatic input")
            // A plain typed line the provider reports exactly proves the boundary; its turn's Ready edge delivers.
            #expect(queue.enqueue(Data("/work 200\r".utf8)))
            #expect(await screen.contains("Sphyrna: message", timeout: 6), "\(screen.snapshot.suffix(300))")
            #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        } catch { Issue.record("unclassified fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
