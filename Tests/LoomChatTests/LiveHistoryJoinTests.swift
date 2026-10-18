import Foundation
import LoomCore
import Testing
@testable import LoomChat

/// `LiveHistoryJoin`: the transcript's history above a Chat run's live model. The transcript also holds the live run's
/// lines; the joint shows every turn once and loses nothing that began before the run.
@Suite
struct LiveHistoryJoinTests {
    private struct Transcript {
        var model = TurnModel(source: .sessionTranscript)
        var offset: UInt64 = 0
        var offsets: [String: UInt64] = [:]

        mutating func add(_ lines: String..., marking name: String? = nil) {
            for line in lines {
                if let name, offsets[name] == nil { offsets[name] = offset }
                let bytes = Data(line.utf8)
                model.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
                offset += UInt64(bytes.count + 1)
            }
        }
    }

    private static func ids(_ model: TurnModel) -> [String] { model.entries.map(\.id) }

    private static func liveTurn(_ model: inout TurnModel, uuid: String, text: String, messageID: String, answer: String) {
        model.appendPendingUser(uuid: uuid, text: text)
        model.apply(Fixture.message(Fixture.echo(text, uuid: uuid)))
        model.apply(Fixture.message(Fixture.assistant(messageID: messageID, uuid: "a-" + messageID, blocks: [Fixture.textBlock(answer)])))
        model.apply(Fixture.message(Fixture.result()))
    }

