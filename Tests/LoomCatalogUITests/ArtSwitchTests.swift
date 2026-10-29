import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// The art's switch (DESIGN §17 The budget, §2 items 5 and 8, D-12, D-79), kept in the preferences although no surface draws the art
/// since the rescue (D-100) and Settings → Theme no longer shows its row: on by default and kept with the other UI preferences; off, every drawing stands still on one frame and the arrival is the remora at its place; Reduce Motion does not
/// stop it. And the clock's wiring: a surface nobody can see has no ticker.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ArtSwitchTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-art-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func model(at root: URL) -> CatalogModel {
        CatalogModel(catalog: nil, startupError: nil, events: SessionEventHub(),
                     preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
    }

    // MARK: The preference

    @Test func animatedArtIsOnByDefaultAndKept() throws {
        #expect(UIPreferences().animatedArt, "on by default (D-79)")
        let older = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"viewMode":"projects","appearance":"light"}"#.utf8))
        #expect(older.animatedArt, "a file written before the setting existed reads as on")
        let unreadable = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"animatedArt":"yes"}"#.utf8))
        #expect(unreadable.animatedArt, "an unreadable value reads as on")
        var off = UIPreferences()
        off.animatedArt = false
        let decoded = try JSONDecoder().decode(UIPreferences.self, from: try JSONEncoder().encode(off))
        #expect(!decoded.animatedArt)

        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(at: root)
        #expect(model.animatedArt)
        model.setAnimatedArt(false)
        #expect(!model.animatedArt)
        let stored = try JSONDecoder().decode(UIPreferences.self, from: Data(contentsOf: root.appendingPathComponent("ui-preferences.json")))
        #expect(!stored.animatedArt, "kept with the other UI preferences")
        #expect(!self.model(at: root).animatedArt, "a new window reads what was saved")
        model.setAnimatedArt(true)
        #expect(self.model(at: root).animatedArt)
    }

    // MARK: Hosting
}
