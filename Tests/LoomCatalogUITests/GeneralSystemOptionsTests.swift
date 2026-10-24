import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// Settings → General's system options that the system side keeps (`SystemIntegration`), stored in the preferences file beside the
/// other General switches.
@MainActor
@Suite struct GeneralSystemOptionsTests {
    private func store() throws -> (UIPreferencesStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-general-options-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (UIPreferencesStore(url: root.appendingPathComponent("p.json")), root)
    }

    @Test func keepMacAwakeIsOffByDefaultAndKeptAcrossLaunches() throws {
        let (preferences, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let integration = SystemIntegration()
        integration.attach(preferences: preferences)
        #expect(integration.keepAwake == .off, "a file without the key reads as Off")
        var changes = 0
        integration.onKeepAwakeChange = { changes += 1 }
        integration.setKeepAwake(.whileWorking)
        integration.setKeepAwake(.whileWorking)
        #expect(changes == 1, "the app hears a change once")

        let relaunched = SystemIntegration()
        relaunched.attach(preferences: UIPreferencesStore(url: preferences.url))
        #expect(relaunched.keepAwake == .whileWorking)
        #expect(UIPreferencesStore(url: preferences.url).current.notifyApprovals, "the other General switches are untouched")
    }
}
