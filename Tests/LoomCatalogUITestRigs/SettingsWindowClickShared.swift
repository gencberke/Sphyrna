import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `SettingsWindowClickTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum SettingsWindowClickShared {
    @MainActor
    static func settingsTestModel() throws -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-settings-window-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (CatalogModel(catalog: nil, events: SessionEventHub(),
                             preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json"))), root)
    }

    @MainActor
    static func settingsTestView(_ model: CatalogModel, _ navigation: SettingsNavigation) -> SettingsView {
        let root = FileManager.default.temporaryDirectory
        return SettingsView(model: model, usage: nil, navigation: navigation,
                            about: SettingsAbout(version: "Version 1.6.1", dataFolder: root.appendingPathComponent("Loom"),
                                                 claudeProfile: nil))
    }
}
