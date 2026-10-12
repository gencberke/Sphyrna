import Foundation
@testable import LoomCore
import Testing
@testable import LoomCatalogUI

/// H1-F at the model: the menu bar summary follows live state and fires on a change only (working moves it
/// where the Dock badge does not), the menu is built from titles and projects, and the two switches persist.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct MenuBarModelTests {
    struct Rig {
        let root: URL
        let hub: SessionEventHub
        let model: CatalogModel
        let ids: [UUID]
        @MainActor func cleanup() {
            model.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeRig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-menubar-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let folder = root.appendingPathComponent("enmusait", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await catalog.addProject(path: folder.path).project
        var ids: [UUID] = []
        for index in 0..<3 {
            let session = ManagedSession(provider: .claude, providerConversationID: "conv-\(index)", workingDirectory: root.path)
            try await catalog.insertSession(
                session, title: "s\(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle,
                projectID: index == 0 ? project.id : nil)
            ids.append(session.id)
        }
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        await model.start()
        return Rig(root: root, hub: hub, model: model, ids: ids)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func live(_ rig: Rig, _ index: Int, _ activity: AgentActivity) async {
        await rig.hub.publish(sessionID: rig.ids[index], change: .runStarted(UUID()))
        await rig.hub.publish(sessionID: rig.ids[index], change: .status(ProviderWorkState(activity: activity)))
    }

    @Test func theSummaryFollowsLiveStateAndFiresOnAChangeOnly() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        var summaries: [MenuBarSummary] = []
        var dockCounts: [Int] = []
        rig.model.onMenuBarChange = { summaries.append($0) }
        rig.model.onAttentionCountChange = { dockCounts.append($0) }

        await live(rig, 0, .working)
        #expect(await waitUntil { rig.model.menuBarSummary.badge == .working })
        #expect(summaries.last?.working == 1 && dockCounts.isEmpty, "working moves the menu bar, not the Dock badge")

        await live(rig, 1, .waitingForApproval)
        #expect(await waitUntil { rig.model.menuBarSummary.badge == .attention })
        #expect(rig.model.menuBarSummary.approvals == [rig.ids[1]])
        #expect(summaries.last?.accessibilityLabel == "Loom, 1 session needs you, 1 working")

        // The same state again is not a change.
        let count = summaries.count
        await rig.hub.publish(sessionID: rig.ids[1], change: .status(ProviderWorkState(activity: .waitingForApproval)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(summaries.count == count)

        // Answered: the approval leaves the set.
        await rig.hub.publish(sessionID: rig.ids[1], change: .status(ProviderWorkState(activity: .working)))
        #expect(await waitUntil { rig.model.menuBarSummary.approvals.isEmpty })
        #expect(rig.model.menuBarSummary.badge == .working && rig.model.menuBarSummary.working == 2)
    }

    @Test func theMenuIsBuiltFromTheSessionsTitlesAndProjects() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        await live(rig, 0, .waitingForInput)
        await live(rig, 2, .working)
        #expect(await waitUntil { rig.model.menuBarSummary.needsYou == 1 && rig.model.menuBarSummary.working == 1 })
        let state = rig.model.menuBarState()
        #expect(state.needsYou.map(\.id) == [rig.ids[0]] && state.needsYou.first?.title == "s0")
        #expect(state.needsYou.first?.project == "enmusait")
        #expect(state.working.map(\.id) == [rig.ids[2]] && state.working.first?.project == nil)
        let content = rig.model.titleAndProject(of: rig.ids[0])
        #expect(content?.title == "s0" && content?.project == "enmusait")
        let body = ApprovalNotificationPlanner.body(project: content?.project)
        #expect(body == "enmusait · Claude is waiting for your approval.")
    }

    @Test func theTwoSwitchesPersistTouchNothingElseAndCallBack() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        var menuCalls = 0, notifyCalls = 0
        rig.model.onShowInMenuBarChange = { menuCalls += 1 }
        rig.model.onNotifyApprovalsChange = { notifyCalls += 1 }
        #expect(rig.model.showInMenuBar && rig.model.notifyApprovals)

        rig.model.setShowInMenuBar(false)
        #expect(!rig.model.showInMenuBar && rig.model.notifyApprovals && menuCalls == 1 && notifyCalls == 0)
        rig.model.setShowInMenuBar(false)
        #expect(menuCalls == 1, "no change, no call")
        rig.model.setNotifyApprovals(false)
        #expect(!rig.model.notifyApprovals && menuCalls == 1 && notifyCalls == 1)

        let saved = try JSONDecoder().decode(UIPreferences.self, from: Data(contentsOf: rig.root.appendingPathComponent("ui-preferences.json")))
        #expect(!saved.showInMenuBar && !saved.notifyApprovals)
    }
}
