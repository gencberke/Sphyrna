import Foundation
@testable import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// W3-f: the Dock icon's menu, built from what the model holds: who has a request waiting, who is working, five of each at most,
/// then New Claude Session.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct DockMenuTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func entry(_ title: String, _ indicator: SessionIndicator, age: TimeInterval, project: String? = "api") -> MenuBarEntry {
        MenuBarEntry(id: UUID(), indicator: indicator, lastActivityAt: now.addingTimeInterval(-age), title: title, project: project)
    }

    @Test func requestsThenWorkingFiveEachThenNewSession() throws {
        var entries: [MenuBarEntry] = []
        for index in 0..<4 { entries.append(entry("Question \(index)", .waitingForInput, age: Double(index))) }
        for index in 0..<3 { entries.append(entry("Approval \(index)", .waitingForApproval, age: 100 + Double(index))) }
        for index in 0..<7 { entries.append(entry("Work \(index)", .working, age: Double(10 * index))) }
        entries.append(entry("Unread", .unviewedCompletion, age: 0))
        entries.append(entry("Broken", .failed(nil), age: 0))

        let items = DockMenu.items(for: entries.shuffled(), canStartSession: true)
        #expect(items.map(\.kind) == [.header] + Array(repeating: .needsYouSession, count: 5) + [.header]
                + Array(repeating: .workingSession, count: 5) + [.separator, .newSession])
        #expect(items.filter { $0.kind == .header }.map(\.title) == ["Needs you", "Working"])
        #expect(items.filter { $0.kind == .needsYouSession }.map(\.title)
                == ["Approval 0", "Approval 1", "Approval 2", "Question 0", "Question 1"], "approvals first, then most recent")
        #expect(items.filter { $0.kind == .workingSession }.map(\.title) == (0..<5).map { "Work \($0)" })
        #expect(!items.contains { $0.title == "Unread" || $0.title == "Broken" }, "a finished turn or a failure is not a request")
        let last = try #require(items.last)
        #expect(last.title == "New Claude Session" && last.enabled)
        let first = try #require(items.first { $0.kind == .needsYouSession })
        #expect(DockMenu.rowTitle(first) == "Approval 0 \u{2014} api" && first.sessionID != nil)
    }

    @Test func withNothingGoingOnTheMenuIsNewSessionAlone() {
        let items = DockMenu.items(for: [entry("Idle", .ready, age: 0)], canStartSession: false)
        #expect(items.map(\.kind) == [.newSession])
        #expect(items[0].enabled == false, "disabled where ⌘N is")
        #expect(DockMenu.rowTitle(MenuBarMenuItem(kind: .workingSession, title: "Solo", project: nil, enabled: true,
                                                  sessionID: nil, attention: nil, key: nil)) == "Solo")
    }

    @Test func theModelBuildsItFromItsLiveSessions() async throws {
        let rig = try await InspectorRig.make(sessions: 3)
        defer { rig.cleanup() }
        await rig.hub.publish(sessionID: rig.ids[0], change: .runStarted(UUID()))
        await rig.hub.publish(sessionID: rig.ids[0], change: .status(ProviderWorkState(activity: .waitingForApproval)))
        await rig.hub.publish(sessionID: rig.ids[1], change: .runStarted(UUID()))
        await rig.hub.publish(sessionID: rig.ids[1], change: .status(ProviderWorkState(activity: .working)))
        let built = await inspectorWaitUntil {
            rig.model.dockMenuItems().filter { $0.sessionID != nil }.count == 2
        }
        #expect(built)
        let items = rig.model.dockMenuItems()
        #expect(items.first { $0.kind == .needsYouSession }?.sessionID == rig.ids[0])
        #expect(items.first { $0.kind == .needsYouSession }?.title == "Session 0")
        #expect(items.first { $0.kind == .workingSession }?.sessionID == rig.ids[1])
        #expect(items.last?.kind == .newSession)
    }
}
