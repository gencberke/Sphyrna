import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// Which sidebar views evaluate their body when something changes. The real sidebar is hosted in a tall
/// window that is never ordered front (nothing appears on screen), 30 cards are laid out, and
/// `SidebarRenderProbe` counts the body evaluations of each card and of its time label.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SidebarRenderTests {
    typealias Clock = DailyUsePolishTests.ClockBox
    typealias Gate = DailyUsePolishTests.TickGate

    struct Hosted {
        let model: CatalogModel
        let hub: SessionEventHub
        let window: NSWindow
        let hosting: NSHostingController<SidebarView>
        let root: URL
        let clock: Clock
        let gate: Gate
        let ids: [UUID]
    }

    private func local(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour,
                                                   minute: minute, second: second))!
    }

    private func host(cards: Int, mode: CatalogViewMode = .activity) async throws -> Hosted {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-render-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let noon = local(10, 12, 0, 30)
        var ids: [UUID] = []
        for index in 0..<cards {
            let id = UUID()
            ids.append(id)
            // Spread over the last few hours of the same day so every card has its own "5m", "2h".
            let used = noon.addingTimeInterval(-Double(index) * 600)
            try await catalog.insertSession(
                ManagedSession(id: id, provider: .claude, workingDirectory: root.path), title: "Card \(index)",
                createdAt: used, lastUsedAt: used, lifecycle: .idle)
        }
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        try preferences.update { $0.viewMode = mode }
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub, preferences: preferences)
        model.branchReader = { _ in .unavailable }
        let clock = Clock(noon)
        let gate = Gate()
        model.currentDate = clock.read
        model.sleepUntil = { try await gate.sleep(until: $0) }
        await model.start()
        await model.stopAndWait()
        await model.settle()

        SidebarRenderProbe.watch(ids)
        let hosting = NSHostingController(rootView: SidebarView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 3_200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 320, height: 3_200))
        window.isReleasedWhenClosed = false // never ordered front: the layout runs against a window nobody sees
        let hosted = Hosted(model: model, hub: hub, window: window, hosting: hosting, root: root, clock: clock, gate: gate, ids: ids)
        try await settle(hosted, until: { SidebarRenderProbe.cardBodies.count == cards })
        return hosted
    }

    /// Lays the window out until the evaluation counts stop moving (and, when given, `expected` holds), so a
    /// busy machine (other suites run alongside) delays the answer instead of changing it.
    private func settle(_ hosted: Hosted, until expected: (() -> Bool)? = nil) async throws {
        var quiet = 0
        var last = SidebarRenderProbe.cardTotal + SidebarRenderProbe.timeLabelTotal
        var rounds = 0
        while rounds < 60 {
            rounds += 1
            try await Task.sleep(for: .milliseconds(120))
            hosted.window.contentView?.layoutSubtreeIfNeeded()
            hosted.window.displayIfNeeded()
            let now = SidebarRenderProbe.cardTotal + SidebarRenderProbe.timeLabelTotal
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= 3, expected?() ?? true { return }
        }
    }

    private func finish(_ hosted: Hosted) {
        SidebarRenderProbe.watch([])
        hosted.model.stop()
        hosted.window.close()
        try? FileManager.default.removeItem(at: hosted.root)
    }

    private func tooltipFormats(_ model: CatalogModel) -> Int {
        model.list(for: .activity).rows.reduce(0) { $0 + $1.tooltipFormats }
    }

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// Before: every card read the selected id, so a selection change evaluated all 30 cards.
    @Test func aSelectionChangeEvaluatesOnlyTheOldAndTheNewCard() async throws {
        let hosted = try await host(cards: 30)
        defer { finish(hosted) }
        let model = hosted.model
        #expect(SidebarRenderProbe.cardBodies.count == 30, "all 30 cards are laid out")

        let earlier = SidebarRenderProbe.cardBodies[hosted.ids[3]] ?? 0
        model.selectFromList(hosted.ids[3])
        try await settle(hosted, until: { (SidebarRenderProbe.cardBodies[hosted.ids[3]] ?? 0) > earlier })
        #expect(model.list(for: .activity).rows[3].isSelected)

        SidebarRenderProbe.reset()
        model.selectFromList(hosted.ids[7])
        try await settle(hosted, until: { SidebarRenderProbe.cardTotal >= 2 })
        let evaluated = Set(SidebarRenderProbe.cardBodies.keys)
        #expect(SidebarRenderProbe.cardTotal == 2, "card bodies evaluated by a selection change: \(SidebarRenderProbe.cardTotal)")
        #expect(evaluated == [hosted.ids[3], hosted.ids[7]])

        // The flag follows the selection: exactly the new card is selected, the old one is not.
        let rows = model.list(for: .activity).rows
        #expect(rows.filter(\.isSelected).map(\.id) == [hosted.ids[7]])
        model.select(nil)
        #expect(rows.allSatisfy { !$0.isSelected })
    }

    /// Before: the minute tick evaluated all 30 cards (and regrouped the days); now only the 30 time labels.
    @Test func theMinuteTickEvaluatesOnlyTheTimeLabelsAndDoesNotRegroupTheDays() async throws {
        let hosted = try await host(cards: 30)
        defer { finish(hosted) }
        let model = hosted.model
        model.setWindowVisible(true)
        #expect(await waitUntil { hosted.gate.requested.count == 1 })
        try await settle(hosted)

        SidebarRenderProbe.reset()
        let builds = SidebarRenderProbe.groupings
        let formats = tooltipFormats(model)
        hosted.clock.set(local(10, 12, 1))
        hosted.gate.release()
        #expect(await waitUntil { model.now == local(10, 12, 1) })
        try await settle(hosted, until: { SidebarRenderProbe.timeLabelTotal == 30 })
        #expect(SidebarRenderProbe.cardTotal == 0, "card bodies evaluated by a minute tick: \(SidebarRenderProbe.cardTotal)")
        #expect(SidebarRenderProbe.timeLabelTotal == 30, "time labels: \(SidebarRenderProbe.timeLabelTotal)")
        #expect(SidebarRenderProbe.groupings == builds, "day groupings by a minute tick: \(SidebarRenderProbe.groupings - builds)")
        #expect(tooltipFormats(model) == formats, "tooltips formatted by a minute tick")
    }

    @Test func theTimeLabelsAndTheirTooltipsFollowTheClockAndTheRecord() async throws {
        let hosted = try await host(cards: 5)
        defer { finish(hosted) }
        let model = hosted.model
        let row = try #require(model.list(for: .activity).rows.first)
        #expect(CardTimeLabel.text(for: row, deleting: false, now: model.now) == "now")
        #expect(CardTimeLabel.text(for: row, deleting: false, now: model.now.addingTimeInterval(5 * 60)) == "5m")
        #expect(CardTimeLabel.text(for: row, deleting: true, now: model.now) == "Deleting…")

        model.setWindowVisible(true)
        #expect(await waitUntil { hosted.gate.requested.count == 1 })
        SidebarRenderProbe.reset()
        hosted.clock.set(local(10, 12, 1))
        hosted.gate.release()
        #expect(await waitUntil { model.now == local(10, 12, 1) })
        try await settle(hosted, until: { SidebarRenderProbe.timeLabelBodies[row.id] != nil })
        #expect(SidebarRenderProbe.timeLabelBodies[row.id] == 1)

        // The tooltip is the formatted activity time, kept with the row until the time moves.
        let expected = "Last activity " + row.record.lastActivityAt.formatted(date: .abbreviated, time: .shortened)
        #expect(row.activityTooltip == expected)
        let formats = row.tooltipFormats
        #expect(row.activityTooltip == expected)
        #expect(row.tooltipFormats == formats, "asking again formats nothing")
        let stamp = local(10, 13, 15)
        try await model.catalog?.markActivity(sessionID: row.id, at: stamp)
        await model.refreshRow(row.id)
        #expect(row.record.lastActivityAt == stamp)
        #expect(row.activityTooltip == "Last activity " + stamp.formatted(date: .abbreviated, time: .shortened))
    }

    /// The day headings are grouped once per list change and calendar day, not on every body pass.
    @Test func theDaySectionsAreGroupedOncePerListChangeAndDay() async throws {
        let hosted = try await host(cards: 12)
        defer { finish(hosted) }
        let model = hosted.model
        let list = model.list(for: .activity)
        let builds = SidebarRenderProbe.groupings
        let first = list.daySections(today: model.today)
        let again = list.daySections(today: model.today)
        #expect(SidebarRenderProbe.groupings == builds, "no regrouping for the same list and day")
        #expect(first.map(\.id) == again.map(\.id))
        #expect(first.flatMap(\.rows).map(\.id) == list.rows.map(\.id))
        #expect(first.first?.title == "Today")

        // Midnight: same rows, a new day, new headings.
        model.setWindowVisible(true)
        #expect(await waitUntil { hosted.gate.requested.count == 1 })
        let before = SidebarRenderProbe.groupings
        hosted.clock.set(local(11, 0, 0))
        hosted.gate.release()
        #expect(await waitUntil { model.now == local(11, 0, 0) })
        try await settle(hosted, until: { SidebarRenderProbe.groupings > before })
        #expect(SidebarRenderProbe.groupings - before == 1, "one regrouping at midnight")
        #expect(list.daySections(today: model.today).first?.title == "Yesterday")

        // A row that moves day (new activity) is regrouped even though the list's rows stayed the same.
        let row = try #require(list.rows.first)
        let beforeStamp = SidebarRenderProbe.groupings
        try await model.catalog?.markActivity(sessionID: row.id, at: local(11, 0, 0, 30))
        await model.refreshRow(row.id)
        let moved = list.daySections(today: model.today)
        #expect(SidebarRenderProbe.groupings - beforeStamp == 1)
        #expect(moved.first?.title == "Today" && moved.first?.rows.map(\.id) == [row.id])
    }

    /// The Active section moves a card between two places in the list without touching the others: a flip
    /// evaluates the moved card at most once (it is a new view in its new place) and regroups the days once;
    /// a frame that flips nothing evaluates no other card and regroups nothing. Before: no such section.
    @Test func aMembershipFlipEvaluatesOnlyTheMovedCardAndRegroupsTheDaysOnce() async throws {
        let hosted = try await host(cards: 30)
        defer { finish(hosted) }
        let model = hosted.model
        let reader = FrameReader(await hosted.hub.subscribe())
        model.apply(try #require(await reader.next())) // the initial snapshot
        let target = hosted.ids[12]
        func feed(_ change: SessionEventChange) async throws {
            await hosted.hub.publish(sessionID: target, change: change)
            model.apply(try #require(await reader.next()))
        }
        func others() -> Int { SidebarRenderProbe.cardTotal - (SidebarRenderProbe.cardBodies[target] ?? 0) }

        try await feed(.runStarted(UUID()))
        await model.settle()
        try await settle(hosted)
        #expect(model.activeIDs.isEmpty)

        // Flip in: the turn starts.
        SidebarRenderProbe.reset()
        try await feed(.status(ProviderWorkState(activity: .working)))
        try await settle(hosted, until: { SidebarRenderProbe.groupings == 1 && SidebarRenderProbe.cardBodies[target] != nil })
        #expect(model.activityLayout().active.map(\.id) == [target])
        #expect(SidebarRenderProbe.groupings == 1, "one regrouping for the flip: \(SidebarRenderProbe.groupings)")
        #expect((SidebarRenderProbe.cardBodies[target] ?? 0) <= 1, "moved card bodies: \(SidebarRenderProbe.cardBodies[target] ?? 0)")
        #expect(others() == 0, "other cards evaluated by the flip: \(others())")

        // A frame that flips nothing (background work after the turn, then the finish unseen) regroups nothing.
        SidebarRenderProbe.reset()
        try await feed(.status(ProviderWorkState(activity: .turnComplete, pendingProviderWorkCount: 1)))
        try await feed(.status(ProviderWorkState(activity: .turnComplete)))
        try await settle(hosted)
        #expect(model.activityLayout().active.map(\.id) == [target])
        #expect(SidebarRenderProbe.groupings == 0, "regroupings by frames that flip nothing: \(SidebarRenderProbe.groupings)")
        #expect(others() == 0, "other cards evaluated by frames that flip nothing: \(others())")

        // Flip out: the user marks it read.
        SidebarRenderProbe.reset()
        model.markRead(target)
        await model.settle()
        model.apply(try #require(await reader.next()))
        try await settle(hosted, until: { SidebarRenderProbe.groupings == 1 && SidebarRenderProbe.cardBodies[target] != nil })
        #expect(model.activityLayout().active.isEmpty)
        #expect(SidebarRenderProbe.groupings == 1, "one regrouping for the flip back: \(SidebarRenderProbe.groupings)")
        #expect((SidebarRenderProbe.cardBodies[target] ?? 0) <= 1)
        #expect(others() == 0)
    }
}
