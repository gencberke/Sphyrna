import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI

/// A model and the rows `ChatRowStore` keeps for it, checked against the rows derived from scratch after every change.
/// `flat` is the list the stream would hold: it takes what the store says (all rows, or patches) the way the controller does.
@MainActor
struct RowsSession {
    var model: TurnModel
    var store = ChatRowStore()
    private(set) var flat: [ChatRow] = []
    var mode = ChatViewMode.normal
    var toggled = Set<String>()
    var flags: [String: Set<String>] = [:]
    var fullOutputs: [String: ChatFullOutput] = [:]
    var isWorking = false
    var hasOlder = false
    var workingDirectory: String?
    private var liveStarts: [String: Date] = [:]
    private var ticks = 0
    private var offset: UInt64 = 0
    /// What the last change did: everything was replaced, or these stretches.
    private(set) var lastWasAll = false
    private(set) var lastPatches: [ChatRowsPatch] = []
    private(set) var mismatches = 0

    init(source: TurnModel.Source) {
        model = TurnModel(source: source)
    }

    /// Rows the last change removed or added (0 for a change that touched nothing).
    var lastTouchedRows: Int { lastWasAll ? flat.count : lastPatches.reduce(0) { $0 + max($1.removed, $1.rows.count) } }

    /// Appends transcript lines to a transcript model, as a read of the file would, and returns what they touched.
    mutating func append(_ lines: [String]) -> ModelDelta {
        var delta = ModelDelta()
        for line in lines {
            let bytes = Data(line.utf8)
            let made = model.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
            delta.inserted += made.inserted
            for id in made.updated where !delta.inserted.contains(id) && !delta.updated.contains(id) { delta.updated.append(id) }
            delta.turnsChanged = delta.turnsChanged || made.turnsChanged
            offset += UInt64(bytes.count + 1)
        }
        return delta
    }

    /// Gives the store the model as it is and checks the result.
    @discardableResult
    mutating func sync(_ cause: ChatRowStore.Cause = .state, _ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        ticks += 1
        if isWorking, let turn = model.turns.last, turn.startedAt == nil, liveStarts[turn.id] == nil {
            liveStarts[turn.id] = Date(timeIntervalSince1970: 1_800_000_000 + Double(ticks))
        }
        let input = ChatBuildInput(model: model, mode: mode, toggled: toggled, flags: flags, fullOutputs: fullOutputs, isWorking: isWorking,
                                   hasOlder: hasOlder, workingDirectory: workingDirectory, liveStarts: liveStarts,
                                   lastActivity: Date(timeIntervalSince1970: 1_800_000_000 + Double(ticks)))
        switch store.update(input, cause: cause) {
        case let .all(rows):
            flat = rows
            lastWasAll = true
            lastPatches = []
        case let .patches(patches):
            for patch in patches.reversed() { flat.replaceSubrange(patch.start..<(patch.start + patch.removed), with: patch.rows) }
            lastWasAll = false
            lastPatches = patches
        }
        let expected = ChatRowBuilder.rows(input)
        let same = flat == expected && store.rows == expected
        if !same {
            mismatches += 1
            let ids = flat.map(\.id), want = expected.map(\.id)
            let first = zip(flat, expected).enumerated().first { $1.0 != $1.1 }?.offset ?? min(flat.count, expected.count)
            Issue.record("rows differ from a full rebuild \(note) at \(first): have \(ids.count) rows (\(ids.dropFirst(first).prefix(4))), want \(want.count) (\(want.dropFirst(first).prefix(4))); store \(store.rows == expected ? "equal" : "differs")",
                         sourceLocation: sourceLocation)
        }
        return same
    }
}

/// Live-stream messages as the CLI sends them.
enum LiveScript {
    static func message(_ value: JSONValue) -> StreamMessage { try! StreamMessage(line: Data(ChatFixture.line(value).utf8)) }

    static func partial(_ event: JSONValue) -> StreamMessage {
        message(["type": "stream_event", "event": event, "session_id": "s1", "parent_tool_use_id": .null])
    }

