import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomChat
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

private typealias ComposerSpy = PinnedFixRoundShared.ComposerSpy

// The fix round after the strict review of V18 (pinned cards), view side: each test fails without the fix it names.

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PinnedFixRoundTests {
    // MARK: Fix 4: bounded approval content

    @Test func aHugeCommandOrFileBuildsASmallCardWithAVisibleCut() {
        let started = ProcessInfo.processInfo.systemUptime
        let oneLine = String(repeating: "a", count: 3_000_000)
        let command = PinnedApprovalContent.make(PinnedFixRoundShared.request("c", input: ["command": .string(oneLine)]))
        #expect(command.lines.count <= PinnedApprovalContent.maximumLines + 1)
        #expect(command.lines.allSatisfy { $0.text.count <= PinnedApprovalContent.maximumLineCharacters + 1 })
        #expect(command.lines.first?.text.hasSuffix("\u{2026}") == true, "a cut line ends in the mark")

        let manyLines = (1...100_000).map { "line \($0)" }.joined(separator: "\n")
        let write = PinnedApprovalContent.make(PinnedFixRoundShared.request("w", tool: "Write", input: ["file_path": "/tmp/a.txt", "content": .string(manyLines)]))
        #expect(write.lines.count <= PinnedApprovalContent.maximumLines + 3)
        #expect(write.lines.last?.text == "\u{2026} the rest is not shown", "\(write.lines.last?.text ?? "")")
        #expect(write.lines.map(\.text.count).reduce(0, +) <= PinnedApprovalContent.maximumCharacters + 1_000)

        let edit = PinnedApprovalContent.make(PinnedFixRoundShared.request("e", tool: "Edit", input: [
            "file_path": "/tmp/a.swift", "old_string": .string(manyLines), "new_string": .string(manyLines + "\nmore")]))
        #expect(edit.lines.count <= PinnedApprovalContent.maximumLines + 3)
        #expect(ProcessInfo.processInfo.systemUptime - started < 5, "building the content of huge inputs stays cheap")

        // A small input is shown whole, without a mark.
        let small = PinnedApprovalContent.make(PinnedFixRoundShared.request("s", input: ["command": "make clean\nmake"]))
        #expect(small.lines.map(\.text) == ["make clean", "make"])
    }

    @Test func theContentIsBuiltOncePerRequestNotOnEveryBody() {
        let cards = PinnedCardsModel(source: CardSource())
        let one = PinnedFixRoundShared.request("a", tool: "Write", input: ["file_path": "/tmp/a.txt", "content": "x\ny"])
        let first = cards.content(for: one)
        let second = cards.content(for: one)
        #expect(first == second)
        cards.apply(PinnedFixRoundShared.state([one]))
        cards.apply(PinnedFixRoundShared.state([]))
        #expect(cards.content(for: one) == first)
    }

    // MARK: Fix 2: stopping

    @Test func theButtonsAreOffWhileTheSessionStopsAndTheDriversRefusalReadsAsStopping() async {
        let source = CardSource()
        let cards = PinnedCardsModel(source: source)
        let one = PinnedFixRoundShared.request("a")
        cards.apply(PinnedFixRoundShared.state([one], phase: .stopping))
        #expect(cards.isStopping)
        cards.apply(PinnedFixRoundShared.state([one], phase: .needsYou))
        #expect(!cards.isStopping)
        await source.fail(with: ChatDriverError.stopping)
        await cards.allowOnce(one)
        #expect(cards.failures["a"] == "The session is stopping.")
        #expect(cards.current?.requestID == "a", "the card stays")
    }

    // MARK: Fix 14: the ring

    @Test func theRingStartsNowhereAndMovesFromTheEdges() {
        #expect(PinnedKeyRegion.moved(from: nil, by: 1, count: 3) == 0, "→ from nowhere goes to the first")
        #expect(PinnedKeyRegion.moved(from: nil, by: -1, count: 3) == 2, "← from nowhere goes to the last")
        #expect(PinnedKeyRegion.moved(from: 2, by: 1, count: 3) == 0)
        #expect(PinnedKeyRegion.moved(from: 0, by: -1, count: 3) == 2)
        let cards = PinnedCardsModel(source: CardSource())
        cards.apply(PinnedFixRoundShared.state([PinnedFixRoundShared.request("a")]))
        cards.focus()
        #expect(cards.focusedIndex == nil, "Tab alone puts the ring on no button")
    }

    @Test func aFailureLineThatAppearsDoesNotMoveTheRing() async {
        let source = CardSource()
        let cards = PinnedCardsModel(source: source)
        let one = PinnedFixRoundShared.request("a")
        cards.apply(PinnedFixRoundShared.state([one]))
        cards.focusedIndex = 1
        await source.fail(with: ChatDriverError.inputFull)
        await cards.allowOnce(one)
        #expect(cards.failures["a"] != nil)
        #expect(cards.focusedIndex == 1, "the ring lives in the model, so a card drawn again keeps it")
    }

    // MARK: Fix 15: the typing guard

    @Test func theGuardReadsTheMonotonicClockAndNotTheWallClock() {
        let wall = Mutex2<Date>(Date())
        let uptime = Mutex2<TimeInterval>(1_000)
        let cards = PinnedCardsModel(source: CardSource(), clock: { wall.value }, typingClock: { uptime.value }, typingHold: 1.5)
        cards.note.hasFocus = true
        cards.composerTextChanged("typing")
        // The wall clock jumps a day back (a clock change, sleep, a time zone): it holds or releases nothing.
        wall.value = wall.value.addingTimeInterval(-86_400)
        uptime.value += 0.5
        cards.apply(PinnedFixRoundShared.state([PinnedFixRoundShared.request("a")]))
        #expect(cards.isHeld)
        wall.value = wall.value.addingTimeInterval(7 * 86_400)
        cards.releaseHoldIfIdle()
        #expect(cards.isHeld, "half a second of the monotonic clock is not a pause")
        uptime.value += 1.1
        cards.releaseHoldIfIdle()
        #expect(!cards.isHeld)

        // The default clock is the system uptime: an edit stamped with it holds a card that arrives at once.
        let real = PinnedCardsModel(source: CardSource())
        real.note.hasFocus = true
        real.composerTextChanged("typing")
        real.apply(PinnedFixRoundShared.state([PinnedFixRoundShared.request("b")]))
        #expect(real.isHeld, "the default typing clock is the monotonic one")
    }

    @Test func aTextTheCardsOrTheComposerSetThemselvesIsNotTyping() {
        let uptime = Mutex2<TimeInterval>(10)
        let cards = PinnedCardsModel(source: CardSource(), typingClock: { uptime.value }, typingHold: 1.5)
        let spy = ComposerSpy()
        cards.attach(spy, text: "", hasFocus: false)
        cards.note.hasFocus = true
        cards.composerTextChanged("typed")
        uptime.value += 5
        // A clear (a send, a restore, a pick) is not an edit by the user, and does not make the composer busy.
        cards.composerTextSet("")
        cards.note.set("a pick's text")
        cards.apply(PinnedFixRoundShared.state([PinnedFixRoundShared.request("a")]))
        #expect(!cards.isHeld, "five seconds after the last keystroke, whatever was set since")
        #expect(spy.notes == ["a pick's text"])
    }
}

// MARK: Fix: real key events
