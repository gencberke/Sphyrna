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
    @Test func aManagedPipeChildNeverRoutesThroughTheOrdinaryChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-managed-route-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let child = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await catalog.insertSession(child, title: "Reviewer")
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui.json")))
        model.intents = Intents()
        await model.start()
        defer { model.stop() }
        model.select(child.id)
        #expect(await waitUntil { model.selectedRow?.id == child.id })
        let run = UUID(), task = UUID()
        await hub.publish(sessionID: child.id, change: .managedTaskChanged(task))
        await hub.publish(sessionID: child.id, change: .runStarted(run))
        await hub.publish(sessionID: child.id, change: .runEndpoint(run, .pipe))
        #expect(await waitUntil { model.selectedRow?.live?.runEndpoint == .pipe })
        #expect(model.detailRouteKind == "managedAgent",
                "managed children must not expose the ordinary Chat composer")
        #expect(!model.canChooseFace)
        await hub.publish(sessionID: child.id, change: .runEnded(run, .processExited))
        #expect(await waitUntil { model.selectedRow?.live?.runID == nil })
        model.readOnlyChatEnabled = true
        #expect(model.detailRouteKind == "managedAgent", "the task record remains managed after Stop")
        #expect(!model.canChooseFace, "a task view offers Take Over, not the frozen face switch")
        await hub.publish(sessionID: child.id, change: .managedTaskDetached(task))
        #expect(await waitUntil { model.selectedRow?.live?.managedTaskID == nil })
        #expect(model.detailRouteKind != "managedAgent")
    }
}
