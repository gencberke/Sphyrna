import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomChat
@testable import LoomCore
@testable import LoomCatalogUI

/// V22 part 3: the Side tab in the inspector's frame (who gets it, its width and the overlay rule), the words it says, the
/// discard question and the answer's note text. The flows that start a fork are in `SideChatFlowTests`.
@MainActor
struct SideTabTests {
    // MARK: The tab

    @Test func theSideTabComesAfterTheOthersAndTakesTheMediumColumn() {
        #expect(InspectorTab.allCases == [.overview, .changes, .agents, .side])
        #expect(InspectorTab.side.width == LoomTheme.Rhythm.inspectorWidthSide && InspectorTab.side.width == 392)
        // The others keep their widths.
        #expect(InspectorTab.overview.width == 328 && InspectorTab.agents.width == 328 && InspectorTab.changes.width == 556)
        #expect(InspectorTabBar.title(.side) == "Side")
    }

    @Test func theOverlayRuleUsesTheSideWidthAndTheWidthChangesOnlyWithTheTab() {
        let side = InspectorTab.side.width
        let minimum = LoomTheme.Inspector.minimumContent
        // 392 + 480: the content keeps 480 pt beside the column, or the column is drawn over it.
        #expect(InspectorPlacement.of(open: true, detailWidth: side + minimum, inspectorWidth: side) == .column)
        #expect(InspectorPlacement.of(open: true, detailWidth: side + minimum - 1, inspectorWidth: side) == .overlay)
        // The same pane holds the narrow column and not this one.
        #expect(InspectorPlacement.of(open: true, detailWidth: 850, inspectorWidth: InspectorTab.overview.width) == .column)
        #expect(InspectorPlacement.of(open: true, detailWidth: 850, inspectorWidth: side) == .overlay)
        #expect(InspectorPlacement.of(open: false, detailWidth: 2_000, inspectorWidth: side) == .closed)
        // An overlay is never wider than the pane it covers.
        #expect(InspectorPlacement.overlay.inspectorWidth(detailWidth: 850, tabWidth: side) == side)
        #expect(InspectorPlacement.overlay.inspectorWidth(detailWidth: 360, tabWidth: side) == 360)
        #expect(InspectorPlacement.column.contentWidth(detailWidth: 1_200, inspectorWidth: side) == 1_200 - side)
    }

    /// A model over a catalog of one session per case: a Claude session with a conversation id, one without, a Codex one.
    private struct Fixture {
        let root: URL
        let model: CatalogModel
        let claude: UUID
        let noIdentity: UUID
        let codex: UUID

        @MainActor static func make() async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-side-tab-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
            func add(_ provider: ManagedSession.Provider, conversation: String?, at second: Double) async throws -> UUID {
                let session = ManagedSession(provider: provider, providerConversationID: conversation, workingDirectory: root.path)
                try await catalog.insertSession(session, title: "Session", createdAt: Date(timeIntervalSince1970: 1_000 + second),
                                                lastUsedAt: Date(timeIntervalSince1970: 10_000 + second), lifecycle: .idle)
                return session.id
            }
            let claude = try await add(.claude, conversation: "conv-claude", at: 0)
            let noIdentity = try await add(.claude, conversation: nil, at: 1)
            let codex = try await add(.codex, conversation: "conv-codex", at: 2)
            let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                     preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs.json")))
            await model.start()
            model.readOnlyChatEnabled = true // the Side tab is the frozen Chat face's (D-100)
            return Fixture(root: root, model: model, claude: claude, noIdentity: noIdentity, codex: codex)
        }

        @MainActor func show(_ id: UUID) async -> Bool {
            model.select(id)
            return await inspectorWaitUntil { model.selectedRow?.id == id }
        }

        @MainActor func cleanup() {
            model.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func onlyAClaudeSessionWithAProviderConversationIdGetsTheTab() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(await fixture.show(fixture.claude))
        #expect(model.inspectorTabs == [.overview, .changes, .agents, .side])
        #expect(await fixture.show(fixture.noIdentity))
        #expect(model.inspectorTabs == [.overview, .changes, .agents], "a fork needs the session's id")
        #expect(await fixture.show(fixture.codex))
        #expect(model.inspectorTabs == [.overview, .changes, .agents], "Codex has no side chats")
    }

