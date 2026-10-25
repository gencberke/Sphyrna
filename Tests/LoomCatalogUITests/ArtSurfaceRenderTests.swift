import AppKit
import Foundation
import LoomCore
@testable import LoomRemora
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// The rescue (D-100): no surface draws the art any more. I5's surfaces hosted in windows nobody sees (never ordered front), in Ink
/// and Paper: none has an art view, so no display link runs for it. With `LOOM_ART_RENDER_DIR` set each picture is written there as
/// `surface-<name>-<ink|paper>.png`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(6)))
struct ArtSurfaceRenderTests {
    private var directory: URL? {
        ProcessInfo.processInfo.environment["LOOM_ART_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private func host<Content: View>(_ content: Content, size: CGSize, dark: Bool) -> (NSWindow, NSHostingController<AnyView>) {
        let root = AnyView(content.frame(width: size.width, height: size.height)
            .background(LoomTheme.Surface.canvas)
            .environment(\.colorScheme, dark ? .dark : .light))
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        return (window, hosting)
    }

    private func settle(_ window: NSWindow, rounds: Int = 8, until: () -> Bool = { true }) async throws {
        for _ in 0..<rounds {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if until() { return }
        }
    }

    private static func arts(in view: NSView) -> [ArtLayerView] { ArtSwitchTests.arts(in: view) }

    /// Renders `content`, writes it when asked, and hands the hosting view to `check` while the window is open.
    private func render<Content: View>(_ content: Content, name: String, size: CGSize, dark: Bool,
                                       until: @escaping (NSView) -> Bool = { _ in true },
                                       check: (NSView) throws -> Void = { _ in }) async throws {
        let (window, hosting) = host(content, size: size, dark: dark)
        defer { window.close() }
        try await settle(window, rounds: 30) { until(hosting.view) }
        try await settle(window, rounds: 3)
        if let directory {
            let bounds = hosting.view.bounds
            let rep = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: bounds))
            hosting.view.cacheDisplay(in: bounds, to: rep)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("surface-\(name)-\(dark ? "ink" : "paper").png"))
        }
        try check(hosting.view)
    }

    private func populated() async throws -> ListRig {
        try await ListRig.make(projects: 2, perProject: 4, unassigned: 0, mode: .projects)
    }

    private func noArt(_ name: String) -> (NSView) -> Void {
        { view in #expect(Self.arts(in: view).isEmpty, "no art on \(name)") }
    }

    private func emptyModel(_ root: URL) -> CatalogModel {
        CatalogModel(catalog: nil, startupError: nil, events: SessionEventHub(),
                     preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
    }

    // MARK: Home

    @Test func homesBandAndTheFirstLaunchDrawNoArt() async throws {
        let rig = try await populated()
        rig.model.showHome()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-art-first-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = emptyModel(root)
        for dark in [true, false] {
            try await render(HomeView(model: rig.model), name: "home-band", size: CGSize(width: 1019, height: 760), dark: dark,
                             check: noArt("Home"))
            try await render(HomeEmptyCatalog(model: model), name: "first-launch", size: CGSize(width: 1019, height: 760), dark: dark,
                             check: noArt("first launch"))
        }
    }

    /// Remora stays as it is: its still face, and no art behind the brief or the fold.
    @Test func remorasBriefAndFoldDrawNoArt() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 7_200), .init(title: "Rate limiter", project: 1, ago: 9_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        try rig.keepBrief(text: "You left off in **loom**, where the billing webhook waits for a review, and in api, where the rate limiter needs a test.",
                          chips: [(0, "Waits for review"), (1, "Needs a test")], ago: 600)
        rig.model.showHome()
        for dark in [true, false] {
            try await render(HomeView(model: rig.model), name: "remora-brief", size: CGSize(width: 1019, height: 760), dark: dark,
                             check: { view in
                #expect(Self.arts(in: view).isEmpty, "no art behind the brief")
                #expect(accessibilityElements(in: view).contains { $0.accessibilityIdentifier?() == "home-remora" }, "Remora is there")
            })
        }
        let fold = try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 600), .init(title: "Rate limiter", project: 1, ago: 9_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await fold.finish() } }
        try fold.keepBrief(text: "You left off in loom and api.", chips: [(0, "Waits for review"), (1, "Needs a test")], ago: 7_200)
        fold.model.showHome()
        try await render(HomeView(model: fold.model), name: "remora-fold", size: CGSize(width: 1019, height: 600), dark: true,
                         check: noArt("the fold"))
    }

    // MARK: The new-session page, About, Settings → Theme

    @Test func theNewSessionPageAboutAndThemeDrawNoArtAndThemeHasNoAnimatedArtRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-art-pages-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = emptyModel(root)
        let about = SettingsAbout(version: "Version 1.6.0 (build 214, 371aaf6)", dataFolder: root, claudeProfile: nil)
        let size = CGSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height)
        for dark in [true, false] {
            try await render(DraftSessionView(model: model, projectID: nil), name: "draft", size: CGSize(width: 1019, height: 880),
                             dark: dark, check: noArt("the new-session page"))
            try await render(SettingsView(model: model, usage: nil, navigation: SettingsNavigation(section: .about), about: about),
                             name: "about", size: size, dark: dark, check: noArt("About"))
        }
        enableAccessibilityTree()
        try await render(SettingsView(model: model, usage: nil, navigation: SettingsNavigation(section: .theme), about: about),
                         name: "settings-theme", size: size, dark: true, check: { view in
            #expect(Self.arts(in: view).isEmpty)
            #expect(!accessibilityElements(in: view).contains { ($0.accessibilityLabel?() ?? "") == "Animated art" },
                    "Settings → Theme has no Animated art row")
        })
    }

    // MARK: Panes

    @Test func theEmptyAndWaitingPanesAndTheRecordDrawNoArt() async throws {
        let panes: [(String, AnyView, CGSize)] = [
            ("empty-agents", AnyView(InspectorEmptyState(text: "No subagents in this session.")), CGSize(width: 340, height: 160)),
            ("empty-changes", AnyView(InspectorEmptyState(text: "Claude has not edited files in the last turn.")),
             CGSize(width: 340, height: 160)),
            ("reading-branch", AnyView(InspectorEmptyState(text: ChangesBodyWords.readingBranch, detail: "git diff --numstat -M · 2 s")),
             CGSize(width: 340, height: 170)),
            ("empty-side", AnyView(SideEmptyState()), CGSize(width: 340, height: 280)),
            ("empty-project", AnyView(ProjectEmptyList()), CGSize(width: 640, height: 200)),
        ]
        for dark in [true, false] {
            for (name, pane, size) in panes {
                try await render(VStack(spacing: 0) { pane; Spacer(minLength: 0) }, name: name, size: size, dark: dark,
                                 check: noArt(name))
            }
        }
        let rig = try await populated()
        let (side, sideHosting) = host(SidebarView(model: rig.model), size: CGSize(width: 300, height: 700), dark: true)
        defer { side.close() }
        try await settle(side)
        #expect(Self.arts(in: sideHosting.view).isEmpty, "never in the sidebar")
    }
}
