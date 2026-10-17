import Darwin
import Foundation
import LoomCore
import Testing
@testable import LoomChat

/// Locating a session's transcript, reading it backward in bounded pages and forward as it grows, and the lens that
/// builds the model from it. Every file is made in a temporary folder and removed.
@Suite(.timeLimit(.minutes(3)))
struct TranscriptReaderTests {
    private struct Tree {
        let root: URL
        var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
        var folder: URL { projects.appendingPathComponent("-tmp-work", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-tmp-work"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func url(_ id: String = "sess1") -> URL { folder.appendingPathComponent("\(id).jsonl") }

        func file(_ id: String = "sess1") throws -> ClaudeTranscriptFile {
            try #require(ClaudeTranscriptLocator.locate(sessionID: id, configDirectory: root))
        }
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Writes `turns` turns of: a prompt, a thought, a tool call with `toolBytes` of output, and an answer.
    private func writeTranscript(_ url: URL, turns: Int, toolBytes: Int, toolsPerTurn: Int = 1, bigTurn: (index: Int, bytes: Int)? = nil) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = String(repeating: "o", count: toolBytes)
        var batch = ""
        for turn in 0..<turns {
            let bytes = bigTurn.flatMap { $0.index == turn ? $0.bytes : nil }
            batch += Fixture.transcriptUser("prompt \(turn)", uuid: "u\(turn)") + "\n"
            batch += Fixture.transcriptAssistant(messageID: "m\(turn)a", uuid: "a\(turn)", blocks: [Fixture.thinkingBlock("thinking \(turn)")]) + "\n"
            for call in 0..<toolsPerTurn {
                let id = "t\(turn)-\(call)"
                batch += Fixture.transcriptAssistant(messageID: "m\(turn)a", uuid: "b\(turn)-\(call)", blocks: [Fixture.toolUse(id, "Bash", ["command": .string("cmd \(turn)")])]) + "\n"
                batch += Fixture.transcriptToolResult(id: id, text: bytes.map { String(repeating: "B", count: $0) } ?? output) + "\n"
            }
            batch += Fixture.transcriptAssistant(messageID: "m\(turn)b", uuid: "c\(turn)", blocks: [Fixture.textBlock("answer \(turn)")]) + "\n"
            if batch.utf8.count > 4 << 20 || turn == turns - 1 {
                try append(batch, to: url)
                batch = ""
            }
        }
    }

    // MARK: Locator

    @Test func aSessionIsFoundByIdUnderTheConfigDirectoryAndNothingElseIs() throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append("{}\n", to: tree.url())
        let found = try #require(ClaudeTranscriptLocator.locate(sessionID: "sess1", configDirectory: tree.root))
        #expect(found.sessionID == "sess1" && found.path.hasSuffix("/projects/-tmp-work/sess1.jsonl"))
        let hinted = ClaudeTranscriptLocator.locate(sessionID: "sess1", configDirectory: tree.root, workingDirectory: "/tmp/work")
        #expect(hinted == found)
        // Not an identifier, not there, or a link that leads out of the projects folder.
        #expect(ClaudeTranscriptLocator.locate(sessionID: "../sess1", configDirectory: tree.root) == nil)
        #expect(ClaudeTranscriptLocator.locate(sessionID: "nope", configDirectory: tree.root) == nil)
        let outside = tree.root.appendingPathComponent("outside.jsonl")
        try append("{}\n", to: outside)
        try FileManager.default.createSymbolicLink(at: tree.url("link"), withDestinationURL: outside)
        #expect(ClaudeTranscriptLocator.locate(sessionID: "link", configDirectory: tree.root) == nil)
        #expect(ClaudeTranscriptLocator.resolve(path: outside.path, sessionID: "outside", projectsDirectory: tree.projects) == nil)
        #expect(ClaudeTranscriptLocator.resolve(path: tree.url().path, sessionID: "sess1", projectsDirectory: tree.projects) == found)
    }

    // MARK: Reader

