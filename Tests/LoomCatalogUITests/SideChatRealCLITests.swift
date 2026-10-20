import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

private final class SideRealAnchor: NSObject {}

/// V22 part 3, against the user's real `claude` (Haiku) under the isolated profile, through the model's own paths
/// (`submitSideQuestion`, `sendSideNote`). Runs only when `LOOM_V22C_REAL=1`, and only by the exact name of its test.
/// Three model turns: the parent's turn, which waits on a `touch` card (the profile asks before it) for as long as the test
/// wants, the side question, asked while that card waits, and the parent's reply to the note. The test answers the card
/// itself, once the side answer is in. Environment:
///
/// - `LOOM_V22C_CLAUDE_CONFIG`: the isolated, logged-in profile (`Loom-Dev/probe/claude-config`);
/// - `LOOM_V22C_WORK`: a new, empty work folder under `/private/tmp/loom-real/` (the parent's working folder);
/// - `LOOM_V22C_DIR`: the evidence folder, where `real-side.log` collects one line per phase.
///
/// Output holds counts and booleans: no content of a prompt, an answer or a file.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(8)),
       .enabled(if: ProcessInfo.processInfo.environment["LOOM_V22C_REAL"] == "1"))
struct SideChatRealCLITests {
    private static func log(_ line: String) {
        let text = "[v22c-real] \(line)"
        print(text)
        guard let folder = ProcessInfo.processInfo.environment["LOOM_V22C_DIR"] else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("real-side.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: url)
        }
    }

    private static func capture(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func wait(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private static func prompts(_ model: TurnModel) -> [String] {
        model.entries.compactMap { if case let .user(prompt) = $0.body { prompt.text } else { nil } }
    }

    private static func answerCount(_ model: TurnModel) -> Int {
        model.entries.filter { if case .assistantText = $0.body { true } else { false } }.count
    }

    @Test func v22cRealSideQuestionMidTurnAndNoteToMain() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = URL(fileURLWithPath: try #require(env["LOOM_V22C_CLAUDE_CONFIG"]), isDirectory: true)
        let work = URL(fileURLWithPath: try #require(env["LOOM_V22C_WORK"]), isDirectory: true)
        #expect(work.path.hasPrefix("/private/tmp/loom-real/"))
        let claude = env["LOOM_V22C_CLAUDE"] ?? "/opt/homebrew/bin/claude"
        let child = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                     "CLAUDE_CONFIG_DIR": config.path]
        var launchEnvironment = ["PATH": child["PATH"]!, "HOME": NSHomeDirectory(), "USER": NSUserName(),
                                 "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8"]
        launchEnvironment["TMPDIR"] = env["TMPDIR"]
        let toolEnvironment = launchEnvironment
        let capabilities = ProviderCapabilities(
            version: try Self.capture(claude, ["--version"], environment: child).trimmingCharacters(in: .whitespacesAndNewlines),
            help: try Self.capture(claude, ["--help"], environment: child))
        #expect(capabilities.supportsForkSession)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-v22c-real-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketDirectory = URL(fileURLWithPath: "/tmp/lv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let binaries = Bundle(for: SideRealAnchor.self).bundleURL.deletingLastPathComponent()
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let bundle = try RunScopeLauncher.assembleOwnedBundle(executable: binaries.appendingPathComponent("loom-run-host"), in: root)
        let supervisor = try await ProcessSupervisor.restoring(
            catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs")))
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: { provider in
                    ProviderToolchain(provider: provider, executable: claude, capabilities: capabilities,
                                      environment: toolEnvironment, profileDirectory: config, extraArguments: [])
                },
                hookHelperPath: binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: work.path, idlePolicy: SessionIdlePolicy(),
                codexIdentityTimeout: 3, claudeProfileDirectory: config,
                claudePluginDirectory: root.appendingPathComponent("claude-plugin", isDirectory: true),
                hookSilenceGrace: 10, catalogBackupDelay: nil))
        try await runtime.start()

        let model = CatalogModel(catalog: catalog, events: await supervisor.events,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        let controller = ConversationController(runtime: runtime, model: model)
        await controller.begin()
        await model.start()
        model.installChatSessions(runtime: runtime, dataRoot: root)
        model.setClaudeConfigDirectory(config)
        let host = try #require(model.chatSessions)
        defer {
            controller.stopObserving()
            model.stop()
            RunScopeLauncher.removeOwnedBundle(in: root)
            try? FileManager.default.removeItem(at: socketDirectory)
            try? FileManager.default.removeItem(at: root)
        }

        // Model turn 1 of 3: the parent's turn, in the Chat face, held open by a card: the profile asks before `touch`, and a
        // turn stays open while its card waits (a long text answer does not: Haiku finishes it before a side answer returns).
        let question = "In one short sentence, without using any tools: what is the main session in the middle of doing?"
        let parent = UUID()
        let draft = NewSessionLaunch(firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "default", model: "haiku"))
        let parentDriver = try await host.startNewSession(projectID: nil, sessionID: parent, draft: draft)
        Self.log("model turn 1 of 3: the parent's turn, which waits on a touch card")
        try await parentDriver.send("Use the Bash tool to run exactly: touch r3-parent.txt . Then reply with the single word: done")
        var card: ChatPendingRequest?
        let waiting = await wait(90) {
            card = await parentDriver.liveState().requests.first
            return card != nil
        }
        let conversation = await parentDriver.liveState().conversationID
        let parentAsked = await parentDriver.snapshot()
        Self.log("parent card waiting \(waiting), tool \(card?.request.toolName ?? "-"), phase \(parentAsked.phase), turn running \(parentAsked.turnRunning), "
            + "conversation known \(conversation != nil)")
        #expect(waiting && card?.request.toolName == "Bash")
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("r3-parent.txt").path))
        let seen = await wait(20) { model.rowModels[parent] != nil }
        #expect(seen)
        model.select(parent)

