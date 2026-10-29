import AppKit
import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// A producer model, the changes it makes, and a presentation that takes them: the whole path a source (the transcript lens, later
/// the chat driver) walks. After each step the stream holds the rows `ChatRowBuilder` derives from the producer's model, and the
/// presentation's copy of that model equals it. A change that is lost or refused is answered the way the transcript adapter does,
/// with a snapshot.
@MainActor
struct RoundTrip {
    var source: SyntheticSource
    let presentation: ChatPresentation
    let stream: ChatHostedStream
    private let gap = GapFlag()
    private(set) var mismatches = 0
    /// What the source says about older turns, in the changes it makes next.
    var hasOlder = false
    /// A change was made and not delivered.
    private(set) var outstanding = false

    final class GapFlag { var raised = false }

    init(id: String, source kind: TurnModel.Source = .sessionTranscript, working: Bool = false) {
        ChatSessionMemoryStore.removeAll()
        source = SyntheticSource(source: kind)
        presentation = ChatPresentation(sessionID: id, workingDirectory: nil, isWorking: working)
        stream = ChatHostedStream()
        presentation.attach(stream.controller)
        let flag = gap
        presentation.onGap = { flag.raised = true }
        #if DEBUG
        ChatPresentation.verifiesRows = true
        ChatPresentation.onMismatch = { report in Issue.record("\(report)") }
        #endif
    }

    func finish() {
        #if DEBUG
        ChatPresentation.verifiesRows = false
        ChatPresentation.onMismatch = nil
        #endif
        stream.controller.stop()
    }

    // MARK: Changes

    mutating func start(_ lines: [String], firstOffset: UInt64 = 0, hasOlder: Bool, _ note: String = "start") {
        self.hasOlder = hasOlder
        let change = source.start(with: lines, firstOffset: firstOffset, hasOlder: hasOlder)
        deliver(change, note)
    }

    mutating func grow(_ lines: [String], _ note: String) {
        let change = source.lines(lines, hasOlder: hasOlder)
        deliver(change, note)
    }

    /// A growth that never reaches the presentation.
    mutating func lose(_ lines: [String]) {
        _ = source.lines(lines, hasOlder: hasOlder)
        outstanding = true
    }

    mutating func older(_ lines: [String], hasOlder: Bool, _ note: String = "older page") {
        self.hasOlder = hasOlder
        let change = source.older(lines, hasOlder: hasOlder)
        deliver(change, note)
    }

    mutating func replace(_ lines: [String], hasOlder: Bool, _ note: String = "replaced") {
        self.hasOlder = hasOlder
        let change = source.start(with: lines, hasOlder: hasOlder)
        deliver(change, note)
    }

    mutating func deliver(_ change: ModelChange, _ note: String) {
        presentation.apply(change)
        var rounds = 0
        while gap.raised, rounds < 3 {
            gap.raised = false
            rounds += 1
            presentation.apply(source.snapshot(hasOlder: hasOlder))
        }
        outstanding = outstanding && !presentation.model.rowInputsEqual(source.model)
        check(note)
    }

    /// Something the reader did.
    mutating func reader(_ note: String, _ action: (ChatPresentation) -> Void) {
        action(presentation)
        check(note)
    }

    // MARK: Checks

    mutating func check(_ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
        if outstanding { return }
        var input = presentation.buildInput()
        input.model = source.model
        let expected = ChatRowBuilder.rows(input)
        let rows = stream.controller.rows
        if rows != expected {
            mismatches += 1
            let first = zip(rows, expected).enumerated().first { $1.0 != $1.1 }?.offset ?? min(rows.count, expected.count)
            Issue.record("rows differ from a full rebuild of the producer's model (\(note)) at \(first): \(rows.count) shown, \(expected.count) expected, \(rows.dropFirst(first).prefix(3).map(\.id)) against \(expected.dropFirst(first).prefix(3).map(\.id))",
                         sourceLocation: sourceLocation)
        }
        if !presentation.model.rowInputsEqual(source.model) {
            mismatches += 1
            Issue.record("the presentation's copy of the model differs from the producer's (\(note))", sourceLocation: sourceLocation)
        }
        if presentation.hasOlder != hasOlder {
            mismatches += 1
            Issue.record("hasOlder is \(presentation.hasOlder), the source said \(hasOlder) (\(note))", sourceLocation: sourceLocation)
        }
    }
}

extension ChatHosted {
    /// producer model -> `ModelChange` -> receiver -> rows, against the rows of the producer's model.
    @MainActor
    @Suite
    struct ChatRoundTripTests {
        private static func history(_ range: Range<Int>) -> [String] {
            range.flatMap { ChatFixture.turn($0, tools: [ChatFixture.bash("make \($0)")], start: ($0 * 20) % 3000) }
        }