    @Test func pagesWalkBackToTheStartAndEveryLineComesOutOnceInOrder() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let lines = (0..<500).map { "line-\(String(format: "%04d", $0))-" + String(repeating: "z", count: $0 % 37) }
        try append(lines.joined(separator: "\n") + "\n", to: tree.url())
        let reader = try #require(ClaudeTranscriptReader(file: tree.file()))
        var collected: [String] = []
        var pages = 0
        while true {
            let page = reader.readBackward(pageBytes: 700)
            pages += 1
            #expect(page.records.reduce(0) { $0 + $1.length + 1 } <= 700 + 40)
            collected.insert(contentsOf: page.records.map { String(decoding: $0.bytes ?? Data(), as: UTF8.self) }, at: 0)
            if page.reachedStart { break }
            #expect(pages < 1000)
        }
        #expect(collected == lines && pages > 10)
        #expect(reader.historyOffset == 0 && reader.readBackward().records.isEmpty)
    }

    @Test func aLineLongerThanAPageIsAPageOfItsOwnAndOneOverTheCapIsOnlyMarked() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let big = String(repeating: "B", count: 300_000)
        let huge = String(repeating: "H", count: 900_000)
        try append("first\n\(big)\nmiddle\n\(huge)\nlast\n", to: tree.url())
        let reader = try #require(ClaudeTranscriptReader(file: tree.file()))
        var pages: [TranscriptBackwardPage] = []
        while pages.last?.reachedStart != true { pages.append(reader.readBackward(pageBytes: 1000, maximumLineBytes: 500_000)) }
        let records = pages.reversed().flatMap(\.records)
        #expect(records.count == 5)
        #expect(records[0].bytes == Data("first".utf8) && records[2].bytes == Data("middle".utf8) && records[4].bytes == Data("last".utf8))
        #expect(records[1].bytes == Data(big.utf8))
        // Over the cap: not read, but its place and length are known, and it can be read on demand.
        #expect(records[3].isOversized && records[3].length == 900_000)
        #expect(reader.readLine(at: records[3].offset) == Data(huge.utf8))
        #expect(reader.readLine(at: records[3].offset, maximumLineBytes: 1000) == nil)
    }

    @Test func growthDeliversWholeLinesOnlyAndStartsWhereHistoryEnds() throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append("one\ntwo\npartial", to: tree.url())
        let reader = try #require(ClaudeTranscriptReader(file: tree.file()))
        // History ends at the last whole line; "partial" belongs to growth once it is finished.
        #expect(reader.readBackward().records.compactMap(\.bytes) == [Data("one".utf8), Data("two".utf8)])
        #expect(reader.readGrowth().records.isEmpty)
        try append(" line\nthree\n", to: tree.url())
        let growth = reader.readGrowth()
        #expect(growth.records.compactMap(\.bytes).map { String(decoding: $0, as: UTF8.self) } == ["partial line", "three"] && !growth.restarted)
        #expect(growth.records[0].offset == 8)
        #expect(reader.readGrowth().records.isEmpty)
        // A line over the cap is reported, not buffered.
        try append(String(repeating: "x", count: 20_000_000) + "\nafter\n", to: tree.url())
        let more = reader.readGrowth()
        #expect(more.records.count == 2 && more.records[0].isOversized && more.records[0].length == 20_000_000)
        #expect(more.records[1].bytes == Data("after".utf8))
    }

    @Test func aReplacedFileRestartsTheReader() throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append("old1\nold2\n", to: tree.url())
        let reader = try #require(ClaudeTranscriptReader(file: tree.file()))
        _ = reader.readBackward()
        let replacement = tree.folder.appendingPathComponent("new.tmp")
        try append("new1\nnew2\nnew3\n", to: replacement)
        _ = try FileManager.default.replaceItemAt(tree.url(), withItemAt: replacement)
        let growth = reader.readGrowth()
        #expect(growth.restarted)
        #expect(reader.readBackward().records.compactMap(\.bytes).count == 3)
    }

    // MARK: Lens

    @Test func aColdOpenOfALongTranscriptReadsOnlyTheLastTenTurns() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try writeTranscript(tree.url(), turns: 1500, toolBytes: 6_000)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: tree.url().path)[.size] as? Int)
        let lens = try #require(TranscriptLens(file: tree.file()))
        let opened = await lens.coldOpen()
        print("cold open of \(size) bytes read \(opened.bytesRead) bytes")
        #expect(size > 10_000_000)
        #expect(opened.model.prompts.map(\.text) == (1490..<1500).map { "prompt \($0)" })
        #expect(opened.model.turns.count == 10 && opened.model.turns.allSatisfy(\.hasUserPrompt) && opened.hasOlder)
        #expect(opened.bytesRead <= 1_572_864 + 16 * 1024)
        #expect(opened.delta.inserted.count == opened.model.entries.count)
        // Rows keep their ids; the live stream would have given the same ones.
        #expect(opened.model.entries.first?.id == "u1490" && opened.model.entries.contains { $0.id == "m1499a#0" })
        #expect(opened.model.turns.last?.status == .open && opened.model.turns.first?.status == .ended)

        // The top comes near: 20 more turns go in front, and nothing already shown changes.
        let older = try #require(await lens.loadOlder())
        #expect(older.model.prompts.count == 30 && older.model.prompts.first?.text == "prompt 1470")
        #expect(Array(older.model.entries.suffix(opened.model.entries.count)) == opened.model.entries)
        #expect(older.delta.inserted.count == older.model.entries.count - opened.model.entries.count && older.hasOlder)
        #expect(older.model.turns.dropLast(0).map(\.status).dropLast() .allSatisfy { $0 == .ended })
        #expect(older.bytesRead < 1_572_864 + 8 * 1024 * 1024)
        await lens.close()
    }

    @Test func theColdOpenReadCapHoldsWhenTurnsAreHuge() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        // Each turn carries 6 tool results of 50 KB, so ten turns would be 3 MB: twice the cap.
        try writeTranscript(tree.url(), turns: 60, toolBytes: 50_000, toolsPerTurn: 6)
        let lens = try #require(TranscriptLens(file: tree.file()))
        let opened = await lens.coldOpen()
        print("cold open of huge turns read \(opened.bytesRead) bytes, \(opened.model.prompts.count) prompts")
        #expect(opened.bytesRead <= 1_572_864 + 128 * 1024)
        #expect(opened.model.prompts.count < 10 && opened.model.prompts.count >= 3 && opened.hasOlder)
        // It starts at a clean boundary: no call without its result, no row without its message.
        #expect(opened.model.prompts.last?.text == "prompt 59")
        #expect(opened.model.tools.allSatisfy { $0.status == .succeeded && !$0.name.isEmpty })
        #expect(Set(opened.model.entries.map(\.id)).count == opened.model.entries.count)
        // Older pages continue from there, and the cut turn becomes whole. No row appears twice and no call is left running.
        var older = try #require(await lens.loadOlder())
        #expect(older.model.turns.first?.hasUserPrompt == true && older.model.prompts.count > opened.model.prompts.count)
        #expect(Set(older.model.turns.map(\.id)).count == older.model.turns.count)
        while let next = await lens.loadOlder() { older = next }
        let ids = older.model.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(older.model.tools.count == 60 * 6 && older.model.tools.allSatisfy { $0.status == .succeeded && !$0.name.isEmpty })
        #expect(older.model.prompts.map(\.text) == (0..<60).map { "prompt \($0)" } && older.model.raws.isEmpty)
        await lens.close()
    }

    @Test func linesOfHundredsOfKilobytesStillOpenWithinTwiceTheCap() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try writeTranscript(tree.url(), turns: 30, toolBytes: 400_000)
        let lens = try #require(TranscriptLens(file: tree.file()))
        let opened = await lens.coldOpen()
        #expect(opened.bytesRead <= 2 * 1_572_864 && opened.model.prompts.last?.text == "prompt 29" && opened.hasOlder)
        // An ordinary line is never read as "oversized" because little of the budget is left: it waits for the next page.
        #expect(opened.model.raws.isEmpty)
        #expect(opened.model.tools.allSatisfy { $0.status == .succeeded && !$0.name.isEmpty })
        var all = opened
        while let older = await lens.loadOlder() { all = older }
        let ids = all.model.entries.map(\.id)
        #expect(Set(ids).count == ids.count && all.model.raws.isEmpty && all.model.tools.count == 30)
        #expect(all.model.tools.allSatisfy { $0.status == .succeeded && !$0.name.isEmpty })
        await lens.close()
    }

    @Test(arguments: [3_300, 4_100, 5_000, 5_700, 6_400, 7_300, 8_100, 9_000, 9_700, 10_400, 11_300])
    func aColdOpenThatEndsInsideATurnStartsAtAMessageAndOlderPagesJoinItWithoutRepeats(budget: Int) async throws {
        let tree = try Tree()
        defer { tree.remove() }
        // One long turn: a prompt, then 60 steps of an assistant message holding one call, and its short result. The lines
        // are small, so a byte budget can end between any two of them.
        FileManager.default.createFile(atPath: tree.url().path, contents: nil)
        var text = Fixture.transcriptUser("do the long job", uuid: "u0") + "\n"
        for step in 0..<60 {
            text += Fixture.transcriptAssistant(messageID: "m\(step)", uuid: "a\(step)", blocks: [Fixture.toolUse("t\(step)", "Bash", ["command": .string("step \(step)")])]) + "\n"
            text += Fixture.transcriptToolResult(id: "t\(step)", text: String(repeating: "r", count: 300)) + "\n"
        }
        text += Fixture.transcriptAssistant(messageID: "mEnd", uuid: "aEnd", blocks: [Fixture.textBlock("finished")]) + "\n"
        try append(text, to: tree.url())
        var limits = TranscriptLens.Limits()
        limits.coldOpenBytes = budget
        limits.olderBytes = budget
        limits.pageBytes = 2_000
        let lens = try #require(TranscriptLens(file: tree.file(), limits: limits))
        let opened = await lens.coldOpen()
        // Cut inside the turn: it has no prompt in view, begins with a call (never with a result), and every call has its result.
        #expect(opened.hasOlder && opened.model.turns.count == 1 && opened.model.turns[0].hasUserPrompt == false)
        #expect(opened.model.tools.count >= 1 && opened.model.tools.count < 60)
        #expect(opened.model.tools.allSatisfy { !$0.name.isEmpty && $0.status == .succeeded })
        #expect(opened.model.entries.first.map { $0.id.hasPrefix("t") && $0.id != "tEnd" } == true)
        var latest = opened
        var pages = 0
        while let older = await lens.loadOlder() {
            latest = older
            pages += 1
            let ids = older.model.entries.map(\.id)
            #expect(Set(ids).count == ids.count)
            #expect(older.model.tools.allSatisfy { !$0.name.isEmpty && $0.status == .succeeded })
        }
        #expect(pages >= 2 && !latest.hasOlder)
        #expect(latest.model.tools.count == 60 && latest.model.turns.count == 1 && latest.model.turns[0].hasUserPrompt)
        #expect(latest.model.entries.first?.id == "u0" && latest.model.texts.last?.text == "finished")
        await lens.close()
    }

    @Test func pagingWithSmallBudgetsGivesTheSameRowsAsReadingTheWholeFile() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try writeTranscript(tree.url(), turns: 14, toolBytes: 2_500, toolsPerTurn: 3)
        var reference = TurnModel(source: .sessionTranscript)
        var position: UInt64 = 0
        for line in try String(contentsOf: tree.url(), encoding: .utf8).split(separator: "\n") {
            let bytes = Data(line.utf8)
            reference.apply(record: TranscriptLineRecord(offset: position, length: bytes.count, bytes: bytes))
            position += UInt64(bytes.count + 1)
        }
        var limits = TranscriptLens.Limits()
        limits.coldOpenTurns = 2
        limits.olderTurns = 2
        limits.coldOpenBytes = 9_000
        limits.olderBytes = 9_000
        limits.pageBytes = 2_000
        let lens = try #require(TranscriptLens(file: tree.file(), limits: limits))
        var latest = await lens.coldOpen()
        var pages = 0
        while let older = await lens.loadOlder() {
            latest = older
            pages += 1
            let ids = older.model.entries.map(\.id)
            #expect(Set(ids).count == ids.count)
        }
        #expect(pages > 4)
        #expect(latest.model.entries == reference.entries)
        #expect(latest.model.turns.map(\.id) == reference.turns.map(\.id) && latest.model.turns.map(\.status) == reference.turns.map(\.status))
        await lens.close()
    }

    @Test func promptsFromOtherOriginsDoNotCountTowardTheTurnsOfAColdOpen() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let peer = Fixture.transcriptUser("Another Claude session sent a message: the report", uuid: "peer1", extra: ["origin": .object(["kind": .string("peer")])])
        try append([Fixture.transcriptUser("one", uuid: "p1"),
                    Fixture.transcriptAssistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock("first")]),
                    Fixture.transcriptUser("two", uuid: "p2"),
                    Fixture.transcriptAssistant(messageID: "m2", uuid: "a2", blocks: [Fixture.textBlock("second")]),
                    peer,
                    Fixture.transcriptUser("three", uuid: "p3"),
                    Fixture.transcriptAssistant(messageID: "m3", uuid: "a3", blocks: [Fixture.textBlock("third")])].joined(separator: "\n") + "\n", to: tree.url())
        var limits = TranscriptLens.Limits()
        limits.coldOpenTurns = 2
        let lens = try #require(TranscriptLens(file: tree.file(), limits: limits))
        let opened = await lens.coldOpen()
        // The peer's hand-back is a notice, as in the model: the last two prompts are "two" and "three".
        #expect(opened.model.prompts.map(\.text) == ["two", "three"] && opened.hasOlder)
        #expect(opened.model.markers == [.notice("peer")])
        await lens.close()
    }

    @Test func anOversizedLineIsAMarkedRowThatCanBeReadOnDemand() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        // The last turn's tool output is 5 MB: over the lens's 4 MiB line cap.
        try writeTranscript(tree.url(), turns: 5, toolBytes: 100, bigTurn: (4, 5_000_000))
        let lens = try #require(TranscriptLens(file: tree.file()))
        let opened = await lens.coldOpen()
        let raw = try #require(opened.model.raws.first)
        #expect(raw.reason == .oversized && raw.byteCount > 5_000_000)
        let entry = try #require(opened.model.entries.first { if case .unknown = $0.body { true } else { false } })
        let offset = try #require(entry.sourceOffset)
        let line = try #require(await lens.line(at: offset))
        #expect(line.count == raw.byteCount)
        let value = try JSONDecoder().decode(JSONValue.self, from: line)
        #expect(value["message"]?["content"]?[0]?["tool_use_id"] == "t4-0")
        // The tool call has no result row to update, so it keeps running; the turn still has its prompt and answer.
        #expect(opened.model.prompts.last?.text == "prompt 4" && opened.model.texts.last?.text == "answer 4")
        await lens.close()
    }

    @Test func growthAddsRowsAndOnlyCompleteLinesCount() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try writeTranscript(tree.url(), turns: 3, toolBytes: 50)
        let lens = try #require(TranscriptLens(file: tree.file()))
        let opened = await lens.coldOpen()
        #expect(opened.model.prompts.count == 3 && !opened.hasOlder)
        #expect(await lens.loadOlder() == nil)

        let next = Fixture.transcriptUser("prompt 3", uuid: "u3")
        try append(String(next.prefix(40)), to: tree.url())
        let half = await lens.readGrowth()
        #expect(half.delta.isEmpty && half.model.prompts.count == 3)
        try append(String(next.dropFirst(40)) + "\n" + Fixture.transcriptAssistant(messageID: "m3a", uuid: "a3", blocks: [Fixture.textBlock("hello")]) + "\n", to: tree.url())
        let grown = await lens.readGrowth()
        #expect(grown.delta.inserted == ["u3", "m3a#0"] && grown.delta.turnsChanged)
        #expect(grown.model.turns.count == 4 && grown.model.turns[2].status == .ended && grown.model.turns[3].status == .open)
        #expect(grown.model.prompts.last?.text == "prompt 3")
        await lens.close()
    }

    @Test func aSubagentTranscriptOpensThroughTheSameLens() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let directory = tree.folder.appendingPathComponent("session-1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("agent-a1.jsonl")
        try append([Fixture.transcriptUser("Review auth.py", uuid: "b1", extra: ["isSidechain": true]),
                    Fixture.transcriptAssistant(messageID: "s1", uuid: "s1a", blocks: [Fixture.textBlock("Looking.")])].joined(separator: "\n") + "\n", to: url)
        let file = try #require(SubagentTranscriptLocation.resolve(path: url.path, agentID: "a1", projectsDirectory: tree.projects))
        let lens = try #require(TranscriptLens(subagent: file))
        let opened = await lens.coldOpen()
        #expect(opened.model.source == .subagentTranscript && opened.model.prompts.first?.isBrief == true)
        #expect(opened.model.texts.map(\.text) == ["Looking."])
        await lens.close()
    }
}
