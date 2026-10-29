import AppKit
import Foundation
import LoomCore
import LoomTerminal
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// V16: "running" is a run, not a terminal view. A Chat-face (pipe) run has no terminal: the session routes to its
/// live chat, shows no "not running" banner and offers no face switch; a terminal run still reads as before.
@MainActor
@Suite
struct LiveChatRouteTests: LiveChatRouteFixtures {
    @Test func aLivePipeRunShowsItsChatAndIsRunning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-live-route-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .claude, providerConversationID: UUID().uuidString.lowercased(),
                                     workingDirectory: root.path)
        try await catalog.insertSession(session, title: "Live")
        let hub = SessionEventHub()
        let intents = Intents()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        model.intents = intents
        await model.start()
        defer { model.stop() }
        model.select(session.id)
        #expect(await waitUntil { model.selectedRow?.id == session.id })
        // Even with the read-only chat switched off, a pipe run is the chat.
        model.readOnlyChatEnabled = false

        let run = UUID()
        await hub.publish(sessionID: session.id, change: .runStarted(run))
        await hub.publish(sessionID: session.id, change: .runEndpoint(run, .pipe))
        await hub.publish(sessionID: session.id, change: .status(ProviderWorkState(activity: .working)))
        #expect(await waitUntil { model.selectedRow?.live?.runEndpoint == .pipe })
        let row = try #require(model.selectedRow)
        #expect(model.detailRoute == .chat(sessionID: session.id))
        #expect(model.isRunning(row))
        #expect(!SessionChatView.showsNotRunning(isRunning: model.isRunning(row)))
        model.readOnlyChatEnabled = true
        #expect(!model.canChooseFace)

        // The run ends: not running, and the banner is back.
        await hub.publish(sessionID: session.id, change: .runEnded(run, .processExited))
        #expect(await waitUntil { model.selectedRow?.live?.runID == nil })
        let ended = try #require(model.selectedRow)
        #expect(!model.isRunning(ended))
        #expect(SessionChatView.showsNotRunning(isRunning: model.isRunning(ended)))
        #expect(model.canChooseFace)
    }
}
