import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3b follow-ups: Home's two doors to Remora's memory, and the words of the memory's times (a note's "rewritten", Settings' Working
/// memory "updated"). Home is hosted in a window nobody sees (never ordered front). No Claude call, no real profile or vault.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RemoraFollowUpDoorTests {
    // MARK: The door

    /// A model whose Settings requests are recorded, and the Settings window's navigation the door reaches.
    private func door() -> (CatalogModel, SettingsNavigation, () -> [SettingsSection?]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-door-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let navigation = SettingsNavigation(section: .general)
        var shown: [SettingsSection?] = []
        model.onShowSettings = { section in
            shown.append(section)
            navigation.open(section) // what the app's window controller does first
        }
        return (model, navigation, { shown })
    }

    @Test func moreMenusMemoryRowOpensSettingsRemoraWithTheMemorySheetOverIt() {
        let (model, navigation, shown) = door()
        // Without a door, ⋯ has no Memory… row.
        let closed = HomeRemoraMoreMenu.items(openMemory: nil, catchMeUp: {}, settings: {})
        #expect(closed.map(\.id) == ["catch", "settings"])

        let items = HomeRemoraMoreMenu.items(openMemory: HomeRemoraMemoryDoor.action(model: model, navigation: { navigation }),
                                             catchMeUp: {}, settings: {})
        #expect(items.map(\.id) == ["catch", "memory", "settings"] && items[1].title == "Memory…")
        navigation.memoryTab = .notes
        items[1].action()
        #expect(shown() == [.remora], "the window shows on Remora's tab")
        #expect(navigation.section == .remora && navigation.openSheet == .remoraMemory && navigation.memoryTab == .journal)
    }

    @Test func theFootersMemoryLinkOpensTheSameSheet() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom"], seeds: [.init(title: "Billing webhook", project: 0, ago: 7_200)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
        defer { Task { await rig.finish() } }
        try rig.keepBrief(text: "You left off in loom.", chips: [(0, "Waits for review")], ago: 600)
        rig.model.showHome()
        let navigation = SettingsNavigation(section: .general)
        var shown: [SettingsSection?] = []
        rig.model.onShowSettings = { section in
            shown.append(section)
            navigation.open(section)
        }

        func hostHome(door: Bool) -> (NSWindow, NSView) {
            let view = HomeView(model: rig.model).remoraMemoryDoor(model: rig.model, navigation: { door ? navigation : nil })
            let content: AnyView = door ? AnyView(view) : AnyView(HomeView(model: rig.model))
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 760), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 940, height: 760))
            window.isReleasedWhenClosed = false
            return (window, hosting.view)
        }
        func element(_ id: String, in view: NSView) -> AnyObject? {
            accessibilityElements(in: view).first { $0.accessibilityIdentifier?() == id }
        }
        func settle(_ window: NSWindow, _ view: NSView) async throws {
            for _ in 0..<50 where element("home-remora-footer", in: view) == nil {
                try await Task.sleep(for: .milliseconds(100))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }

        // No door: the footer has Sources but no Memory….
        let (bare, bareView) = hostHome(door: false)
        try await settle(bare, bareView)
        #expect(element("home-remora-footer", in: bareView) != nil && element("home-remora-memory", in: bareView) == nil)
        bare.close()

        let (window, view) = hostHome(door: true)
        defer { window.close() }
        try await settle(window, view)
        let link = try #require(element("home-remora-memory", in: view), "the footer's Memory… is drawn with a door")
        #expect(link.accessibilityPerformPress?() == true)
        #expect(shown == [.remora])
        #expect(navigation.section == .remora && navigation.openSheet == .remoraMemory && navigation.memoryTab == .journal)
    }

    // MARK: The memory's times

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Wednesday 21 October 2026, 15:00.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))! }
    private func at(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func aNoteCardSaysWhenItsNoteWasRewritten() {
        let note = RemoraProjectNote(text: "- 2026-10-21 · Next: the fixtures.\n")
        #expect(RemoraNoteText.meta(note, rewrittenAt: at(day: 21, hour: 9, minute: 12), now: now, calendar: calendar)
            == "rewritten 09:12 · 0.0 of 2 KB", "today: the time, as the reference draws it")
        #expect(RemoraNoteText.meta(note, rewrittenAt: at(day: 20, hour: 9, minute: 5), now: now, calendar: calendar)
            == "rewritten yesterday 09:05 · 0.0 of 2 KB")
        #expect(RemoraNoteText.meta(note, rewrittenAt: at(day: 12, hour: 9, minute: 5), now: now, calendar: calendar)
            == "rewritten 12 October · 0.0 of 2 KB")
        #expect(RemoraNoteText.meta(note, rewrittenAt: nil, now: now, calendar: calendar) == "0.0 of 2 KB", "no time known: the size alone")
    }

    @Test func theWorkingMemoryLineSaysWhenItWasUpdated() {
        #expect(RemoraSettingsLine.workingMemory(days: 14, notes: 4, updated: at(day: 21, hour: 9, minute: 12), now: now, calendar: calendar)
            == "14 days · 4 project notes · updated today 09:12", "the reference's line")
        #expect(RemoraSettingsLine.workingMemory(days: 1, notes: 1, updated: at(day: 20, hour: 23, minute: 40), now: now, calendar: calendar)
            == "1 day · 1 project note · updated yesterday 23:40")
        #expect(RemoraSettingsLine.workingMemory(days: 3, notes: 0, updated: at(day: 2, hour: 8, minute: 0), now: now, calendar: calendar)
            == "3 days · 0 project notes · updated 2 October")
        #expect(RemoraSettingsLine.workingMemory(days: 0, notes: 0, updated: nil) == "Nothing kept yet", "nil is an empty memory")
    }

    @Test func overAHostTheCardsAndTheLineReadTheirTimesFromTheMemory() async throws {
        let rig = try RemoraMemoryRig()
        defer { rig.finish() }
        let before = await rig.model.remoraWorkingMemoryUpdatedAt()
        #expect(before == nil, "an empty memory has no time")
        let started = Date().addingTimeInterval(-2)
        try await rig.seed(journal: [RemoraJournalEntry(date: Date(), kind: .question, question: "q", answer: "a")])
        let memory = RemoraMemoryModel(catalog: rig.model)
        await memory.load()
        let card = try #require(memory.cards.first)
        let rewritten = try #require(card.rewrittenAt, "the card carries the host's rewrittenAt")
        #expect(rewritten >= started)
        #expect(memory.meta(of: card).hasPrefix("rewritten ") && memory.meta(of: card).hasSuffix(" · " + card.size))
        let updated = try #require(await rig.model.remoraWorkingMemoryUpdatedAt())
        #expect(RemoraSettingsLine.workingMemory(days: 1, notes: 1, updated: updated).hasPrefix("1 day · 1 project note · updated today "))
    }
}