        @Test func growthThatEndsATurnAndAddsTwoMoreIsOneChange() {
            var trip = RoundTrip(id: "trip-1")
            defer { trip.finish() }
            trip.start(Self.history(0..<3), hasOlder: false)
            // One read: the newest turn ends, and two prompts arrive.
            trip.grow([ChatFixture.user("four", uuid: "u40", at: 100), ChatFixture.user("five", uuid: "u50", at: 110),
                       ChatFixture.assistant("m50", uuid: "a50", blocks: [ChatFixture.text("Five.")], at: 111)], "two prompts")
            #expect(trip.presentation.model.turns.map(\.status).dropLast() == trip.source.model.turns.map(\.status).dropLast())
            trip.grow([ChatFixture.user("six", uuid: "u60", at: 120)], "a third")
            #expect(trip.mismatches == 0)
        }

        @Test func olderPagesAndTheEndOfHistoryRoundTrip() {
            var trip = RoundTrip(id: "trip-2")
            defer { trip.finish() }
            trip.start(Self.history(8..<12), firstOffset: ChatFixture.size(of: Self.history(0..<8)), hasOlder: true)
            trip.grow(ChatFixture.turn(20, tools: [ChatFixture.bash("live")], start: 300), "growth")
            trip.older(Self.history(6..<8), hasOlder: true)
            trip.grow(ChatFixture.turn(21, start: 320), "growth between pages")
            trip.older(Self.history(2..<6), hasOlder: true)
            trip.older(Self.history(0..<2), hasOlder: false, "the last page")
            #expect(trip.presentation.hasOlder == false)
            #expect(trip.stream.controller.rows.first?.kind.tag == "start")
            #expect(trip.mismatches == 0)
        }

        @Test func anOlderPageAfterAMissedGrowthRoundTrips() {
            var trip = RoundTrip(id: "trip-3")
            defer { trip.finish() }
            let open = [ChatFixture.user("go", uuid: "ua", at: 100),
                        ChatFixture.assistant("ma", uuid: "ca", blocks: [ChatFixture.tool("ta", "Bash", ["command": "sleep 9"])], at: 101)]
                + ChatFixture.turn(9, tools: [ChatFixture.bash("last")], start: 120)
            trip.start(open, firstOffset: ChatFixture.size(of: Self.history(0..<4)), hasOlder: true)
            trip.lose([ChatFixture.result("ta", "finally", at: 130)])
            trip.older(Self.history(0..<4), hasOlder: false, "page after the missed growth")
            #expect(!trip.outstanding)
            #expect(trip.mismatches == 0)
        }

        @Test func aReplacedModelAndALostChangeRoundTrip() {
            var trip = RoundTrip(id: "trip-4")
            defer { trip.finish() }
            trip.start(Self.history(0..<3), hasOlder: false)
            trip.grow(ChatFixture.turn(7, start: 200), "growth")
            trip.lose(ChatFixture.turn(8, start: 220))
            trip.grow(ChatFixture.turn(9, start: 240), "after a lost change")
            #expect(!trip.outstanding)
            trip.replace(Self.history(30..<33), hasOlder: true)
            trip.reader("fold") { $0.toggle("fold:turn:u31") }
            #expect(trip.mismatches == 0)
        }

        @Test func aLiveStreamRoundTripsWithItsStatus() {
            var trip = RoundTrip(id: "trip-5", source: .live, working: true)
            defer { trip.finish() }
            let snapshot = trip.source.snapshot()
            trip.deliver(snapshot, "snapshot")
            for message in [LiveScript.start("m1"), LiveScript.block(0, ["type": "text", "text": ""]), LiveScript.textDelta(0, "Hello"),
                            LiveScript.stop(0), LiveScript.message(["type": "system", "subtype": "status", "status": "compacting", "session_id": "s1"]),
                            LiveScript.result()] {
                let change = trip.source.grow { $0.apply(message, at: Date(timeIntervalSince1970: 1_800_000_000)) }
                trip.deliver(change, "message")
            }
            let prompt = trip.source.prompt("u1", "go")
            trip.deliver(prompt, "prompt")
            #expect(trip.mismatches == 0)
        }

        /// Overlapping reads leave two turns with one id. The reference builder and the incremental path pick the same one.
        @Test func aTurnIdThatIsThereTwiceIsTheSameTurnToBothPaths() {
            let lines = ChatFixture.turn(1, tools: [ChatFixture.bash("a")]) + ChatFixture.turn(2, tools: [ChatFixture.bash("b")], start: 10)
            var session = RowsSession(source: .sessionTranscript)
            session.model = ChatFixture.model(lines)
            session.model.prepend(ChatFixture.model(lines))
            #expect(Set(session.model.turns.map(\.id)).count < session.model.turns.count, "the ids are there twice")
            session.isWorking = true
            session.sync(.replaced, "duplicates")
            session.sync(.growth(session.append(ChatFixture.turn(2, start: 30).suffix(1))), "growth of the duplicated turn")
            #expect(session.mismatches == 0)
        }

