import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// I4b: every Settings section and both sheets drawn offscreen at the window's size, hosted in a window nobody sees. With
/// `LOOM_SETTINGS_RENDER_DIR` set the pictures are written there as `settings-<section>-<ink|paper>-<tone>.png` (Ink and Paper, and
/// the tones in `LOOM_SETTINGS_RENDER_TONES`, `neutral` by default) to be set beside the reference; without it each section is drawn once
/// in Ink and the test only checks that something was drawn.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct InkSettingsRenderTests {
    private let size = NSSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height)
    private static let now = Date(timeIntervalSince1970: 1_791_374_400)

    private var directory: URL? {
        ProcessInfo.processInfo.environment["LOOM_SETTINGS_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private var looks: [(dark: Bool, tone: PaneTone)] {
        guard directory != nil else { return [(true, .neutral)] }
        let named = (ProcessInfo.processInfo.environment["LOOM_SETTINGS_RENDER_TONES"] ?? "neutral").split(separator: ",")
        let tones = named.compactMap { name in PaneTone.allCases.first { $0.rawValue == String(name) } }
        return [true, false].flatMap { dark in (tones.isEmpty ? [PaneTone.neutral] : tones).map { (dark, $0) } }
    }

    private func makeModel() throws -> CatalogModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-render-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CatalogModel(catalog: nil, events: SessionEventHub(),
                            preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
    }

    /// Draws a view in a window nobody sees and returns what it drew; writes the picture when a folder is set.
    private func render<V: View>(_ view: V, name: String, dark: Bool, tone: PaneTone,
                                     after: (() -> Void)? = nil) async throws -> NSBitmapImageRep {
        let previous = LoomTheme.ThemeState.shared.tone
        LoomTheme.ThemeState.shared.tone = tone
        defer { LoomTheme.ThemeState.shared.tone = previous }
        let hosting = NSHostingController(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        if let after {
            after()
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(100))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        let bounds = hosting.view.bounds
        let rep = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.view.cacheDisplay(in: bounds, to: rep)
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = "settings-\(name)-\(dark ? "ink" : "paper")-\(tone.rawValue).png"
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(file))
        }
        return rep
    }

    /// Something was drawn: the picture is the window's size and has more than a few distinct colours.
    private func expectDrawn(_ rep: NSBitmapImageRep, _ name: String) {
        #expect(rep.pixelsWide >= Int(size.width) && rep.pixelsHigh >= Int(size.height), "\(name) is the window's size")
        var seen = Set<UInt32>()
        let step = max(1, rep.pixelsWide / 80)
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255))
            }
        }
        #expect(seen.count > 6, "\(name) drew \(seen.count) colours")
    }

    private func settingsView(_ model: CatalogModel, _ section: SettingsSection, sheet: SettingsSheet? = nil,
                              usage: UsageModel? = nil) -> SettingsView {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let navigation = SettingsNavigation(section: section)
        if let sheet { navigation.setSheet(sheet) }
        return SettingsView(
            model: model, usage: usage, navigation: navigation,
            about: SettingsAbout(version: "Version 1.6.0 (build 214, 371aaf6)",
                                 dataFolder: home.appendingPathComponent("Library/Application Support/Loom"),
                                 claudeProfile: home.appendingPathComponent(".claude")))
    }

    @Test func generalThemeAndAboutDrawInEveryLook() async throws {
        for look in looks {
            let model = try makeModel()
            for section in [SettingsSection.general, .theme, .about] {
                let name = section.title.lowercased()
                expectDrawn(try await render(settingsView(model, section), name: name, dark: look.dark, tone: look.tone), name)
            }
        }
    }

    // MARK: Usage

    private static func usagePage(report: UsageReport) -> some View {
        // The Usage section's page without its model: the band, the cards at the page width and the footer.
        VStack(spacing: 0) {
            SettingsBand(sections: SettingsSection.available(cleanupReview: true), selection: .usage, onSelect: { _ in })
            SettingsPage {
                UsageReportView(report: report, limits: limits, limitsFailure: nil, linesNotUnderstood: 0,
                                timeZone: TimeZone(identifier: "UTC")!, now: now)
            }
            SettingsFooter { Text("Updated 17:20 · Prices as of Oct 7, 2026") } trailing: {
                SettingsRefreshButton(label: "Update usage now") {}
            }
        }
        .background(LoomTheme.Surface.canvas)
    }

    private static var limits: PlanLimits {
        PlanLimits(fiveHour: PlanLimitWindow(usedPercent: 38, resetsAt: now.addingTimeInterval(9_000)),
                   weekly: PlanLimitWindow(usedPercent: 26, resetsAt: now.addingTimeInterval(4 * 86_400)), fetchedAt: now)
    }

    private static var report: UsageReport {
        let tokens = UsageTokens(input: 400_000, output: 300_000, cacheWrite5m: 500_000, cacheRead: 1_900_000)
        let models = [
            UsageModelTotal(model: "opus", displayName: "Opus 5.5", tokens: UsageTokens(output: 2_000_000),
                            estimatedCostUSD: 25.1, messageCount: 4),
            UsageModelTotal(model: "sonnet", displayName: "Sonnet 5.5", tokens: UsageTokens(output: 900_000),
                            estimatedCostUSD: 5.2, messageCount: 4),
            UsageModelTotal(model: "haiku", displayName: "Haiku 5.5", tokens: UsageTokens(output: 200_000),
                            estimatedCostUSD: 0.9, messageCount: 4),
        ]
        let snapshot = UsageSnapshot(provider: .claude, asOf: now, priceTableAsOf: "2026-10-07", range: UsagePeriod.days7.range,
                                     tokens: tokens, estimatedCostUSD: 31.2, unknownModels: [], messageCount: 70, sessionCount: 7,
                                     days: [], models: models, activityWindow: nil)
        var bars: [UsageBar] = []
        for index in 0..<7 {
            bars.append(UsageBar(start: now.addingTimeInterval(Double(index - 6) * 86_400),
                                 tokens: Int64([320, 180, 540, 812, 260, 90, 400][index]) * 1_000, isCurrent: index == 6))
        }
        let hours: [Int64] = [40_000, 100_000, 60_000, 210_000, 290_000]
        let cells = hours.enumerated().map { UsageBar(start: now.addingTimeInterval(Double($0.offset - 4) * 3_600), tokens: $0.element, isCurrent: $0.offset == 4) }
        return UsageReport(period: .days7, snapshot: snapshot, bars: bars, cells: cells)
    }

    @Test func usageDrawsItsFourCardsAndFooterInEveryLook() async throws {
        for look in looks {
            let rep = try await render(Self.usagePage(report: Self.report), name: "usage", dark: look.dark, tone: look.tone)
            expectDrawn(rep, "usage")
        }
    }

    // MARK: Sessions

    @Test func sessionsDrawsItsDueLineRowsAndCleanupInEveryLook() async throws {
        let day: TimeInterval = 86_400
        func session(_ title: String, stale: Double, pinned: Bool = false) -> CatalogSession {
            CatalogSession(session: ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: title,
                           createdAt: Self.now.addingTimeInterval(-90 * day), lastUsedAt: Self.now.addingTimeInterval(-60 * day),
                           lifecycle: .stale, pinned: pinned, staleSince: Self.now.addingTimeInterval(-stale * day))
        }
        let eligible = [session("Try the old sidebar spacing", stale: 45), session("Rename the usage chip", stale: 30),
                        session("zsh prompt with the branch", stale: 25)]
        let snapshot = CleanupReview(
            generatedAt: Self.now, due: .due, mode: .reviewRequired(.automaticDisabled),
            eligible: eligible.enumerated().map { CleanupEligibleRow(record: $1, eligibleSince: Self.now.addingTimeInterval(-10 * day),
                                                                     byteCount: Int64(14_000_000 / ($0 + 1)), fileCount: 162 / ($0 + 1)) },
            excluded: [CleanupExcludedRow(record: session("Release C health check", stale: 45, pinned: true), reason: .pinned)])
        for look in looks {
            let model = try makeModel()
            model.installCleanupReview(CleanupReviewTests.FakeBackend(snapshot: snapshot))
            let review = try #require(model.cleanupReview)
            await review.open()
            // The page opens a review of its own when it appears, which clears the checks: check the rows after it.
            let rep = try await render(settingsView(model, .conversations), name: "sessions", dark: look.dark, tone: look.tone,
                                       after: { review.selectAll() })
            expectDrawn(rep, "sessions")
            // The Delete sheet over it, for the checked sessions.
            let sheet = try await render(settingsView(model, .conversations, sheet: .delete), name: "sheet-delete",
                                         dark: look.dark, tone: look.tone, after: { review.selectAll() })
            expectDrawn(sheet, "sheet-delete")
        }
    }

    @Test func theFullAccessSheetDrawsOverGeneralInEveryLook() async throws {
        for look in looks {
            let model = try makeModel()
            let rep = try await render(settingsView(model, .general, sheet: .fullAccess), name: "sheet-full-access",
                                       dark: look.dark, tone: look.tone)
            expectDrawn(rep, "sheet-full-access")
        }
    }
}