    static func start(_ id: String) -> StreamMessage { partial(["type": "message_start", "message": ["id": .string(id), "model": "m"]]) }
    static func block(_ index: Int, _ kind: JSONValue) -> StreamMessage { partial(["type": "content_block_start", "index": .number(Double(index)), "content_block": kind]) }
    static func textDelta(_ index: Int, _ text: String) -> StreamMessage {
        partial(["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "text_delta", "text": .string(text)]])
    }
    static func thinkingDelta(_ index: Int, _ text: String) -> StreamMessage {
        partial(["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "thinking_delta", "thinking": .string(text)]])
    }
    static func jsonDelta(_ index: Int, _ text: String) -> StreamMessage {
        partial(["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "input_json_delta", "partial_json": .string(text)]])
    }
    static func stop(_ index: Int) -> StreamMessage { partial(["type": "content_block_stop", "index": .number(Double(index))]) }
    static func end() -> StreamMessage { partial(["type": "message_stop"]) }

    static func toolResult(_ id: String, _ text: String, isError: Bool = false) -> StreamMessage {
        message(["type": "user", "uuid": .string("r-" + id), "session_id": "s1", "parent_tool_use_id": .null,
                 "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": .string(text),
                                                         "is_error": .bool(isError)]]]])
    }

    static func result(terminalReason: String = "completed") -> StreamMessage {
        message(["type": "result", "subtype": "success", "is_error": false, "result": "done", "duration_ms": 4200, "num_turns": 1,
                 "session_id": "s1", "terminal_reason": .string(terminalReason), "total_cost_usd": 0.1,
                 "usage": ["input_tokens": 1, "output_tokens": 1]])
    }
}

@MainActor
struct ChatRowStoreTests {
    /// A message of the live stream.
    private static func live(_ session: inout RowsSession, _ message: StreamMessage, _ note: String = "") {
        let delta = session.model.apply(message, at: Date(timeIntervalSince1970: 1_800_000_000))
        session.sync(.growth(delta), note)
    }

    /// One turn of the live stream, a step at a time: your message, thinking, text, a tool, its result, the answer.
    private static func liveTurn(_ session: inout RowsSession, _ number: Int, settle: Bool = true) {
        let n = "\(number)"
        let delta = session.model.appendPendingUser(uuid: "u" + n, text: "prompt " + n, at: Date(timeIntervalSince1970: 1_800_000_000))
        session.sync(.growth(delta), "prompt \(n)")
        Self.live(&session, LiveScript.start("m" + n + "a"), "message start")
        Self.live(&session, LiveScript.block(0, ["type": "thinking", "thinking": ""]))
        Self.live(&session, LiveScript.thinkingDelta(0, "**Looking** at the files."))
        Self.live(&session, LiveScript.stop(0))
        Self.live(&session, LiveScript.block(1, ["type": "text", "text": ""]))
        for word in ["I'll ", "look ", "at ", "it."] { Self.live(&session, LiveScript.textDelta(1, word), "text growth") }
        Self.live(&session, LiveScript.stop(1))
        Self.live(&session, LiveScript.block(2, ["type": "tool_use", "id": .string("t" + n + "a"), "name": "Bash"]), "tool start")
        Self.live(&session, LiveScript.jsonDelta(2, "{\"command\":"))
        Self.live(&session, LiveScript.jsonDelta(2, "\"ls\"}"))
        Self.live(&session, LiveScript.stop(2))
        Self.live(&session, LiveScript.end())
        Self.live(&session, LiveScript.toolResult("t" + n + "a", "file1\nfile2"), "tool finish")
        Self.live(&session, LiveScript.start("m" + n + "b"))
        Self.live(&session, LiveScript.block(0, ["type": "tool_use", "id": .string("t" + n + "b"), "name": "Read"]), "second tool")
        Self.live(&session, LiveScript.jsonDelta(0, "{\"file_path\":\"/p/a.swift\"}"))
        Self.live(&session, LiveScript.stop(0))
        Self.live(&session, LiveScript.end())
        Self.live(&session, LiveScript.toolResult("t" + n + "b", "1\tline"), "second tool finish")
        Self.live(&session, LiveScript.start("m" + n + "c"))
        Self.live(&session, LiveScript.block(0, ["type": "text", "text": ""]))
        Self.live(&session, LiveScript.textDelta(0, "Done with " + n + "."), "answer")
        Self.live(&session, LiveScript.stop(0))
        Self.live(&session, LiveScript.end())
        if settle { Self.live(&session, LiveScript.result(), "turn settles") }
    }

    // MARK: Live

    @Test func aLiveSessionGrowsLikeAFullRebuild() {
        var session = RowsSession(source: .live)
        session.isWorking = true
        Self.liveTurn(&session, 1)
        #expect(session.mismatches == 0)
        session.isWorking = false
        session.sync(.state, "stopped working")
        Self.liveTurn(&session, 2, settle: false)
        session.isWorking = true
        Self.liveTurn(&session, 3)
        #expect(session.mismatches == 0)
        #expect(session.flat.contains { $0.kind.tag == "fold" })
    }

    @Test func aGrowingTurnReplacesOnlyItsOwnRows() {
        var session = RowsSession(source: .live)
        session.isWorking = true
        for number in 1...30 { Self.liveTurn(&session, number) }
        let before = session.flat.count
        let delta = session.model.appendPendingUser(uuid: "u31", text: "again", at: Date(timeIntervalSince1970: 1_800_000_000))
        session.sync(.growth(delta))
        #expect(!session.lastWasAll)
        for word in ["a", "b", "c"] {
            Self.live(&session, LiveScript.start("x" + word))
            Self.live(&session, LiveScript.block(0, ["type": "text", "text": ""]))
            Self.live(&session, LiveScript.textDelta(0, word))
            #expect(!session.lastWasAll)
            // The new turn and the one before it (it settled into its fold) are all that can change.
            #expect(session.lastTouchedRows <= 12, "touched \(session.lastTouchedRows) of \(session.flat.count) rows")
            Self.live(&session, LiveScript.stop(0))
            Self.live(&session, LiveScript.end())
        }
        #expect(session.flat.count > before)
        #expect(session.mismatches == 0)
        // Every row of an old turn is the value it was.
        #expect(session.lastPatches.allSatisfy { $0.start >= before - 12 })
    }

    @Test func anInterruptedLiveTurnAndTheNextOne() {
        var session = RowsSession(source: .live)
        session.isWorking = true
        Self.liveTurn(&session, 1)
        let delta = session.model.appendPendingUser(uuid: "u2", text: "run it", at: Date(timeIntervalSince1970: 1_800_000_000))
        session.sync(.growth(delta))
        Self.live(&session, LiveScript.start("m2"))
        Self.live(&session, LiveScript.block(0, ["type": "tool_use", "id": "t2", "name": "Bash"]), "tool running")
        Self.live(&session, LiveScript.jsonDelta(0, "{\"command\":\"sleep 99\"}"))
        Self.live(&session, LiveScript.stop(0))
        Self.live(&session, LiveScript.result(terminalReason: "aborted_tools"), "interrupted")
        #expect(session.model.turns.last?.status == .interrupted)
        #expect(session.flat.contains { $0.kind.tag == "divider" })
        session.isWorking = false
        session.sync(.state)
        Self.liveTurn(&session, 3)
        #expect(session.mismatches == 0)
    }

    // MARK: The reader's state

    @Test func foldsFlagsFullOutputsAndViewsFollowTheReader() {
        var session = RowsSession(source: .live)
        for number in 1...6 { Self.liveTurn(&session, number) }
        let ids = session.flat.map(\.id)
        #expect(ids.contains("fold:turn:u3"))

        // A fold of an old turn opens and closes: only its turn's rows change.
        session.toggled.insert("fold:turn:u3")
        session.sync(.state, "open fold")
        #expect(!session.lastWasAll)
        #expect(session.lastPatches.count == 1)
        #expect(session.flat.first { $0.id == "fold:turn:u3" }?.open == true)
        session.toggled.insert("t3a")
        session.sync(.state, "open a tool body")
        session.flags["t3b"] = ["all"]
        session.sync(.state, "flag")
        session.fullOutputs["t3a"] = .text("the whole output")
        session.sync(.state, "show all")
        session.fullOutputs["t3a"] = .missing
        session.sync(.state, "show all missing")
        session.toggled.remove("fold:turn:u3")
        session.sync(.state, "close fold")
        // Two changes at once, in turns far apart.
        session.toggled.formUnion(["fold:turn:u1", "fold:turn:u5"])
        session.sync(.state, "two folds")
        #expect(session.lastPatches.count == 2)
        // An id no row has changes nothing.
        session.toggled.insert("fold:turn:ghost")
        session.sync(.state, "ghost")
        #expect(session.lastPatches.isEmpty)

        // The views reach every turn.
        session.mode = .thinking
        session.sync(.state, "thinking view")
        #expect(session.lastWasAll)
        session.mode = .verbose
        session.sync(.state, "verbose view")
        session.mode = .normal
        session.sync(.state, "normal view")
        session.workingDirectory = "/p"
        session.sync(.state, "working directory")
        #expect(session.mismatches == 0)
    }

    @Test func workingStartsAndStopsOnTheNewestTurnOnly() {
        var session = RowsSession(source: .sessionTranscript)
        _ = session.append(ChatFixture.turn(1, tools: [ChatFixture.bash("ls")]))
        session.sync(.growth(ModelDelta()), "first")
        let delta = session.append([ChatFixture.user("next", uuid: "u2", at: 20),
                                    ChatFixture.assistant("m2", uuid: "c2", blocks: [ChatFixture.tool("t2", "Bash", ["command": "swift build"])], at: 21)])
        session.sync(.growth(delta), "second turn")
        session.isWorking = true
        session.sync(.state, "working")
        #expect(session.flat.last?.kind.tag == "live")
        #expect(session.lastTouchedRows <= 8)
        session.isWorking = false
        session.sync(.state, "stopped")
        #expect(session.flat.last?.kind.tag != "live")
        #expect(session.mismatches == 0)
    }

    // MARK: Transcripts

    @Test func aTranscriptGrowsThroughTurnsToolsAndAnInterrupt() {
        var session = RowsSession(source: .sessionTranscript)
        session.isWorking = true
        var lines = ChatFixture.turn(1, tools: [ChatFixture.bash("a"), ChatFixture.bash("b"), ChatFixture.read("/p/x")], thought: "Thinking about it.")
        session.sync(.growth(session.append(lines)), "first turn")
        // A prompt, then a tool that has not finished.
        lines = [ChatFixture.user("go", uuid: "u2", at: 30),
                 ChatFixture.assistant("m2", uuid: "c2", blocks: [ChatFixture.tool("t2", "Bash", ["command": "sleep 5"])], at: 31)]
        session.sync(.growth(session.append(lines)), "tool starts")
        session.sync(.growth(session.append([ChatFixture.result("t2", "done", at: 33)])), "tool finishes")
        // The reader stops the next one.
        session.sync(.growth(session.append([ChatFixture.user("again", uuid: "u3", at: 40),
                                            ChatFixture.assistant("m3", uuid: "c3", blocks: [ChatFixture.tool("t3", "Bash", ["command": "sleep 99"])], at: 41)])), "third turn")
        session.sync(.growth(session.append([ChatFixture.user("[Request interrupted by user]", uuid: "int3", at: 45)])), "interrupt")
        #expect(session.flat.contains { $0.kind.tag == "divider" })
        session.isWorking = false
        session.sync(.state, "stopped")
        session.sync(.growth(session.append(ChatFixture.turn(4, tools: [ChatFixture.bash("c")], start: 60))), "fourth turn")
        #expect(session.mismatches == 0)
    }

    @Test func aResultThatArrivesAfterTheNextPromptUpdatesItsOwnTurn() {
        var session = RowsSession(source: .sessionTranscript)
        session.sync(.growth(session.append([ChatFixture.user("one", uuid: "u1", at: 1),
                                            ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("t1", "Bash", ["command": "sleep 9"])], at: 2)])), "turn one")
        session.sync(.growth(session.append(ChatFixture.turn(2, tools: [ChatFixture.bash("x")], start: 10))), "turn two")
        for number in 3...8 { session.sync(.growth(session.append(ChatFixture.turn(number, start: number * 10))), "turn \(number)") }
        // The first turn's tool ends long after: its turn changes, and the newest one.
        session.sync(.growth(session.append([ChatFixture.result("t1", "finally", at: 100)])), "late result")
        #expect(!session.lastWasAll)
        #expect(session.mismatches == 0)
    }

    @Test func olderTurnsPutInFrontKeepTheRowsOfTheTurnsTheyDidNotChange() {
        let all = (0..<12).flatMap { ChatFixture.turn($0, tools: [ChatFixture.bash("make \($0)")], start: $0 * 20) }
        let cut = 6 * ChatFixture.turn(0, tools: [ChatFixture.bash("make 0")]).count

        // The read began at a prompt: the older read ends where it begins.
        var session = RowsSession(source: .sessionTranscript)
        session.hasOlder = true
        session.model = ChatFixture.model(Array(all[cut...]), firstOffset: ChatFixture.size(of: Array(all[..<cut])))
        session.sync(.replaced, "newest turns")
        let before = session.flat.count
        session.model.prepend(ChatFixture.model(Array(all[..<cut])))
        session.hasOlder = false
        session.sync(.older, "older page")
        #expect(!session.lastWasAll)
        #expect(session.flat.count > before)
        #expect(session.mismatches == 0)

        // The read began inside a turn: the older page ends inside it, and the two halves become one turn.
        var inside = RowsSession(source: .sessionTranscript)
        inside.hasOlder = true
        let middle = cut + 2
        inside.model = ChatFixture.model(Array(all[middle...]), firstOffset: ChatFixture.size(of: Array(all[..<middle])))
        inside.sync(.replaced, "newest part")
        inside.model.prepend(ChatFixture.model(Array(all[..<middle])))
        inside.sync(.older, "older page inside a turn")
        #expect(!inside.lastWasAll)
        #expect(inside.mismatches == 0)
        // And once more, with a reader's open fold in the way.
        inside.toggled.insert("fold:turn:u8")
        inside.sync(.state, "fold")
        #expect(inside.mismatches == 0)
    }

    @Test func aReplacedModelStartsOver() {
        var session = RowsSession(source: .sessionTranscript)
        session.sync(.growth(session.append(ChatFixture.turn(1, tools: [ChatFixture.bash("a")]))), "first")
        session.sync(.growth(session.append(ChatFixture.turn(2, tools: [ChatFixture.bash("b")], start: 10))), "second")
        session.model = ChatFixture.model(ChatFixture.turn(9, tools: [ChatFixture.read("/x")], answer: "Other."))
        session.sync(.replaced, "restarted")
        #expect(session.lastWasAll)
        #expect(session.mismatches == 0)
        // Nothing to show yet, then something.
        session.model = TurnModel(source: .sessionTranscript)
        session.sync(.replaced, "empty")
        #expect(session.flat.map(\.kind.tag) == ["empty"])
        session.sync(.growth(session.append(ChatFixture.turn(1))), "first lines")
        #expect(session.mismatches == 0)
    }

    // MARK: A long mixed run

    /// A seeded run of every kind of change, checked against a full rebuild after each one.
    @Test(arguments: [1, 2, 3, 4, 5, 6]) func aMixedRunStaysEqualToAFullRebuild(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        var session = RowsSession(source: .sessionTranscript)
        var turn = 0
        var pending: [String] = []
        var second = 0
        func tick() -> Int { second += 1; return second % 3000 }
        for step in 0..<150 {
            let choice = Int.random(in: 0..<14, using: &generator)
            switch choice {
            case 0...2:
                // A new turn with a prompt and a tool that may stay unfinished.
                turn += 1
                let id = "t\(turn)"
                var lines = [ChatFixture.user("prompt \(turn)", uuid: "u\(turn)", at: tick()),
                             ChatFixture.assistant("m\(turn)", uuid: "c\(turn)", blocks: [ChatFixture.tool(id, "Bash", ["command": .string("run \(turn)")])], at: tick())]
                if Bool.random(using: &generator) { lines.append(ChatFixture.result(id, "ok \(turn)", at: tick())) } else { pending.append(id) }
                session.sync(.growth(session.append(lines)), "step \(step): new turn")
            case 3...4:
                // The answer, or more work, in the newest turn.
                guard turn > 0 else { continue }
                turn += 1
                let id = "x\(turn)"
                let lines = [ChatFixture.assistant("m\(turn)", uuid: "c\(turn)", blocks: [ChatFixture.tool(id, "Read", ["file_path": .string("/p/\(turn).swift")])], at: tick()),
                             ChatFixture.result(id, "1\tline", at: tick()),
                             ChatFixture.assistant("a\(turn)", uuid: "ans\(turn)", blocks: [ChatFixture.text("Answer \(turn).")], at: tick())]
                session.sync(.growth(session.append(lines)), "step \(step): work and answer")
            case 5:
                // A tool of any turn finishes.
                guard let id = pending.popLast() else { continue }
                session.sync(.growth(session.append([ChatFixture.result(id, "late", at: tick())])), "step \(step): result")
            case 6:
                guard turn > 0 else { continue }
                session.sync(.growth(session.append([ChatFixture.user("[Request interrupted by user]", uuid: "int\(step)", at: tick())])), "step \(step): interrupt")
            case 7...9:
                guard let row = session.flat.randomElement(using: &generator) else { continue }
                if session.toggled.contains(row.id) { session.toggled.remove(row.id) } else { session.toggled.insert(row.id) }
                session.sync(.state, "step \(step): toggle \(row.id)")
            case 10:
                guard let row = session.flat.filter({ $0.kind.tag == "tool" || $0.kind.tag == "prose" || $0.kind.tag == "answer" }).randomElement(using: &generator) else { continue }
                session.flags[row.id] = session.flags[row.id] == nil ? ["all"] : nil
                session.sync(.state, "step \(step): flag \(row.id)")
            case 11:
                session.isWorking.toggle()
                session.sync(.state, "step \(step): working \(session.isWorking)")
            case 12:
                session.mode = session.mode.next
                session.sync(.state, "step \(step): view \(session.mode)")
            default:
                guard let row = session.flat.first(where: { $0.kind.tag == "tool" }) else { continue }
                session.fullOutputs[row.id] = session.fullOutputs[row.id] == nil ? .text("all of \(row.id)") : nil
                session.sync(.state, "step \(step): show all \(row.id)")
            }
            if session.mismatches > 0 { break }
        }
        #expect(session.mismatches == 0)
    }
}

/// A fixed sequence for a seed, so a failing run can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
