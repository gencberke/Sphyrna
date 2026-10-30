import AppKit
import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// A source of changes with no lens: a model that grows by hand and numbers the changes it makes, as `TranscriptLens` does.
struct SyntheticSource {
    private(set) var model: TurnModel
    private(set) var sequence = 0
    private var offset: UInt64 = 0

    init(source: TurnModel.Source = .live) { model = TurnModel(source: source) }

    mutating func snapshot(hasOlder: Bool = false) -> ModelChange {
        sequence += 1
        return model.snapshot(sequence: sequence, hasOlder: hasOlder)
    }

    /// Changes the model with `step` and returns the growth it made.
    mutating func grow(hasOlder: Bool = false, _ step: (inout TurnModel) -> ModelDelta) -> ModelChange {
        let entries = model.entries.count, turns = model.turns.count, activity = model.activity
        let delta = step(&model)
        let change = model.growth(sequence: sequence + 1, entriesBefore: entries, turnsBefore: turns, delta: delta, hasOlder: hasOlder,
                                  activityChanged: model.activity != activity)
        if !change.isEmpty { sequence += 1 }
        return change
    }

    mutating func message(_ message: StreamMessage) -> ModelChange {
        grow { $0.apply(message, at: Date(timeIntervalSince1970: 1_800_000_000)) }
    }

    mutating func prompt(_ id: String, _ text: String) -> ModelChange {
        grow { $0.appendPendingUser(uuid: id, text: text, at: Date(timeIntervalSince1970: 1_800_000_000)) }
    }

    /// Transcript lines, as one read of the file.
    mutating func lines(_ lines: [String], hasOlder: Bool = false) -> ModelChange {
        let start = offset
        var position = start
        let records = lines.map { line -> TranscriptLineRecord in
            let bytes = Data(line.utf8)
            defer { position += UInt64(bytes.count + 1) }
            return TranscriptLineRecord(offset: position, length: bytes.count, bytes: bytes)
        }
        offset = position
        return grow(hasOlder: hasOlder) { model in
            var delta = ModelDelta()
            for record in records {
                let made = model.apply(record: record)
                delta.inserted += made.inserted
                for id in made.updated where !delta.inserted.contains(id) && !delta.updated.contains(id) { delta.updated.append(id) }
                delta.turnsChanged = delta.turnsChanged || made.turnsChanged
            }
            return delta
        }
    }

    /// A model that starts with `lines` (a read of the newest turns), as a snapshot.
    mutating func start(with lines: [String], firstOffset: UInt64 = 0, hasOlder: Bool) -> ModelChange {
        model = ChatFixture.model(lines, firstOffset: firstOffset)
        offset = firstOffset + ChatFixture.size(of: lines)
        return snapshot(hasOlder: hasOlder)
    }

    /// Older turns read from `lines` and put in front of the model.
    mutating func older(_ lines: [String], hasOlder: Bool) -> ModelChange {
        model.prepend(ChatFixture.model(lines))
        sequence += 1
        return model.snapshot(sequence: sequence, kind: .older, hasOlder: hasOlder)
    }
}

extension ChatHosted {
    /// The presentation of a session driven by synthetic changes (no lens, no file): the rows it hands the stream equal a full
    /// rebuild, a change that is not the next is refused, and the reader's state belongs to the session and not to the view.
    @MainActor
    @Suite
    struct ChatPresentationTests {
        /// The stream holds the rows of a full rebuild, from the presentation's model or from `model` (the source's own).
        private func expectRows(_ presentation: ChatPresentation, _ stream: ChatHostedStream, _ note: String = "", _ model: TurnModel? = nil,
                                sourceLocation: SourceLocation = #_sourceLocation) {
            var input = presentation.buildInput()
            if let model { input.model = model }
            let expected = ChatRowBuilder.rows(input)
            #expect(stream.controller.rows == expected, "rows differ from a full rebuild \(note)", sourceLocation: sourceLocation)
        }

