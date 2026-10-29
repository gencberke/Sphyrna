import AppKit
import Foundation
import LoomCore
import LoomTerminal
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

extension ChatHosted {
    /// The read-only Chat view in the session route (V13 routed by the Release A glue): it reads the transcript below the
    /// config directory the app gave the model, draws today's kept screen when none resolves, and looks again when the
    /// session's run starts or its status changes. Transcripts are fixtures in temporary folders; the real `~/.claude` is
    /// never read.
    @MainActor
    @Suite
    struct SessionChatViewTests: SessionChatViewFixtures {
        private func keptScreen(in view: NSView) -> EndedScreenContainerView? {
            if let found = view as? EndedScreenContainerView { return found }
            for child in view.subviews { if let found = keptScreen(in: child) { return found } }
            return nil
        }

        @Test func theRecordInTheChatLeavesOutWhatTheChatAlreadyDraws() {
            #expect(!ConversationDetail.showsRequests(inChat: true))
            #expect(ConversationDetail.showsRequests(inChat: false))
            // Without a terminal the notice above has Resume; with one there is no notice, so the record keeps it.
            #expect(!ConversationDetail.showsResume(inChat: true, hasTerminal: false))
            #expect(ConversationDetail.showsResume(inChat: true, hasTerminal: true))
            #expect(ConversationDetail.showsResume(inChat: false, hasTerminal: false))
        }
    }
}
