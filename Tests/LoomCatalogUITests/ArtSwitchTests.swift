import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// Settings → Theme → Animated art (DESIGN §17 The budget, §2 items 5 and 8, D-12, D-79): on by default and kept with the other UI
/// preferences; off, every drawing stands still on one frame and the arrival is the remora at its place; Reduce Motion does not
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

    @Test func theThemeSectionOffersItUnderAppearance() async throws {
        enableAccessibilityTree()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(at: root)
        let (window, hosting) = host(ThemeSettings(model: model), size: CGSize(width: LoomTheme.Settings.width, height: 520))
        defer { window.close() }
        try await settle(window)
        let spoken = accessibilityElements(in: hosting.view).compactMap { element -> String? in
            let label = element.accessibilityLabel?() ?? ""
            return label.isEmpty ? nil : label
        }
        let appearance = try #require(spoken.firstIndex(of: "Appearance"), "\(spoken)")
        let art = try #require(spoken.firstIndex(of: "Animated art"), "\(spoken)")
        let tone = try #require(spoken.firstIndex(of: "Tone"), "\(spoken)")
        #expect(appearance < art && art < tone, "Animated art sits under Appearance: \(spoken)")
    }

    // MARK: Off gives a still frame; Reduce Motion does not stop it

    @Test func offEveryDrawingStandsStillOnOneFrame() async throws {
        for animated in [true, false] {
            for place in ArtPlace.allCases {
                try await withHostedArt(place, animated: animated) { view in
                #expect(view.animatedArt == animated, "\(place)")
                // Were the window seen and active, the rule would give this view a rate only with Animated art on.
                var seen = view.clockInput
                seen.viewOnScreen = true; seen.windowVisible = true; seen.windowUnoccluded = true; seen.appActive = true
                let tick = ArtClock.tick(seen)
                if animated {
                    if place.kind != .resting { #expect(tick != .still, "\(place) moves with Animated art on") }
                } else {
                    #expect(tick == .still, "\(place) stands still with Animated art off: \(tick)")
                }
                }
            }
        }
    }

    @Test func reduceMotionIsNotAnInputOfTheRule() {
        // The rule reads where the view is, the app, the switch and the kind; nothing about Reduce Motion (D-12, D-79).
        let input = ArtClockInput(viewOnScreen: true, windowVisible: true, windowUnoccluded: true, appActive: true, animatedArt: true,
                                  kind: .ambient)
        let fields = Mirror(reflecting: input).children.compactMap(\.label)
        #expect(fields == ["viewOnScreen", "windowVisible", "windowUnoccluded", "appActive", "animatedArt", "kind"])
        #expect(ArtClock.tick(input) == .rate(24))
        // The view reads the switch alone, whatever macOS says about motion.
        let view = ArtLayerView(scene: ArtPlace.draftPage.scene, cell: LoomTheme.Art.ambientCell, kind: .ambient, animatedArt: true)
        #expect(view.clockInput.animatedArt)
    }

    @Test func settingsHandsTheSwitchToAboutsArt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(at: root)
        let about = SettingsAbout(version: "Version 1.6.0", dataFolder: root, claudeProfile: nil)
        let view = SettingsView(model: model, usage: nil, navigation: SettingsNavigation(section: .about), about: about)
        let (window, hosting) = host(view, size: CGSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height))
        defer { window.close() }
        try await settle(window)
        let art = try #require(Self.arts(in: hosting.view).first, "About draws its hammerhead")
        #expect(art.animatedArt && art.replaysWhenShown)
        model.setAnimatedArt(false)
        try await settle(window)
        #expect(!art.animatedArt, "the switch reaches the art at once")
    }

    // MARK: The clock's wiring

    @Test func aSurfaceNobodyCanSeeHasNoTicker() async throws {
        for place in ArtPlace.allCases {
            try await withHostedArt(place, animated: true) { view in
                #expect(view.window != nil && view.clockInput.windowVisible == false, "the window is never ordered front")
                #expect(!view.tickerRunning, "\(place) has a timer in a window nobody sees")
            }
        }
        // A hidden view has no timer either, and nor do the drawings that stand still.
        try await withHostedArt(.emptyAgents, animated: true) { view in
            view.isHidden = true
            #expect(!view.clockInput.viewOnScreen && !view.tickerRunning)
        }
    }

    // MARK: Hosting

    static func arts(in view: NSView) -> [ArtLayerView] {
        (view as? ArtLayerView).map { [$0] } ?? view.subviews.flatMap(arts(in:))
    }

    private func host<Content: View>(_ content: Content, size: CGSize) -> (NSWindow, NSHostingController<AnyView>) {
        let hosting = NSHostingController(rootView: AnyView(content.frame(width: size.width, height: size.height)))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        return (window, hosting)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(60))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// The place's art hosted alone with the switch as given, in a window nobody sees, open while `body` runs.
    private func withHostedArt(_ place: ArtPlace, animated: Bool, _ body: (ArtLayerView) throws -> Void) async throws {
        let (window, hosting) = host(ArtSurface(place: place).environment(\.animatedArt, animated),
                                     size: CGSize(width: 600, height: 320))
        defer { window.close() }
        try await settle(window)
        try body(try #require(Self.arts(in: hosting.view).first, "\(place) is drawn"))
    }
}
