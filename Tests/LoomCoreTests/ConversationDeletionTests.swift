import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

private actor PeerDeletionGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class PeerDeletionStepGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false
    var entered: Bool { condition.withLock { waiting } }
    func hold() {
        condition.lock(); waiting = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

/// CP4-C: deleting a conversation end to end through the production runtime, driven by the fake
/// provider and temp trees only. Nothing here reads or writes the real ~/.claude: the Claude
/// profile is a directory under the test's own root (the toolchain names it explicitly) and tier 2
/// points at a folder in the same root.
extension SessionCatalog {
    /// Test helper: a title the backup test can look for in file bytes.
    func renameTitleForBackupTest(_ id: UUID, _ title: String) throws {
        try database.withStatement("UPDATE sessions SET title = ? WHERE id = ?") { statement in
            try database.bind(title, at: 1, to: statement)
            try database.bind(id.uuidString, at: 2, to: statement)
            try database.stepDone(statement, operation: "test title")
        }
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct ConversationDeletionTests {
    // MARK: Fixture

    final class Env: @unchecked Sendable {
        let root: URL
        let home: URL
        let state: URL
        let profile: URL
        let temporary: URL
        let socketDirectory: URL
        var catalogURL: URL { root.appendingPathComponent("catalog.sqlite3") }

        /// The folder that holds the profile; `root` itself unless the test wants a parent it can remove.
        let profileParent: URL

        init(profileUnder parent: String? = nil) throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("loom-cp4c-\(UUID().uuidString)", isDirectory: true)
            root = base
            home = root.appendingPathComponent("home", isDirectory: true)
            state = root.appendingPathComponent("fake-state", isDirectory: true)
            profileParent = parent.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
            profile = profileParent.appendingPathComponent("claude-config", isDirectory: true)
            temporary = root.appendingPathComponent("tmp-claude", isDirectory: true)
            socketDirectory = URL(fileURLWithPath: "/tmp/lr-\(UUID().uuidString.prefix(8))", isDirectory: true)
            for directory in [home, state, profile, temporary] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketDirectory)
        }

        func write(_ relative: String, _ text: String, under base: URL? = nil) throws {
            let url = (base ?? profile).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        /// Everything Claude keeps for these ids (one transcript, a history folder, a debug log,
        /// and a tier-2 folder); returns the relative paths under the profile.
        @discardableResult
        func seed(_ ids: [String], project: String = "p") throws -> [String] {
            var paths: [String] = []
            for id in ids {
                let files = ["projects/\(project)/\(id).jsonl", "file-history/\(id)/v1", "debug/\(id).txt"]
                for file in files { try write(file, "data of \(id)") }
                try write("h1/\(id)/out.txt", "tmp of \(id)", under: temporary)
                paths += files
            }
            return paths
        }

        func exists(_ relative: String) -> Bool {
            var info = stat()
            return lstat(profile.appendingPathComponent(relative).path, &info) == 0
        }

        func tierTwoExists(_ id: String) -> Bool {
            var info = stat()
            return lstat(temporary.appendingPathComponent("h1/\(id)").path, &info) == 0
        }

        /// Relative path -> contents of every file under the profile that mentions one of `ids`.
        func snapshot(of ids: [String]) throws -> [String: String] {
            var result: [String: String] = [:]
            guard let walker = FileManager.default.enumerator(atPath: profile.path) else { return result }
            for case let relative as String in walker {
                guard ids.contains(where: { relative.lowercased().contains($0.lowercased()) }) else { continue }
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: profile.appendingPathComponent(relative).path, isDirectory: &isDirectory)
                result[relative] = isDirectory.boolValue ? "dir"
                    : (try? String(contentsOf: profile.appendingPathComponent(relative), encoding: .utf8)) ?? ""
            }
            return result
        }
    }

    struct World {
        let env: Env
        let catalog: SessionCatalog
        let supervisor: ProcessSupervisor
        let runtime: SessionRuntime
        let forgetters: ConversationForgetters
        let toolchainSwitch: ToolchainSwitch

        var events: SessionEventHub { supervisor.events }
    }

    /// A runtime over `env`'s catalog. Calling it again for the same `env` is a new instance of
    /// the app: the catalog is reopened, the supervisor restores from it, nothing is shared.
    static func makeWorld(
        _ env: Env, forgetters: ConversationForgetters = ConversationForgetters(), start: Bool = true,
        profileDirectory: URL? = nil
    ) async throws -> World {
        let catalog = try SessionCatalog(url: env.catalogURL)
        let supervisor = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: catalog)
        let toolchainSwitch = ToolchainSwitch()
        let fake = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
        let profile = env.profile, home = env.home, state = env.state
        let resolver: ProviderToolchainResolver = { provider in
            if toolchainSwitch.delay > 0 { try await Task.sleep(for: .seconds(toolchainSwitch.delay)) }
            try toolchainSwitch.check()
            return ProviderToolchain(
                provider: provider, executable: fake,
                capabilities: ProviderCapabilities(
                    version: "fake 1", help: "--settings <settings> --session-id <id> --remote <ADDR>",
                    serverHelp: "--listen <URL>"
                ),
                environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "LOOM_FAKE_STATE": state.path],
                profileDirectory: profile, extraArguments: []
            )
        }
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: resolver,
                hookHelperPath: RuntimeFixture.binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: env.socketDirectory, homeDirectory: env.home.path,
                codexIdentityTimeout: 3,
                claudeTemporaryRoot: env.temporary, forgetters: forgetters,
                claudeProfileDirectory: profileDirectory ?? env.profile
            )
        )
        if start { try await runtime.start() }
        return World(env: env, catalog: catalog, supervisor: supervisor, runtime: runtime,
                     forgetters: forgetters, toolchainSwitch: toolchainSwitch)
    }

    /// A stopped conversation with its own provider id and seeded files.
    @discardableResult
    static func addConversation(
        _ world: World, provider: ManagedSession.Provider = .claude, providerID: String? = UUID().uuidString.lowercased(),
        projectID: UUID? = nil, seed: Bool = true
    ) async throws -> ManagedSession {
        let session = ManagedSession(provider: provider, providerConversationID: providerID,
                                     workingDirectory: world.env.home.path)
        try await world.supervisor.createSession(session, projectID: projectID)
        if seed, provider == .claude {
            try world.env.seed([session.id.uuidString.lowercased()] + (providerID.map { [$0] } ?? []))
        }
        return session
    }

    static func ids(_ session: ManagedSession) -> [String] {
        [session.id.uuidString.lowercased()] + (session.providerConversationID.map { [$0] } ?? [])
    }

    static func launch(_ world: World) async throws -> (RuntimeLaunch, SessionRuntimeTests.Screen) {
        let screen = SessionRuntimeTests.Screen()
        let launch = try await world.runtime.startConversation(provider: .claude, projectID: nil, outputSink: screen)
        screen.attach(launch.terminal)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        return (launch, screen)
    }

    static func envelope(_ session: UUID, run: UUID, event: String, providerSession: String,
                         fields: [String: Any] = [:]) throws -> ClaudeHookEnvelope {
        var object: [String: Any] = ["session_id": providerSession, "hook_event_name": event, "cwd": "/tmp"]
        object.merge(fields) { _, new in new }
        return ClaudeHookEnvelope(sessionID: session, managedRunID: run,
                                  payload: try JSONSerialization.data(withJSONObject: object))
    }

    /// The loom ids and provider ids of a launched conversation (lowercase), once its identity is bound.
    static func providerID(_ world: World, _ id: UUID) async throws -> String {
        #expect(try await SessionRuntimeTests.waitUntil {
            try await world.catalog.session(id: id)?.session.providerConversationID != nil
        })
        return try #require(try await world.catalog.session(id: id)?.session.providerConversationID)
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(UUID, [String])] = []
        private var failures = 0
        func record(_ id: UUID, _ ids: [String]) throws {
            try lock.withLock {
                storage.append((id, ids))
                if failures > 0 { failures -= 1; throw LoomError.message("hook failed") }
            }
        }
        func failNext(_ count: Int) { lock.withLock { failures = count } }
        var all: [(UUID, [String])] { lock.withLock { storage } }
    }

    final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SessionEventFrame] = []
        private var task: Task<Void, Never>?
        init(_ hub: SessionEventHub) async {
            // The app's subscription keeps only the newest frame, so under load a later frame can
            // replace the transient change a test asserts before this task reads it.
            let stream = await hub.subscribe(bufferingPolicy: .unbounded)
            task = Task { [weak self] in
                for await frame in stream { self?.lock.withLock { self?.storage.append(frame) } }
            }
        }
        deinit { task?.cancel() }
        var all: [SessionEventFrame] { lock.withLock { storage } }
        func has(_ change: SessionEventChange, for id: UUID) async -> Bool {
            await SessionRuntimeTests.waitUntil(3) { all.contains { $0.change == change && $0.sessionID == id } }
        }
    }

    // MARK: Happy path

    @Test func deletingALiveConversationStopsItRemovesEverythingAndLeavesTheOtherAlone() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let calls = Calls()
        let forgetters = ConversationForgetters()
        forgetters.register { id, ids in try calls.record(id, ids) }
        let world = try await Self.makeWorld(env, forgetters: forgetters)
        let frames = await Frames(world.events)
        let project = try await world.catalog.addProject(path: env.home.path).project
        let other = try await Self.addConversation(world, projectID: project.id)
        let otherBefore = try env.snapshot(of: Self.ids(other))
        #expect(!otherBefore.isEmpty)

        let (launch, screen) = try await Self.launch(world)
        try await screen.send("hello")
        #expect(await screen.contains("echo: hello"))
        let providerID = try await Self.providerID(world, launch.sessionID)
        let loomID = launch.sessionID.uuidString
        // Transcript under the uppercase Loom id, history under the lowercase provider id.
        try env.write("projects/p/\(loomID).jsonl", "transcript")
        try env.write("file-history/\(providerID)/v1", "history")
        try env.write("h1/\(providerID)/out.txt", "tmp", under: env.temporary)
        let preview = try await world.runtime.deletionPreview(id: launch.sessionID)
        #expect(preview.isRunning)
        #expect(preview.fileCount == 3)
        #expect(preview.byteCount == Int64("transcript".utf8.count + "history".utf8.count + "tmp".utf8.count))
        #expect(preview.configDirectory == realPath(env.profile))
        #expect(try await world.catalog.pendingDeletions().isEmpty)   // a preview records nothing
        #expect(env.exists("projects/p/\(loomID).jsonl"))

        let outcome = try await world.runtime.deleteConversation(id: launch.sessionID)
        #expect(outcome == .deleted)

        // Process, catalog, supervisor, hub, files, tier 2: nothing is left.
        #expect(await world.runtime.liveRunCount() == 0)
        #expect(await world.supervisor.runningSessionIDs().isEmpty)
        #expect(await world.supervisor.session(id: launch.sessionID) == nil)
        #expect(try await world.catalog.session(id: launch.sessionID) == nil)
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect(await world.events.snapshot().sessions[launch.sessionID] == nil)
        #expect(!env.exists("projects/p/\(loomID).jsonl"))
        #expect(!env.exists("file-history/\(providerID)"))
        #expect(!env.tierTwoExists(providerID))
        #expect(try env.snapshot(of: [loomID, providerID]).isEmpty)
        // The forget hook saw the Loom id and the provider id.
        #expect(calls.all.count == 1)
        #expect(calls.all.first?.0 == launch.sessionID)
        #expect(Set(calls.all.first?.1.map { $0.lowercased() } ?? []) == [loomID.lowercased(), providerID.lowercased()])
        // The removal is announced without recreating hub state for the id.
        #expect(await frames.has(.conversationDeleted, for: launch.sessionID))
        #expect(frames.all.last { $0.change == .conversationDeleted }?.sessions[launch.sessionID] == nil)

        // The other conversation is exactly as it was, in the catalog and on disk.
        #expect(try env.snapshot(of: Self.ids(other)) == otherBefore)
        #expect(try await world.catalog.session(id: other.id)?.projectID == project.id)
        #expect(try await world.catalog.sessions().map(\.session.id) == [other.id])
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func aConversationThatMovedItsRunToAnotherCardIsDeletedWithoutStoppingTheRun() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let (launch, screen) = try await Self.launch(world)
        try await screen.send("first")
        #expect(await screen.contains("echo: first"))
        let oldProvider = try await Self.providerID(world, launch.sessionID)
        try await screen.send("/clear")
        #expect(await screen.contains("CLEARED "))
        #expect(try await SessionRuntimeTests.waitUntil { try await world.catalog.sessions().count == 2 })
        let newCard = try #require(try await world.catalog.sessions().first { $0.session.id != launch.sessionID }).session
        try env.seed([launch.sessionID.uuidString.lowercased(), oldProvider])

        #expect(try await world.runtime.deleteConversation(id: launch.sessionID) == .deleted)
        // The run belongs to the new card and keeps working.
        #expect(await world.supervisor.runningSessionIDs() == [newCard.id])
        try await screen.send("still alive")
        #expect(await screen.contains("echo: still alive"))
        #expect(try await world.catalog.session(id: launch.sessionID) == nil)
        #expect(try await world.catalog.session(id: newCard.id) != nil)
        #expect(!env.exists("file-history/\(oldProvider)"))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func twoConversationsInOneProjectDeleteIndependently() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let folder = env.root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await world.catalog.addProject(path: folder.path).project
        let a = try await Self.addConversation(world, projectID: project.id)
        let b = try await Self.addConversation(world, projectID: project.id)
        // Both live in the same Claude project folder.
        #expect(env.exists("projects/p/\(Self.ids(a)[1]).jsonl") && env.exists("projects/p/\(Self.ids(b)[1]).jsonl"))
        let before = try env.snapshot(of: Self.ids(b))
        let rowBefore = try #require(try await world.catalog.session(id: b.id))

        #expect(try await world.runtime.deleteConversation(id: a.id) == .deleted)
        #expect(try env.snapshot(of: Self.ids(b)) == before)
        #expect(try await world.catalog.session(id: b.id) == rowBefore)
        #expect(await world.supervisor.session(id: b.id) != nil)
        #expect(try env.snapshot(of: Self.ids(a)).isEmpty)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    /// H1-B item 8, the deletion contract: a backup taken before a deletion never survives it, and a
    /// fresh one (without the conversation) takes its place.
    @Test func aFinishedDeletionLeavesOnlyAFreshBackupWithoutTheDeletedConversation() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let doomed = try await Self.addConversation(world)
        let other = try await Self.addConversation(world)
        try await world.catalog.renameTitleForBackupTest(doomed.id, "DOOMED-TITLE-FOR-BACKUP")
        let store = world.catalog.backupStore
        guard case .created = await store.backUp() else { Issue.record("no first backup"); return }
        #expect(store.list().count == 1)
        let oldBackup = try #require(store.list().first)

        #expect(try await world.runtime.deleteConversation(id: doomed.id) == .deleted)

        // The old backup is gone at once; the fresh one is written in the background.
        #expect(!FileManager.default.fileExists(atPath: oldBackup.url.path))
        #expect(await SessionRuntimeTests.waitUntil(5) { store.list().count == 1 })
        let fresh = try #require(store.list().first)
        #expect(fresh.url != oldBackup.url)
        let bytes = try Data(contentsOf: fresh.url)
        #expect(bytes.range(of: Data("DOOMED-TITLE-FOR-BACKUP".utf8)) == nil)
        #expect(try await world.catalog.session(id: other.id) != nil)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: Refusals

    @Test func codexSyntheticSharedAndUnknownConversationsAreRefusedBeforeAnythingIsRecorded() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let codex = try await Self.addConversation(world, provider: .codex, seed: false)
        let synthetic = try await Self.addConversation(world, provider: .synthetic, seed: false)
        for session in [codex, synthetic] {
            await #expect(throws: SessionRuntimeError.self) { _ = try await world.runtime.deleteConversation(id: session.id) }
            await #expect(throws: SessionRuntimeError.self) { _ = try await world.runtime.deletionPreview(id: session.id) }
        }
        do { _ = try await world.runtime.deleteConversation(id: codex.id) }
        catch let error as SessionRuntimeError {
            guard case let .deletionRefused(reason) = error else { throw error }
            #expect(reason.contains("Codex"))
        }
        let unknown = UUID()
        await #expect(throws: SessionRuntimeError.sessionNotFound(unknown)) {
            _ = try await world.runtime.deleteConversation(id: unknown)
        }

        // Two rows that name the same Claude conversation: deleting one would take the other's data.
        let shared = UUID().uuidString.lowercased()
        let first = try await Self.addConversation(world, providerID: shared)
        let second = try await Self.addConversation(world, providerID: shared, seed: false)
        let before = try env.snapshot(of: [shared])
        do { _ = try await world.runtime.deleteConversation(id: first.id); Issue.record("shared id accepted") }
        catch let error as SessionRuntimeError {
            guard case .deletionRefused = error else { throw error }
        }
        #expect(try env.snapshot(of: [shared]) == before)
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect(try await world.catalog.session(id: first.id) != nil)
        #expect(try await world.catalog.session(id: second.id) != nil)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func aDeletionAlreadyOnItsWayDoesNotCountAsSharing() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let shared = UUID().uuidString.lowercased()
        let first = try await Self.addConversation(world, providerID: shared)
        let second = try await Self.addConversation(world, providerID: shared, seed: false)
        #expect(try await world.catalog.isProviderIDShared(shared, excluding: first.id))
        let plan = CatalogDeletionPlan(provider: .claude, providerIDs: [shared, second.id.uuidString],
                                       configDirectory: nil, workingDirectory: nil)
        try await world.catalog.beginDeletion(sessionID: second.id, plan: plan)
        // `second` is going away with its data, so `first` is no longer blocked by it.
        #expect(try await world.catalog.isProviderIDShared(shared, excluding: first.id) == false)
        #expect(try await world.runtime.deleteConversation(id: first.id) == .deleted)
        #expect(try await world.catalog.isProviderIDPendingDeletion(shared.uppercased()))
        #expect(try await world.catalog.isProviderIDPendingDeletion(UUID().uuidString) == false)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func aDeletionIsRefusedWhileTheConversationIsStarting() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let session = try await Self.addConversation(world)
        world.toolchainSwitch.slow(by: 1)
        let resuming = Task { try await world.runtime.resumeConversation(sessionID: session.id) }
        #expect(await SessionRuntimeTests.waitUntil { await world.runtime.startingSessions.contains(session.id) })
        await #expect(throws: SessionRuntimeError.alreadyStarting(session.id)) {
            _ = try await world.runtime.deleteConversation(id: session.id)
        }
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        _ = try? await resuming.value
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func anUnopenedMailboxWithResidualWALCannotBeSilentlySkipped() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env, start: false)
        let target = try await Self.addConversation(world)
        let directory = env.root.appendingPathComponent("session-mailbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let wal = directory.appendingPathComponent("mailbox.sqlite3-wal")
        try Data("synthetic retained data".utf8).write(to: wal)
        let outcome = try await world.runtime.deleteConversation(id: target.id)
        guard case let .incomplete(pending) = outcome else {
            Issue.record("a residual mailbox WAL was skipped"); _ = await world.runtime.shutdown(); return
        }
        #expect(pending.lastFailure?.contains("mailbox_unavailable") == true)
        #expect(try Data(contentsOf: wal) == Data("synthetic retained data".utf8))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: Stop must be verified

    @Test func anUnverifiedStopKeepsTheRowAndTheFilesUntilARetryVerifiesIt() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let frames = await Frames(world.events)
        let (launch, screen) = try await Self.launch(world)
        try await screen.send("hello")
        #expect(await screen.contains("echo: hello"))
        let providerID = try await Self.providerID(world, launch.sessionID)
        let mailbox = try #require(await world.runtime.peerMailbox)
        let sender = SessionTaskBinding(sessionID: UUID(), nativeSessionID: "owned-sender", managedRunID: UUID(), generation: UUID())
        let message = PeerSendOffer(id: UUID(), sender: sender, senderTitle: "Sender", targetID: launch.sessionID,
            targetNativeID: providerID, targetTitle: "Target", targetHarness: .claude, message: "keep until verified")
        _ = try await mailbox.offer(message)
        _ = try await mailbox.decide(id: message.id, accept: true)
        let ids = [launch.sessionID.uuidString.lowercased(), providerID]
        try env.seed(ids)
        let before = try env.snapshot(of: ids)
        let attempts = AttemptCounter()
        try await world.supervisor.registerStopHooks(
            runID: launch.runID,
            hooks: ManagedRunStopHooks(
                prepare: { if attempts.next() == 1 { throw LoomError.message("provider work still running") } },
                completed: {}
            )
        )
        // A terminal surface's input queue, registered the way the app does.
        let rejected = InputErrorLog()
        let queue = TerminalInputQueue(endpoint: launch.terminal, onError: { rejected.append($0) })
        world.runtime.inputGate.register(runID: launch.runID, queue: queue)
        #expect(queue.enqueue(Array("typed before\r".utf8)))

        let first = try await world.runtime.deleteConversation(id: launch.sessionID)
        guard case let .incomplete(pending) = first else { Issue.record("expected incomplete"); return }
        #expect(pending.state == .stopping)
        #expect(pending.lastFailure?.contains("stop_unverified") == true)
        // Nothing was removed: row, files, the live run and the in-memory conversation all remain.
        #expect(try await world.catalog.session(id: launch.sessionID) != nil)
        #expect(try await mailbox.unread(target: launch.sessionID).map(\.message) == ["keep until verified"])
        #expect(try env.snapshot(of: ids) == before)
        #expect(await world.supervisor.session(id: launch.sessionID)?.currentRun != nil)
        #expect(try await world.runtime.pendingDeletions().map(\.id) == [launch.sessionID])
        #expect(await frames.has(.deletionIncomplete, for: launch.sessionID))
        // While it is pending the conversation cannot be used, and nothing more can be typed.
        #expect(!queue.enqueue(Array("typed after".utf8)))
        #expect(rejected.values.count == 1)
        await #expect(throws: SessionRuntimeError.self) { _ = try await world.runtime.resumeConversation(sessionID: launch.sessionID) }
        await #expect(throws: SessionCatalogError.self) { try await world.runtime.markViewed(sessionID: launch.sessionID) }

        let retried = try await world.runtime.retryDeletion(id: launch.sessionID)
        #expect(retried == .deleted)
        #expect(try env.snapshot(of: ids).isEmpty)
        #expect(try await world.catalog.session(id: launch.sessionID) == nil)
        #expect(try await mailbox.unread(target: launch.sessionID).isEmpty)
        #expect(await world.supervisor.runningSessionIDs().isEmpty)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func deletionFencesPendingPeerApprovalAndPreservesUnreadUntilVerifiedRetry() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let (target, _) = try await Self.launch(world)
        let (sender, _) = try await Self.launch(world)
        let senderClaim = try #require(await world.runtime.taskRunPlans[sender.sessionID]?.claim)
        let targetClaim = try #require(await world.runtime.taskRunPlans[target.sessionID]?.claim)
        #expect(await SessionRuntimeTests.waitUntil(3) {
            let first = await world.runtime.authenticateTaskRun(senderClaim)
            let second = await world.runtime.authenticateTaskRun(targetClaim)
            return first != nil && second != nil
        })
        @Sendable func call(_ id: UUID, _ message: String) -> SessionTaskWireRequest {
            var result = SessionTaskWireRequest(command: "peer-send", sessionID: senderClaim.sessionID,
                runID: senderClaim.managedRunID, generation: senderClaim.generation, credential: senderClaim.credential)
            result.operationID = id; result.targetSessionID = target.sessionID; result.message = message
            return result
        }
        let firstID = UUID(), first = Task { await world.runtime.submitPeerSend(call(firstID, "retained")) }
        guard await SessionRuntimeTests.waitUntil(3, { await world.runtime.openRequestSnapshot().contains { $0.id == firstID } }) else {
            first.cancel(); Issue.record("first card not offered"); _ = await world.runtime.shutdown(); return
        }
        try await world.runtime.approvePeerSendRequest(firstID)
        #expect(await first.value.status == "sent")
        let secondID = UUID(), second = Task { await world.runtime.submitPeerSend(call(secondID, "blocked")) }
        guard await SessionRuntimeTests.waitUntil(3, { await world.runtime.openRequestSnapshot().contains { $0.id == secondID } }) else {
            second.cancel(); Issue.record("second card not offered"); _ = await world.runtime.shutdown(); return
        }
        let fences = await world.runtime.peerTargetFences
        let originalFence = try #require(fences.acquire(target.sessionID))
        let stepGate = PeerDeletionStepGate()
        await world.runtime.setDeletionFailpointForTesting { state, phase in
            if state == .requested && phase == .before { stepGate.hold() }
        }
        let gate = PeerDeletionGate(), attempts = AttemptCounter()
        try await world.supervisor.registerStopHooks(runID: target.runID, hooks: ManagedRunStopHooks(prepare: {
            if attempts.next() == 1 { await gate.hold(); throw LoomError.message("stop unverified") }
        }, completed: {}))
        let deletion = Task { try await world.runtime.deleteConversation(id: target.sessionID) }
        let stepReached = await SessionRuntimeTests.waitUntil(3) { stepGate.entered }
        if stepReached {
            #expect(!originalFence.attempt { true }, "target input is fenced before the stop begins")
        } else { Issue.record("deletion did not enter the requested step") }
        stepGate.release()
        let reached = await SessionRuntimeTests.waitUntil(3) { await gate.entered }
        if reached {
            #expect(!originalFence.isActive, "deletion revokes the previously granted target fence before waiting")
            await #expect(throws: SessionTaskError.unauthorized) {
                try await world.runtime.approvePeerSendRequest(secondID)
            }
            #expect(await second.value.status == "failed")
        } else { second.cancel(); Issue.record("deletion did not reach its stop") }
        await gate.release()
        let outcome = try await deletion.value
        if case .incomplete = outcome {} else { Issue.record("expected unverified stop") }
        let mailbox = try #require(await world.runtime.peerMailbox)
        #expect(try await mailbox.unread(target: target.sessionID).map(\.message) == ["retained"])
        #expect(await world.runtime.submitPeerSend(call(UUID(), "still blocked")).status == "refused")
        #expect(try await world.runtime.retryDeletion(id: target.sessionID) == .deleted)
        #expect(try await mailbox.unread(target: target.sessionID).isEmpty)
        #expect(await world.runtime.openRequestSnapshot().allSatisfy { $0.send?.targetSessionID != target.sessionID })
        #expect(try await world.catalog.session(id: sender.sessionID) != nil)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: Fences

    @Test func aPendingConversationCannotStartOrResumeOrBeUsed() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let session = try await Self.addConversation(world)
        let plan = CatalogDeletionPlan(provider: .claude, providerIDs: Self.ids(session),
                                       configDirectory: nil, workingDirectory: nil)
        try await world.catalog.beginDeletion(sessionID: session.id, plan: plan)

        await #expect(throws: SessionRuntimeError.deletionPending(session.id)) {
            _ = try await world.runtime.resumeConversation(sessionID: session.id)
        }
        // The supervisor refuses before it spawns anything, so no run ever exists.
        let environment = ["LOOM_RUN_ID": world.supervisor.ownershipRunID.uuidString, "LOOM_SESSION_ID": session.id.uuidString]
        await #expect(throws: SessionManagementError.deletionPending(session.id)) {
            _ = try await world.supervisor.launch(sessionID: session.id, executable: "/usr/bin/true", environment: environment)
        }
        #expect(try await world.catalog.runs().isEmpty)
        #expect(await world.supervisor.runningSessionIDs().isEmpty)
        await #expect(throws: SessionCatalogError.self) { try await world.runtime.markViewed(sessionID: session.id) }
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func lateEventsOfADeletedRunNeverBringTheConversationBack() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let (launch, screen) = try await Self.launch(world)
        try await screen.send("hello")
        #expect(await screen.contains("echo: hello"))
        let providerID = try await Self.providerID(world, launch.sessionID)
        #expect(try await world.runtime.deleteConversation(id: launch.sessionID) == .deleted)

        for (event, fields) in [("Stop", ["last_assistant_message": "late"]), ("SessionEnd", ["reason": "other"]),
                                ("SessionStart", ["source": "resume"]), ("UserPromptSubmit", [:])] as [(String, [String: Any])] {
            let late = try Self.envelope(launch.sessionID, run: launch.runID, event: event, providerSession: providerID, fields: fields)
            #expect(try await world.runtime.harnesses.claude.adapter.receive(late) == .staleRun)
        }
        #expect(try await world.catalog.sessions().isEmpty)
        #expect(try await world.catalog.session(provider: .claude, conversationID: providerID) == nil)
        #expect(await world.supervisor.session(id: launch.sessionID) == nil)
        #expect(await world.supervisor.managedSessions().isEmpty)
        #expect(await world.events.snapshot().sessions[launch.sessionID] == nil)
        #expect(await world.supervisor.runContext(runID: launch.runID) == nil)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func anotherRunCannotResumeIntoADeletedConversation() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let (doomed, doomedScreen) = try await Self.launch(world)
        try await doomedScreen.send("hello")
        #expect(await doomedScreen.contains("echo: hello"))
        let deletedID = try await Self.providerID(world, doomed.sessionID)
        let (survivor, _) = try await Self.launch(world)
        #expect(try await world.runtime.deleteConversation(id: doomed.sessionID) == .deleted)

        // The surviving run reports a SessionStart(resume) of the deleted provider conversation.
        let resume = try Self.envelope(survivor.sessionID, run: survivor.runID, event: "SessionStart",
                                       providerSession: deletedID, fields: ["source": "resume"])
        #expect(try await world.runtime.harnesses.claude.adapter.receive(resume) == .staleRun)
        #expect(try await world.catalog.session(provider: .claude, conversationID: deletedID) == nil)
        #expect(try await world.catalog.sessions().map(\.session.id) == [survivor.sessionID])
        #expect(await world.supervisor.managedSessions().map(\.id) == [survivor.sessionID])
        #expect(await world.supervisor.activeSessionID(runID: survivor.runID) == survivor.sessionID)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func aDeletionStillOnItsWayAlsoFencesLateResumeOfItsProviderIDs() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        let providerID = try #require(victim.providerConversationID)
        let (survivor, _) = try await Self.launch(world)
        // The catalog rows are gone, the in-memory conversation is not yet discarded: only the
        // deletion record still names the id.
        await world.runtime.setDeletionFailpointForTesting { state, phase in
            if state == .catalog, phase == .after { throw LoomError.message("stop here") }
        }
        let outcome = try await world.runtime.deleteConversation(id: victim.id)
        guard case let .incomplete(pending) = outcome else { Issue.record("expected incomplete"); return }
        #expect(pending.state == .catalog)
        #expect(try await world.catalog.session(id: victim.id) == nil)

        let resume = try Self.envelope(survivor.sessionID, run: survivor.runID, event: "SessionStart",
                                       providerSession: providerID, fields: ["source": "resume"])
        #expect(try await world.runtime.harnesses.claude.adapter.receive(resume) == .staleRun)
        #expect(try await world.catalog.session(provider: .claude, conversationID: providerID) == nil)
        #expect(try await world.catalog.sessions().map(\.session.id) == [survivor.sessionID])
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: Recovery

    struct Interruption: Sendable, CustomTestStringConvertible {
        let state: CatalogDeletionState
        let phase: DeletionFailpointPhase
        var testDescription: String { "\(state.rawValue) \(phase)" }
    }

    static let interruptions: [Interruption] = CatalogDeletionState.allCases.flatMap { state in
        [Interruption(state: state, phase: .before)]
            + (state == .verifying ? [] : [Interruption(state: state, phase: .after)])
    }

    @Test(arguments: interruptions)
    func anInterruptedDeletionIsFinishedByANewRuntimeInstance(point: Interruption) async throws {
        let env = try Env()
        defer { env.cleanup() }
        let calls = Calls()
        let first = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(first)
        let bystander = try await Self.addConversation(first)
        let bystanderBefore = try env.snapshot(of: Self.ids(bystander))
        await first.runtime.setDeletionFailpointForTesting { state, phase in
            if state == point.state, phase == point.phase { throw LoomError.message("interrupted") }
        }
        let outcome = try await first.runtime.deleteConversation(id: victim.id)
        guard case let .incomplete(pending) = outcome else { Issue.record("expected incomplete"); return }
        #expect(pending.state == point.state)
        #expect(pending.attempts == 1)
        #expect(pending.lastFailure == "step_failed")
        #expect(try await first.runtime.pendingDeletions().map(\.id) == [victim.id])
        #expect((await first.runtime.shutdown()).succeeded)

        // The app starts again: nothing is retried until `start`, which finishes the record.
        let forgetters = ConversationForgetters()
        forgetters.register { id, ids in try calls.record(id, ids) }
        let second = try await Self.makeWorld(env, forgetters: forgetters)
        await second.runtime.finishDeletionRecovery()
        #expect(try await second.runtime.pendingDeletions().isEmpty)
        #expect(try await second.catalog.session(id: victim.id) == nil)
        #expect(await second.supervisor.session(id: victim.id) == nil)
        #expect(try env.snapshot(of: Self.ids(victim)).isEmpty)
        #expect(!env.tierTwoExists(try #require(victim.providerConversationID)))
        #expect(calls.all.map(\.0) == [victim.id])
        #expect(try env.snapshot(of: Self.ids(bystander)) == bystanderBefore)
        #expect(try await second.catalog.session(id: bystander.id) != nil)
        #expect(await second.runtime.deletionRecoveryFailure() == nil)
        #expect((await second.runtime.shutdown()).succeeded)
    }

    @Test func aConversationThatAppearsAgainBeforeVerificationKeepsTheDeletionOpen() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        let providerID = try #require(victim.providerConversationID)
        await world.runtime.setDeletionFailpointForTesting { state, phase in
            if state == .catalog, phase == .after { throw LoomError.message("interrupted") }
        }
        _ = try await world.runtime.deleteConversation(id: victim.id)
        await world.runtime.setDeletionFailpointForTesting(nil)
        // Something creates a row for the provider conversation again.
        let returned = ManagedSession(provider: .claude, providerConversationID: providerID, workingDirectory: env.home.path)
        try await world.catalog.insertSession(returned)
        guard case let .incomplete(pending) = try await world.runtime.retryDeletion(id: victim.id) else {
            Issue.record("expected incomplete"); return
        }
        #expect(pending.state == .verifying)
        #expect(pending.lastFailure == "provider_id_reappeared")
        #expect(try await world.catalog.pendingDeletions().map(\.sessionID) == [victim.id])
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func aFailedStepStaysVisibleAndOnlyAManualRetryResumesIt() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let calls = Calls()
        calls.failNext(1)
        let forgetters = ConversationForgetters()
        forgetters.register { id, ids in try calls.record(id, ids) }
        let first = try await Self.makeWorld(env, forgetters: forgetters)
        let victim = try await Self.addConversation(first)
        let outcome = try await first.runtime.deleteConversation(id: victim.id)
        guard case let .incomplete(pending) = outcome else { Issue.record("expected incomplete"); return }
        // The files and the rows are gone; only the registered hook failed.
        #expect(pending.state == .verifying)
        #expect(pending.lastFailure == "forget_hook_failed")
        #expect(try await first.catalog.session(id: victim.id) == nil)
        #expect(try env.snapshot(of: Self.ids(victim)).isEmpty)
        // A repeat of "delete" on a pending conversation is a retry.
        #expect(try await first.runtime.deleteConversation(id: victim.id) == .deleted)
        #expect(calls.all.count == 2)
        #expect(try await first.runtime.pendingDeletions().isEmpty)
        await #expect(throws: SessionRuntimeError.deletionNotPending(victim.id)) {
            _ = try await first.runtime.retryDeletion(id: victim.id)
        }
        #expect((await first.runtime.shutdown()).succeeded)
    }

    @Test func aLaunchRecoveryThatCannotFinishLeavesTheRecordWithItsFailure() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let first = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(first)
        // Make the plan fail for good: the config folder is writable by everyone.
        await first.runtime.setDeletionFailpointForTesting { state, phase in
            if state == .providerData, phase == .before { throw LoomError.message("interrupted") }
        }
        _ = try await first.runtime.deleteConversation(id: victim.id)
        #expect((await first.runtime.shutdown()).succeeded)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: env.profile.path)
        defer { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.profile.path) }

        let second = try await Self.makeWorld(env)
        await second.runtime.finishDeletionRecovery()
        let pending = try #require(try await second.runtime.pendingDeletions().first)
        #expect(pending.state == .providerData)
        #expect(pending.lastFailure == "unsafe_directory")
        #expect(pending.attempts == 2)
        #expect(try await second.catalog.session(id: victim.id) != nil)
        // The user fixes it and retries by hand.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.profile.path)
        #expect(try await second.runtime.retryDeletion(id: victim.id) == .deleted)
        #expect((await second.runtime.shutdown()).succeeded)
    }

    @Test func anIncompleteProviderDeletionIsReportedNotHidden() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        // A data folder moved elsewhere and linked back cannot be searched: deleting is not complete.
        try FileManager.default.removeItem(at: env.profile.appendingPathComponent("debug"))
        let moved = env.root.appendingPathComponent("moved-debug")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: moved.appendingPathComponent("\(Self.ids(victim)[1]).txt"))
        try FileManager.default.createSymbolicLink(at: env.profile.appendingPathComponent("debug"), withDestinationURL: moved)

        let preview = try await world.runtime.deletionPreview(id: victim.id)
        #expect(preview.unreachable == ["debug"])
        let outcome = try await world.runtime.deleteConversation(id: victim.id)
        guard case let .incomplete(pending) = outcome else { Issue.record("expected incomplete"); return }
        #expect(pending.state == .providerData)
        #expect(pending.lastFailure == "unreachable_folder: debug")
        // What could be reached is gone, the row stays, and the unreachable data was not touched.
        #expect(!env.exists("projects/p/\(Self.ids(victim)[1]).jsonl"))
        #expect(try await world.catalog.session(id: victim.id) != nil)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("\(Self.ids(victim)[1]).txt").path))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: OPT1 - retry can fix leftovers, a missing folder is not success, no CLI needed

    /// A file of the conversation appears after `provider_data` (a run that moved to another card keeps
    /// writing its debug log, or a start raced the request): verifying removes it in the same step.
    @Test func aFileThatReappearsBeforeVerifyingIsRemovedWithinTheSameDeletion() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        let providerID = try #require(victim.providerConversationID)
        let counter = AttemptCounter()
        await world.runtime.setDeletionFailpointForTesting { [env] state, phase in
            guard state == .verifying, phase == .before, counter.next() == 1 else { return }
            try env.write("debug/\(providerID).txt", "written again")
        }
        #expect(try await world.runtime.deleteConversation(id: victim.id) == .deleted)
        #expect(try env.snapshot(of: Self.ids(victim)).isEmpty)
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    /// The same leftover while Claude still holds the conversation: the first attempt fails visibly at
    /// `verifying`, and a retry (after the process is gone) completes instead of failing forever.
    @Test func leftoversAtVerifyingFailVisiblyAndARetryCompletes() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        let providerID = try #require(victim.providerConversationID)
        let counter = AttemptCounter()
        await world.runtime.setDeletionFailpointForTesting { [env] state, phase in
            guard state == .verifying, phase == .before, counter.next() == 1 else { return }
            try env.write("debug/\(providerID).txt", "written again")
            // This test process stands in for a live Claude process that holds the conversation.
            try env.write("sessions/\(getpid()).json", "{\"sessionId\":\"\(providerID)\",\"pid\":\(getpid())}")
        }
        guard case let .incomplete(pending) = try await world.runtime.deleteConversation(id: victim.id) else {
            Issue.record("expected incomplete"); return
        }
        #expect(pending.state == .verifying)
        #expect(pending.lastFailure == "live_session")
        #expect(env.exists("debug/\(providerID).txt"))

        try FileManager.default.removeItem(at: env.profile.appendingPathComponent("sessions/\(getpid()).json"))
        #expect(try await world.runtime.retryDeletion(id: victim.id) == .deleted)
        #expect(!env.exists("debug/\(providerID).txt"))
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    /// A config folder that cannot be shown to be gone (its parent is missing: an unmounted volume)
    /// is not a finished deletion. A folder that is gone while its parent exists is.
    @Test(arguments: [CatalogDeletionState.providerData, .verifying])
    func aMissingParentOfTheConfigFolderFailsTheStepAndARetryCompletes(state: CatalogDeletionState) async throws {
        let env = try Env(profileUnder: "volume")
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        let counter = AttemptCounter()
        await world.runtime.setDeletionFailpointForTesting { [env] at, phase in
            guard at == state, phase == .before, counter.next() == 1 else { return }
            try FileManager.default.removeItem(at: env.profileParent)
        }
        guard case let .incomplete(pending) = try await world.runtime.deleteConversation(id: victim.id) else {
            Issue.record("expected incomplete"); return
        }
        #expect(pending.state == state)
        #expect(pending.lastFailure == "config_unavailable")
        #expect(try await world.runtime.pendingDeletions().map(\.id) == [victim.id])

        // The volume is back (its files are not): the retry now finds the folder and finishes.
        try FileManager.default.createDirectory(at: env.profile, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #expect(try await world.runtime.retryDeletion(id: victim.id) == .deleted)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func aConfigFolderThatIsGoneWhileItsParentExistsHasNothingLeftToDelete() async throws {
        let env = try Env(profileUnder: "volume")
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        await world.runtime.setDeletionFailpointForTesting { [env] state, phase in
            guard state == .providerData, phase == .before else { return }
            try? FileManager.default.removeItem(at: env.profile)
        }
        #expect(try await world.runtime.deleteConversation(id: victim.id) == .deleted)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    /// Finding the config folder must not run the Claude CLI: with Claude gone from PATH the
    /// resolver fails, and preview and delete still work.
    @Test func previewAndDeleteNeverResolveTheClaudeToolchain() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        world.toolchainSwitch.fail(with: LoomError.message("claude is not installed"))
        let victim = try await Self.addConversation(world)

        let preview = try await world.runtime.deletionPreview(id: victim.id)
        #expect(preview.configDirectory == realPath(env.profile))
        #expect(preview.fileCount == 8)   // per id (Loom's and Claude's): transcript, history folder, debug log, tier 2
        #expect(try await world.runtime.deleteConversation(id: victim.id) == .deleted)
        #expect(world.toolchainSwitch.calls == 0)
        #expect(try env.snapshot(of: Self.ids(victim)).isEmpty)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func withoutAnExplicitProfileTheLoomEnvironmentNamesTheFolder() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let catalog = try SessionCatalog(url: env.catalogURL)
        let supervisor = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: catalog)
        let toolchains = ToolchainSwitch()
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: { _ in try toolchains.check(); throw LoomError.message("claude is not installed") },
                hookHelperPath: "/usr/bin/true", socketDirectory: env.socketDirectory,
                homeDirectory: env.home.path, claudeTemporaryRoot: env.temporary,
                forgetters: ConversationForgetters(),
                claudeEnvironment: ["CLAUDE_CONFIG_DIR": env.profile.path]
            )
        )
        let session = ManagedSession(provider: .claude, providerConversationID: UUID().uuidString.lowercased(),
                                     workingDirectory: env.home.path)
        try await supervisor.createSession(session, projectID: nil)
        try env.seed(Self.ids(session))
        #expect(try await runtime.deletionPreview(id: session.id).configDirectory == realPath(env.profile))
        #expect(try await runtime.deleteConversation(id: session.id) == .deleted)
        #expect(toolchains.calls == 0)
        #expect((await runtime.shutdown()).succeeded)
    }

    @Test func anUnusableConfigFolderIsAReadableRefusalNotARawError() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let missing = env.root.appendingPathComponent("not-mounted/claude-config", isDirectory: true)
        let world = try await Self.makeWorld(env, profileDirectory: missing)
        let victim = try await Self.addConversation(world, seed: false)
        for attempt in 0..<2 {
            do {
                if attempt == 0 { _ = try await world.runtime.deletionPreview(id: victim.id) }
                else { _ = try await world.runtime.deleteConversation(id: victim.id) }
                Issue.record("expected a refusal")
            } catch let error as SessionRuntimeError {
                guard case let .deletionRefused(reason) = error else { throw error }
                #expect(reason.contains("Claude data folder"))
            }
        }
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect(world.toolchainSwitch.calls == 0)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: DP-CP4-8 - the login shell's CLAUDE_CONFIG_DIR, resolved once at launch

    private static func runtimeWithoutProfile(
        _ env: Env, claudeEnvironment: [String: String],
        login: (@Sendable () async throws -> [String: String])?
    ) async throws -> (SessionRuntime, ManagedSession, ProcessSupervisor) {
        let catalog = try SessionCatalog(url: env.catalogURL)
        let supervisor = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: catalog)
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: { _ in throw LoomError.message("claude is not installed") },
                hookHelperPath: "/usr/bin/true", socketDirectory: env.socketDirectory,
                homeDirectory: env.home.path, claudeTemporaryRoot: env.temporary,
                forgetters: ConversationForgetters(),
                claudeEnvironment: claudeEnvironment, claudeLoginEnvironment: login
            )
        )
        let session = ManagedSession(provider: .claude, providerConversationID: UUID().uuidString.lowercased(),
                                     workingDirectory: env.home.path)
        try await supervisor.createSession(session, projectID: nil)
        try env.seed(Self.ids(session))
        return (runtime, session, supervisor)
    }

    @Test func aDeleteUsesTheFolderOnlyTheLoginShellNames() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let profile = env.profile.path
        // Loom's own environment names no folder (and `~/.claude` under the test's home does not exist).
        let (runtime, session, _) = try await Self.runtimeWithoutProfile(
            env, claudeEnvironment: [:], login: { ["CLAUDE_CONFIG_DIR": profile, "PATH": "/usr/bin"] })
        try await runtime.start()
        await runtime.finishLoginEnvironmentCapture()
        #expect(try await runtime.deletionPreview(id: session.id).configDirectory == realPath(env.profile))
        #expect(try await runtime.deleteConversation(id: session.id) == .deleted)
        #expect(try env.snapshot(of: Self.ids(session)).isEmpty)
        #expect((await runtime.shutdown()).succeeded)
    }

    @Test func aLoginShellThatCannotBeCapturedLeavesLoomsOwnEnvironmentInForce() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let (runtime, session, _) = try await Self.runtimeWithoutProfile(
            env, claudeEnvironment: ["CLAUDE_CONFIG_DIR": env.profile.path],
            login: { throw LoomError.message("shell timed out") })
        try await runtime.start()
        await runtime.finishLoginEnvironmentCapture()
        #expect(try await runtime.deletionPreview(id: session.id).configDirectory == realPath(env.profile))
        #expect((await runtime.shutdown()).succeeded)
    }

    final class ShellReads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// RS-2: the delete target's environment and the toolchain's come from one login shell, also when the toolchain is asked
    /// while the launch capture is still running.
    @Test func theLoginShellIsReadOnceForTheDeleteTargetAndTheToolchain() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let bin = env.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\ncase \"$1\" in\n  --version) echo 2.1.0 ;;\n  --help) echo '--settings <file> --session-id <uuid>' ;;\nesac\n".utf8).write(to: claude)
        chmod(claude.path, 0o755)
        let reads = ShellReads()
        let profile = env.profile.path
        let catalog = try SessionCatalog(url: env.catalogURL)
        let supervisor = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: catalog)
        let system = SystemProviderToolchains(
            supervisor: supervisor, origin: .development,
            environmentSource: {
                reads.bump()
                try await Task.sleep(for: .milliseconds(150))
                return LaunchEnvironment.Resolution(environment: ["PATH": "\(bin.path):/usr/bin:/bin", "CLAUDE_CONFIG_DIR": profile])
            }
        )
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: { try await system.toolchain(for: $0) },
                hookHelperPath: "/usr/bin/true", socketDirectory: env.socketDirectory,
                homeDirectory: env.home.path, claudeTemporaryRoot: env.temporary,
                forgetters: ConversationForgetters(), claudeEnvironment: [:],
                claudeLoginEnvironment: { try await system.terminalEnvironment().environment }
            )
        )
        try await runtime.start()
        // The launch capture is still running: the toolchain joins it instead of starting a second shell.
        _ = try await system.toolchain(for: .claude)
        await runtime.finishLoginEnvironmentCapture()
        _ = try await system.toolchain(for: .claude)
        #expect(reads.count == 1)
        #expect((await runtime.shutdown()).succeeded)
    }

    // MARK: DP-CP4-7 - a link that cannot hold this session's files does not stop its deletion

    private static func link(_ env: Env, _ relative: String, to target: URL) throws {
        let url = env.profile.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    @Test func aLinkedFolderOfAnotherProjectDoesNotStopTheDeletion() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        let elsewhere = env.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: elsewhere.appendingPathComponent("notes.txt"))
        try Self.link(env, "projects/-some-other-project", to: elsewhere)

        let preview = try await world.runtime.deletionPreview(id: victim.id)
        #expect(preview.unreachable.isEmpty)
        #expect(try await world.runtime.deleteConversation(id: victim.id) == .deleted)
        #expect(try env.snapshot(of: Self.ids(victim)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("notes.txt").path))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func theSessionsOwnProjectFolderAsALinkStillStopsTheDeletion() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        let own = ClaudeTranscriptLocator.folderName(forWorkingDirectory: env.home.path)
        let moved = env.root.appendingPathComponent("moved-project", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: moved.appendingPathComponent("\(Self.ids(victim)[1]).jsonl"))
        try Self.link(env, "projects/\(own)", to: moved)

        #expect(try await world.runtime.deletionPreview(id: victim.id).unreachable == ["projects/\(own)"])
        guard case let .incomplete(pending) = try await world.runtime.deleteConversation(id: victim.id) else {
            Issue.record("expected incomplete"); return
        }
        #expect(pending.lastFailure == "unreachable_folder: \(own)")
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("\(Self.ids(victim)[1]).jsonl").path))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: RS-1 - one scan gives every row of the cleanup review what its own preview gives

    @Test func theBatchedPreviewsEqualTheSinglePreviewsOfAProfileWithLinksAndSeveralFolders() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let otherFolder = env.root.appendingPathComponent("other-work", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let first = try await Self.addConversation(world)
        let second = try await Self.addConversation(world)
        // A conversation of another working directory, with files in its own project folder and a link-free profile part.
        let elsewhere = ManagedSession(provider: .claude, providerConversationID: UUID().uuidString.lowercased(),
                                       workingDirectory: otherFolder.path)
        try await world.supervisor.createSession(elsewhere, projectID: nil)
        try env.seed(Self.ids(elsewhere), project: ClaudeTranscriptLocator.folderName(forWorkingDirectory: otherFolder.path))
        let empty = try await Self.addConversation(world, seed: false)
        let codex = try await Self.addConversation(world, provider: .codex, providerID: nil, seed: false)
        // The home folder's own project folder is a link (it blocks the home conversations only), another project's is one too
        // (it blocks nobody), and a tier-2 and a residual entry exist.
        let own = ClaudeTranscriptLocator.folderName(forWorkingDirectory: env.home.path)
        let moved = env.root.appendingPathComponent("moved-project", isDirectory: true)
        let away = env.root.appendingPathComponent("elsewhere", isDirectory: true)
        for folder in [moved, away] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Self.link(env, "projects/\(own)", to: moved)
        try Self.link(env, "projects/-some-other-project", to: away)
        try env.write("projects/p/memory/note.md", "kept")

        let ids = [first.id, second.id, elsewhere.id, empty.id, codex.id]
        let batch = await world.runtime.deletionPreviews(ids: ids)
        for session in [first, second, elsewhere, empty] {
            let single = try await world.runtime.deletionPreview(id: session.id)
            #expect(batch[session.id] == single, "\(session.id)")
        }
        #expect(batch[codex.id] == nil, "a conversation its own preview refuses has no entry")
        await #expect(throws: SessionRuntimeError.self) { _ = try await world.runtime.deletionPreview(id: codex.id) }
        // The numbers are not trivial: files and bytes counted, the own-folder link blocks, the other project's does not.
        let firstPreview = try #require(batch[first.id])
        #expect(firstPreview.fileCount > 0 && firstPreview.byteCount > 0)
        #expect(firstPreview.unreachable == ["projects/\(own)"])
        #expect(try #require(batch[elsewhere.id]).unreachable.isEmpty)
        #expect(try #require(batch[elsewhere.id]).fileCount > 0)
        #expect(try #require(batch[empty.id]).fileCount == 0)
        #expect(!firstPreview.notRemoved.isEmpty)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    // MARK: DP-CP4-7 - "Remove from Loom only"

    @Test func removingFromLoomOnlyKeepsEveryFileOfClaudesAndForgetsTheSession() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let calls = Calls()
        let forgetters = ConversationForgetters()
        forgetters.register { id, ids in try calls.record(id, ids) }
        let world = try await Self.makeWorld(env, forgetters: forgetters)
        let frames = await Frames(world.events)
        let victim = try await Self.addConversation(world)
        let neighbour = try await Self.addConversation(world)
        let before = try env.snapshot(of: Self.ids(victim) + Self.ids(neighbour))
        #expect(!before.isEmpty)

        // No deletion was tried first: the sheet offers this when a folder blocks it.
        try await world.runtime.removeFromLoomOnly(id: victim.id)
        #expect(try await world.catalog.session(id: victim.id) == nil)
        #expect(try await world.catalog.session(id: neighbour.id) != nil)
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect(try env.snapshot(of: Self.ids(victim) + Self.ids(neighbour)) == before)
        #expect(env.tierTwoExists(Self.ids(victim)[0]))
        #expect(calls.all.map(\.0) == [victim.id])
        #expect(await frames.has(.conversationDeleted, for: victim.id))
        // The session is gone for good: nothing to remove a second time.
        await #expect(throws: SessionRuntimeError.sessionNotFound(victim.id)) {
            try await world.runtime.removeFromLoomOnly(id: victim.id)
        }
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func removingFromLoomOnlyFinishesADeletionThatCouldNotFinish() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let victim = try await Self.addConversation(world)
        let own = ClaudeTranscriptLocator.folderName(forWorkingDirectory: env.home.path)
        let moved = env.root.appendingPathComponent("moved-project", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: moved.appendingPathComponent("\(Self.ids(victim)[1]).jsonl"))
        try Self.link(env, "projects/\(own)", to: moved)
        guard case .incomplete = try await world.runtime.deleteConversation(id: victim.id) else {
            Issue.record("expected incomplete"); return
        }
        #expect(try await world.runtime.pendingDeletions().map(\.id) == [victim.id])
        // What the failed deletion left in Claude's folders (other than what it already removed) stays.
        let keptByClaude = try env.snapshot(of: Self.ids(victim))

        try await world.runtime.removeFromLoomOnly(id: victim.id)
        #expect(try await world.catalog.session(id: victim.id) == nil)
        #expect(try await world.runtime.pendingDeletions().isEmpty)
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        #expect(try env.snapshot(of: Self.ids(victim)) == keptByClaude)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("\(Self.ids(victim)[1]).jsonl").path))
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func removingFromLoomOnlyStopsARunningSessionFirst() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await Self.makeWorld(env)
        let (launch, screen) = try await Self.launch(world)
        try await screen.send("hello")
        #expect(await screen.contains("echo: hello"))
        let providerID = try await Self.providerID(world, launch.sessionID)
        try env.write("projects/p/\(providerID).jsonl", "transcript")

        try await world.runtime.removeFromLoomOnly(id: launch.sessionID)
        #expect(try await world.catalog.session(id: launch.sessionID) == nil)
        #expect(await world.supervisor.session(id: launch.sessionID)?.currentRun == nil)
        #expect(env.exists("projects/p/\(providerID).jsonl"))
        #expect((await world.runtime.shutdown()).succeeded)
    }
}
