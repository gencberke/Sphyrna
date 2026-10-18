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
        // Loom's own rows of the first run (no transcript has them), between the first run and the terminal's turn.
        live.appendMarker(.face(.continuedInTerminal), at: Self.time("10:00:30"))
        let start = LiveHistoryJoin.RunStart(entries: live.entries.count, turns: live.turns.count,
                                             unknownRecords: live.unknownRecordCount, generation: 2)
        live.appendMarker(.face(.backInChat))
        Self.liveTurn(&live, uuid: "u3", text: "three", messageID: "m3", answer: "answer three")
        var transcript = Transcript()
        transcript.add(Fixture.transcriptUser("one", uuid: "u1"),
                       Fixture.transcriptAssistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock("answer one")]))
        transcript.add(Fixture.transcriptUser("two in the terminal", uuid: "u2", time: "2026-10-17T10:01:00.000Z"),
                       Fixture.transcriptAssistant(messageID: "m2", uuid: "a2", blocks: [Fixture.textBlock("answer two")],
                                                   time: "2026-10-17T10:01:05.000Z"))
        transcript.add(Fixture.transcriptUser("three", uuid: "u3"),
                       Fixture.transcriptAssistant(messageID: "m3", uuid: "a3", blocks: [Fixture.textBlock("answer three")]))

        var join = LiveHistoryJoin(live: live)
        join.setRunStart(start)
        join.setHistory(transcript.model, hasOlder: false)
        let model = join.model
        #expect(model.prompts.map(\.text) == ["one", "two in the terminal", "three"])
        // The earlier run's face marker is carried into the history at its time: before the terminal's turn.
        #expect(model.markers == [.face(.continuedInTerminal), .face(.backInChat)])
        let terminalAt = model.entries.firstIndex { if case let .user(prompt) = $0.body { prompt.text == "two in the terminal" } else { false } }
        let carriedAt = model.entries.firstIndex { $0.body == .marker(.face(.continuedInTerminal)) }
        #expect(carriedAt != nil && terminalAt != nil && carriedAt! < terminalAt!)
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

    private static func time(_ clock: String) -> Date {
        ISO8601DateFormatter().date(from: "2026-10-17T\(clock)Z")!
    }

    /// A prompt a running turn read: the CLI writes a `queued_command` attachment with a uuid of its own, naming the uuid
    /// Loom sent it with as `source_uuid` (S1).
    private static func queuedCommand(_ text: String, sourceUUID: String, uuid: String, time: String) -> String {
        Fixture.line(["type": "attachment", "uuid": .string(uuid), "sessionId": "s1", "timestamp": .string(time),
                      "parentUuid": nil, "isSidechain": false,
                      "attachment": ["type": "queued_command", "prompt": .string(text), "source_uuid": .string(sourceUUID),
                                     "delivery_id": "d1", "commandMode": "prompt", "origin": ["kind": "human"],
                                     "timestamp": .string(time), "humanTurn": true]])
    }

    /// The history before the run: a turn with "again" written before the run began.
    private static func earlier() -> Transcript {
        var transcript = Transcript()
        transcript.add(Fixture.transcriptUser("again", uuid: "e1", time: "2026-10-17T10:00:00.000Z"),
                       Fixture.transcriptAssistant(messageID: "me", uuid: "ae", blocks: [Fixture.textBlock("earlier")],
                                                   time: "2026-10-17T10:00:05.000Z"))
        return transcript
    }

    private static func run(_: TurnModel) -> LiveHistoryJoin.RunStart {
        LiveHistoryJoin.RunStart(entries: 0, turns: 0, unknownRecords: 0, time: time("10:01:00"), generation: 1)
    }

    @Test func aPromptARunningTurnReadIsItsQueuedCommandAndShowsOnce() {
        var live = TurnModel(source: .live)
        Self.liveTurn(&live, uuid: "u1", text: "one", messageID: "m1", answer: "answer one")
        live.appendPendingUser(uuid: "u2", text: "two mid-turn")
        var transcript = Self.earlier()
        // The run's own first lines are not in the file yet; the mid-turn read is.
        transcript.add(Self.queuedCommand("two mid-turn", sourceUUID: "u2", uuid: "q2", time: "2026-10-17T10:01:10.000Z"))
        #expect(transcript.model.prompts.map(\.text) == ["again", "two mid-turn"])
        #expect(transcript.model.entry(id: "u2") != nil)

        var join = LiveHistoryJoin(live: live)
        join.setRunStart(Self.run(live))
        join.setHistory(transcript.model, hasOlder: false)
        #expect(join.model.prompts.map(\.text) == ["again", "one", "two mid-turn"])
        #expect(Set(Self.ids(join.model)).count == join.model.entries.count)
    }

    @Test func aPromptReadNowSentAgainIsFoundByItsNewUUID() {
        var live = TurnModel(source: .live)
        live.appendPendingUser(uuid: "u3", text: "three")
        live.rekeyPendingUser(from: "u3", to: "u3b")
        var transcript = Self.earlier()
        transcript.add(Fixture.transcriptUser("three", uuid: "u3b", time: "2026-10-17T10:01:20.000Z"))
        var join = LiveHistoryJoin(live: live)
        join.setRunStart(LiveHistoryJoin.RunStart(generation: 1))
        join.setHistory(transcript.model, hasOlder: false)
        #expect(join.model.prompts.map(\.text) == ["again", "three"])
        #expect(join.model.entries.last?.id == "u3")
    }

    @Test func aPromptUnderAnotherUUIDIsTheRunsByItsTextOnlyWhenWrittenSinceTheRunBegan() {
        var live = TurnModel(source: .live)
        live.appendPendingUser(uuid: "u4", text: "again")
        var transcript = Self.earlier()
        transcript.add(Fixture.transcriptUser("again", uuid: "x4", time: "2026-10-17T10:01:30.000Z"))
        var join = LiveHistoryJoin(live: live)
        join.setRunStart(Self.run(live))
        join.setHistory(transcript.model, hasOlder: false)
        // The earlier "again" stays; the one written in the run is the live row.
        #expect(join.model.prompts.map(\.text) == ["again", "again"])
        #expect(Self.ids(join.model) == ["e1", "me#0", "u4"])

        // Growth that brings a prompt whose text the run's part of the history holds cuts it again.
        var later = TurnModel(source: .live)
        var again = LiveHistoryJoin(live: later)
        again.setRunStart(Self.run(later))
        again.setHistory(transcript.model, hasOlder: false)
        #expect(again.model.prompts.map(\.text) == ["again", "again"])
        let delta = later.appendPendingUser(uuid: "u4", text: "again")
        guard case .rebuilt = again.apply(later.growth(sequence: 1, entriesBefore: 0, turnsBefore: 0, delta: delta, hasOlder: false)) else {
            Issue.record("the run's prompt written before the live model had it did not cut the history")
            return
        }
        #expect(Self.ids(again.model) == ["e1", "me#0", "u4"])
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
