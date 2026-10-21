import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora

/// L3a: a deleted session's journal lines go through a real runtime's deletion, also when the deletion is the one
/// `SessionRuntime.start()` recovers at launch. The runtime has no provider: a deletion needs only a catalog, a supervisor and
/// a Claude profile folder, which here is a temporary one. Nothing reads a real `~/.claude`.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct RemoraHostForgetterTests {
    private final class Env: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-del-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let socketDirectory = URL(fileURLWithPath: "/tmp/lr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var profile: URL { root.appendingPathComponent("claude-config", isDirectory: true) }
        var temporary: URL { root.appendingPathComponent("tmp-claude", isDirectory: true) }
        var catalogURL: URL { root.appendingPathComponent("catalog.sqlite3") }

        init() throws {
            for directory in [home, profile, temporary] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketDirectory)
        }
    }

    private struct World {
        let catalog: SessionCatalog
        let supervisor: ProcessSupervisor
        let runtime: SessionRuntime
    }

    /// A runtime over `env`'s catalog; calling it again for the same `env` is a relaunch.
    private func makeWorld(_ env: Env, forgetters: ConversationForgetters) async throws -> World {
        let catalog = try SessionCatalog(url: env.catalogURL)
        let supervisor = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: catalog)
        let resolver: ProviderToolchainResolver = { _ in throw LoomError.message("no provider in this test") }
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: resolver, hookHelperPath: "/nonexistent/loom-hook", socketDirectory: env.socketDirectory,
                homeDirectory: env.home.path, claudeTemporaryRoot: env.temporary, forgetters: forgetters,
                claudeProfileDirectory: env.profile, catalogBackupDelay: nil))
        return World(catalog: catalog, supervisor: supervisor, runtime: runtime)
    }

    private func addSession(_ world: World, _ env: Env) async throws -> ManagedSession {
        let session = ManagedSession(provider: .claude, providerConversationID: UUID().uuidString.lowercased(),
                                     workingDirectory: env.home.path)
        try await world.supervisor.createSession(session, projectID: nil)
        return session
    }

    /// Two journal lines in the host's folder: one cites `victim`, one cites someone else.
    private func seedJournal(_ rig: RemoraHostRig, victim: UUID) async throws {
        let memory = try RemoraMemory(directory: rig.remora, timeZone: rig.zone, clock: { [clock = rig.clock] in clock.now })
        for (question, session) in [("about the victim", victim), ("about another", UUID())] {
            try await memory.appendJournal(RemoraJournalEntry.make(
                kind: .question, question: question, answerText: "An answer.", sessions: [session], model: nil, tokens: 10,
                summary: nil, date: rig.clock.now))
        }
    }

    @Test func aDeletedSessionsJournalLinesGoThroughARealRuntimeDeletion() async throws {
        let rig = try RemoraHostRig()
        let env = try Env()
        defer { env.cleanup() }
        let forgetters = ConversationForgetters()
        let host = rig.makeHost()
        host.registerForgetter(in: forgetters)
        let world = try await makeWorld(env, forgetters: forgetters)
        try await world.runtime.start()
        let victim = try await addSession(world, env)
        try await seedJournal(rig, victim: victim.id)

        #expect(try await world.runtime.deleteConversation(id: victim.id) == .deleted)
        #expect(await host.journal(on: rig.clock.now).map(\.question) == ["about another"])
        #expect((await world.runtime.shutdown()).succeeded)
        await rig.finish()
    }

    @Test func aDeletionRecoveredAtLaunchReachesTheJournalBecauseTheForgetterIsRegisteredBeforeStart() async throws {
        let rig = try RemoraHostRig()
        let env = try Env()
        defer { env.cleanup() }
        // The first run is interrupted in the middle of the deletion (the record stays), with no Remora in it.
        let first = try await makeWorld(env, forgetters: ConversationForgetters())
        try await first.runtime.start()
        let victim = try await addSession(first, env)
        try await seedJournal(rig, victim: victim.id)
        await first.runtime.setDeletionFailpointForTesting { state, phase in
            if state == .providerData, phase == .before { throw LoomError.message("interrupted") }
        }
        #expect(try await first.runtime.deleteConversation(id: victim.id) != .deleted)
        #expect((await first.runtime.shutdown()).succeeded)

        // The relaunch: the host is made and its forgetter registered, then start() recovers the deletion.
        let forgetters = ConversationForgetters()
        let host = rig.makeHost()
        host.registerForgetter(in: forgetters)
        let second = try await makeWorld(env, forgetters: forgetters)
        #expect(!host.memoryIsOpen, "launch opened the memory")
        try await second.runtime.start()
        await second.runtime.finishDeletionRecovery()
        #expect(try await second.catalog.pendingDeletions().isEmpty)
        #expect(await host.journal(on: rig.clock.now).map(\.question) == ["about another"])
        #expect((await second.runtime.shutdown()).succeeded)
        await rig.finish()
    }

    @Test func aForgetterRegisteredAfterStartMissesTheRecoveredDeletion() async throws {
        let rig = try RemoraHostRig()
        let env = try Env()
        defer { env.cleanup() }
        let first = try await makeWorld(env, forgetters: ConversationForgetters())
        try await first.runtime.start()
        let victim = try await addSession(first, env)
        try await seedJournal(rig, victim: victim.id)
        await first.runtime.setDeletionFailpointForTesting { state, phase in
            if state == .providerData, phase == .before { throw LoomError.message("interrupted") }
        }
        _ = try await first.runtime.deleteConversation(id: victim.id)
        #expect((await first.runtime.shutdown()).succeeded)

        let forgetters = ConversationForgetters()
        let second = try await makeWorld(env, forgetters: forgetters)
        try await second.runtime.start()
        await second.runtime.finishDeletionRecovery()
        rig.makeHost().registerForgetter(in: forgetters)   // too late: the recovery finished without it
        #expect(Set(await rig.makeHost().journal(on: rig.clock.now).compactMap(\.question)) == ["about the victim", "about another"])
        #expect((await second.runtime.shutdown()).succeeded)
        await rig.finish()
    }
}
