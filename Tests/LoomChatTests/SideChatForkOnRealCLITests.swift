import CryptoKit
import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore

/// V22 part 2, against the user's real `claude` (Haiku) under the isolated profile: one fork of an existing parent session, one
/// message. Runs only when `LOOM_V22B_REAL=1`, and only by the exact name of its test. Environment:
///
/// - `LOOM_V22B_CLAUDE_CONFIG`: the isolated, logged-in profile (`Loom-Dev/probe/claude-config`);
/// - `LOOM_V22B_WORK`: the trusted work folder the parent session ran in (its `.claude/settings.json` allows `Write` and
///   `Bash(echo:*)`, so the ask rule has to beat the project's own allow rules);
/// - `LOOM_V22B_PARENT`: the parent's Claude session id (its transcript is in the profile's `projects/` for that folder);
/// - `LOOM_V22B_DIR`: the evidence folder, where `real-fork.log` collects one line per phase.
///
/// It shows, on the real CLI: the fork takes the id Loom chose and makes one card; a Bash that writes and a Write are answered by the
/// policy (the project's allow rules do not win); a read-only Bash is answered by the policy too; and a discard leaves the parent's
/// transcript byte for byte as it was. Output holds counts and booleans: no content of a prompt, an answer or a file.
///
/// Release C's real-Claude check adds a second test, by its own exact name, that makes its own parent (never `LOOM_V22B_PARENT`):
/// it needs only `LOOM_V22B_REAL`, `LOOM_V22B_CLAUDE_CONFIG`, `LOOM_V22B_WORK` (a new, empty folder under `/private/tmp/loom-real/`,
/// trusted in the profile) and `LOOM_V22B_DIR`. Five model turns.
@Suite(.serialized, .timeLimit(.minutes(12)),
       .enabled(if: ProcessInfo.processInfo.environment["LOOM_V22B_REAL"] == "1"))
struct SideChatForkOnRealCLITests {
    fileprivate static func log(_ line: String) {
        let text = "[v22b-real] \(line)"
        print(text)
        guard let folder = ProcessInfo.processInfo.environment["LOOM_V22B_DIR"] else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("real-fork.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: url)
        }
    }