        /// One live turn as a series of changes.
        private func turn(_ number: Int, _ source: inout SyntheticSource, into presentation: ChatPresentation, _ stream: ChatHostedStream) {
            let n = "\(number)"
            var changes = [source.prompt("u" + n, "prompt " + n),
                           source.message(LiveScript.start("m" + n)),
                           source.message(LiveScript.block(0, ["type": "text", "text": ""]))]
            for word in ["Reading ", "the ", "files."] { changes.append(source.message(LiveScript.textDelta(0, word))) }
            changes += [source.message(LiveScript.stop(0)),
                        source.message(LiveScript.block(1, ["type": "tool_use", "id": .string("t" + n), "name": "Bash"])),
                        source.message(LiveScript.jsonDelta(1, "{\"command\":\"ls\"}")),
                        source.message(LiveScript.stop(1)),
                        source.message(LiveScript.toolResult("t" + n, "a\nb")),
                        source.message(LiveScript.start("m" + n + "b")),
                        source.message(LiveScript.block(0, ["type": "text", "text": ""])),
                        source.message(LiveScript.textDelta(0, "Done.")),
                        source.message(LiveScript.stop(0)),
                        source.message(LiveScript.result())]
            for change in changes {
                // A message that changes nothing the rows show (a message start, a block stop) is no change.
                let took = presentation.apply(change)
                #expect(took == !change.isEmpty)
                expectRows(presentation, stream, "after turn \(number)")
            }
        }

        @Test func syntheticChangesGiveTheRowsOfAFullRebuild() {
            ChatSessionMemoryStore.removeAll()
            let presentation = ChatPresentation(sessionID: "synthetic-1", workingDirectory: nil, isWorking: true)
            let stream = ChatHostedStream()
            presentation.attach(stream.controller)
            var source = SyntheticSource()
            let snapshotTaken = presentation.apply(source.snapshot())
            #expect(snapshotTaken)
            expectRows(presentation, stream, "snapshot")
            for number in 1...12 { turn(number, &source, into: presentation, stream) }
            #expect(stream.controller.rows.contains { $0.kind.tag == "fold" })

            // The reader's state, and the working state.
            presentation.toggle("fold:turn:u3")
            presentation.toggleFlag("t4", "all")
            presentation.setFullOutput(.text("everything"), for: "t5")
            expectRows(presentation, stream, "state")
            presentation.setViewMode(.verbose)
            expectRows(presentation, stream, "verbose")
            presentation.setWorking(false)
            expectRows(presentation, stream, "stopped")
            stream.controller.stop()
        }

        @Test func aChangeThatIsNotTheNextIsRefusedAndAsksForASnapshot() {
            ChatSessionMemoryStore.removeAll()
            let presentation = ChatPresentation(sessionID: "synthetic-2", workingDirectory: nil)
            var source = SyntheticSource()
            let stream = ChatHostedStream()
            presentation.attach(stream.controller)
            defer { stream.controller.stop() }
            var gaps = 0
            presentation.onGap = { gaps += 1 }
            let snapshotTaken = presentation.apply(source.snapshot())
            #expect(snapshotTaken)
            let one = source.prompt("u1", "one")
            let two = source.prompt("u2", "two")
            let three = source.prompt("u3", "three")
            // Two arrives before one: neither is taken until a snapshot says where things are.
            #expect(!presentation.apply(two))
            #expect(gaps == 1)
            #expect(presentation.model.entries.isEmpty)
            #expect(presentation.apply(one))
            #expect(!presentation.apply(one), "the same change twice")
            #expect(presentation.apply(two) && presentation.apply(three))
            #expect(presentation.model.entries.map(\.id) == ["u1", "u2", "u3"])
            // A snapshot that is older than what the presentation has is not taken.
            let oldTaken = presentation.apply(source.snapshot().withSequence(1))
            #expect(!oldTaken)
            // A change with nothing in it is not a change.
            let rebuilds = presentation.rebuilds
            let emptyTaken = presentation.apply(source.grow { _ in ModelDelta() })
            #expect(!emptyTaken)
            #expect(presentation.rebuilds == rebuilds)
        }

        @Test func theSessionKeepsItsStateWhileNoViewIsAttached() {
            ChatSessionMemoryStore.removeAll()
            let presentation = ChatPresentation(sessionID: "synthetic-3", workingDirectory: nil, isWorking: true)
            var source = SyntheticSource()
            let first = ChatHostedStream()
            presentation.attach(first.controller)
            let snapshotTaken = presentation.apply(source.snapshot())
            #expect(snapshotTaken)
            let stream = first
            for number in 1...3 { turn(number, &source, into: presentation, stream) }
            presentation.toggle("fold:turn:u2")
            presentation.cycleViewMode()
            let derived = presentation.rebuilds
            presentation.detach()
            first.controller.stop()

            // The view is gone: changes are taken and no rows are derived.
            for number in 4...6 {
                for change in [source.prompt("u\(number)", "prompt"), source.message(LiveScript.start("m\(number)")),
                               source.message(LiveScript.block(0, ["type": "text", "text": ""])), source.message(LiveScript.textDelta(0, "Hi")),
                               source.message(LiveScript.stop(0)), source.message(LiveScript.result())] {
                    let took = presentation.apply(change)
                    #expect(took == !change.isEmpty)
                }
            }
            #expect(presentation.rebuilds == derived)
            #expect(presentation.model.turns.count == 6)

            // A new view shows the session as it is, with the folds and the view the reader left.
            let second = ChatHostedStream()
            presentation.attach(second.controller)
            expectRows(presentation, second, "second view")
            #expect(presentation.viewMode == .thinking)
            #expect(second.controller.rows.first { $0.id == "fold:turn:u2" }?.open == true)
            #expect(ChatSessionMemoryStore.memory(for: "synthetic-3")?.viewMode == .thinking)
            second.controller.stop()
        }

