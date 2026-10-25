import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

@MainActor
struct SettingsRoutingTests {
    @Test func theWindowOpensOnGeneralAndAnExplicitSectionWins() {
        let navigation = SettingsNavigation()
        #expect(navigation.section == .general)
        navigation.open(.usage)
        #expect(navigation.section == .usage)
        navigation.open(.about)
        #expect(navigation.section == .about)
    }

    @Test func openingWithoutASectionKeepsTheCurrentOne() {
        let navigation = SettingsNavigation()
        navigation.open(.usage)
        navigation.open(nil)
        #expect(navigation.section == .usage)
    }

    @Test func theModelRoutesTheGearAndTheChipToTheirSections() {
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("loom-settings-\(UUID()).json")))
        var requested: [SettingsSection?] = []
        model.onShowSettings = { requested.append($0) }
        model.showSettings()
        model.showSettings(.usage)
        #expect(requested == [nil, .usage])
    }

    @Test func settingsSectionsAreGeneralConnectionsThemeUsageSessionsRemoraAbout() {
        #expect(SettingsSection.allCases.map(\.title) == ["General", "Connections", "Theme", "Usage", "Sessions", "Remora", "About"])
        #expect(SettingsSection.available(cleanupReview: false).map(\.title) == ["General", "Connections", "Theme", "Usage", "Remora", "About"])
        #expect(SettingsSection.available(cleanupReview: true).map(\.title) == ["General", "Connections", "Theme", "Usage", "Sessions", "Remora", "About"])
    }
}
