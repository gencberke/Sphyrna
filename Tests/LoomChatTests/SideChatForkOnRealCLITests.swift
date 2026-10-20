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
@Suite(.serialized, .timeLimit(.minutes(6)),
       .enabled(if: ProcessInfo.processInfo.environment["LOOM_V22B_REAL"] == "1"))
struct SideChatForkOnRealCLITests {
    private static func log(_ line: String) {
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

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
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
}

private final class ForkAnchor: NSObject {}
