import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// D-121 in the UI: a Codex session is deleted from Sphyrna like a Claude one. Its Delete is offered, the confirm sheet names
/// Codex while it checks, and a deletion that stops on one of Codex's own steps shows a plain reason in the banner, never a code.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct CodexDeletionModelTests {
    struct Fixture {
        let root: URL
        let model: CatalogModel
        let intents: DeletionIntents
        let codex: ManagedSession

        func cleanup() async {
            await model.stopAndWait()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codexdel-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let codex = ManagedSession(provider: .codex, providerConversationID: UUID().uuidString.lowercased(),
                                   workingDirectory: root.path)
        try await catalog.insertSession(codex, title: "Codex conversation", createdAt: Date(timeIntervalSince1970: 1_000),
                                        lastUsedAt: Date(timeIntervalSince1970: 10_000), lifecycle: .idle)
        let model = CatalogModel(
            catalog: catalog, events: SessionEventHub(),
            preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs.json")),
            startableProviders: [.claude, .codex]
        )
        let intents = DeletionIntents()
        model.intents = intents
        await model.start()
        return Fixture(root: root, model: model, intents: intents, codex: codex)
    }

    private func pending(_ id: UUID, _ failure: String) -> PendingConversationDeletion {
        PendingConversationDeletion(id: id, state: .providerData, attempts: 1, lastFailure: failure,
                                    requestedAt: Date(), updatedAt: Date(), isRunning: false, provider: .codex)
    }

    /// The shared bounded wait, off the main actor: the condition hops to it for each look.
    @discardableResult
    nonisolated private static func previewReady(_ confirmation: DeletionConfirmation) async -> Bool {
        await waitFor("the Codex preview is ready") { await confirmation.canConfirm }
    }

    private func bannerText(_ model: CatalogModel, _ id: UUID) -> String? {
        Banners.items(for: model).first { $0.kind == .deletionFailure(id) }?.text
    }

    @Test func aCodexSessionIsOfferedDeleteAndAFailedStepShowsAPlainReason() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.cleanup() } }
        let id = fixture.codex.id
        let row = try #require(fixture.model.list(for: .activity).rows.first { $0.id == id })
        #expect(fixture.model.deletionDisabledReason(for: row) == nil)
        #expect(fixture.model.canDelete(row))

        // The sheet names Codex while the dry run runs (the preview's task has not run before this actor yields), then
        // the runtime is asked to delete.
        fixture.model.requestDeletion(id)
        let confirmation = try #require(fixture.model.deletions.confirmation)
        #expect(confirmation.phase == .loading)
        #expect(confirmation.checkingText == "Checking what Codex has kept for this session…")
        await Self.previewReady(confirmation)

        // Codex would delete subagent sessions that are not this session's own: the banner says so in words.
        fixture.intents.deleteOutcome = .incomplete(pending(id, "native_descendants"))
        await fixture.model.confirmDeletion()
        #expect(fixture.intents.calls.contains("delete:\(id)"))
        let descendants = try #require(bannerText(fixture.model, id))
        #expect(descendants.contains("subagent sessions"), "\(descendants)")
        #expect(!descendants.contains("_") && !descendants.contains("Claude"), "\(descendants)")

        // Sphyrna could not reach Codex's own server: the retry fails with a reason that says what to do.
        fixture.intents.retryOutcome = .incomplete(pending(id, "server_unavailable"))
        await fixture.model.retryDeletion(id)
        let server = try #require(bannerText(fixture.model, id))
        #expect(server.contains("Codex") && server.contains("try again"), "\(server)")
        #expect(!server.contains("_") && !server.contains("Claude"), "\(server)")
    }
}
