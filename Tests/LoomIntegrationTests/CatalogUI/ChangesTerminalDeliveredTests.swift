import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs
@testable import LoomCoreTestRigs

/// B2 (r9 closing optimizer): "Delivered" takes away exactly the comments the session read. A comment the 16 KiB bound left
/// out of the message stays, and the footer says how many; a comment edited while the message waited stays with its new
/// text; the ones that went as they are written go.
@MainActor
@Suite(.processHeavy, .timeLimit(.minutes(3)))
struct ChangesTerminalDeliveredTests {
    private struct InboxPage: Decodable, Sendable {
        struct Message: Decodable, Sendable { let senderTitle: String; let message: String }
        let messages: [Message]
    }

    private static func inbox(claim: SessionTaskClaim, socket: String) async throws -> InboxPage {
        try await onOwnThread("changes-delivered-inbox") {
            let process = Process(), output = Pipe(), ended = DispatchSemaphore(value: 0)
            process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-hook")
            process.arguments = ["inbox"]
            process.environment = ["SPHYRNA_TASK_SOCKET": socket, "SPHYRNA_TASK_TOKEN": claim.credential,
                "SPHYRNA_TASK_SESSION_ID": claim.sessionID.uuidString, "SPHYRNA_TASK_RUN_ID": claim.managedRunID.uuidString,
                "SPHYRNA_TASK_GENERATION": claim.generation.uuidString]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in ended.signal() }
            try process.run()
            guard ended.wait(timeout: .now() + 8) == .success else {
                process.terminate(); _ = ended.wait(timeout: .now() + 1)
                throw CocoaError(.executableLoad)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return try JSONDecoder().decode(InboxPage.self, from: data)
        }
    }

    private static func anchor(_ number: Int) -> ChangeAnchor {
        ChangeAnchor(fileID: "/w/src/f\(number % 4).swift", line: number + 1, removed: false, text: "let value = \(number)")
    }

    private static func body(_ number: Int) -> String { "#\(number)# " + String(repeating: "word ", count: 100) }

    @Test func deliveredRemovesOnlyTheCommentsTheSessionReadAsTheyWereSent() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_TASK_ROUNDS": "1"],
                                                                claudeVersion: "2.0.0")
        defer {
            context.cleanup()
            try? FileManager.default.removeItem(at: context.root)
        }
        let model = CatalogModel(catalog: context.catalog, events: context.events,
                                 preferences: UIPreferencesStore(url: context.root.appendingPathComponent("ui-preferences.json")))
        let controller = ConversationController(runtime: context.runtime, model: model)
        await controller.begin()
        await model.start()
        do {
            let folder = context.root.appendingPathComponent("changes-delivered", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let screen = SessionRuntimeRig.Screen()
            let target = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
            screen.attach(target.terminal)
            let queue = TerminalInputQueue(endpoint: target.terminal, onError: { _ in })
            context.runtime.inputGate.register(runID: target.runID, queue: queue)
            let claim = try #require(await context.runtime.taskRunPlans[target.sessionID]?.claim)
            await waitFor("the session's run to be authenticated and Ready") {
                guard let binding = await context.runtime.authenticateTaskRun(claim) else { return false }
                return await context.runtime.taskNativeStatus(binding) == .ready
            }
            await waitFor("the model to see the terminal run") {
                model.rowModels[target.sessionID].map { model.runEndpoint(of: $0) == .terminal } == true
            }

            // A turn is under way, so the message waits in the mailbox until the session's next Ready edge.
            #expect(queue.enqueue(Data("/work 2500\r".utf8)))
            #expect(await screen.contains("WORKING 2500"), "the turn runs")

            // 40 comments of about 540 bytes: more than a message holds, so the oldest are left out of it.
            let session = model.changes.session(for: target.sessionID)
            let count = 40
            for number in 0..<count {
                session.saveComment(Self.body(number), at: Self.anchor(number), displayPath: "src/f\(number % 4).swift",
                                    in: .lastTurn)
            }
            await model.refreshChangesReceiver(for: target.sessionID)
            #expect(model.changesSendTitle(for: target.sessionID) == "Send to Claude")
            await model.sendChangeComments(for: target.sessionID)
            #expect(session.sendStatus.holdsSend, "sent and waiting to be read: \(session.sendStatus)")

            // The newest comment went with the message; the user edits it while the message waits.
            let edited = count - 1
            session.saveComment("Edited while it waits.", at: Self.anchor(edited), displayPath: "src/f\(edited % 4).swift",
                                in: .lastTurn)
            #expect(session.sendStatus.holdsSend, "still waiting after the edit: \(session.sendStatus)")
            #expect(await screen.contains("Sphyrna: message", timeout: 8), "the pointer comes on the Ready edge")
            let socket = try #require(await context.runtime.taskSocketPath)

            let page = try await Self.inbox(claim: claim, socket: socket)
            let message = try #require(page.messages.first?.message)
            #expect(message.utf8.count <= SessionTaskLimits.payloadBytes)
            let sent = Set((0..<count).filter { message.contains("#\($0)# ") })
            let leftOut = Set(0..<count).subtracting(sent)
            #expect(!leftOut.isEmpty && sent.contains(edited), "the bound left the oldest out: sent \(sent.sorted())")
            #expect(!message.contains("Edited while it waits."), "the message holds the text as it was when sent")

            await waitFor("the footer to say Delivered with the left-out count") {
                session.sendStatus == .deliveredInPart(notSent: leftOut.count)
            }
            #expect(session.sendStatus.line == "Delivered · \(leftOut.count) comments were not sent: a message holds at most 16 KiB")
            let remaining = session.comments(in: .lastTurn)
            let expected = leftOut.map(Self.body).sorted() + ["Edited while it waits."]
            #expect(remaining.map(\.text).sorted() == expected.sorted(),
                    "left-out comments and the edited one stay; the sent ones go")
            #expect(remaining.first { $0.anchor == Self.anchor(edited) }?.text == "Edited while it waits.")
            #expect(model.changesSendTitle(for: target.sessionID) == "Send to Claude", "what stays can be sent again")

            #expect(try await context.runtime.stopConversation(sessionID: target.sessionID).succeeded)
        } catch { Issue.record("terminal delivered fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
