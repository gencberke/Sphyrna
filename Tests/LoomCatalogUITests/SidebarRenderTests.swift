import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// Which sidebar views evaluate their body when something changes. The real sidebar is hosted in a tall
/// window that is never ordered front (nothing appears on screen), 30 cards are laid out, and
/// `SidebarRenderProbe` counts the body evaluations of each card and of its time label.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .renderProbe)
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

        #expect(RenderProbeExclusive.isHeld, "a test that watches the probe holds the probe lock (.renderProbe)")
        SidebarRenderProbe.watch(ids, model: model)
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

    @Test func changingOneCachedModelDoesNotRebuildCardBodies() async throws {
        let hosted = try await host(cards: 30)
        defer { finish(hosted) }
        SidebarRenderProbe.reset()
        hosted.model.cardModels.publish(stored: [hosted.ids[3]: "claude-opus-5-5"], reported: [:])
        try await settle(hosted)
        #expect(SidebarRenderProbe.cardTotal == 0,
                "the model and accessibility leaves update without rebuilding the card bodies")
    }

    @Test func managedProgressRevisionsDoNotRebuildSidebarCards() async throws {
        let hosted = try await host(cards: 30)
        defer { finish(hosted) }
        let target = hosted.ids[3], task = UUID()
        await hosted.hub.publish(sessionID: target, change: .managedTaskChanged(task))
        hosted.model.apply(await hosted.hub.snapshot())
        try await settle(hosted)
        let meaningfulRevision = hosted.model.liveRevision
        SidebarRenderProbe.reset()
        for _ in 0..<20 {
            await hosted.hub.publish(sessionID: target, change: .managedTaskChanged(task))
            hosted.model.apply(await hosted.hub.snapshot())
        }
        try await settle(hosted)
        #expect(SidebarRenderProbe.cardTotal == 0,
                "streamed task progress belongs to the selected managed pane, not the sidebar card bodies")
        #expect(hosted.model.liveStates[target]?.managedTaskRevision == 21)
        #expect(hosted.model.rowModels[target]?.managedTaskRevision == 21)
        #expect(hosted.model.liveRevision == meaningfulRevision, "task progress does not invalidate every project's status")
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

    /// V25: a hover lives in the row's own pill. Before it was a state of the card (or of the list), so a pointer crossing the
    /// sidebar redrew cards. The evidence run's `hover:` command holds a pill's hover through the same leaf state the pointer
    /// sets, so the counts here are the pointer's.
    @Test func aHoverEvaluatesOnlyThePillsOfItsRowsAndNoCardOrList() async throws {
        LookEvidence.arm()
        let hosted = try await host(cards: 30)
        defer { LookEvidence.setHover(nil); finish(hosted) }
        let first = "sidebar-card:\(hosted.ids[5])"
        let second = "sidebar-card:\(hosted.ids[11])"
        // Other views alive in the same test process draw pills of their own; only this sidebar's keys count.
        let mine = Set(hosted.ids.map { "sidebar-card:\($0)" })
        func evaluated() -> Set<String> { Set(SidebarRenderProbe.pillBodies.keys).intersection(mine) }
        #expect(SidebarRenderProbe.pillBodies[first] != nil, "the card's pill is drawn")

        SidebarRenderProbe.reset()
        LookEvidence.setHover(first)
        try await settle(hosted, until: { (SidebarRenderProbe.pillBodies[first] ?? 0) > 0 })
        #expect(evaluated() == [first], "pills evaluated by a hover: \(evaluated())")
        #expect(SidebarRenderProbe.cardTotal == 0, "card bodies evaluated by a hover: \(SidebarRenderProbe.cardTotal)")
        #expect(SidebarRenderProbe.timeLabelTotal == 0 && SidebarRenderProbe.projectListBodies == 0)

        // The pointer moving on to another card: the two pills, still no card.
        SidebarRenderProbe.reset()
        LookEvidence.setHover(second)
        try await settle(hosted, until: { evaluated().count == 2 })
        #expect(evaluated() == [first, second])
        #expect(SidebarRenderProbe.cardTotal == 0, "card bodies evaluated by a hover moving on: \(SidebarRenderProbe.cardTotal)")
    }

    /// Before: the project list read the drafts in its own body, so every keystroke in a draft redrew the list.
    @Test func typingInADraftEvaluatesTheDraftsRowAndNeitherTheProjectListNorACard() async throws {
        let hosted = try await host(cards: 8, mode: .projects)
        defer { finish(hosted) }
        let model = hosted.model
        model.setDraftText("Fix the log", projectID: nil)
        try await settle(hosted, until: { SidebarRenderProbe.draftRowBodies.isEmpty == false })
        #expect(!SidebarRenderProbe.draftRowBodies.isEmpty, "the draft has its row")

        SidebarRenderProbe.reset()
        model.setDraftText("Fix the login", projectID: nil)
        try await settle(hosted, until: { !SidebarRenderProbe.draftRowBodies.isEmpty })
        #expect(SidebarRenderProbe.draftRowBodies.values.reduce(0, +) >= 1, "the draft's row follows the text")
        #expect(SidebarRenderProbe.projectListBodies == 0, "project list bodies evaluated by typing: \(SidebarRenderProbe.projectListBodies)")
        #expect(SidebarRenderProbe.cardTotal == 0, "card bodies evaluated by typing: \(SidebarRenderProbe.cardTotal)")
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
        let expected = "Last activity " + LoomDateFormat.dateTime(row.record.lastActivityAt)
        #expect(row.activityTooltip == expected)
        let formats = row.tooltipFormats
        #expect(row.activityTooltip == expected)
        #expect(row.tooltipFormats == formats, "asking again formats nothing")
        let stamp = local(10, 13, 15)
        try await model.catalog?.markActivity(sessionID: row.id, at: stamp)
        await model.refreshRow(row.id)
        #expect(row.record.lastActivityAt == stamp)
        #expect(row.activityTooltip == "Last activity " + LoomDateFormat.dateTime(stamp))
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

    // MARK: Sidebar v2 (V04)

    private func label(_ hosted: Hosted, hasPrefix prefix: String) -> (label: String, element: AnyObject)? {
        for element in accessibilityElements(in: hosted.hosting.view) {
            if let label = element.accessibilityLabel?(), label.hasPrefix(prefix) { return (label, element) }
        }
        return nil
    }

    /// The reason line shows only on an Active card and changes only at hook boundaries: a reason that arrives
    /// evaluates its own card and no other, the card says it to VoiceOver, and the minute tick still evaluates
    /// no card at all. The Home row counts the session and opens Home.
    @Test func aReasonChangeEvaluatesOnlyItsOwnCardAndTheTickLeavesItAlone() async throws {
        enableAccessibilityTree()
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
        try await feed(.status(ProviderWorkState(activity: .working)))
        await model.settle()
        try await settle(hosted, until: { model.activityLayout().active.map(\.id) == [target] })
        #expect(model.activityLayout().active.map(\.id) == [target])
        try await settle(hosted)

        // The reason arrives before the status it explains: its card is evaluated, nobody else's.
        SidebarRenderProbe.reset()
        let reason = StatusReason(.approval(tool: "Bash"), detail: "git push origin fix/webhook-sig")
        try await feed(.reason(reason))
        try await settle(hosted, until: { SidebarRenderProbe.cardBodies[target] != nil })
        #expect(model.list(for: .activity).rows.first { $0.id == target }?.reason == reason)
        #expect(others() == 0, "other cards evaluated by a reason: \(others())")

        SidebarRenderProbe.reset()
        try await feed(.status(ProviderWorkState(activity: .waitingForApproval)))
        try await settle(hosted, until: { SidebarRenderProbe.cardBodies[target] != nil })
        #expect(others() == 0, "other cards evaluated by the status it explains: \(others())")

        // The Active card names the reason after its state; a card in a day section does not.
        let active = try #require(label(hosted, hasPrefix: "Card 12, "))
        #expect(active.label == "Card 12, Claude, No project, Needs you, Needs approval, Asks to run: git push origin fix/webhook-sig")
        let day = try #require(label(hosted, hasPrefix: "Card 11, "))
        #expect(day.label == "Card 11, Claude, No project, Idle")

        // The activity reason takes the branch's place on the bottom line; one-line cards keep the same height.
        let activeHeight = try #require(active.element.accessibilityFrame?()).height
        let dayHeight = try #require(day.element.accessibilityFrame?()).height
        #expect(abs(activeHeight - dayHeight) < 1.5, "Active card \(activeHeight) pt, day card \(dayHeight) pt")

        // The Home row counts it and opens Home.
        let home = try #require(label(hosted, hasPrefix: "Home"))
        #expect(home.label == "Home, 1 session needs you")
        #expect(model.destination != .home)
        #expect(home.element.accessibilityPerformPress?() == true)
        #expect(model.destination == .home)

        // The minute tick redraws the 29 activity-age labels, never a card. The waiting card shows its status instead.
        model.setWindowVisible(true)
        #expect(await waitUntil { hosted.gate.requested.count == 1 })
        try await settle(hosted)
        SidebarRenderProbe.reset()
        hosted.clock.set(local(10, 12, 1))
        hosted.gate.release()
        #expect(await waitUntil { model.now == local(10, 12, 1) })
        try await settle(hosted, until: { SidebarRenderProbe.timeLabelTotal == 29 })
        #expect(SidebarRenderProbe.cardTotal == 0, "card bodies evaluated by a minute tick: \(SidebarRenderProbe.cardTotal)")
        #expect(SidebarRenderProbe.timeLabelTotal == 29)
    }

    /// RESCUE C3: both views draw the three-layer card (top line, title, bottom row), the same height.
    @Test func bothViewsDrawTheThreeLayerCard() async throws {
        enableAccessibilityTree()
        func rowHeight(mode: CatalogViewMode) async throws -> CGFloat {
            let hosted = try await host(cards: 5, mode: mode)
            defer { finish(hosted) }
            try await settle(hosted)
            let row = try #require(label(hosted, hasPrefix: "Card 1, "))
            return try #require(row.element.accessibilityFrame?()).height
        }
        let projects = try await rowHeight(mode: .projects)
        let card = try await rowHeight(mode: .activity)
        #expect(card > LoomTheme.Rhythm.sessionCardRow, "three-layer card height \(card)")
        #expect(abs(projects - card) < 1.5, "project view card height \(projects), activity \(card)")
    }
}
