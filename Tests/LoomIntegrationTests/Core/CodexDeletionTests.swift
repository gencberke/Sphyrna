import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// D2 step 4 (D-121): deleting a Codex session through the production runtime and the fake Codex app-server. The deletion
/// starts its own server on the session's Codex home (a temporary folder here, synthetic data only) and Codex's own
/// `thread/delete` removes the data; the catalog row goes only after the native id, the rollout and the index record are
/// shown gone. The shared prompt history and the capability marker are kept, byte for byte.
// serialized: each test runs fake Codex servers, deletion servers and a relaunch on one temporary catalog
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct CodexDeletionTests {
    // MARK: Fixture

    final class Env: @unchecked Sendable {
        let root: URL
        let home: URL
        let state: URL
        let claudeProfile: URL
        let codexHome: URL
        let socketDirectory: URL
        var catalogURL: URL { root.appendingPathComponent("catalog.sqlite3") }

        init() throws {
            root = URL(fileURLWithPath: realPath(FileManager.default.temporaryDirectory), isDirectory: true)
                .appendingPathComponent("loom-d2x-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            state = root.appendingPathComponent("fake-state", isDirectory: true)
            claudeProfile = root.appendingPathComponent("claude-config", isDirectory: true)
            codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
            socketDirectory = URL(fileURLWithPath: "/tmp/lr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            for directory in [home, state, claudeProfile, codexHome] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketDirectory)
        }
    }

    struct World {
        let env: Env
        let catalog: SessionCatalog
        let supervisor: ProcessSupervisor
        let runtime: SessionRuntime
    }

    /// A runtime over `env`'s catalog; again for the same `env` is the app's next launch.
    static func makeWorld(_ env: Env, environment: [String: String] = [:]) async throws -> World {
        let catalog = try SessionCatalog(url: env.catalogURL)
        let supervisor = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: catalog)
        let fake = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
        let (home, state, claude, codex) = (env.home, env.state, env.claudeProfile, env.codexHome)
        let resolver: ProviderToolchainResolver = { provider in
            ProviderToolchain(
                provider: provider, executable: fake,
                capabilities: ProviderCapabilities(version: "fake 1",
                    help: "--settings <settings> --session-id <id> --remote <ADDR>", serverHelp: "--listen <URL>"),
                environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "LOOM_FAKE_STATE": state.path]
                    .merging(environment) { _, new in new },
                profileDirectory: provider == .codex ? codex : claude, extraArguments: []
            )
        }
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: resolver,
                hookHelperPath: RuntimeFixture.binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: env.socketDirectory, homeDirectory: env.home.path, codexIdentityTimeout: 3,
                claudeProfileDirectory: env.claudeProfile
            )
        )
        try await runtime.start()
        return World(env: env, catalog: catalog, supervisor: supervisor, runtime: runtime)
    }

    /// What Codex keeps for one native thread, synthetic: the fake server's record of it, a rollout, an index record, a
    /// line in the shared prompt history and the capability marker.
    struct Seed {
        let home: URL
        let state: URL
        let threadID: String
        var rolloutRelative: String { "sessions/2026/10/30/rollout-2026-10-30T00-00-00-\(threadID).jsonl" }
        var rollout: URL { home.appendingPathComponent(rolloutRelative) }
        var marker: URL { home.appendingPathComponent("tui-thread-reference-capabilities/\(threadID)") }

        init(_ env: Env, threadID: String = UUID().uuidString.lowercased(), home: URL? = nil) throws {
            self.home = home ?? env.codexHome
            self.state = env.state
            self.threadID = threadID
            try env.home.path.write(to: state.appendingPathComponent("codex-thread-\(threadID).cwd"),
                                    atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\",\"cwd\":\"\(env.home.path)\"}}\n"
                + "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\","
                + "\"content\":[{\"type\":\"input_text\",\"text\":\"synthetic\"}]}}\n").utf8).write(to: rollout)
            try Self.append("{\"id\":\"\(threadID)\",\"thread_name\":\"synthetic\",\"updated_at\":\"2026-10-30T00:00:00Z\"}\n",
                            to: self.home.appendingPathComponent("session_index.jsonl"))
            try Self.append("{\"session_id\":\"\(threadID)\",\"ts\":1,\"text\":\"synthetic prompt\"}\n",
                            to: self.home.appendingPathComponent("history.jsonl"))
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: marker)
        }

        static func append(_ text: String, to url: URL) throws {
            let old = (try? Data(contentsOf: url)) ?? Data()
            try (old + Data(text.utf8)).write(to: url)
        }

        var serverKnowsIt: Bool { FileManager.default.fileExists(atPath: state.appendingPathComponent("codex-thread-\(threadID).cwd").path) }
        var rolloutExists: Bool { FileManager.default.fileExists(atPath: rollout.path) }
        var indexRecords: Int {
            let text = (try? String(contentsOf: home.appendingPathComponent("session_index.jsonl"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").filter { line in
                ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? String == threadID
            }.count
        }
    }

    static func addSession(_ world: World, nativeID: String?) async throws -> ManagedSession {
        let session = ManagedSession(provider: .codex, providerConversationID: nativeID,
                                     workingDirectory: world.env.home.path)
        try await world.supervisor.createSession(session, projectID: nil)
        return session
    }

    /// The fake server's deletion requests, in order ("thread/delete <id>", "thread/list <id>").
    static func deletionCalls(_ env: Env) -> [String] {
        ((try? String(contentsOf: env.state.appendingPathComponent("codex-methods-delete.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Every app-server the deletion started is gone: no Codex server record, no supervised process left running.
    static func ownedScopeIsEmpty(_ world: World) async -> Bool {
        let servers = await world.runtime.codexServerState().servers
        let running = await world.supervisor.runningSessionIDs()
        return servers == 0 && running.isEmpty
    }

    // MARK: Target only

    @Test func deletingACodexSessionRemovesOnlyItsNativeDataAndKeepsTheSharedHistory() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let target = try Seed(env)
        let control = try Seed(env)
        // An unrelated, hand-made line naming the target's id in its text only: never matched as text.
        try Seed.append("{\"id\":\"\(UUID().uuidString.lowercased())\",\"thread_name\":\"about \(target.threadID)\"}\n",
                        to: env.codexHome.appendingPathComponent("session_index.jsonl"))
        let session = try await Self.addSession(world, nativeID: target.threadID)
        let controlSession = try await Self.addSession(world, nativeID: control.threadID)
        let history = try Data(contentsOf: env.codexHome.appendingPathComponent("history.jsonl"))
        let controlRollout = try Data(contentsOf: control.rollout)
        let controlRow = try #require(try await world.catalog.session(id: controlSession.id))

        let preview = try await world.runtime.deletionPreview(id: session.id)
        #expect(preview.provider == .codex)
        #expect(preview.fileCount == 1)
        #expect(preview.byteCount == Int64(try Data(contentsOf: target.rollout).count))
        #expect(preview.configDirectory == env.codexHome.path)
        #expect(preview.notRemoved == ["history.jsonl", "tui-thread-reference-capabilities/\(target.threadID)"])
        #expect(Self.deletionCalls(env).isEmpty, "a preview asks Codex nothing")

        #expect(try await world.runtime.deleteConversation(id: session.id) == .deleted)

        // The target: native thread, rollout and index record gone; its catalog row and deletion record too.
        #expect(!target.serverKnowsIt)
        #expect(!target.rolloutExists)
        #expect(target.indexRecords == 0)
        #expect(try await world.catalog.session(id: session.id) == nil)
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect(Self.deletionCalls(env).filter { $0.hasPrefix("thread/delete") } == ["thread/delete \(target.threadID)"])
        // Kept by decision: the shared prompt history byte for byte, and the content-free marker.
        #expect(try Data(contentsOf: env.codexHome.appendingPathComponent("history.jsonl")) == history)
        #expect(FileManager.default.fileExists(atPath: target.marker.path))
        // The control session is untouched, natively and in the catalog; so is the unrelated index line.
        #expect(control.serverKnowsIt)
        #expect(try Data(contentsOf: control.rollout) == controlRollout)
        #expect(control.indexRecords == 1)
        #expect(try String(contentsOf: env.codexHome.appendingPathComponent("session_index.jsonl"), encoding: .utf8)
            .contains("about \(target.threadID)"))
        #expect(try await world.catalog.session(id: controlSession.id) == controlRow)
        // The deletion's own server ran on the recorded home with the daemon and agent features off, and is gone.
        let launches = try String(contentsOf: env.state.appendingPathComponent("codex-server-arguments.log"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        #expect(!launches.isEmpty)
        for arguments in launches {
            #expect(Array(arguments.suffix(6)) == SessionRuntime.codexDeletionServerArguments, "\(arguments)")
        }
        #expect(await Self.ownedScopeIsEmpty(world))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    /// The cleanup review and Storage preview every Codex session from one walk of the home (the r9 delta pass, S1): each
    /// preview is that session's own, equal to its single preview; a session with no native thread yet shows nothing.
    @Test func theCleanupPreviewsOfManyCodexSessionsAreEachSessionsOwn() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let first = try Seed(env), second = try Seed(env)
        let a = try await Self.addSession(world, nativeID: first.threadID)
        let b = try await Self.addSession(world, nativeID: second.threadID)
        let unstarted = try await Self.addSession(world, nativeID: nil)
        let previews = await world.runtime.deletionPreviews(ids: [a.id, b.id, unstarted.id])
        #expect(previews.count == 3)
        for id in [a.id, b.id, unstarted.id] {
            #expect(previews[id] == (try await world.runtime.deletionPreview(id: id)))
        }
        #expect(previews[a.id]?.fileCount == 1)
        #expect(previews[a.id]?.byteCount == Int64(try Data(contentsOf: first.rollout).count))
        #expect(previews[a.id]?.notRemoved == ["history.jsonl", "tui-thread-reference-capabilities/\(first.threadID)"])
        #expect(previews[b.id]?.notRemoved == ["history.jsonl", "tui-thread-reference-capabilities/\(second.threadID)"])
        #expect(previews[unstarted.id]?.fileCount == 0)
        #expect(Self.deletionCalls(env).isEmpty, "a preview asks Codex nothing")
        #expect((await world.runtime.shutdown()).succeeded)
    }

    /// A preview reads no session index (S1): its sizes show even when the index cannot be read, and the deletion, which
    /// needs the index, still refuses with the reason before anything changes.
    @Test func aPreviewReadsNoSessionIndexButTheDeletionStillNeedsIt() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let target = try Seed(env)
        let session = try await Self.addSession(world, nativeID: target.threadID)
        let index = env.codexHome.appendingPathComponent("session_index.jsonl")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let preview = try await world.runtime.deletionPreview(id: session.id)
        #expect(preview.fileCount == 1)
        #expect(await world.runtime.deletionPreviews(ids: [session.id])[session.id] == preview)
        await #expect(throws: SessionRuntimeError.deletionRefused("Codex's session index cannot be read")) {
            try await world.runtime.deleteConversation(id: session.id)
        }
        #expect(target.rolloutExists && target.serverKnowsIt)
        #expect(try await world.catalog.session(id: session.id) != nil)
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func aSessionWhoseNativeDataIsAlreadyGoneIsDeletedAndARepeatFindsNothing() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let control = try Seed(env)
        let gone = UUID().uuidString.lowercased()
        let session = try await Self.addSession(world, nativeID: gone)

        #expect(try await world.runtime.deleteConversation(id: session.id) == .deleted)
        // Codex's "not found" was accepted only because the absence was then shown.
        #expect(Self.deletionCalls(env).filter { $0.hasPrefix("thread/delete") } == ["thread/delete \(gone)"])
        #expect(try await world.catalog.session(id: session.id) == nil)
        await #expect(throws: SessionRuntimeError.sessionNotFound(session.id)) {
            _ = try await world.runtime.deleteConversation(id: session.id)
        }
        #expect(Self.deletionCalls(env).filter { $0.hasPrefix("thread/delete") }.count == 1)
        #expect(control.serverKnowsIt && control.rolloutExists && control.indexRecords == 1)
        #expect(await Self.ownedScopeIsEmpty(world))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: Vendor answers that are not success

    @Test(arguments: ["error", "keep-rollout"])
    func aNativeDeleteThatFailsOrLeavesTheRolloutKeepsTheCatalogRow(mode: String) async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env, environment: ["LOOM_FAKE_CODEX_DELETE": mode])
        let target = try Seed(env)
        let session = try await Self.addSession(world, nativeID: target.threadID)

        let outcome = try await world.runtime.deleteConversation(id: session.id)
        guard case let .incomplete(pending) = outcome else { Issue.record("expected incomplete, got \(outcome)"); return }
        #expect(pending.state == .providerData)
        if mode == "error" {
            #expect(pending.lastFailure == "native_delete_failed")
            #expect(target.serverKnowsIt && target.indexRecords == 1)
        } else {
            #expect(pending.lastFailure == "leftover_files: \(target.rollout.lastPathComponent)")
        }
        #expect(target.rolloutExists)
        // The row stays, fenced, until a retry verifies; no provider text reached the record.
        #expect(try await world.catalog.session(id: session.id) != nil)
        #expect(!(pending.lastFailure ?? "").contains("private"))
        #expect(await Self.ownedScopeIsEmpty(world))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: Descendants

    @Test func aSessionWithNativeSubagentSessionsOfItsOwnIsRefusedBeforeAnythingChanges() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let target = try Seed(env)
        let child = try Seed(env)
        try "\(target.threadID) \(child.threadID)\n".write(to: env.state.appendingPathComponent("codex-spawn-edges.log"),
                                                           atomically: true, encoding: .utf8)
        let session = try await Self.addSession(world, nativeID: target.threadID)

        do {
            _ = try await world.runtime.deleteConversation(id: session.id)
            Issue.record("a session with a foreign native descendant was deleted")
        } catch let SessionRuntimeError.deletionRefused(reason) {
            #expect(reason.contains("subagent"))
        }
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect(try await world.catalog.session(id: session.id) != nil)
        #expect(Self.deletionCalls(env) == ["thread/list \(target.threadID)", "thread/list \(target.threadID)"])
        for seed in [target, child] { #expect(seed.serverKnowsIt && seed.rolloutExists && seed.indexRecords == 1) }
        #expect(await Self.ownedScopeIsEmpty(world))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: Crash and resume

    struct Interruption: Sendable, CustomTestStringConvertible {
        let state: CatalogDeletionState
        let phase: DeletionFailpointPhase
        /// How many `thread/delete` requests the two launches send together.
        let nativeDeletes: Int
        var testDescription: String { "\(state.rawValue) \(phase)" }
    }

    static let interruptions = [
        Interruption(state: .providerData, phase: .after, nativeDeletes: 2),   // after the native delete
        Interruption(state: .catalog, phase: .before, nativeDeletes: 1),       // before the catalog step
        Interruption(state: .verifying, phase: .before, nativeDeletes: 1),     // during verifying
    ]

    @Test(arguments: interruptions)
    func anInterruptedCodexDeletionIsFinishedByTheNextLaunch(point: Interruption) async throws {
        let env = try Env()
        defer { env.cleanup() }
        let first = try await Self.makeWorld(env)
        let target = try Seed(env)
        let control = try Seed(env)
        let session = try await Self.addSession(first, nativeID: target.threadID)
        let history = try Data(contentsOf: env.codexHome.appendingPathComponent("history.jsonl"))
        await first.runtime.setDeletionFailpointForTesting { state, phase in
            if state == point.state, phase == point.phase { throw LoomError.message("interrupted") }
        }
        let outcome = try await first.runtime.deleteConversation(id: session.id)
        guard case let .incomplete(pending) = outcome else { Issue.record("expected incomplete"); return }
        #expect(pending.state == point.state)
        #expect(!target.rolloutExists, "the native delete ran before the interruption")
        #expect((await first.runtime.shutdown()).succeeded)

        // The next launch resumes the record from its state: a second native delete answers "not found", which is
        // accepted only after the absence is verified.
        let second = try await Self.makeWorld(env)
        await second.runtime.finishDeletionRecovery()
        #expect(try await second.runtime.pendingDeletions().isEmpty)
        #expect(try await second.catalog.session(id: session.id) == nil)
        #expect(Self.deletionCalls(env).filter { $0.hasPrefix("thread/delete") }.count == point.nativeDeletes)
        #expect(!target.serverKnowsIt && target.indexRecords == 0)
        #expect(control.serverKnowsIt && control.rolloutExists && control.indexRecords == 1)
        #expect(try Data(contentsOf: env.codexHome.appendingPathComponent("history.jsonl")) == history)
        #expect(await second.runtime.deletionRecoveryFailure() == nil)
        #expect(await Self.ownedScopeIsEmpty(second))
        #expect((await second.runtime.shutdown()).succeeded)
    }

    // MARK: A live session, in run scopes

    @Test func aRunningCodexSessionIsStoppedThenDeletedAndEveryOwnedScopeEnds() async throws {
        let context = try await SessionRuntimeRig.makeContext(scoped: true)
        defer { context.cleanup() }
        let screen = SessionRuntimeRig.Screen()
        let launch = try await context.runtime.startConversation(provider: .codex, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        #expect(try await SessionRuntimeRig.waitUntil(10) {
            try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID != nil
        })
        let threadID = try #require(try await context.catalog.session(id: launch.sessionID)?.session.providerConversationID)
        // The rig's Codex home is its profile folder; the fake server keeps the thread in its state.
        let rollout = context.profile.appendingPathComponent("sessions/2026/10/30/rollout-2026-10-30T00-00-00-\(threadID).jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\"}}\n".utf8).write(to: rollout)
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)

        #expect(try await context.runtime.deleteConversation(id: launch.sessionID) == .deleted)
        #expect(await context.runtime.liveRunCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: rollout.path))
        #expect(!FileManager.default.fileExists(atPath: context.state.appendingPathComponent("codex-thread-\(threadID).cwd").path))
        #expect(try await context.catalog.session(id: launch.sessionID) == nil)
        #expect(await context.runtime.codexServerState().servers == 0)
        #expect(await context.supervisor.liveScopes.isEmpty, "the run's and the deletion's scopes both ended")
        #expect(await context.supervisor.scopesOpened >= 3, "the run, the request's check and the delete each had a scope")
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