        /// The window is covered (the feed stops) while a read is in flight: its change is lost, the file never changes again, and the
        /// view still ends with the last words.
        @Test func aChangeLostWhenTheFeedStopsIsRecoveredWhenItStartsAgain() async throws {
            ChatSessionMemoryStore.removeAll()
            let profile = try ChatTranscriptModelTests.Profile(lines: ChatFixture.turn(1, tools: [ChatFixture.bash("ls")]))
            defer { profile.remove() }
            let model = ChatTranscriptModel(sessionID: profile.id, configDirectory: profile.root, workingDirectory: nil)
            model.setOnScreen(true)
            model.setWindowVisible(true)
            while model.phase == .resolving { try await Task.sleep(for: .milliseconds(5)) }
            model.setWindowVisible(true)
            try await Task.sleep(for: .milliseconds(150))
            #expect(model.isFeeding)

            model.setWindowVisible(false)
            #expect(!model.isFeeding)
            try profile.append([ChatFixture.user("last words", uuid: "u2", at: 40),
                                ChatFixture.assistant("m2", uuid: "a2", blocks: [ChatFixture.text("The final answer.")], at: 41)])
            let lens = try #require(model.lensForTesting)
            let lost = await lens.readGrowthChange()
            #expect(!lost.isEmpty, "the read happened and nobody got its change")

            // The file stays as it is.
            model.setWindowVisible(true)
            var waited = 0
            func shown() -> Bool {
                model.model.entries.contains { entry in
                    if case let .assistantText(text) = entry.body { text.text == "The final answer." } else { false }
                }
            }
            while !shown(), waited < 300 {
                try await Task.sleep(for: .milliseconds(20))
                waited += 1
            }
            #expect(shown(), "the last answer reached the view")
            #expect(model.controller.rows == ChatRowBuilder.rows(model.presentation.buildInput()))
            #expect(model.controller.rows.contains { $0.kind.tag == "answer" })
            model.close()
        }

        /// A seeded run of every kind of change through the whole path.
        @Test(arguments: [11, 12, 13, 14, 15, 16]) func aMixedRunRoundTrips(seed: Int) {
            var generator = SeededGenerator(seed: UInt64(seed))
            var trip = RoundTrip(id: "trip-mix-\(seed)")
            defer { trip.finish() }
            let total = 24
            var oldest = 18
            trip.start(Self.history(oldest..<total), firstOffset: ChatFixture.size(of: Self.history(0..<oldest)), hasOlder: true)
            var turn = 1_000
            var pending: [String] = []
            var second = 0
            func tick() -> Int { second += 1; return second % 3000 }
            for step in 0..<120 {
                switch Int.random(in: 0..<14, using: &generator) {
                case 0...2:
                    turn += 1
                    let id = "t\(turn)"
                    var lines = [ChatFixture.user("prompt \(turn)", uuid: "u\(turn)", at: tick()),
                                 ChatFixture.assistant("m\(turn)", uuid: "c\(turn)", blocks: [ChatFixture.tool(id, "Bash", ["command": .string("run \(turn)")])], at: tick())]
                    if Bool.random(using: &generator) { lines.append(ChatFixture.result(id, "ok", at: tick())) } else { pending.append(id) }
                    trip.grow(lines, "step \(step): turn")
                case 3:
                    // Two prompts in one read.
                    turn += 2
                    trip.grow([ChatFixture.user("a", uuid: "u\(turn - 1)", at: tick()), ChatFixture.user("b", uuid: "u\(turn)", at: tick())], "step \(step): two prompts")
                case 4:
                    guard let id = pending.popLast() else { continue }
                    trip.grow([ChatFixture.result(id, "late", at: tick())], "step \(step): late result")
                case 5:
                    turn += 1
                    trip.lose([ChatFixture.assistant("l\(turn)", uuid: "lc\(turn)", blocks: [ChatFixture.text("Lost \(turn).")], at: tick())])
                case 6:
                    guard oldest > 0 else { continue }
                    let from = max(0, oldest - 3)
                    trip.older(Self.history(from..<oldest), hasOlder: from > 0, "step \(step): older \(from)")
                    oldest = from
                case 7:
                    trip.grow([ChatFixture.user("[Request interrupted by user]", uuid: "int\(step)", at: tick())], "step \(step): interrupt")
                case 8...9:
                    guard let row = trip.stream.controller.rows.randomElement(using: &generator) else { continue }
                    trip.reader("step \(step): toggle \(row.id)") { $0.toggle(row.id) }
                case 10:
                    guard let row = trip.stream.controller.rows.filter({ $0.kind.tag == "tool" || $0.kind.tag == "prose" }).randomElement(using: &generator) else { continue }
                    trip.reader("step \(step): flag") { $0.toggleFlag(row.id, "all") }
                case 11:
                    trip.reader("step \(step): working") { $0.setWorking(!$0.isWorking) }
                case 12:
                    trip.reader("step \(step): view") { $0.cycleViewMode() }
                default:
                    turn += 1
                    trip.grow([ChatFixture.assistant("w\(turn)", uuid: "wc\(turn)", blocks: [ChatFixture.text("Words \(turn).")], at: tick())], "step \(step): words")
                }
                if trip.mismatches > 0 { break }
            }
            #expect(trip.mismatches == 0)
        }
    }
}
