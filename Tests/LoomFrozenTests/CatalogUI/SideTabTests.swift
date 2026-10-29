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
}
