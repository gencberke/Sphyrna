import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// L3b: Settings → Remora (on and off) and Remora's memory sheet (its three tabs and the Clear question) drawn offscreen at the window's
/// size, in a window nobody sees. With `LOOM_SETTINGS_RENDER_DIR` set the pictures are written there as
/// `remora-<what>-<ink|paper>-<tone>.png` (Ink and Paper, and the tones in `LOOM_SETTINGS_RENDER_TONES`, `neutral` by default) to be
/// set beside the reference; without it each is drawn once in Ink and the test only checks that something was drawn. The data is a
/// temporary memory with sample lines and notes: no Claude, no profile, no vault.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(8)))
struct RemoraSettingsRenderTests {
    private let size = NSSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height)

    private var directory: URL? {
        ProcessInfo.processInfo.environment["LOOM_SETTINGS_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private var looks: [(dark: Bool, tone: PaneTone)] {
        guard directory != nil else { return [(true, .neutral)] }
        let named = (ProcessInfo.processInfo.environment["LOOM_SETTINGS_RENDER_TONES"] ?? "neutral").split(separator: ",")
        let tones = named.compactMap { name in PaneTone.allCases.first { $0.rawValue == String(name) } }
        return [true, false].flatMap { dark in (tones.isEmpty ? [PaneTone.neutral] : tones).map { (dark, $0) } }
    }

    private func rig() async throws -> RemoraMemoryRig {
        let rig = try await RemoraMemoryRig.withProjects(["loom", "second-brain", "backend-api", "website"])
        let now = Date()
        let lines: [(String?, String)] = [
            ("Which session touched the auth middleware?", "I named Migrate auth to JWT and Rate limiter tests."),
            (nil, "The Ink sidebar at step 5 of 6, Thesis outline finished and not read, backend-api failing on three token tests."),
            ("What is half done in loom?", "I named Port the sidebar to Ink tokens, stopped at step 4."),
        ]
        let journal = lines.enumerated().map { index, line in
            RemoraJournalEntry(date: now.addingTimeInterval(-Double(index) * 3_600), kind: line.0 == nil ? .brief : .question,
                               question: line.0, answer: line.1, summary: line.0 == nil ? line.1 : nil)
        }
        try await rig.seed(journal: journal, notes: [
            "The Ink sidebar port is at step 5 of 6 on ui/ink-sidebar: rows, heads and search use Ink's tokens.\nNext: the footer tokens, then the contrast tests.",
            "Thesis outline finished with five chapters. Next: the reading list for chapter three.",
            "Migrate auth to JWT stopped with three token tests failing in test_tokens.py.",
        ])
        rig.model.setRemoraNoteFile(rig.root.appendingPathComponent("vault/Remora.md"))
        return rig
    }

    private func settingsView(_ model: CatalogModel, sheet: SettingsSheet? = nil, tab: RemoraMemoryTab = .journal) -> SettingsView {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let navigation = SettingsNavigation(section: .remora)
        if sheet == .remoraMemory { navigation.openRemoraMemory(tab: tab) } else if let sheet { navigation.setSheet(sheet) }
        return SettingsView(model: model, usage: nil, navigation: navigation,
                            about: SettingsAbout(version: "Version 1.6.0", dataFolder: home.appendingPathComponent("Library/Application Support/Loom"),
                                                 claudeProfile: nil))
    }

    private func render<V: View>(_ view: V, name: String, dark: Bool, tone: PaneTone, height: CGFloat? = nil) async throws -> NSBitmapImageRep {
        let size = NSSize(width: size.width, height: height ?? size.height)
        let previous = LoomTheme.ThemeState.shared.tone
        LoomTheme.ThemeState.shared.tone = tone
        defer { LoomTheme.ThemeState.shared.tone = previous }
        let hosting = NSHostingController(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let bounds = hosting.view.bounds
        let rep = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.view.cacheDisplay(in: bounds, to: rep)
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = "remora-\(name)-\(dark ? "ink" : "paper")-\(tone.rawValue).png"
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(file))
        }
        return rep
    }

    private func expectDrawn(_ rep: NSBitmapImageRep, _ name: String) {
        #expect(rep.pixelsWide >= Int(size.width) && rep.pixelsHigh >= Int(size.height), "\(name) is at least the window's size")
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

    @Test func theTabDrawsOnAndOffInEveryLook() async throws {
        let rig = try await rig()
        defer { rig.finish() }
        for look in looks {
            for on in [true, false] {
                rig.model.setRemoraOn(on)
                let name = on ? "settings-on" : "settings-off"
                expectDrawn(try await render(settingsView(rig.model), name: name, dark: look.dark, tone: look.tone), name)
            }
        }
        rig.model.setRemoraOn(true)
    }

    /// The whole tab at once (the window shows it scrolled): taller than the window, for the picture beside the reference.
    @Test func theWholeTabDrawsAtFullHeightOnAndOff() async throws {
        let rig = try await rig()
        defer { rig.finish() }
        for look in looks {
            for on in [true, false] {
                rig.model.setRemoraOn(on)
                let page = VStack(spacing: 0) {
                    SettingsBand(sections: SettingsSection.available(cleanupReview: false), selection: .remora, onSelect: { _ in })
                    RemoraSettingsView(model: rig.model, navigation: SettingsNavigation(section: .remora))
                }
                .background(LoomTheme.Surface.canvas)
                let rep = try await render(page, name: on ? "tab-full-on" : "tab-full-off", dark: look.dark, tone: look.tone, height: 1000)
                #expect(rep.pixelsHigh >= 1000)
            }
        }
        rig.model.setRemoraOn(true)
    }

    @Test func theMemorySheetDrawsItsThreeTabsAndTheClearQuestionInEveryLook() async throws {
        let rig = try await rig()
        defer { rig.finish() }
        for look in looks {
            for tab in RemoraMemoryTab.allCases {
                let name = "memory-\(tab.evidenceName)"
                expectDrawn(try await render(settingsView(rig.model, sheet: .remoraMemory, tab: tab), name: name, dark: look.dark, tone: look.tone), name)
            }
            expectDrawn(try await render(settingsView(rig.model, sheet: .remoraClear(returnsToMemory: false)), name: "clear",
                                         dark: look.dark, tone: look.tone), "clear")
        }
    }

    /// L3b follow-ups: the Journal tab with its folded weeks (the lines of 20 and 27 days ago, one line a week after the days).
    @Test func theJournalTabDrawsItsDaysThenItsWeeksInEveryLook() async throws {
        let rig = try await rig()
        defer { rig.finish() }
        let now = Date()
        try await rig.seed(journal: [
            RemoraJournalEntry(date: now.addingTimeInterval(-20 * 86_400), kind: .brief, answer: "The importer moved to async.",
                               summary: "The importer moved to async; three sessions finished"),
            RemoraJournalEntry(date: now.addingTimeInterval(-27 * 86_400), kind: .question, question: "What is half done?", answer: "Two."),
        ], notes: [])
        let memory = RemoraMemoryModel(catalog: rig.model)
        await memory.load()
        #expect(memory.groups.filter { $0.label.hasPrefix("Week of ") }.count == 2, "\(memory.groups.map(\.label))")
        for look in looks {
            let name = "memory-journal-weeks"
            expectDrawn(try await render(settingsView(rig.model, sheet: .remoraMemory, tab: .journal), name: name, dark: look.dark,
                                         tone: look.tone), name)
        }
    }
}
