import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI

@MainActor
struct HarnessConnectionPreferencesTests {
    @Test(arguments: HarnessCatalogue.ids)
    func everyHarnessSwitchSurvivesTheAppsPreferenceWiring(id: HarnessID) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-connect-preferences-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let store = UIPreferencesStore(url: url)
        let connections = store.makeHarnessConnections()
        let choice = !connections.isOn(id)
        connections.setOn(id, choice)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.current.isHarnessConnected(id) != choice, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.current.isHarnessConnected(id) == choice, "The app's switch saves every catalogue id")
        let reloaded = UIPreferencesStore(url: url).makeHarnessConnections()
        #expect(reloaded.isOn(id) == choice, "A new app connection reads the persisted choice")
        let writes = store.writeCount
        connections.setOn(id, choice)
        await Task.yield()
        #expect(store.writeCount == writes, "An unchanged switch causes no extra preference write")
    }
}