    @Test func theBoundaryTurnShowsOnceAndTheTurnsBeforeTheRunStay() {
        var transcript = Transcript()
        transcript.add(Fixture.transcriptUser("one", uuid: "u1"),
                       Fixture.transcriptAssistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock("answer one")]))
        transcript.add(Fixture.transcriptUser("two", uuid: "u2"),
                       Fixture.transcriptAssistant(messageID: "m2", uuid: "a2", blocks: [Fixture.toolUse("t2", "Bash", ["command": "ls"])]),
                       Fixture.transcriptToolResult(id: "t2", text: "a\nb"),
                       Fixture.transcriptAssistant(messageID: "m2b", uuid: "a2b", blocks: [Fixture.textBlock("answer two")]))
        // The live run's first turn, already in the file.
        transcript.add(Fixture.transcriptUser("three", uuid: "u3"),
                       Fixture.transcriptAssistant(messageID: "m3", uuid: "a3", blocks: [Fixture.textBlock("answer three")]),
                       marking: "run")
        var live = TurnModel(source: .live)
        Self.liveTurn(&live, uuid: "u3", text: "three", messageID: "m3", answer: "answer three")

        var join = LiveHistoryJoin(live: live)
        join.setHistory(transcript.model, hasOlder: true)
        let model = join.model
        #expect(model.prompts.map(\.text) == ["one", "two", "three"])
        #expect(model.texts.map(\.text) == ["answer one", "answer two", "answer three"])
        #expect(Set(Self.ids(model)).count == model.entries.count)
        #expect(model.turns.map(\.id) == ["turn:u1", "turn:u2", "turn:u3"])
        #expect(model.turns.last?.status == .succeeded)
        #expect(join.hasOlder)
        // "Show all" for a live row scans from the run's first line.
        #expect(join.liveLinesStart == transcript.offsets["run"])
    }

    @Test func aTurnThatBeganBeforeTheRunKeepsWhatItHeld() {
        var transcript = Transcript()
        transcript.add(Fixture.transcriptUser("one", uuid: "u1"),
                       Fixture.transcriptAssistant(messageID: "m1", uuid: "a1", blocks: [Fixture.toolUse("t1", "Bash", ["command": "ls"])]),
                       // The run goes on in the same turn without a prompt.
                       Fixture.transcriptAssistant(messageID: "m2", uuid: "a2", blocks: [Fixture.textBlock("carried on")]))
        var live = TurnModel(source: .live)
        live.apply(Fixture.message(Fixture.assistant(messageID: "m2", uuid: "a2", blocks: [Fixture.textBlock("carried on")])))

        var join = LiveHistoryJoin(live: live)
        join.setHistory(transcript.model, hasOlder: false)
        let model = join.model
        #expect(Self.ids(model) == ["u1", "t1", "m2#0"])
        #expect(model.prompts.map(\.text) == ["one"])
        #expect(model.texts.map(\.text) == ["carried on"])
        #expect(model.turns.first?.id == "turn:u1")
    }

    @Test func aLiveEntryTheHistoryAlreadyHeldCutsItAgainAndGrowthKeepsAMirrorEqual() {
        var transcript = Transcript()
        transcript.add(Fixture.transcriptUser("one", uuid: "u1"),
                       Fixture.transcriptAssistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock("answer one")]))
        // Written by the CLI before the live model had it.
        transcript.add(Fixture.transcriptUser("two", uuid: "u2"))
        var live = TurnModel(source: .live)
        var join = LiveHistoryJoin(live: live)
        join.setHistory(transcript.model, hasOlder: false)
        #expect(join.model.prompts.map(\.text) == ["one", "two"])

        var sequence = 0
        func step(_ make: (inout TurnModel) -> ModelDelta) -> LiveHistoryJoin.Outcome {
            let entries = live.entries.count, turns = live.turns.count
            let delta = make(&live)
            sequence += 1
            return join.apply(live.growth(sequence: sequence, entriesBefore: entries, turnsBefore: turns, delta: delta, hasOlder: false))
        }
        guard case .rebuilt = step({ $0.appendPendingUser(uuid: "u2", text: "two") }) else {
            Issue.record("the live prompt the history held did not cut it")
            return
        }
        #expect(join.model.prompts.map(\.text) == ["one", "two"])
        #expect(Set(Self.ids(join.model)).count == join.model.entries.count)

        var mirror = join.model
        let steps: [(inout TurnModel) -> ModelDelta] = [
            { $0.apply(Fixture.message(Fixture.echo("two", uuid: "u2"))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "message_start", "message": ["id": "m2", "model": "m"]]))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Answer"]]))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "content_block_stop", "index": 0]))) },
            { $0.apply(Fixture.message(Fixture.result())) },
            { $0.appendPendingUser(uuid: "u3", text: "three") },
        ]
        for (index, make) in steps.enumerated() {
            switch step(make) {
            case let .growth(change):
                let applied = mirror.apply(change)
                #expect(applied, "step \(index)")
            case .unchanged:
                // A step that changed no row (a message start) hands nothing on.
                break
            case .rebuilt, .refused:
                Issue.record("step \(index) was not a growth")
                return
            }
            #expect(mirror.rowInputsEqual(join.model), "step \(index)")
        }
        #expect(join.model.prompts.map(\.text) == ["one", "two", "three"])
    }

    /// Chat, then Terminal, then Chat again with the same driver: its model holds the first run; the terminal's turn is only
    /// in the transcript. The live part shown is the newest run, so the terminal's turn stays between them.
    @Test func aNewRunShowsTheTurnsThatRanElsewhereSinceTheLastOne() {
        var live = TurnModel(source: .live)
        Self.liveTurn(&live, uuid: "u1", text: "one", messageID: "m1", answer: "answer one")
        // A background tool of the first run, whose result comes later.
        live.apply(Fixture.message(Fixture.assistant(messageID: "m1t", uuid: "a1t", blocks: [Fixture.toolUse("t1", "Bash", ["command": "ls"])])))
        live.appendMarker(.face(.continuedInTerminal))
        let start = LiveHistoryJoin.RunStart(entries: live.entries.count, turns: live.turns.count,
                                             unknownRecords: live.unknownRecordCount)
        live.appendMarker(.face(.backInChat))
        Self.liveTurn(&live, uuid: "u3", text: "three", messageID: "m3", answer: "answer three")
        var transcript = Transcript()
        transcript.add(Fixture.transcriptUser("one", uuid: "u1"),
                       Fixture.transcriptAssistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock("answer one")]))
        transcript.add(Fixture.transcriptUser("two in the terminal", uuid: "u2"),
                       Fixture.transcriptAssistant(messageID: "m2", uuid: "a2", blocks: [Fixture.textBlock("answer two")]))
        transcript.add(Fixture.transcriptUser("three", uuid: "u3"),
                       Fixture.transcriptAssistant(messageID: "m3", uuid: "a3", blocks: [Fixture.textBlock("answer three")]))

        var join = LiveHistoryJoin(live: live)
        join.setRunStart(start)
        join.setHistory(transcript.model, hasOlder: false)
        let model = join.model
        #expect(model.prompts.map(\.text) == ["one", "two in the terminal", "three"])
        #expect(model.markers == [.face(.backInChat)])
        #expect(Set(Self.ids(model)).count == model.entries.count)

        // Growth of the new run moves past the history and the hidden first run; a change to the first run shows nothing.
        var mirror = model
        let entries = live.entries.count, turns = live.turns.count
        let delta = live.appendPendingUser(uuid: "u4", text: "four")
        guard case let .growth(change) = join.apply(live.growth(sequence: 1, entriesBefore: entries, turnsBefore: turns,
                                                                delta: delta, hasOlder: false)) else {
            Issue.record("not a growth")
            return
        }
        let applied = mirror.apply(change)
        #expect(applied)
        #expect(mirror.rowInputsEqual(join.model))
        let before = (live.entries.count, live.turns.count)
        let hidden = live.apply(Fixture.message(Fixture.toolResult(id: "t1", text: "late")))
        #expect(hidden.updated == ["t1"])
        guard case .unchanged = join.apply(live.growth(sequence: 2, entriesBefore: before.0, turnsBefore: before.1,
                                                      delta: hidden, hasOlder: false)) else {
            Issue.record("a change to the hidden run was shown")
            return
        }
        #expect(mirror.rowInputsEqual(join.model))
    }

    @Test func aChangeNotMadeOnTheLiveModelIsRefused() {
        var live = TurnModel(source: .live)
        live.appendPendingUser(uuid: "u1", text: "one")
        var join = LiveHistoryJoin(live: TurnModel(source: .live))
        let change = live.growth(sequence: 1, entriesBefore: 1, turnsBefore: 1, delta: ModelDelta(), hasOlder: false,
                                 activityChanged: true)
        guard case .refused = join.apply(change) else {
            Issue.record("a change for another model was taken")
            return
        }
    }

    @Test func madeUpIDsOfTheHistoryNeverMeetTheLiveModels() {
        var history = TurnModel(source: .sessionTranscript)
        history.appendMarker(.face(.continuedInTerminal), at: Date())
        var live = TurnModel(source: .live)
        live.appendMarker(.face(.backInChat), at: Date())
        #expect(history.entries.first?.id == live.entries.first?.id)

        var join = LiveHistoryJoin(live: live)
        join.setHistory(history, hasOlder: false)
        let model = join.model
        #expect(model.markers == [.face(.continuedInTerminal), .face(.backInChat)])
        #expect(Set(Self.ids(model)).count == 2)
        #expect(model.entry(id: live.entries[0].id)?.body == .marker(.face(.backInChat)))
    }
}
