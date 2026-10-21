import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomCore

/// I6b: the main window's Delete sheet in the family's facts (DESIGN §6 Sheets): one lead sentence, then "Removed" and "Kept", from
/// the runtime's dry run; and its keys (D-78, "Filled means Return"): no filled button, Return does nothing, Esc cancels.
@MainActor
@Suite struct InkDeleteSheetTests {
    private func preview(files: Int = 214, bytes: Int64 = 0, folder: String = "/tmp/claude-config", running: Bool = false,
                         unreachable: [String] = [], sideChats: Int = 0) -> ConversationDeletionPreview {
        var preview = ConversationDeletionPreview(sessionID: UUID(), fileCount: files, byteCount: bytes, configDirectory: folder,
                                                  isRunning: running, notRemoved: [], unreachable: unreachable)
        preview.sideChatCount = sideChats
        return preview
    }

    @Test func theFactsAreALeadSentenceThenWhatIsRemovedAndWhatIsKept() {
        let facts = DeleteSessionFacts(preview(files: 1))
        #expect(facts.lead == "Loom removes it from Loom and deletes Claude's local files for it. This can't be undone.")
        #expect(facts.removed == ["The transcript and the subagent transcripts", "File snapshots and session folders"])
        #expect(facts.totals == "1 file · 0 bytes · in /tmp/claude-config")
        #expect(facts.kept == ["Your prompts in Claude's shared prompt history", "Project files and worktrees",
                               "Anything already sent to Anthropic"])
        #expect(DeleteSessionFacts.removedTitle == "Removed" && DeleteSessionFacts.keptTitle == "Kept")
    }

    @Test func theCountSizeAndFolderComeFromTheDryRun() {
        let bytes: Int64 = 18_200_000
        let home = NSHomeDirectory() + "/.claude"
        let facts = DeleteSessionFacts(preview(files: 214, bytes: bytes, folder: home))
        #expect(facts.totals == "214 files · \(DeleteSheetText.size(bytes)) · in ~/.claude")
    }

    @Test func aRunningSessionAndItsSideChatsAreSaidInTheLead() {
        let running = DeleteSessionFacts(preview(running: true))
        #expect(running.lead == "It is running now, so Loom stops it first, then removes it from Loom and deletes Claude's local files "
                + "for it. This can't be undone.")
        let withSides = DeleteSessionFacts(preview(sideChats: 2))
        #expect(withSides.lead == "Loom removes it and its 2 side chats from Loom and deletes Claude's local files for them. "
                + "This can't be undone.")
        #expect(withSides.removed == DeleteSheetText.removedItems, "one transcript per session, as the cleanup's Delete says")
        #expect(DeleteSessionFacts(preview(sideChats: 1)).lead.contains("its 1 side chat from"))
        for facts in [running, withSides] {
            #expect(!(facts.lead + facts.removed.joined() + facts.kept.joined()).localizedCaseInsensitiveContains("conversation"))
        }
    }

    @Test func theSheetHasNoFilledButtonSoReturnDoesNothingAndEscCancels() {
        let confirmation = DeletionConfirmation(id: UUID(), title: "Port the sidebar to Ink tokens")
        confirmation.phase = .ready(preview())
        let ready = DeleteConversationSheet.buttons(for: confirmation, removeOnly: {}, delete: {})
        #expect(ready.leading == nil)
        #expect(ready.actions.map(\.id) == ["delete-permanently"] && ready.actions.map(\.title) == ["Delete Permanently"])
        #expect(!ready.actions.contains(where: \.isFilled) && ready.actions.allSatisfy(\.isEnabled))
        if case .failure = ready.actions[0].tint {} else { Issue.record("Delete Permanently is tinted in the failure tone") }
        let filled = ready.actions.contains(where: \.isFilled)
        #expect(SheetKeys.reaction(to: .return, hasFilledButton: filled) == .swallow)
        #expect(SheetKeys.reaction(to: .escape, hasFilledButton: filled) == .cancel)
        #expect(SheetFocusOrder.next(from: nil, in: [SheetFocusOrder.cancel] + ready.actions.map(\.id), forward: true) == "cancel")
    }

    @Test func aBlockedDeleteOffersRemoveFromLoomOnlyAtTheLeadingEdge() {
        let confirmation = DeletionConfirmation(id: UUID(), title: "Port the sidebar to Ink tokens")
        confirmation.phase = .ready(preview(unreachable: ["shared-projects"]))
        let blocked = DeleteConversationSheet.buttons(for: confirmation, removeOnly: {}, delete: {})
        #expect(blocked.leading?.id == "remove-from-loom" && blocked.leading?.title == "Remove from Loom Only")
        #expect(blocked.leading?.isFilled == false)
        #expect(blocked.actions.first?.isEnabled == false, "Delete Permanently waits while a folder blocks it")
        confirmation.phase = .loading
        let loading = DeleteConversationSheet.buttons(for: confirmation, removeOnly: {}, delete: {})
        #expect(loading.leading == nil && loading.actions.first?.isEnabled == false)
    }
}
