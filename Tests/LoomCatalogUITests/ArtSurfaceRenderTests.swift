import AppKit
import Foundation
import LoomCore
@testable import LoomRemora
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// I5's surfaces hosted in windows nobody sees (never ordered front), in Ink and Paper: each surface draws its art where DESIGN §17
/// puts it, and nowhere else (not over Home's lists, not in the sidebar, not in a pane that has content). With
/// `LOOM_ART_RENDER_DIR` set each picture is written there as `surface-<name>-<ink|paper>.png`.
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

    /// The art's views under `view`, with their frames in its coordinates (y down from the top).
    private func artFrames(in view: NSView) -> [(ArtLayerView, CGRect)] {
        Self.arts(in: view).map { art in
            var frame = art.convert(art.bounds, to: view)
            if !view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            return (art, frame)
        }
    }

    private func id(_ id: String, in view: NSView) -> CGRect? {
        accessibilityElements(in: view).first { $0.accessibilityIdentifier?() == id }.flatMap { $0.accessibilityFrame?() }
    }

    private func populated() async throws -> ListRig {
        try await ListRig.make(projects: 2, perProject: 4, unassigned: 0, mode: .projects)
    }

    // MARK: Home

    @Test func homesBandHasItsOneHammerheadAndNoArtStandsOverTheLists() async throws {
        let rig = try await populated()
        rig.model.showHome()
        for dark in [true, false] {
            try await render(HomeView(model: rig.model), name: "home-band", size: CGSize(width: 1019, height: 760), dark: dark,
                             until: { !Self.arts(in: $0).isEmpty }) { view in
                let arts = artFrames(in: view)
                #expect(arts.count == 1, "the band's hammerhead and nothing else: \(arts.map(\.1))")
                for (art, frame) in arts {
                    #expect(art.scene == ArtPlace.homeBand.scene && art.mask == .band)
                    #expect(frame.maxY <= LoomTheme.Canvas.bandHeight + 1, "the art stays in the band's 300: \(frame)")
                    #expect(art.hitTest(NSPoint(x: 10, y: 10)) == nil, "it never takes a click")
                }
            }
        }
    }

    @Test func theFirstLaunchRoamsBehindTheMessageAndNoSharkSwimsWithoutClaude() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-art-first-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, startupError: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        for dark in [true, false] {
            try await render(HomeEmptyCatalog(model: model), name: "first-launch", size: CGSize(width: 1019, height: 760), dark: dark,
                             until: { !Self.arts(in: $0).isEmpty }) { view in
                let arts = Self.arts(in: view)
                #expect(arts.count == 1 && arts.first?.scene == ArtPlace.firstLaunch.scene && arts.first?.mask == .firstLaunch)
            }
        }
        #expect(HomeEmptyCatalog.showsMark(connectCards: true) == false, "over the Connect your agents cards no shark swims")
    }

    /// The brief with its tiles, a brief being written, and the fold: the band's hammerhead on its own loop is the only art Home
    /// draws; Remora's face is a still drawing with no art view and so no frame clock.
    @Test func remorasBriefAndFoldDrawOnlyTheBandsLoop() async throws {
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 7_200), .init(title: "Rate limiter", project: 1, ago: 9_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        try rig.keepBrief(text: "You left off in **loom**, where the billing webhook waits for a review, and in api, where the rate limiter needs a test.",
                          chips: [(0, "Waits for review"), (1, "Needs a test")], ago: 600)
        rig.model.showHome()
        func onlyTheBand(_ view: NSView) {
            let arts = Self.arts(in: view)
            #expect(arts.count == 1 && arts.first?.scene == ArtPlace.homeBand.scene, "\(arts.map(\.scene))")
            if let band = arts.first {
                #expect(band.drawnKind == .homeLoop, "the band keeps its loop")
            }
        }
        for dark in [true, false] {
            try await render(HomeView(model: rig.model), name: "remora-brief", size: CGSize(width: 1019, height: 760), dark: dark,
                             until: { !Self.arts(in: $0).isEmpty }, check: onlyTheBand)
        }
        // A new brief being written: the face fades in, and still only the band ticks.
        rig.model.remora.phase = .briefing
        try await render(HomeView(model: rig.model), name: "remora-reading", size: CGSize(width: 1019, height: 760), dark: true,
                         until: { !Self.arts(in: $0).isEmpty }, check: onlyTheBand)
        rig.model.remora.phase = .idle
        // Folded: the brief began two hours ago and a session ran after it.
        let fold = try await RemoraHomeRig.make(
            projectNames: ["loom", "api"],
            seeds: [.init(title: "Billing webhook", project: 0, ago: 600), .init(title: "Rate limiter", project: 1, ago: 9_000)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await fold.finish() } }
        try fold.keepBrief(text: "You left off in loom and api.", chips: [(0, "Waits for review"), (1, "Needs a test")], ago: 7_200)
        fold.model.showHome()
        for dark in [true, false] {
            try await render(HomeView(model: fold.model), name: "remora-fold", size: CGSize(width: 1019, height: 600), dark: dark,
                             until: { !Self.arts(in: $0).isEmpty }, check: onlyTheBand)
        }
    }

    // MARK: The new-session page, About

    @Test func theNewSessionPageAndAboutDrawTheirSeas() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-art-pages-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, startupError: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        for dark in [true, false] {
            try await render(DraftSessionView(model: model, projectID: nil), name: "draft", size: CGSize(width: 1019, height: 880),
                             dark: dark, until: { !Self.arts(in: $0).isEmpty }) { view in
                let arts = Self.arts(in: view)
                #expect(arts.count == 1 && arts.first?.scene == ArtPlace.draftPage.scene && arts.first?.mask == .calm)
            }
            let about = SettingsAbout(version: "Version 1.6.0 (build 214, 371aaf6)", dataFolder: root, claudeProfile: nil)
            for t in [4.0, 30.0] {
                let page = SettingsView(model: model, usage: nil, navigation: SettingsNavigation(section: .about), about: about)
                try await render(page, name: "about-\(Int(t))s", size: CGSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height),
                                 dark: dark, until: { view in
                                     // The moment to picture: the crossing at 4 s, at rest by 30 s.
                                     guard let art = Self.arts(in: view).first, art.source != nil else { return false }
                                     art.seek(to: t)
                                     return true
                                 }) { view in
                    let art = try #require(Self.arts(in: view).first)
                    if t > 20 { #expect(art.drawnKind == .resting, "it crossed and rests") }
                    let frame = try #require(artFrames(in: view).first?.1)
                    #expect(abs(frame.height - LoomTheme.Art.aboutHeight) < 1 && abs(frame.width - LoomTheme.Settings.width) < 1,
                            "the art spans the page under the band: \(frame)")
                }
            }
            try await render(SettingsView(model: model, usage: nil, navigation: SettingsNavigation(section: .theme), about: about),
                             name: "settings-theme", size: CGSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height), dark: dark)
        }
    }

    // MARK: Panes

    @Test func theEmptyAndWaitingPanesDrawTheirSmallSharkAboveTheirWords() async throws {
        enableAccessibilityTree()
        let panes: [(String, AnyView, ArtPlace, CGSize)] = [
            ("empty-agents", AnyView(InspectorEmptyState(text: "No subagents in this session.", art: .emptyAgents)), .emptyAgents,
             CGSize(width: 340, height: 160)),
            ("empty-changes", AnyView(InspectorEmptyState(text: "Claude has not edited files in the last turn.", art: .emptyChanges)),
             .emptyChanges, CGSize(width: 340, height: 160)),
            ("reading-branch", AnyView(InspectorEmptyState(text: ChangesBodyWords.readingBranch, detail: "git diff --numstat -M · 2 s",
                                                           art: .readingBranch)), .readingBranch, CGSize(width: 340, height: 170)),
            ("empty-side", AnyView(SideEmptyState()), .emptySide, CGSize(width: 340, height: 280)),
            ("empty-project", AnyView(ProjectEmptyList()), .emptyProject, CGSize(width: 640, height: 200)),
        ]
        for dark in [true, false] {
            for (name, pane, place, size) in panes {
                try await render(VStack(spacing: 0) { pane; Spacer(minLength: 0) }, name: name, size: size, dark: dark,
                                 until: { !Self.arts(in: $0).isEmpty }) { view in
                    let arts = artFrames(in: view)
                    #expect(arts.count == 1 && arts.first?.0.scene == place.scene, "\(name)")
                    let elements = accessibilityElements(in: view)
                    #expect(!elements.contains { $0 is ArtLayerView }, "the art is not in VoiceOver's tree: \(name)")
                    #expect(arts.allSatisfy { !$0.0.isAccessibilityElement() && $0.0.hitTest(NSPoint(x: 4, y: 4)) == nil })
                }
            }
            try await render(ArtSurface(place: .sessionStarting).frame(height: LoomTheme.Agents.emptyArtHeight), name: "session-starting",
                             size: CGSize(width: 340, height: LoomTheme.Agents.emptyArtHeight), dark: dark)
        }
        #expect(ConversationDetail.showsStartingArt(busy: .starting) && ConversationDetail.showsStartingArt(busy: .resuming))
        #expect(!ConversationDetail.showsStartingArt(busy: nil) && !ConversationDetail.showsStartingArt(busy: .stopping))
    }

    @Test func aPaneWithNoArtAndTheSidebarDrawNone() async throws {
        let (window, hosting) = host(InspectorEmptyState(text: "The changes could not be read."), size: CGSize(width: 340, height: 160),
                                     dark: true)
        defer { window.close() }
        try await settle(window)
        #expect(Self.arts(in: hosting.view).isEmpty, "an empty state without its shark draws none")

        let rig = try await populated()
        let (side, sideHosting) = host(SidebarView(model: rig.model), size: CGSize(width: 300, height: 700), dark: true)
        defer { side.close() }
        try await settle(side)
        #expect(Self.arts(in: sideHosting.view).isEmpty, "never in the sidebar")
    }
}