    fileprivate static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func capture(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> String {
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

    @Test func v22bForkRefusesWritesAnswersReadsAndLeavesTheParentByteIdentical() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = URL(fileURLWithPath: try #require(env["LOOM_V22B_CLAUDE_CONFIG"]), isDirectory: true)
        let work = URL(fileURLWithPath: try #require(env["LOOM_V22B_WORK"]), isDirectory: true)
        let parentConversation = try #require(env["LOOM_V22B_PARENT"])
        #expect(!work.path.hasPrefix(NSHomeDirectory()))
        let claude = env["LOOM_V22B_CLAUDE"] ?? "/opt/homebrew/bin/claude"
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

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-v22b-real-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketDirectory = URL(fileURLWithPath: "/tmp/lv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let binaries = Bundle(for: ForkAnchor.self).bundleURL.deletingLastPathComponent()
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
        defer {
            RunScopeLauncher.removeOwnedBundle(in: root)
            try? FileManager.default.removeItem(at: socketDirectory)
            try? FileManager.default.removeItem(at: root)
        }

        // The parent: a card for the session the isolated profile already holds, on Haiku as it ran.
        let parent = ManagedSession(provider: .claude, providerConversationID: parentConversation, workingDirectory: work.path)
        try await catalog.insertSession(parent, title: "Parent")
        await runtime.recordLaunchChoices(ClaudeLaunchChoices(model: "haiku"), sessionID: parent.id)
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        let parentFile = try #require(
            FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "\(parentConversation).jsonl" })
        let before = try Self.sha256(parentFile)
        Self.log("parent transcript \(try Data(contentsOf: parentFile).count) bytes, sha256 \(before.prefix(12))")

        let host = await MainActor.run { ChatSessionHost(runtime: runtime, dataRoot: root) }
        let side = try await host.startSideChat(parentSessionID: parent.id)
        let sideID = await side.sessionID
        Self.log("fork ready, phase \(await side.currentPhase)")
        try await Task.sleep(for: .seconds(3))
        let hidden = try await catalog.sideChats(of: parent.id)
        let forkConversation = hidden.first?.session.providerConversationID
        Self.log("listed sessions \(try await catalog.sessions().count) (want 1), side chats \(hidden.count) (want 1), fork id stored \(forkConversation != nil), "
            + "differs from the parent's \(forkConversation?.lowercased() != parentConversation.lowercased())")
        #expect(try await catalog.sessions().map(\.session.id) == [parent.id])
        #expect(hidden.map(\.session.id) == [sideID])
        let fork = try #require(forkConversation)
        let forkTranscript = { () -> URL? in
            FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "\(fork).jsonl" }
        }
        Self.log("fork transcript exists before the first message \(forkTranscript() != nil)")

        // The one model turn of this test.
        Self.log("model turn: one message to the fork (ls, then a writing Bash, then a Write)")
        try await side.send("Run these Bash commands, one per call: first `ls`, then `echo hi > y.txt`. If the second one is refused, "
            + "try to create y.txt with the Write tool instead. Then reply with the single word: done")
        var mostCards = 0
        let finished = await waitUntil(150) {
            let snapshot = await side.snapshot()
            mostCards = max(mostCards, snapshot.requests.count)
            return snapshot.isIdle && !snapshot.model.turns.isEmpty
        }
        let state = try #require(await side.sideChatState())
        let snapshot = await side.snapshot()
        let wrote = FileManager.default.fileExists(atPath: work.appendingPathComponent("y.txt").path)
        Self.log("turn finished \(finished); cards shown \(mostCards) (want 0); refused \(state.refusedCount) allowed \(state.allowedCount); "
            + "y.txt written \(wrote) (want false); stream lines of refusals \(snapshot.model.entries.filter { if case .request = $0.body { true } else { false } }.count)")
        #expect(finished)
        #expect(mostCards == 0, "a request reached the user as a card")
        #expect(!wrote, "the project's allow rules won over the ask rule")
        #expect(state.refusedCount >= 1, "no request reached the policy")
        try? FileManager.default.removeItem(at: work.appendingPathComponent("y.txt"))

        // The fork's file is written under the id Loom chose.
        let forkFile = try #require(forkTranscript())
        Self.log("fork transcript under the stored id after the turn \(FileManager.default.fileExists(atPath: forkFile.path))")
        // Discard: the fork's process, file and card go; the parent's file is what it was.
        let outcome = try await host.discardSideChat(id: sideID)
        let after = try Self.sha256(parentFile)
        Self.log("discard \(outcome), fork file gone \(!FileManager.default.fileExists(atPath: forkFile.path)), parent byte-identical \(after == before), "
            + "side chats left \(try await catalog.sideChats(of: parent.id).count)")
        #expect(outcome == .deleted)
        #expect(after == before)
        #expect(!FileManager.default.fileExists(atPath: forkFile.path))
        #expect(try await catalog.sideChats(of: parent.id).isEmpty)
        let report = await runtime.shutdown()
        Self.log("shutdown succeeded \(report.succeeded)")
    }

    /// Release C's real-Claude check, V22 part 2 beyond the first test (five Haiku turns): a fork of a parent that is mid-turn, a
    /// relaunch, a discard, and the parent's resume. The parent is made here:
    /// 1. the parent answers once (it is given a code word);
    /// 2. its next turn waits on a `touch` card (the profile asks before it);
    /// 3. while it waits, a side chat forks from it and answers one question: the fork has no card, runs no command, and the
    ///    parent still waits on the same card;
    /// 4. the card is allowed and the parent's turn ends;
    /// 5. relaunch: every driver stops, the runtime and the host are made again over the same data root and profile, and the
    ///    side chat, reached through `sideChatDriver(for:parentSessionID:)`, answers again under the same id; the catalog's listed
    ///    sessions are the parent's alone;
    /// 6. Discard returns `.deleted`, and the parent's transcript is byte-identical across it;
    /// 7. the parent resumes and answers.
    /// The test answers its own card (allow once); nothing is bypassed. Output: counts and booleans, no content.
    @Test func v22bForkOfAParentWaitingOnACardSurvivesARelaunchIsDiscardedAndTheParentResumesUntouched() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = URL(fileURLWithPath: try #require(env["LOOM_V22B_CLAUDE_CONFIG"]), isDirectory: true)
        let work = URL(fileURLWithPath: try #require(env["LOOM_V22B_WORK"]), isDirectory: true)
        #expect(work.path.hasPrefix("/private/tmp/loom-real/") && !work.path.hasPrefix(NSHomeDirectory()))
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        try #require(existing.filter { $0 != ".claude" }.isEmpty, "the work folder is not new")
        let rig = try ForkRig(config: config, work: work)
        var current: ForkRig.Running?
        do {
            try await Self.relaunchScenario(rig: rig, work: work, config: config, current: &current)
        } catch {
            if let runtime = current?.runtime { _ = await runtime.shutdown() }
            rig.cleanup()
            throw error
        }
        rig.cleanup()
    }

    private static func relaunchScenario(rig: ForkRig, work: URL, config: URL, current: inout ForkRig.Running?) async throws {
        let touched = work.appendingPathComponent("r2-parent.txt")
        let codeWord = "MANGO-17"
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        func transcript(_ conversation: String) -> URL? {
            FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "\(conversation).jsonl" }
        }
        func answered(_ driver: ChatSessionDriver, seconds: Double, cards: inout Int) async -> (done: Bool, text: String) {
            var most = cards
            var text = ""
            let done = await waitUntil(seconds) {
                let snapshot = await driver.snapshot()
                most = max(most, snapshot.requests.count)
                text = snapshot.model.entries.compactMap { entry -> String? in
                    if case let .assistantText(answer) = entry.body { answer.text } else { nil }
                }.joined(separator: "\n")
                return snapshot.phase == .ready && !snapshot.turnRunning && !text.isEmpty
            }
            cards = most
            return (done, text)
        }

        // 1. The parent answers once.
        var first = try await rig.start(generation: 1)
        current = first
        let parentID = UUID()
        let draft = NewSessionLaunch(firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "default", model: "haiku"))
        let parent = try await first.host.startNewSession(projectID: nil, sessionID: parentID, draft: draft)
        Self.log("model turn 1 of 5: the parent answers once")
        try await parent.send("The code word of this session is \(codeWord). Remember it. Reply with the single word: ready")
        var cards = 0
        let ready = await answered(parent, seconds: 120, cards: &cards)
        Self.log("parent answered \(ready.done)")
        try #require(ready.done, "the parent's first turn did not end: the check stops here, with no further turn")
        let parentConversation = try #require(await parent.liveState().conversationID)
        let parentFile = try #require(transcript(parentConversation), "the parent's transcript was not found")

        // 2. Its next turn waits on a touch card.
        Self.log("model turn 2 of 5: the parent's turn waits on a touch card")
        try await parent.send("Use the Bash tool to run exactly: touch r2-parent.txt . Then reply with the single word: done")
        var card: ChatPendingRequest?
        let waiting = await waitUntil(90) {
            card = await parent.liveState().requests.first
            return card != nil
        }
        let parentCard = try #require(card, "no card arrived within 90 s: the check stops here")
        Self.log("parent card waiting \(waiting), tool \(parentCard.request.toolName), file exists \(FileManager.default.fileExists(atPath: touched.path)) (want false)")
        #expect(parentCard.request.toolName == "Bash")

        // 3. While it waits, a side chat forks from it and answers one question.
        let side = try await first.host.startSideChat(parentSessionID: parentID)
        let sideID = await side.sessionID
        Self.log("fork ready, phase \(await side.currentPhase); model turn 3 of 5: one question to the fork, while the parent waits")
        try await side.send("Without using any tools: what is the code word of this session? Answer in one short sentence.")
        var sideCards = 0
        let sideAnswer = await answered(side, seconds: 120, cards: &sideCards)
        let parentNow = await parent.liveState()
        let sideState = try #require(await side.sideChatState())
        Self.log("fork answered \(sideAnswer.done), names the code word \(sideAnswer.text.contains(codeWord)); cards on the fork \(sideCards) (want 0), "
            + "refused \(sideState.refusedCount) allowed \(sideState.allowedCount); parent phase \(parentNow.phase), turn running \(parentNow.turnRunning), "
            + "same card still waits \(parentNow.requests.first?.requestID == parentCard.requestID); file made meanwhile \(FileManager.default.fileExists(atPath: touched.path)) (want false)")
        #expect(sideAnswer.done, "the fork of a parent that waits on a card gave no answer")
        #expect(sideAnswer.text.contains(codeWord))
        #expect(sideCards == 0, "a request reached the user as a card on the fork")
        #expect(parentNow.phase == .needsYou && parentNow.turnRunning && parentNow.requests.first?.requestID == parentCard.requestID)
        #expect(!FileManager.default.fileExists(atPath: touched.path), "a command ran before the card was allowed")
        let hidden = try await first.catalog.sideChats(of: parentID)
        let forkConversation = try #require(hidden.first?.session.providerConversationID, "the fork's id was not stored")
        #expect(try await first.catalog.sessions().map(\.session.id) == [parentID])
        #expect(hidden.map(\.session.id) == [sideID])
        #expect(forkConversation.lowercased() != parentConversation.lowercased())

        // 4. The card is allowed and the parent's turn ends.
        try await parent.answer(requestID: parentCard.requestID, .allowOnce)
        var parentCards = 0
        let finished = await answered(parent, seconds: 150, cards: &parentCards)
        Self.log("parent finished its turn \(finished.done); file made by the allowed command \(FileManager.default.fileExists(atPath: touched.path))")
        try #require(finished.done, "the parent's turn did not end after its card was allowed")
        #expect(FileManager.default.fileExists(atPath: touched.path))

        // 5. Relaunch: every driver stops, then the runtime and the host are made again over the same data root and profile.
        let sideStop = try await side.stop()
        let parentStop = try await parent.stop()
        let shutdown = await first.runtime.shutdown()
        Self.log("relaunch: side stopped \(sideStop.succeeded), parent stopped \(parentStop.succeeded), first runtime shut down \(shutdown.succeeded)")
        try #require(sideStop.succeeded && parentStop.succeeded && shutdown.succeeded)
        first = try await rig.start(generation: 2)
        current = first
        let sideAgain = await first.host.sideChatDriver(for: sideID, parentSessionID: parentID)
        let listed = try await first.catalog.sessions().map(\.session.id)
        let sideRows = try await first.catalog.sideChats(of: parentID).map(\.session.id)
        Self.log("after the relaunch: listed sessions \(listed.count) (want 1, the parent's), side chats \(sideRows.count) (want 1, the same id) \(sideRows == [sideID])")
        #expect(listed == [parentID])
        #expect(sideRows == [sideID])
        try await sideAgain.resume()
        Self.log("model turn 4 of 5: the side chat, resumed after the relaunch, answers again; phase \(await sideAgain.currentPhase)")
        try await sideAgain.send("Without using any tools: what is the code word of this session? Answer in one short sentence.")
        var againCards = 0
        let again = await answered(sideAgain, seconds: 120, cards: &againCards)
        let againID = await sideAgain.sessionID
        Self.log("side chat answered after the relaunch \(again.done), names the code word \(again.text.contains(codeWord)); same id \(againID == sideID); cards \(againCards) (want 0)")
        #expect(again.done, "the side chat gave no answer after the relaunch")
        #expect(again.text.contains(codeWord))
        #expect(againID == sideID && againCards == 0)
        #expect(try await first.catalog.sessions().map(\.session.id) == [parentID])
        #expect(try await first.catalog.sessions(includingSideChats: true).count == 2)

        // 6. Discard: the fork goes, the parent's transcript is what it was.
        let forkFile = transcript(forkConversation)
        let before = try Self.sha256(parentFile)
        let outcome = try await first.host.discardSideChat(id: sideID)
        let after = try Self.sha256(parentFile)
        Self.log("discard \(outcome); parent byte-identical across it \(after == before); fork file existed \(forkFile != nil), gone now "
            + "\(forkFile.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false); side chats left \(try await first.catalog.sideChats(of: parentID).count)")
        #expect(outcome == .deleted)
        #expect(after == before)
        #expect(forkFile.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false)
        #expect(try await first.catalog.sideChats(of: parentID).isEmpty)

        // 7. The parent resumes and answers.
        let parentAgain = await first.host.driver(for: parentID)
        try await parentAgain.resume()
        Self.log("model turn 5 of 5: the parent resumes and answers; phase \(await parentAgain.currentPhase)")
        try await parentAgain.send("Without using any tools: what is the code word of this session? Answer in one short sentence.")
        var resumedCards = 0
        let resumed = await answered(parentAgain, seconds: 120, cards: &resumedCards)
        Self.log("parent answered after the discard \(resumed.done), names the code word \(resumed.text.contains(codeWord)); cards \(resumedCards) (want 0)")
        #expect(resumed.done)
        #expect(resumed.text.contains(codeWord))
        let report = await first.runtime.shutdown()
        Self.log("shutdown succeeded \(report.succeeded)")
    }
}