        // Model turn 2 of 3: the side question, asked through the tab's own path while the parent's turn waits on its card.
        let session = model.side.session(for: parent)
        Self.log("model turn 2 of 3: the side question; parent phase \(parentAsked.phase), cards waiting \(parentAsked.requests.count)")
        session.composerText = question
        await model.submitSideQuestion(in: parent)
        Self.log("question accepted, notice \(session.notice != nil), side chats \(session.items.count)")
        let sideID = try #require(session.openID)
        let sideDriver = try #require(host.existingDriver(for: sideID))
        #expect(await sideDriver.isSideChat)
        let answered = await wait(90) {
            let snapshot = await sideDriver.snapshot()
            return snapshot.phase == .ready && !snapshot.turnRunning && Self.answerCount(snapshot.model) > 0
        }
        let parentWhenAnswered = await parentDriver.snapshot()
        Self.log("side answer arrived \(answered); parent phase at that moment \(parentWhenAnswered.phase), turn still running "
            + "\(parentWhenAnswered.turnRunning), card still waiting \(parentWhenAnswered.requests.first?.requestID == card?.requestID); "
            + "parent never saw the question \(!Self.prompts(parentWhenAnswered.model).contains { $0.contains("in the middle of doing") })")
        #expect(answered)
        #expect(!session.isWaiting, "a card reached the side chat")
        #expect(parentWhenAnswered.turnRunning && parentWhenAnswered.phase == .needsYou, "the parent's turn did not wait on its card")
        #expect(parentWhenAnswered.requests.first?.requestID == card?.requestID)
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("r3-parent.txt").path), "the side chat ran the command")

        // The card is allowed, and the parent ends its turn, untouched by the side chat.
        try await parentDriver.answer(requestID: try #require(card).requestID, .allowOnce)
        let finished = await wait(150) {
            let state = await parentDriver.liveState()
            return state.phase == .ready && !state.turnRunning
        }
        let afterParent = await parentDriver.snapshot()
        Self.log("parent finished its turn \(finished); touch ran \(FileManager.default.fileExists(atPath: work.appendingPathComponent("r3-parent.txt").path)); "
            + "parent prompts \(Self.prompts(afterParent.model).count) (want 1)")
        #expect(finished)
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("r3-parent.txt").path))
        #expect(Self.prompts(afterParent.model).count == 1)

        // The thread the tab shows: the side question and its answer, none of the parent's copy.
        let item = try #require(session.item(sideID))
        let feed = try #require(model.sideFeed(for: item, in: parent))
        feed.start()
        let shown = await wait(30) { feed.phase == .ready && Self.answerCount(feed.joinedModelForTesting) > 0 }
        let thread = feed.joinedModelForTesting
        Self.log("thread shown \(shown); thread prompts \(Self.prompts(thread).count) (want 1); thread answers \(Self.answerCount(thread))")
        #expect(Self.prompts(thread) == [question])
        let answerEntry = try #require(thread.entries.last { if case .assistantText = $0.body { true } else { false } })
        guard case let .assistantText(answer) = answerEntry.body else { return }

        // Model turn 3 of 3: "Send to main as a note" reaches the parent as one message, which the parent answers.
        let expected = SideText.note(question: question, answer: answer.text)
        Self.log("model turn 3 of 3: the note to the parent")
        await model.sendSideNote(answerID: answerEntry.id, chat: sideID, in: parent)
        Self.log("note status sent \(session.noteModel(for: sideID).status(for: answerEntry.id) == .sent)")
        #expect(session.noteModel(for: sideID).status(for: answerEntry.id) == .sent)
        let replied = await wait(150) {
            let snapshot = await parentDriver.snapshot()
            return snapshot.phase == .ready && !snapshot.turnRunning && Self.prompts(snapshot.model).count == 2
        }
        let final = await parentDriver.snapshot()
        let notes = Self.prompts(final.model).filter { $0 == expected }
        Self.log("parent replied \(replied); parent prompts \(Self.prompts(final.model).count) (want 2); "
            + "the note arrived as one message with the exact text \(notes.count == 1)")
        #expect(replied)
        #expect(notes.count == 1)
        // The same text is in the parent's transcript file, once.
        if let conversation, let file = FileManager.default.enumerator(at: config.appendingPathComponent("projects"), includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "\(conversation).jsonl" }) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let marker = "A note from a side chat:"
            Self.log("note records in the parent's transcript \(text.components(separatedBy: marker).count - 1) (want 1)")
            #expect(text.components(separatedBy: marker).count - 1 == 1)
        }
        // Discard: part 2's path, the side chat's file goes, the parent's stays.
        let outcome = try await host.discardSideChat(id: sideID)
        Self.log("discard \(outcome)")
        #expect(outcome == .deleted)
        let report = await runtime.shutdown()
        Self.log("shutdown succeeded \(report.succeeded)")
    }
}
