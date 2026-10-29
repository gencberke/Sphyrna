import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// The real Settings window (`SettingsWindowConfiguration`, as the app builds it) and what happens to it outside a click.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SettingsWindowTests {
    @Test func closingTheWindowClosesTheSheetOverSettings() throws {
        let (model, root) = try SettingsWindowClickShared.settingsTestModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = SettingsNavigation(section: .remora)
        let window = SettingsWindowConfiguration.makeWindow(content: SettingsWindowClickShared.settingsTestView(model, navigation), background: .windowBackgroundColor)
        navigation.openRemoraMemory()
        #expect(navigation.openSheet == .remoraMemory)
        window.close()
        #expect(navigation.openSheet == nil, "the window comes back without the sheet it was closed under")
    }
}
