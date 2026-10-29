import Foundation
import LoomCore
import Testing
@testable import LoomChat
@testable import LoomChatTestRigs

/// `ModelChange`: a copy of a model kept by applying changes equals the model the changes were made on, and a source hands
/// its changes out in order, one at a time.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ModelChangeTests {
    private func equal(_ mirror: TurnModel, _ producer: TurnModel) -> Bool {
        mirror.rowInputsEqual(producer) && producer.entries.allSatisfy { mirror.entry(id: $0.id) == $0 }
    }

    /// Applies each step to the producer, makes the change, applies it to the mirror, and compares.
    private func check(_ producer: inout TurnModel, _ mirror: inout TurnModel, sequence: inout Int, _ step: (inout TurnModel) -> ModelDelta) -> Bool {
        let entries = producer.entries.count, turns = producer.turns.count
        let activity = producer.activity
        let delta = step(&producer)
        sequence += 1
        let change = producer.growth(sequence: sequence, entriesBefore: entries, turnsBefore: turns, delta: delta, hasOlder: false,
                                     activityChanged: producer.activity != activity)
        return mirror.apply(change) && equal(mirror, producer)
    }

    @Test func aMirrorKeptByChangesEqualsTheModelOfALiveStream() {
        var producer = TurnModel(source: .live)
        var mirror = TurnModel(source: .live)
        var sequence = 0
        let steps: [(inout TurnModel) -> ModelDelta] = [
            { $0.appendPendingUser(uuid: "u1", text: "go") },
            { $0.apply(Fixture.message(Fixture.partial(["type": "message_start", "message": ["id": "m1", "model": "m"]]))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Looking "]]))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "now."]]))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "content_block_stop", "index": 0]))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "t1", "name": "Bash"]]))) },
            { $0.apply(Fixture.message(Fixture.toolResult(id: "t1", text: "ok"))) },
            { $0.apply(Fixture.message(Fixture.result())) },
            // The next turn: the one before it settles.
            { $0.appendPendingUser(uuid: "u2", text: "again") },
            { $0.apply(Fixture.message(Fixture.partial(["type": "message_start", "message": ["id": "m2", "model": "m"]]))) },
            { $0.apply(Fixture.message(Fixture.partial(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "t2", "name": "Read"]]))) },
            { $0.apply(Fixture.message(Fixture.result(terminalReason: "aborted_streaming"))) },
        ]
        for (index, step) in steps.enumerated() {
            #expect(check(&producer, &mirror, sequence: &sequence, step), "step \(index)")
        }
        #expect(producer.turns.map(\.id).count == 2)
    }

    @Test func aMirrorKeptByChangesEqualsTheModelOfAGrowingTranscript() {
        var producer = TurnModel(source: .sessionTranscript)
        var mirror = TurnModel(source: .sessionTranscript)
        var sequence = 0
        var offset: UInt64 = 0
        func lines(_ text: [String]) -> (inout TurnModel) -> ModelDelta {
            { model in
                var delta = ModelDelta()
                for line in text {
                    let bytes = Data(line.utf8)
                    let made = model.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
                    delta.inserted += made.inserted
                    for id in made.updated where !delta.inserted.contains(id) && !delta.updated.contains(id) { delta.updated.append(id) }
                    delta.turnsChanged = delta.turnsChanged || made.turnsChanged
                    offset += UInt64(bytes.count + 1)
                }
                return delta
            }
        }
        let batches: [[String]] = [
            [Fixture.transcriptUser("one", uuid: "u1"), Fixture.transcriptAssistant(messageID: "m1", uuid: "a1", blocks: [Fixture.toolUse("t1", "Bash", ["command": "ls"])])],
            [Fixture.transcriptToolResult(id: "t1", text: "a\nb")],
            [Fixture.transcriptUser("two", uuid: "u2"), Fixture.transcriptAssistant(messageID: "m2", uuid: "a2", blocks: [Fixture.toolUse("t2", "Bash", ["command": "sleep 9"])])],
            // The first turn's tool finishes late, and a line that is not JSON arrives.
            [Fixture.transcriptToolResult(id: "t2", text: "done"), "{not json"],
            [Fixture.transcriptUser("three", uuid: "u3"), Fixture.transcriptUser("[Request interrupted by user]", uuid: "int", time: "2026-10-17T10:00:09.000Z")],
        ]
        for (index, batch) in batches.enumerated() {
            #expect(check(&producer, &mirror, sequence: &sequence, lines(batch)), "batch \(index)")
        }
        #expect(mirror.unknownRecordCount == producer.unknownRecordCount)
    }

    @Test func aChangeMadeOnAnotherModelIsNotApplied() {
        var producer = TurnModel(source: .live)
        var mirror = TurnModel(source: .live)
        _ = producer.appendPendingUser(uuid: "u1", text: "one")
        mirror = producer
        var delta = producer.appendPendingUser(uuid: "u2", text: "two")
        let change = producer.growth(sequence: 2, entriesBefore: 1, turnsBefore: 1, delta: delta, hasOlder: false)
        // The mirror missed a change before this one.
        var behind = TurnModel(source: .live)
        let behindTook = behind.apply(change)
        #expect(!behindTook)
        #expect(behind.entries.isEmpty && behind.turns.isEmpty)
        let took = mirror.apply(change)
        #expect(took && equal(mirror, producer))
        // And the same change twice.
        let tookTwice = mirror.apply(change)
        #expect(!tookTwice)
        delta = ModelDelta()
        #expect(ModelChange(kind: .growth, sequence: 3, hasOlder: false, delta: delta).isEmpty)
    }

    @Test func aChangeThatEndsATurnAndAddsTwoMoreCarriesTheEndedTurn() {
        var producer = TurnModel(source: .sessionTranscript)
        var offset: UInt64 = 0
        func feed(_ lines: [String]) -> ModelDelta {
            var delta = ModelDelta()
            for line in lines {
                let bytes = Data(line.utf8)
                let made = producer.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
                delta.inserted += made.inserted
                delta.turnsChanged = delta.turnsChanged || made.turnsChanged
                offset += UInt64(bytes.count + 1)
            }
            return delta
        }
        _ = feed([Fixture.transcriptUser("one", uuid: "u1", time: "2026-10-17T10:00:00.000Z"),
                  Fixture.transcriptAssistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock("One.")], time: "2026-10-17T10:00:05.000Z"),
                  Fixture.transcriptUser("two", uuid: "u2", time: "2026-10-17T10:01:00.000Z"),
                  Fixture.transcriptAssistant(messageID: "m2", uuid: "a2", blocks: [Fixture.textBlock("Two.")], time: "2026-10-17T10:01:05.000Z")])
        var mirror = producer
        let entries = producer.entries.count, turns = producer.turns.count
        // One read: the second turn ends (its time grows), and two prompts arrive.
        let delta = feed([Fixture.transcriptAssistant(messageID: "m2b", uuid: "a2b", blocks: [Fixture.textBlock("Two, again.")], time: "2026-10-17T10:02:00.000Z"),
                          Fixture.transcriptUser("three", uuid: "u3", time: "2026-10-17T10:03:00.000Z"),
                          Fixture.transcriptUser("four", uuid: "u4", time: "2026-10-17T10:04:00.000Z")])
        let change = producer.growth(sequence: 2, entriesBefore: entries, turnsBefore: turns, delta: delta, hasOlder: false)
        #expect(change.turns.map(\.position).contains(turns - 1), "the turn that was newest travels with the change")
        let took = mirror.apply(change)
        #expect(took && mirror.turns == producer.turns && mirror.rowInputsEqual(producer))
        #expect(producer.turns[1].status == .ended)
    }

    @Test func aStatusWithNoEntryIsAChange() {
        var producer = TurnModel(source: .live)
        _ = producer.appendPendingUser(uuid: "u1", text: "go")
        var mirror = producer
        let status = producer.apply(Fixture.message(Fixture.line(["type": "system", "subtype": "status", "status": "compacting", "session_id": "s1"])))
        #expect(status.isEmpty, "no entry moved")
        let quiet = producer.growth(sequence: 2, entriesBefore: 1, turnsBefore: 1, delta: status, hasOlder: false)
        #expect(quiet.isEmpty)
        let change = producer.growth(sequence: 2, entriesBefore: 1, turnsBefore: 1, delta: status, hasOlder: false, activityChanged: true)
        #expect(!change.isEmpty)
        let took = mirror.apply(change)
        #expect(took && mirror.activity == "compacting")
    }

    @Test func aChangeCostsWhatItTouchedNotTheModel() {
        var producer = TurnModel(source: .sessionTranscript)
        var offset: UInt64 = 0
        for index in 0..<2_000 {
            for line in [Fixture.transcriptUser("p\(index)", uuid: "u\(index)"),
                         Fixture.transcriptAssistant(messageID: "m\(index)", uuid: "a\(index)", blocks: [Fixture.textBlock("Answer \(index)")])] {
                let bytes = Data(line.utf8)
                producer.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
                offset += UInt64(bytes.count + 1)
            }
        }
        let entries = producer.entries.count, turns = producer.turns.count
        let line = Fixture.transcriptAssistant(messageID: "mx", uuid: "ax", blocks: [Fixture.textBlock("More")])
        let bytes = Data(line.utf8)
        let delta = producer.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
        let change = producer.growth(sequence: 1, entriesBefore: entries, turnsBefore: turns, delta: delta, hasOlder: false)
        #expect(change.appended.count == 1 && change.updated.isEmpty)
        #expect(change.turns.count <= 2, "the newest turns only: \(change.turns.count)")
    }

    // MARK: A lens hands out changes in order

    private struct Tree {
        let root: URL
        var url: URL { root.appendingPathComponent("projects/-tmp-work/sess1.jsonl") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-change-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-tmp-work"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func file() throws -> ClaudeTranscriptFile {
            try #require(ClaudeTranscriptLocator.locate(sessionID: "sess1", configDirectory: root))
        }

        func append(_ text: String) throws {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
    }

    private func prompt(_ index: Int) -> String { Fixture.transcriptUser("prompt \(index)", uuid: "u\(index)") + "\n" }

    @Test func aLensNumbersItsChangesAndAMirrorFollowsThem() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.append((0..<5).map(prompt).joined())
        let lens = try #require(TranscriptLens(file: tree.file()))
        let first = await lens.coldOpenChange()
        #expect(first.kind == .replaced && first.sequence == 1)
        var mirror = try #require(first.model)

        try tree.append(prompt(5) + prompt(6))
        let growth = await lens.readGrowthChange()
        #expect(growth.kind == .growth && growth.sequence == 2)
        #expect(growth.appended.count == 2)
        let tookGrowth = mirror.apply(growth)
        #expect(tookGrowth)
        #expect(mirror.entries.map(\.id) == (0...6).map { "u\($0)" })

        // Nothing new: the number is not used.
        let none = await lens.readGrowthChange()
        #expect(none.isEmpty && none.sequence == 2)
        try tree.append(prompt(7))
        let next = await lens.readGrowthChange()
        let tookNext = mirror.apply(next)
        #expect(next.sequence == 3 && tookNext)

        // A snapshot takes the next number and replaces the mirror.
        let snapshot = await lens.snapshotChange()
        #expect(snapshot.kind == .replaced && snapshot.sequence == 4)
        #expect(snapshot.model?.entries == mirror.entries)
        await lens.close()
    }

    @Test func aFileThatWasReplacedComesBackAsAReplacement() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.append((0..<3).map(prompt).joined())
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpenChange()
        try Data().write(to: tree.url)
        try tree.append(Fixture.transcriptUser("fresh", uuid: "uf") + "\n")
        let restarted = await lens.readGrowthChange()
        #expect(restarted.kind == .replaced && restarted.sequence == 2)
        #expect(restarted.model?.entries.map(\.id) == ["uf"])
        await lens.close()
    }

    @Test func aChangeLostWithAStoppedFeedShowsInTheNextFeedsFirstRead() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.append(prompt(0))
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpenChange()
        // A read ran and its change never reached anyone (the feed was stopped, the view left).
        try tree.append(prompt(1))
        let lost = await lens.readGrowthChange()
        #expect(lost.sequence == 2 && !lost.isEmpty)

        // The file does not change again. The next feed's first read is empty, and says where the lens is.
        let feed = TranscriptGrowthFeed(file: try tree.file(), lens: lens, coalescing: 0.02, delivery: .changes)
        var iterator = feed.changes.makeAsyncIterator()
        feed.start()
        let first = await iterator.next()
        #expect(first?.isEmpty == true && first?.sequence == 2)
        feed.stopAndWait()
        await lens.close()
    }

    @Test func aFeedDeliversOneChangeAtATimeAndMergesWhatArrivesMeanwhile() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.append(prompt(0))
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpenChange()
        let feed = TranscriptGrowthFeed(file: try tree.file(), lens: lens, coalescing: 0.02, delivery: .changes)
        var iterator = feed.changes.makeAsyncIterator()
        feed.start()

        // Nothing changed when it began: the first read is delivered all the same, empty, with the lens's number (a receiver
        // that lost a change while a feed was stopped sees by it that it is behind).
        let hello = await iterator.next()
        #expect(hello?.isEmpty == true && hello?.sequence == 1)
        feed.acknowledge()
        try tree.append(prompt(1))
        let one = await iterator.next()
        #expect(one?.sequence == 2 && one?.appended.map(\.id) == ["u1"])

        // The consumer is busy: ten more writes land, and no read begins.
        for index in 2..<12 {
            try tree.append(prompt(index))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(150))
        let readsWhileBusy = feed.readCount
        #expect(readsWhileBusy == 2, "the start-up read and the one that found u1: \(readsWhileBusy)")

        // It takes the change and says so: everything written meanwhile arrives as one change.
        feed.acknowledge()
        let merged = await iterator.next()
        #expect(merged?.sequence == 3)
        #expect(merged?.appended.map(\.id) == (2..<12).map { "u\($0)" })
        feed.stopAndWait()
        await lens.close()
    }
}
