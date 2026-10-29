import AppKit
import Foundation
import LoomChat
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// Release B's fix round 2, the look and composer items: one composer for the draft and the live session (item 3) and the
/// user row's text (item 5). The popover contrast is `HighlightTests`, the Usage meters `UsageCardsTests`, the `@` menu
/// `ChatComposerBehaviorTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct FixRoundLookTests {
    // MARK: Item 5, long user rows

    private func repeated(_ unit: String, bytes: Int) -> String {
        String(repeating: unit, count: bytes / unit.utf8.count)
    }

    @Test func isLongKeepsItsMeaningForShortAndLongMessages() {
        #expect(!ChatUserText.isLong(""))
        #expect(!ChatUserText.isLong("one line"))
        #expect(!ChatUserText.isLong(String(repeating: "a", count: 600)))
        #expect(ChatUserText.isLong(String(repeating: "a", count: 601)))
        // Eight lines are not long, nine are (the old rule: newlines + 1 > 8).
        #expect(!ChatUserText.isLong(Array(repeating: "x", count: 8).joined(separator: "\n")))
        #expect(ChatUserText.isLong(Array(repeating: "x", count: 9).joined(separator: "\n")))
        // Characters, not bytes, below the bound: 400 Chinese characters are 1,200 bytes and short.
        #expect(!ChatUserText.isLong(String(repeating: "字", count: 400)))
        #expect(ChatUserText.isLong(String(repeating: "字", count: 601)))
        // A text of any size past the bound is long at once.
        #expect(ChatUserText.isLong(repeated("a", bytes: 4_000_000)))
    }

    /// Before: `text.count` and a Character-wise reduce over the whole text, twice per body. A 4 MB message now takes the
    /// UTF-8 length and an early exit.
    @Test func isLongOnAFourMegabyteStringTakesUnderAMillisecond() {
        let plain = repeated("lorem ipsum ", bytes: 4_000_000)
        let lines = repeated("a\n", bytes: 4_000_000)
        let wide = repeated("字", bytes: 4_000_000)
        for text in [plain, lines, wide] {
            _ = ChatUserText.isLong(text) // warm up
            let started = ContinuousClock.now
            var long = true
            for _ in 0..<100 { long = long && ChatUserText.isLong(text) }
            let each = (ContinuousClock.now - started) / 100
            #expect(long)
            #expect(each < .milliseconds(1), "isLong took \(each) on \(text.utf8.count) bytes")
        }
    }

    @Test func aCollapsedRowTakesABoundedPrefixAndAShortTextIsUntouched() {
        let huge = repeated("lorem ipsum ", bytes: 4_000_000)
        let started = ContinuousClock.now
        let prefix = ChatUserText.collapsedPrefix(huge)
        #expect(ContinuousClock.now - started < .milliseconds(1))
        #expect(prefix.count == ChatUserText.collapsedCharacters)
        #expect(huge.hasPrefix(prefix), "the start of the message, as the collapsed row shows it today")
        let short = "first\nsecond\nthird"
        #expect(String(ChatUserText.collapsedPrefix(short)) == short)
        // The prefix holds every line the collapsed row can show.
        #expect(ChatUserText.collapsedCharacters >= LoomTheme.Chat.userCollapsedLines * 80)
    }

    /// A pointer entering or leaving a user row used to evaluate the row's body, which ran `isLong` twice over the whole
    /// message. The hover lives in an object only the footer reads: the footer evaluates, the message does not.
    @Test func aHoverEvaluatesTheFooterAndNeverScansTheText() async throws {
        let text = String(repeating: "paste ", count: 4_000) // long, and light enough to lay out
        let model = ChatFixture.model([ChatFixture.user(text, uuid: "u-long")])
        let entry = try #require(model.entries.first)
        let key = ChatUserMessageView.highlightKey(entry.id)

        LookEvidence.arm()
        ChatUserText.resetProbe()
        ChatUserText.watchedID = entry.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The pointer's own path: the row's hover object, which `onHover` sets and only the footer reads.
        let hover = ChatRowHover()
        let hosting = NSHostingView(rootView: ChatUserMessageView(entry: entry, open: false, context: ChatRowContext(), hover: hover))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        window.contentView = hosting
        defer {
            LookEvidence.setHover(nil)
            ChatUserText.watchedID = nil
            ChatUserText.resetProbe()
            window.close()
        }

        func settle(until: () -> Bool) async throws {
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(60))
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                if until() { return }
            }
        }
        try await settle { ChatUserText.footerBodies > 0 }
        #expect(ChatUserText.bubbleBodies >= 1 && ChatUserText.footerBodies >= 1, "the row drew")

        ChatUserText.resetProbe()
        hover.isOver = true
        try await settle { ChatUserText.footerBodies > 0 }
        #expect(ChatUserText.footerBodies >= 1, "the hover reached the footer")
        #expect(ChatUserText.bubbleBodies == 0, "a hover evaluated (and scanned) the message \(ChatUserText.bubbleBodies) times")

        ChatUserText.resetProbe()
        hover.isOver = false
        try await settle { ChatUserText.footerBodies > 0 }
        #expect(ChatUserText.footerBodies >= 1 && ChatUserText.bubbleBodies == 0, "leaving scans nothing either")

        // The evidence run's held hover (`hover:`) takes the same path.
        ChatUserText.resetProbe()
        LookEvidence.setHover(key)
        try await settle { ChatUserText.footerBodies > 0 }
        #expect(ChatUserText.footerBodies >= 1 && ChatUserText.bubbleBodies == 0)
    }
}
