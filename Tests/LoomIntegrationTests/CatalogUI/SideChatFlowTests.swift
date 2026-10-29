import AppKit
import CryptoKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// V22 part 3: the Side tab's flows on the model, the real runtime and the Chat driver over the fake provider (a forkable
/// one): the first question forks, a stopped side chat resumes, "New side chat" forks again, "/" is refused where it stands,
/// "Allow edits" reaches the driver and resets, a waiting side chat raises nothing outside the tab, "Send to main as a note"
/// reaches the parent as one `next` message, and Discard goes through part 2's path. A side chat's messages that must reach
/// the fake as a scenario begin with `~scenario` (a side chat sends no text that starts with a slash).
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(8)))
struct SideChatFlowTests: SideChatFlowFixtures {
    // MARK: A side chat's process runs only while it is the open one (D-72)

    // MARK: A terminal-face parent (D-72)

    // MARK: A deleted session's holders

    /// ST-7: the quick question's panel (its `ask` holds the driver), the Changes state and the side holder lived as long as the
    /// app. A deletion drops all three and stops every side chat follower; closing the session's tab keeps them.
    @Test func deletingASessionDropsItsQuickPanelItsChangesStateAndItsSideHolderAndStopsItsFollowers() async throws {
        let fixture = try await make()
        let model = fixture.model
        let (parent, parentDriver) = try await parent(fixture)
        let other = try await startFromDraft(model, text: "another")

        weak var panel: QuickQuestionPanel? = model.quick.panel(for: parent, driver: parentDriver)
        _ = model.quick.panel(for: other, driver: try #require(model.chatSessions?.existingDriver(for: other)))
        let changes = model.changes.session(for: parent)
        _ = model.changes.session(for: other)
        let session = model.side.session(for: parent)
        await ask(model, session, parent, "What does it do?")
        let sideID = try #require(session.openID)
        let live = try #require(session.live(for: sideID))
        #expect(live.isFollowing)
        let otherSide = model.side.session(for: other)

        // Closing the tab keeps what the session holds: the tab can come back.
        model.closeTab(parent)
        #expect(model.quick.panel(for: parent) != nil && model.changes.existing(parent) === changes)
        #expect(model.side.existing(for: parent) === session && live.isFollowing)

        model.forget(sessionID: parent)
        #expect(model.quick.panel(for: parent) == nil)
        #expect(model.changes.existing(parent) == nil)
        #expect(model.side.existing(for: parent) == nil)
        #expect(!live.isFollowing, "the follower's task was cancelled")
        #expect(session.lives.isEmpty)
        #expect(panel == nil, "nothing keeps the panel, and so the driver it asks through, alive")
        // Another session's holders are untouched.
        #expect(model.quick.panel(for: other) != nil && model.changes.existing(other) != nil)
        #expect(model.side.existing(for: other) === otherSide)
        await fixture.cleanup()
    }

    // MARK: What the tab draws
}
