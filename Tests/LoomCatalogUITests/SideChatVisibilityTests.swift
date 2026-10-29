import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// V22 part 2: a side chat is a real session with live state, but it is the Side tab's, not the app's lists'. A side chat that is
/// working or waits for the user must not raise the Dock badge, Home's Needs you, the menu bar, the notifications, the Active
/// section, the palette or its project's attention dot. The same feed for an ordinary session does all of those (the control).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SideChatVisibilityTests {
    private func approval() -> ProviderPendingRequest {
        ProviderPendingRequest(requestID: "r1", toolUseID: "t-r1", kind: .approval, toolName: "Bash", summary: "rm -rf build",
                               note: "Remove the build folder", arrivedAt: Date())
    }

    /// Runs the session and leaves it waiting for approval.
    private func waitForApproval(_ rig: ListRig, _ id: UUID) async throws {
        let run = UUID()
        try await rig.feed(.runStarted(run), for: id)
        try await rig.feed(.runEndpoint(run, .pipe), for: id)
        try await rig.feed(.pendingRequests([approval()]), for: id)
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: id)
    }

    private func settled(_ model: CatalogModel, _ id: UUID) async -> Bool {
        for _ in 0..<200 {
            if model.liveRecords[id] != nil || model.rowModels[id] != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func aSideChatThatWaitsRaisesNothingWhereAnOrdinarySessionDoes() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let project = rig.projects[0].id
        let parent = try #require(rig.ids[project]?.first)
        let ordinary = try #require(rig.ids[project]?.last)
        let sideID = UUID()
        try await rig.catalog.insertSession(
            ManagedSession(id: sideID, provider: .claude, providerConversationID: "side-conv", workingDirectory: rig.root.path),
            title: "Side", createdAt: Date(), lastUsedAt: Date(), lifecycle: .active, projectID: project,
            sideChat: SideChatLink(parentSessionID: parent, forkedAt: Date()))

        // The control: an ordinary session that waits shows up everywhere.
        try await waitForApproval(rig, ordinary)
        #expect(model.activeIDs.contains(ordinary))
        #expect(model.attentionCount == 1)
        #expect(model.sessionsNeedingAttention() == [ordinary])
        #expect(model.menuBarSummary.approvals == [ordinary])
        #expect(model.homeBoard().needsYou.map(\.id) == [ordinary])
        #expect(model.attention(forProject: project) != nil)

        // The side chat waits the same way: nothing changes.
        try await waitForApproval(rig, sideID)
        #expect(await settled(model, sideID))
        #expect(model.liveRecords[sideID]?.isSideChat == true)
        #expect(!model.activeIDs.contains(sideID))
        #expect(model.attentionCount == 1)
        #expect(model.sessionsNeedingAttention() == [ordinary])
        #expect(model.menuBarSummary.approvals == [ordinary])
        #expect(model.homeBoard().needsYou.map(\.id) == [ordinary])
        #expect(model.paletteSessions().map(\.id).contains(sideID) == false)
        #expect(model.paletteSessions().map(\.id).contains(ordinary))

        // A project whose only live session is a side chat (still waiting) has no dot.
        try await rig.feed(.pendingRequests([]), for: ordinary)
        try await rig.feed(.status(ProviderWorkState(activity: .atPrompt)), for: ordinary)
        try await rig.feed(.runEnded(try #require(model.liveStates[ordinary]?.runID), .requested), for: ordinary)
        #expect(model.attention(forProject: project) == nil)
    }
}
