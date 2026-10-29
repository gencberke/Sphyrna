import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// DESIGN §6 Sheets and §3's scrim, in a window built as the Settings window is (`SettingsWindowController.makeWindow`: titled, full
/// size content, a transparent title bar over an empty unified toolbar), hosted off screen and never ordered front. The title strip
/// gives the window a top safe area that the borderless hosts of `InkSettingsHostedTests` do not have: the scrim must cover it too,
/// and the sheet must come down 52 pt from the window's top, not from the strip's foot. With `LOOM_SETTINGS_RENDER_DIR` set, each
/// sheet over its scrim is written there as `settings-window-sheet-<name>-<ink|paper>.png`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct SettingsSheetWindowTests {
    private let size = NSSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height)
    private static let now = Date(timeIntervalSince1970: 1_791_374_400)

    private var directory: URL? {
        ProcessInfo.processInfo.environment["LOOM_SETTINGS_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private func makeModel() throws -> CatalogModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-sheet-window-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CatalogModel(catalog: nil, events: SessionEventHub(),
                            preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
    }

    /// A model whose cleanup review lists three sessions, for the Delete sheet.
    private func modelWithReview() async throws -> (CatalogModel, CleanupReviewModel) {
        let day: TimeInterval = 86_400
        let rows = ["Try the old sidebar spacing", "Rename the usage chip", "zsh prompt with the branch"].map { title in
            CatalogSession(session: ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: title,
                           createdAt: Self.now.addingTimeInterval(-90 * day), lastUsedAt: Self.now.addingTimeInterval(-60 * day),
                           lifecycle: .stale, pinned: false, staleSince: Self.now.addingTimeInterval(-40 * day))
        }
        let snapshot = CleanupReview(
            generatedAt: Self.now, due: .due, mode: .reviewRequired(.automaticDisabled),
            eligible: rows.map { CleanupEligibleRow(record: $0, eligibleSince: Self.now.addingTimeInterval(-10 * day),
                                                    byteCount: 4_000_000, fileCount: 40) },
            excluded: [])
        let model = try makeModel()
        model.installCleanupReview(CleanupReviewTests.FakeBackend(snapshot: snapshot))
        let review = try #require(model.cleanupReview)
        await review.open()
        return (model, review)
    }

    private func settingsView(_ model: CatalogModel, _ navigation: SettingsNavigation) -> SettingsView {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SettingsView(model: model, usage: nil, navigation: navigation,
                            about: SettingsAbout(version: "Version 1.6.0", dataFolder: home.appendingPathComponent("Library/Application Support/Loom"),
                                                 claudeProfile: home.appendingPathComponent(".claude")))
    }

    /// The Settings window's shape, with the view as its content.
    private func host<V: View>(_ view: V, dark: Bool) -> (NSWindow, NSHostingController<some View>) {
        enableAccessibilityTree()
        let hosting = NSHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: NSToolbar.Identifier("loom-settings-test"))
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(size)
        return (window, hosting)
    }

    private func settle(_ window: NSWindow, rounds: Int = 8) async throws {
        for _ in 0..<rounds {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The brightness at a point given in the view's points from its top left.
    private func luma(_ rep: NSBitmapImageRep, x: CGFloat, top: CGFloat, in view: NSView) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let color = rep.colorAt(x: Int(x * scale), y: Int(top * scale))?.usingColorSpace(.sRGB) ?? .clear
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    private func sheetElement(_ identifier: String, in controller: NSViewController) async throws -> AnyObject? {
        for _ in 0..<30 {
            if let found = accessibilityElements(in: controller.view).first(where: { InkAX.identifier($0) == identifier }) { return found }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Opens `sheet` over `section` and checks the scrim and the sheet's top against the window; writes the render when asked.
    private func checkSheet(_ sheet: SettingsSheet, over section: SettingsSection, name: String, dark: Bool,
                            model: CatalogModel, review: CleanupReviewModel? = nil) async throws {
        let navigation = SettingsNavigation(section: section)
        let (window, hosting) = host(settingsView(model, navigation), dark: dark)
        defer { window.close() }
        try await settle(window)
        review?.selectAll()
        try await settle(window, rounds: 3)
        let view = hosting.view
        #expect(abs(view.bounds.width - window.frame.width) <= 0.5 && abs(view.bounds.height - window.frame.height) <= 0.5,
                "the content fills the window, title strip included: \(view.bounds.size) in \(window.frame.size)")
        #expect(view.safeAreaInsets.top > 0 || window.contentLayoutRect.height < window.frame.height,
                "the window has a title strip above its layout rect (\(window.contentLayoutRect))")
        let before = try snapshot(view)

        navigation.setSheet(sheet)
        try await settle(window)
        let after = try snapshot(view)

        // The scrim: every point outside the sheet is darker than it was, from the window's first row to its last (by 40 % of the
        // black in Ink, by the ink at 22 % in Paper; an eighth of the brightness, or 0.01, is the least that counts).
        let width = view.bounds.width, height = view.bounds.height
        let points: [(String, CGFloat, CGFloat)] = [
            ("the title strip, left", 6, 3), ("the title strip, right", width - 6, 3), ("the strip's middle", width - 6, 20),
            ("under the band", 24, 70), ("the page's middle", 24, height / 2), ("the bottom, left", 6, height - 3),
            ("the bottom, right", width - 6, height - 3),
        ]
        for (place, x, top) in points {
            let was = luma(before, x: x, top: top, in: view), now = luma(after, x: x, top: top, in: view)
            #expect(was - now >= max(0.01, was / 8), "\(name), \(dark ? "Ink" : "Paper"): the scrim covers \(place) (\(x), \(top)): \(was) → \(now)")
        }

        // The sheet comes down 52 pt from the window's top.
        let element = try #require(try await sheetElement("settings-sheet-\(name)", in: hosting), "\(name): the sheet is in the accessibility tree")
        let frame = InkAX.frame(element)
        let top = window.frame.maxY - frame.maxY
        #expect(abs(top - LoomTheme.Settings.bandHeight) <= 1,
                "\(name), \(dark ? "Ink" : "Paper"): the sheet's top is \(top) under the window's top")
        #expect(abs(frame.midX - window.frame.midX) <= 1, "\(name): centred")

        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = "settings-window-sheet-\(name)-\(dark ? "ink" : "paper").png"
            try #require(after.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(file))
        }
    }

    @Test(arguments: [true, false]) func theFullAccessSheetsScrimCoversTheWindowAndTheSheetSits52Down(dark: Bool) async throws {
        try await checkSheet(.fullAccess, over: .general, name: "full-access", dark: dark, model: try makeModel())
    }

    @Test(arguments: [true, false]) func theDeleteSheetsScrimCoversTheWindowAndTheSheetSits52Down(dark: Bool) async throws {
        let (model, review) = try await modelWithReview()
        try await checkSheet(.delete, over: .conversations, name: "delete", dark: dark, model: model, review: review)
    }
}
