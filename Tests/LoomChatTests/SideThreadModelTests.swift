import Foundation
import LoomCore
import Testing
@testable import LoomChat

/// V22 part 3: a fork's transcript starts with a copy of the parent's records (and the CLI's repair records for what the parent
/// left open); the side chat's thread starts at its first question. `TurnModel.sideThread` cuts there, whatever part of the file
/// the lens has read so far.
@Suite
struct SideThreadModelTests {
    private static func transcript(_ lines: [String], firstOffset: UInt64 = 0) -> TurnModel {
        var model = TurnModel(source: .sessionTranscript)
        var offset = firstOffset
        for line in lines {
            let bytes = Data(line.utf8)
            model.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
            offset += UInt64(bytes.count + 1)
        }
        return model
    }

    /// The parent's copy: two turns, the second left open (a tool call with no result), then the repair record the CLI writes
    /// for it; then the fork's own two questions.
    private static let lines: [String] = [
        Fixture.transcriptUser("parent one", uuid: "p1"),
        Fixture.transcriptAssistant(messageID: "pm1", uuid: "pa1", blocks: [Fixture.textBlock("parent answer one")]),
        Fixture.transcriptUser("parent two", uuid: "p2"),
        Fixture.transcriptAssistant(messageID: "pm2", uuid: "pa2", blocks: [Fixture.toolUse("pt2", "Bash", ["command": "sleep 9"])]),
        Fixture.transcriptToolResult(id: "pt2", text: "Request interrupted"),
        Fixture.transcriptUser("side one", uuid: "s1"),
        Fixture.transcriptAssistant(messageID: "sm1", uuid: "sa1", blocks: [Fixture.textBlock("side answer one")]),
        Fixture.transcriptUser("side two", uuid: "s2"),
        Fixture.transcriptAssistant(messageID: "sm2", uuid: "sa2", blocks: [Fixture.textBlock("side answer two")]),
    ]

    @Test func theThreadStartsAtTheFirstQuestionAndNothingBeforeItIsKept() {
        let whole = Self.transcript(Self.lines)
        #expect(whole.prompts.map(\.text) == ["parent one", "parent two", "side one", "side two"])
        let thread = whole.sideThread(startingAt: "s1", hasOlder: true)
        #expect(thread.model.prompts.map(\.text) == ["side one", "side two"])
        #expect(thread.model.texts.map(\.text) == ["side answer one", "side answer two"])
        #expect(!thread.hasOlder, "nothing older is wanted once the first question is found")
        // The model stays whole: every kept entry is indexed, and every turn has an entry.
        #expect(thread.model.entries.allSatisfy { thread.model.entry(id: $0.id) != nil })
        #expect(Set(thread.model.entries.map(\.turnID)) == Set(thread.model.turns.map(\.id)))
        #expect(thread.model.entries.first?.id == "s1")
    }

    @Test func aReadThatLiesInsideTheSideChatIsKeptWholeAndAskedToReadOlder() {
        // The lens read the newest turns only: the first question is further back.
        let tail = Self.transcript(Array(Self.lines.suffix(2)), firstOffset: 4_000)
        let thread = tail.sideThread(startingAt: "s1", hasOlder: true)
        #expect(thread.model.prompts.map(\.text) == ["side two"])
        #expect(thread.hasOlder)
    }

    @Test func aReadThatNeverFoundTheFirstQuestionIsTheParentsCopyAndShowsNothing() {
        let whole = Self.transcript(Array(Self.lines.prefix(5)))
        // No question was sent yet (or its record is not written yet), and nothing older exists.
        let none = whole.sideThread(startingAt: nil, hasOlder: false)
        #expect(none.model.entries.isEmpty && none.model.turns.isEmpty && !none.hasOlder)
        let unwritten = whole.sideThread(startingAt: "s1", hasOlder: false)
        #expect(unwritten.model.entries.isEmpty && !unwritten.hasOlder)
        // With no uuid, even a read with older records is the copy: the card has no question yet.
        #expect(whole.sideThread(startingAt: nil, hasOlder: true).model.entries.isEmpty)
    }
}
