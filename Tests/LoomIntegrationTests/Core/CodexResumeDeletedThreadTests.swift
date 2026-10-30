import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// A Codex session whose native thread was deleted outside it (Codex's own `thread/delete`, as another client or the CLI
/// does) is resumed: Codex 0.164's `thread/resume` answers "no rollout found for thread id <id>" on the fresh server the
/// resume starts, and the resume ends in the typed "history unavailable", never in a new thread or a TUI.
@Suite(.processHeavy, .timeLimit(.minutes(2)))
struct CodexResumeDeletedThreadTests {
    typealias Env = CodexDeletionTests.Env
    typealias Seed = CodexDeletionTests.Seed

    @Test func resumingAThreadCodexDeletedEndsInHistoryUnavailable() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await CodexDeletionTests.makeWorld(env)
        let thread = try Seed(env)
        let session = try await CodexDeletionTests.addSession(world, nativeID: thread.threadID)

        // Codex itself deletes the thread; the session stays in Sphyrna with its provider id.
        try await world.runtime.withCodexDeletionServer(card: session.id, home: env.codexHome) { client in
            #expect(try await client.threadExists(thread.threadID))
            try await client.deleteThread(thread.threadID)
        }
        #expect(!thread.serverKnowsIt)

        do {
            _ = try await world.runtime.resumeConversation(sessionID: session.id, outputSink: SessionRuntimeRig.Screen())
            Issue.record("A deleted Codex thread must not resume")
        } catch let error as LoomError {
            guard case .providerHistoryUnavailable(provider: .codex, conversationID: thread.threadID) = error else {
                Issue.record("Expected the typed unavailable-history error; got \(error)")
                return
            }
        }
        // No TUI was started for it, the session keeps its id, and every server the resume started is gone.
        #expect(!FileManager.default.fileExists(atPath: env.state.appendingPathComponent("codex-tui-arguments.log").path))
        #expect(try await world.catalog.session(id: session.id)?.session.providerConversationID == thread.threadID)
        await waitFor("the resume's Codex servers are gone") { await CodexDeletionTests.ownedScopeIsEmpty(world) }
        #expect((await world.runtime.shutdown()).succeeded)
    }
}