/// The runtime of one real test, made again over the same data root for a relaunch: the isolated profile, a run host, the hook
/// helper, and a catalog and a Chat host over one folder.
private struct ForkRig {
    struct Running {
        let catalog: SessionCatalog
        let runtime: SessionRuntime
        let host: ChatSessionHost
    }

    let root: URL
    let config: URL
    let work: URL
    let claude: String
    let capabilities: ProviderCapabilities
    let toolEnvironment: [String: String]
    let bundle: URL
    let binaries: URL
    let socketDirectories: [URL]

    init(config: URL, work: URL) throws {
        let env = ProcessInfo.processInfo.environment
        self.config = config
        self.work = work
        claude = env["LOOM_V22B_CLAUDE"] ?? "/opt/homebrew/bin/claude"
        let child = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                     "CLAUDE_CONFIG_DIR": config.path]
        var launchEnvironment = ["PATH": child["PATH"]!, "HOME": NSHomeDirectory(), "USER": NSUserName(),
                                 "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8"]
        launchEnvironment["TMPDIR"] = env["TMPDIR"]
        toolEnvironment = launchEnvironment
        capabilities = ProviderCapabilities(
            version: try SideChatForkOnRealCLITests.capture(claude, ["--version"], environment: child)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            help: try SideChatForkOnRealCLITests.capture(claude, ["--help"], environment: child))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-v22b-real-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binaries = Bundle(for: ForkAnchor.self).bundleURL.deletingLastPathComponent()
        bundle = try RunScopeLauncher.assembleOwnedBundle(executable: binaries.appendingPathComponent("loom-run-host"), in: root)
        // One short socket folder per run of the runtime (a socket path is short), the second one for the relaunch.
        let tag = UUID().uuidString.prefix(8)
        socketDirectories = (1...2).map { URL(fileURLWithPath: "/tmp/lv-\(tag)-\($0)", isDirectory: true) }
    }

    /// The `generation`th run of the app (1 or 2) over `root`: the same catalog file, profile and data root.
    func start(generation: Int) async throws -> Running {
        let socketDirectory = socketDirectories[generation - 1]
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let supervisor = try await ProcessSupervisor.restoring(
            catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs")))
        let claude = claude, capabilities = capabilities, toolEnvironment = toolEnvironment, config = config
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
        let root = root
        let host = await MainActor.run { ChatSessionHost(runtime: runtime, dataRoot: root) }
        return Running(catalog: catalog, runtime: runtime, host: host)
    }

    func cleanup() {
        RunScopeLauncher.removeOwnedBundle(in: root)
        for directory in socketDirectories { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ForkAnchor: NSObject {}