    @Test func aSideChatItselfIsNeverOfferedTheTab() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let sideID = UUID()
        try await fixture.model.catalog?.insertSession(
            ManagedSession(id: sideID, provider: .claude, providerConversationID: "conv-fork", workingDirectory: fixture.root.path),
            title: "Side", lifecycle: .active, sideChat: SideChatLink(parentSessionID: fixture.claude, forkedAt: Date()))
        let found = try await fixture.model.catalog?.session(id: sideID)
        let record = try #require(found)
        #expect(record.isSideChat)
        #expect(!fixture.model.sideTabIsOffered(for: SessionRowModel(record: record, live: nil)))
        // The same card without the link is a Claude session with an id, and has the tab.
        let parentFound = try await fixture.model.catalog?.session(id: fixture.claude)
        let plain = try #require(parentFound)
        #expect(fixture.model.sideTabIsOffered(for: SessionRowModel(record: plain, live: nil)))
    }

    @Test func theChosenSideTabFallsBackToOverviewOnASessionThatDoesNotOfferIt() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(await fixture.show(fixture.claude))
        model.selectInspectorTab(.side)
        #expect(model.shownInspectorTab == .side)
        #expect(model.shownInspectorTab.width == 392)
        #expect(await fixture.show(fixture.codex))
        #expect(model.inspector.tab == .side, "the choice is kept")
        #expect(model.shownInspectorTab == .overview, "but Codex shows Overview, in its width")
        #expect(model.shownInspectorTab.width == LoomTheme.Rhythm.inspectorWidth)
        #expect(await fixture.show(fixture.claude))
        #expect(model.shownInspectorTab == .side)
    }

    @Test func theTabBarDotFollowsWaitingAndNothingElseShowsInTheSlot() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(!model.sideChatIsWaiting(for: fixture.claude))
        #expect(!model.sideChatIsWaiting(for: nil))
        #expect(model.side.existing(for: fixture.claude) == nil, "asking about the dot makes no holder")
    }

    // MARK: Words

    @Test func theTabSaysWhatThePlannerWrote() {
        #expect(SideText.placeholder == "Ask on the side")
        #expect(SideText.modelHelp == "Same model as the session, so it reuses its cache")
        #expect(SideText.allowEdits == "Allow edits")
        #expect(SideText.allowEditsHelp == "Claude may ask to change files or run commands here. Each request asks you first.")
        #expect(SideText.forkUnsupported == "This Claude version cannot fork a session")
        #expect(SideText.notesNeedChat == "Notes go to Claude in a Chat session")
        #expect(SideText.sendNote == "Send to Main as a Note" && SideText.noteSent == "Sent to the main session")
        #expect(SideText.discard == "Discard Side Chat" && SideText.discardTitle == "Discard this side chat?")
        #expect(SideText.newSideChat == "New side chat" && SideText.earlier == "Earlier side chats")
        #expect(ChatSessionDriver.commandsRefusedText == "Commands don't run in a side chat")
    }

    @Test func theHeaderSaysWhenItWasForkedInTheAppsTimeFormat() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let forked = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 14, minute: 5)))
        let sameDay = SideText.headerNote(forkedAt: forked, now: forked.addingTimeInterval(3_600))
        #expect(sameDay == "Forked at \(LoomDateFormat.time(forked)) \u{00B7} sees the session up to then \u{00B7} the main session never sees it")
        let later = SideText.headerNote(forkedAt: forked, now: forked.addingTimeInterval(3 * 86_400))
        #expect(later.hasPrefix("Forked at ") && later.contains(LoomDateFormat.time(forked)) && later != sameDay)
    }

    @Test func anEarlierSideChatShowsItsFirstLineCutAndItsTime() throws {
        func item(_ title: String?, at date: Date) throws -> SideChatItem {
            let session = ManagedSession(provider: .claude, providerConversationID: "c", workingDirectory: "/tmp")
            return try #require(SideChatItem(CatalogSession(
                session: session, title: title, createdAt: date, lastUsedAt: date, lifecycle: .idle, pinned: false,
                sideChat: SideChatLink(parentSessionID: UUID(), forkedAt: date))))
        }
        let now = Date()
        let long = String(repeating: "x", count: 80)
        let entry = SideText.earlierEntry(try item(long, at: now), now: now)
        #expect(entry.hasPrefix(String(repeating: "x", count: LoomTheme.Side.earlierQuestionLimit) + "…"))
        #expect(entry.hasSuffix(ChatTime.label(for: now, now: now)))
        #expect(SideText.earlierEntry(try item("Why?", at: now), now: now).hasPrefix("Why? \u{00B7} "))
        #expect(SideText.earlierEntry(try item(nil, at: now), now: now).hasPrefix("No question yet"))
    }

    // MARK: The note

    @Test func theNoteQuotesTheQuestionLineByLineAndThenGivesTheAnswer() {
        #expect(SideText.note(question: "Why revoke the whole family?", answer: "Because reuse means theft.")
            == "A note from a side chat:\n\n> Why revoke the whole family?\n\nBecause reuse means theft.")
        // Every line is quoted; an empty line is a bare quote mark (no trailing space), and the question's own edges are trimmed.
        let multi = SideText.note(question: "  First line\n\nthird line\r\nfourth\n", answer: "Answer.\nTwo lines.")
        #expect(multi == "A note from a side chat:\n\n> First line\n>\n> third line\n> fourth\n\nAnswer.\nTwo lines.")
    }

    // MARK: The discard question

    @Test func theDiscardQuestionDefaultsToCancelSoReturnNeverDiscards() {
        #expect(SideDiscardRequest.defaultButton == .cancel)
        #expect(SideText.discardMessage == "Sphyrna deletes its copy of the session. The main session is not touched.")
        #expect(SideText.discardCancel == "Cancel" && SideText.discardConfirm == "Discard")
    }

    @Test func theParentsDeletionSheetNamesItsSideChats() {
        func preview(sideChats: Int, running: Bool = false) -> ConversationDeletionPreview {
            ConversationDeletionPreview(sessionID: UUID(), fileCount: 3, byteCount: 2_048, configDirectory: "/c", isRunning: running,
                                        notRemoved: [], unreachable: [], sideChatCount: sideChats)
        }
        let none = DeletionCopy.confirmBody(preview(sideChats: 0))
        #expect(!none.contains("side chat"))
        #expect(none.hasPrefix("Sphyrna removes it from Sphyrna and deletes Claude's local files for it:"), "unchanged without side chats")
        let one = DeletionCopy.confirmBody(preview(sideChats: 1))
        #expect(one.hasPrefix("Sphyrna removes it and its 1 side chat from Sphyrna and deletes Claude's local files for them:"), "\(one)")
        let many = DeletionCopy.confirmBody(preview(sideChats: 3, running: true))
        #expect(many.hasPrefix("It is running now, so Sphyrna stops it first, then removes it and its 3 side chats from Sphyrna"), "\(many)")
    }

    // MARK: Colours

    @Test func theTabsTextAndDotHoldTheirContrastOnTheInspectorTheComposerAndAPopover() {
        // The tab sits on the inspector surface (a popover when the inspector is drawn over the pane) and its composer on
        // the composer's card level: primary text 7:1, secondary 4.5:1, and the dot, a shape, 3:1.
        for appearance in LoomTheme.Appearance.allCases {
            for tone in PaneTone.allCases {
                let levels = LoomTheme.Surface.greys(appearance, tone: tone)
                for (name, level) in [("inspector", levels.canvas), ("popover", levels.popover), ("composer", levels.raised2)] {
                    let place = "\(name), \(appearance), \(tone)"
                    #expect(LoomTheme.Text.primaryPair[appearance].contrast(with: level) >= 7, "primary on \(place)")
                    #expect(LoomTheme.Text.secondaryPair[appearance].contrast(with: level) >= 4.5, "secondary on \(place)")
                    #expect(LoomTheme.Text.secondaryIncreasedPair[appearance].contrast(with: level)
                            >= LoomTheme.Text.secondaryPair[appearance].contrast(with: level), "increased on \(place)")
                }
                for (name, level) in [("inspector", levels.canvas), ("popover", levels.popover)] {
                    #expect(LoomTheme.Status.attentionPair[appearance].contrast(with: level) >= 3, "dot on \(name), \(appearance), \(tone)")
                }
            }
        }
    }
}
