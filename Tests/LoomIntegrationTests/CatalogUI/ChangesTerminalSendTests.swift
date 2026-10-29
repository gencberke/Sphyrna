import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs
@testable import LoomCoreTestRigs

/// F11 (F2): the Changes tab's comments reach a session that runs in its terminal through the session mailbox. The user's
/// click is the approval; the pointer is typed only on the session's Ready edge, and `inbox` reads the message once.
@MainActor
@Suite(.processHeavy, .timeLimit(.minutes(3)))
struct ChangesTerminalSendTests: ChangesSendFixtures {
    private struct InboxPage: Decodable, Sendable {
        struct Message: Decodable, Sendable { let senderTitle: String; let message: String }
        let messages: [Message]
    }

    private static func inbox(claim: SessionTaskClaim, socket: String) async throws -> InboxPage {
        try await onOwnThread("changes-inbox") {
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

    private func comment(_ model: CatalogModel, _ id: UUID, file: String, line: Int, _ text: String) {
        model.changes.session(for: id).saveComment(
            text, at: ChangeAnchor(fileID: "/w/\(file)", line: line, removed: false, text: "let value = \(line)"),
            displayPath: file, in: .lastTurn)
    }

    @Test func commentsOnTwoFilesReachARunningTerminalSessionOnceAfterItsReadyEdge() async throws {
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
            let folder = context.root.appendingPathComponent("changes-send", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await context.catalog.addProject(path: folder.path).project
            let screen = SessionRuntimeRig.Screen()
            let target = try await context.runtime.startConversation(provider: .claude, projectID: project.id, outputSink: screen)
            screen.attach(target.terminal)
            let queue = TerminalInputQueue(endpoint: target.terminal, onError: { _ in })
            context.runtime.inputGate.register(runID: target.runID, queue: queue)
            let claim = try #require(await context.runtime.taskRunPlans[target.sessionID]?.claim)
            #expect(await waitUntil(10) {
                guard let binding = await context.runtime.authenticateTaskRun(claim) else { return false }
                return await context.runtime.taskNativeStatus(binding) == .ready
            }, "the session's run is authenticated and Ready")
            #expect(await waitUntil(10) {
                model.rowModels[target.sessionID].map { model.runEndpoint(of: $0) == .terminal } == true
            }, "the model sees the terminal run")
            #expect(model.changesSendTitle(for: target.sessionID) == nil, "no comments, no Send")

            // A turn is under way: the comments wait in the mailbox, nothing is typed into the turn.
            #expect(queue.enqueue(Data("/work 2500\r".utf8)))
            #expect(await screen.contains("WORKING 2500"))
            comment(model, target.sessionID, file: "src/b.swift", line: 7, "Why not a constant?")
            comment(model, target.sessionID, file: "src/a.swift", line: 3, "Name this better.")
            comment(model, target.sessionID, file: "src/a.swift", line: 1, "Drop this import.")
            await model.refreshChangesReceiver(for: target.sessionID)
            #expect(model.changesSendTitle(for: target.sessionID) == "Send to Claude")
            await model.sendChangeComments(for: target.sessionID)
            let status = model.changes.session(for: target.sessionID).sendStatus
            #expect(status.line?.hasPrefix("Sent · waiting for ") == true && status.line?.hasSuffix(" to be ready") == true,
                    "sent: \(status)")
            #expect(status.holdsSend, "a second click does not send it again while it waits")
            #expect(!screen.snapshot.contains("Sphyrna: message"), "a working session never receives input")

            #expect(await screen.contains("Sphyrna: message", timeout: 8), "the pointer comes on the Ready edge")
            #expect(!screen.snapshot.contains("Name this better."), "only the pointer enters the terminal")
            let socket = try #require(await context.runtime.taskSocketPath)
            let first = try await Self.inbox(claim: claim, socket: socket)
            #expect(first.messages.map(\.message) == ["""
            Comments on the changes (Last turn):

            src/a.swift
              line 1: > let value = 1
              Drop this import.

              line 3: > let value = 3
              Name this better.

            src/b.swift
              line 7: > let value = 7
              Why not a constant?
            """])
            #expect(first.messages.first?.senderTitle == ChangesMessage.senderTitle)
            let second = try await Self.inbox(claim: claim, socket: socket)
            #expect(second.messages.isEmpty, "inbox reads the message once")
            #expect(await waitUntil(10) { model.changes.session(for: target.sessionID).sendStatus == .delivered },
                    "the footer says Delivered once the session read it")
            #expect(model.changes.session(for: target.sessionID).comments(in: .lastTurn).count == 3,
                    "the comments stay until the user discards them")

            #expect(try await context.runtime.stopConversation(sessionID: target.sessionID).succeeded)
            #expect(await waitUntil(10) { model.rowModels[target.sessionID].map { !model.isRunning($0) } == true },
                    "the model sees the stop")
            await model.refreshChangesReceiver(for: target.sessionID)
            #expect(model.changesSendTitle(for: target.sessionID) == nil, "a stopped session has no Send")
        } catch { Issue.record("terminal send fixture failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
