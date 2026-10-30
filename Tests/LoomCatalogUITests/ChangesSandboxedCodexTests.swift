import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// A Codex session's sandbox blocks Sphyrna's session channel, so Changes never offers "Send to Codex" for it and says why,
/// running or stopped. A Claude session keeps its footer.
@MainActor
struct ChangesSandboxedCodexTests {
    @Test func aSandboxedCodexSessionHasNoSendAndTheFooterSaysWhy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-changes-codex-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let codex = ManagedSession(provider: .codex, providerConversationID: "codex-thread", workingDirectory: root.path)
        let claude = ManagedSession(provider: .claude, providerConversationID: "claude-conv", workingDirectory: root.path)
        for (index, session) in [codex, claude].enumerated() {
            try await catalog.insertSession(session, title: "Session \(index)", createdAt: Date(timeIntervalSince1970: 1_000),
                                            lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle)
        }
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: HarnessMode.acceptEdits.rawValue),
                                              sessionID: codex.id)
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs.json")))
        await model.start()
        defer { model.stop() }
        #expect(await inspectorWaitUntil { model.rowModels[codex.id] != nil && model.rowModels[claude.id] != nil })
        await model.launchModels.load(codex.id, from: catalog)

        for id in [codex.id, claude.id] {
            model.changes.session(for: id).saveComment("Name this better.",
                at: ChangeAnchor(fileID: "/w/a.swift", line: 3, removed: false, text: "x"), displayPath: "a.swift", in: .lastTurn)
        }
        #expect(model.changesSendNote(for: codex.id) == SessionChannelSandbox.codexReason, "stopped: the sandbox is the reason")
        #expect(model.changesSendNote(for: claude.id) == "Comments are sent while the session runs")

        for (id, run) in [(codex.id, UUID()), (claude.id, UUID())] {
            await hub.publish(sessionID: id, change: .runStarted(run))
            await hub.publish(sessionID: id, change: .runEndpoint(run, .terminal))
            #expect(await inspectorWaitUntil { model.rowModels[id]?.live?.runEndpoint == .terminal })
            model.changes.session(for: id).messageRun = run // as if the runtime said this run takes messages
        }
        #expect(model.changesSendAvailability(for: codex.id) == .unavailable)
        #expect(model.changesSendTitle(for: codex.id) == nil, "no Send to Codex")
        #expect(model.changesSendNote(for: codex.id) == SessionChannelSandbox.codexReason)
        #expect(model.changesSendTitle(for: claude.id) == "Send to Claude")
        #expect(model.changesSendNote(for: claude.id) == nil)
    }
}