        // MARK: Lost, late and quiet changes

        @Test func anEmptyChangeAheadOfThePresentationMeansAChangeWasLost() {
            ChatSessionMemoryStore.removeAll()
            let presentation = ChatPresentation(sessionID: "synthetic-4", workingDirectory: nil)
            let stream = ChatHostedStream()
            presentation.attach(stream.controller)
            defer { stream.controller.stop() }
            var source = SyntheticSource(source: .sessionTranscript)
            var gaps = 0
            presentation.onGap = { gaps += 1 }
            _ = source.lines(ChatFixture.turn(1))
            let snapshot = presentation.apply(source.snapshot())
            #expect(snapshot)
            let rebuilds = presentation.rebuilds

            // A feed that started again and found nothing, with nothing lost: it says where the source is, and it is where we are.
            let quiet = presentation.apply(ModelChange(kind: .growth, sequence: source.sequence, hasOlder: false))
            #expect(!quiet && gaps == 0 && presentation.rebuilds == rebuilds)

            // A change was made and never reached us (it was in flight when the feed stopped).
            _ = source.lines([ChatFixture.user("last words", uuid: "u2", at: 40),
                              ChatFixture.assistant("m2", uuid: "a2", blocks: [ChatFixture.text("The final answer.")], at: 41)])
            let hello = presentation.apply(ModelChange(kind: .growth, sequence: source.sequence, hasOlder: false))
            #expect(!hello && gaps == 1 && presentation.isBehind)
            #expect(presentation.rebuilds == rebuilds, "nothing is drawn, and the last activity stays")

            // The snapshot that answers it brings the rows back.
            let recovered = presentation.apply(source.snapshot())
            #expect(recovered && !presentation.isBehind)
            expectRows(presentation, stream, "snapshot", source.model)
            #expect(stream.controller.rows.contains { $0.id == "a2" || $0.id == "m2#0" || $0.kind.tag == "answer" })
        }

        @Test func aRefusedChangeStaysBehindUntilASnapshotReachesIt() {
            ChatSessionMemoryStore.removeAll()
            let presentation = ChatPresentation(sessionID: "synthetic-5", workingDirectory: nil)
            var source = SyntheticSource(source: .sessionTranscript)
            let first = source.snapshot()
            let second = source.lines(ChatFixture.turn(1))
            let early = source.snapshot()
            let ahead = source.lines(ChatFixture.turn(2, start: 10))
            let taken = presentation.apply(first)
            #expect(taken)
            // The newest growth arrives while a snapshot is on its way: it is refused, and the snapshot (older than it) is not enough.
            let refused = presentation.apply(ahead)
            #expect(!refused && presentation.isBehind)
            let tookEarly = presentation.apply(early)
            #expect(tookEarly && presentation.isBehind)
            let tookNext = presentation.apply(source.snapshot())
            #expect(tookNext && !presentation.isBehind)
            _ = second
        }

        @Test func anOlderChangeThatSkippedGrowthBuildsEveryTurnAgain() {
            ChatSessionMemoryStore.removeAll()
            let presentation = ChatPresentation(sessionID: "synthetic-6", workingDirectory: nil)
            let stream = ChatHostedStream()
            presentation.attach(stream.controller)
            defer { stream.controller.stop() }
            var source = SyntheticSource(source: .sessionTranscript)
            let older = (0..<4).flatMap { ChatFixture.turn($0, tools: [ChatFixture.bash("make \($0)")], start: $0 * 20) }
            var newer = [ChatFixture.user("go", uuid: "ua", at: 100),
                         ChatFixture.assistant("ma", uuid: "ca", blocks: [ChatFixture.tool("ta", "Bash", ["command": "sleep 9"])], at: 101)]
            newer += ChatFixture.turn(9, tools: [ChatFixture.bash("last")], start: 120)
            let start = presentation.apply(source.start(with: newer, firstOffset: ChatFixture.size(of: older), hasOlder: true))
            #expect(start)
            expectRows(presentation, stream, "start", source.model)

            // The first turn's tool finishes late, in a change that never reaches the presentation; the older page does.
            _ = source.lines([ChatFixture.result("ta", "finally", at: 130)])
            let page = presentation.apply(source.older(older, hasOlder: false))
            #expect(page)
            expectRows(presentation, stream, "older page after a missed change", source.model)
            guard case let .tool(entry)? = stream.controller.rows.first(where: { $0.id == "ta" })?.kind, case let .tool(call) = entry.body else {
                Issue.record("no tool row")
                return
            }
            #expect(call.status == .succeeded)
        }

