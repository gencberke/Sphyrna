import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs

// D-96 (W3-a): a session dropped on the live Chat composer, or picked in its `@` list, becomes a mention pill in the chip row.
// Nothing here sends a message to a real Claude: the driver is the fake provider's.

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(6)))
struct ComposerMentionTests: ComposerMentionFixtures {
    // MARK: The drop

    @Test func theOtherComposersRefuseASessionDropWithoutInsertingItsTitle() async throws {
        let host = SideComposerProbeHost()
        let editor = ComposerTextEditor(host: host, height: .constant(60))
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        view.coordinator = coordinator
        coordinator.textView = view
        let board = pasteboard()
        defer { board.releaseGlobally() }
        SessionDrag.write(ComposerMentionShared.login.id, title: ComposerMentionShared.login.title, to: board)
        #expect(view.sessionDragOperation(board) == [])
        #expect(view.dropSession(board) == false)
        #expect(view.string.isEmpty)
        withExtendedLifetime(coordinator) {}
    }

    // MARK: Sending
}

/// A composer that is not the live one (the Side tab's, the quick question's, the new-session draft's): the protocol's default.
@MainActor
private final class SideComposerProbeHost: ComposerEditorHost {
    var keyMode: ComposerKeys.Mode { .quick }
    var syncsByRevision: Bool { false }
    var textRevision: Int { 0 }
    var modelText: String { "" }
    func keyState(isRepeat: Bool, hasMarkedText: Bool, bridge: any ComposerEditorBridge) -> ComposerKeys.State {
        ComposerKeys.State()
    }
    func perform(_ action: ComposerKeys.Action, bridge: any ComposerEditorBridge, in window: NSWindow?) -> Bool { false }
    func textChanged(_ text: String) {}
    func editorEndedEditing() {}
    func paste(_ pasteboard: NSPasteboard, plain: Bool) -> Bool { false }
    func drop(_ pasteboard: NSPasteboard) -> Bool { false }
    func editorAttached(_ bridge: (any ComposerEditorBridge)?) {}
}

/// The catalog's half of the rules: only Claude sessions it lists, never a side chat.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ComposerMentionCatalogTests {
    @Test func theCatalogOffersClaudeSessionsOnlyAndNeverASideChat() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let project = rig.projects[0].id
        let claude = try #require(rig.ids[project]?.first)
        let codex = try #require(rig.ids[project]?.last)
        let sideID = UUID()
        try await rig.catalog.insertSession(
            ManagedSession(id: sideID, provider: .claude, providerConversationID: "side-conv", workingDirectory: rig.root.path),
            title: "Side", createdAt: Date(), lastUsedAt: Date(), lifecycle: .active, projectID: project,
            sideChat: SideChatLink(parentSessionID: claude, forkedAt: Date()))
        // Live, so the model holds its record (a side chat is in no list).
        let run = UUID()
        try await rig.feed(.runStarted(run), for: sideID)
        try await rig.feed(.runEndpoint(run, .pipe), for: sideID)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: sideID)
        for _ in 0..<300 where model.liveRecords[sideID] == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.liveRecords[sideID]?.isSideChat == true)

        let target = try #require(model.composerMentionTarget(for: claude))
        #expect(target.id == claude && target.provider == .claude && target.title.hasPrefix("Alpha"))
        #expect(target.accessibilityLabel == "Mentions session \(target.title)")
        #expect(model.composerMentionTarget(for: codex) == nil, "a Codex session is not mentioned")
        #expect(model.composerMentionTarget(for: sideID) == nil, "a side chat is not mentioned")
        #expect(model.composerMentionTarget(for: UUID()) == nil, "a session the catalog does not know")
    }
}
