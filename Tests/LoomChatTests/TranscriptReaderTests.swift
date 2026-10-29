import Darwin
import Foundation
import LoomCore
import Testing
@testable import LoomChat
@testable import LoomChatTestRigs

/// Locating a session's transcript, reading it backward in bounded pages and forward as it grows, and the lens that
/// builds the model from it. Every file is made in a temporary folder and removed.
@Suite(.timeLimit(.minutes(3)))
struct TranscriptReaderTests: TranscriptReaderFixtures {
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
}