        @Test func aStatusWithNoEntryIsAChange() {
            ChatSessionMemoryStore.removeAll()
            let presentation = ChatPresentation(sessionID: "synthetic-7", workingDirectory: nil, isWorking: true)
            let stream = ChatHostedStream()
            presentation.attach(stream.controller)
            defer { stream.controller.stop() }
            var source = SyntheticSource()
            let snapshot = presentation.apply(source.snapshot())
            let prompt = presentation.apply(source.prompt("u1", "go"))
            #expect(snapshot && prompt)
            guard case let .live(before)? = stream.controller.rows.last?.kind else { Issue.record("no live row"); return }
            #expect(before.label != "Compacting")
            let status = source.message(LiveScript.message(["type": "system", "subtype": "status", "status": "compacting", "session_id": "s1"]))
            #expect(!status.isEmpty)
            let taken = presentation.apply(status)
            #expect(taken)
            guard case let .live(after)? = stream.controller.rows.last?.kind else { Issue.record("no live row"); return }
            #expect(after.label == "Compacting")
            expectRows(presentation, stream, "status", source.model)
        }

        #if DEBUG // the row check is debug only
        /// Two presentations checked at the same time, each by its own verifier (`ChatRowVerifier`), as two suites that verify
        /// rows run side by side. The check used to be one process-wide switch and report (`verifiesRows`/`onMismatch`): the
        /// suite that finished first turned it off for the other, or took its reports. A stream that drifts from its
        /// presentation reports to its own verifier, and the other one's stays clean, and checked.
        @Test func twoPresentationsCheckedAtOnceReportEachToItsOwnVerifier() throws {
            let first = ChatPresentation(sessionID: "verify-first-\(UUID())", workingDirectory: nil)
            let second = ChatPresentation(sessionID: "verify-second-\(UUID())", workingDirectory: nil)
            let firstStream = ChatHostedStream(), secondStream = ChatHostedStream()
            defer { firstStream.controller.stop(); secondStream.controller.stop() }
            let firstCheck = ChatRowCheck(), secondCheck = ChatRowCheck()
            firstCheck.watch(first)
            secondCheck.watch(second)
            first.attach(firstStream.controller)
            second.attach(secondStream.controller)
            var firstSource = SyntheticSource(), secondSource = SyntheticSource()
            #expect(first.apply(firstSource.snapshot()) && second.apply(secondSource.snapshot()))
            for number in 1...3 {
                turn(number, &firstSource, into: first, firstStream)
                turn(number, &secondSource, into: second, secondStream)
            }
            #expect(firstCheck.mismatches.isEmpty && secondCheck.mismatches.isEmpty,
                    "\(firstCheck.mismatches) \(secondCheck.mismatches)")

            // The first stream's first two rows trade places behind its presentation; the next rebuild of each is checked.
            var drifted = firstStream.controller.rows
            try #require(drifted.count > 2, "rows: \(drifted.count)")
            drifted.swapAt(0, 1)
            firstStream.controller.apply(drifted, hasOlder: false)
            first.toggle("no-such-row")
            second.toggle("no-such-row")

            #expect(firstCheck.mismatches.count == 1 && firstCheck.mismatches.first?.contains(first.sessionID) == true,
                    "the drift is reported to the first presentation's own verifier: \(firstCheck.mismatches)")
            secondCheck.expectClean("the second presentation, checked beside the first")
            #expect(firstCheck.checks == secondCheck.checks, "both checked every rebuild: \(firstCheck.checks), \(secondCheck.checks)")
        }
        #endif
    }
}

extension ModelChange {
    /// The same change with another sequence number (a test of an old one).
    func withSequence(_ value: Int) -> ModelChange {
        var copy = self
        copy.sequence = value
        return copy
    }
}
