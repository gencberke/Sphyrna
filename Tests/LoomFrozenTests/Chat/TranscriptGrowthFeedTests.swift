import Foundation
import LoomCore
import Testing
@testable import LoomChat
import LoomTestSupport
@testable import LoomChatTestRigs

/// The growth feed of a transcript view: file events (no polling) drive coalesced reads of the lens; nothing exists
/// before `start()` or after `stop()`.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TranscriptGrowthFeedTests {
    private struct Tree {
        let root: URL
        var url: URL { root.appendingPathComponent("projects/-tmp-work/sess1.jsonl") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-feed-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-tmp-work"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func file() throws -> ClaudeTranscriptFile {
            try #require(ClaudeTranscriptLocator.locate(sessionID: "sess1", configDirectory: root))
        }
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func prompt(_ index: Int) -> String {
        Fixture.transcriptUser("prompt \(index)", uuid: "u\(index)") + "\n"
    }

    /// Waits for updates until `predicate` holds for the newest model, or fails after `seconds`.
    private func collect(_ feed: TranscriptGrowthFeed, seconds: Double = 10,
                         until predicate: (TurnModel) -> Bool) async -> [TranscriptLens.Update] {
        var received: [TranscriptLens.Update] = []
        let deadline = Task {
            try? await Task.sleep(for: .seconds(seconds))
            feed.stop()
        }
        for await update in feed.updates {
            received.append(update)
            if predicate(update.model) { break }
        }
        deadline.cancel()
        return received
    }

    @Test func appendedLinesArriveAsRowsWithoutPolling() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append(prompt(0), to: tree.url)
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpen()
        let feed = TranscriptGrowthFeed(file: try tree.file(), lens: lens)
        feed.start()
        // Written after the watch exists.
        try await Task.sleep(for: .milliseconds(100))
        try append(prompt(1) + Fixture.transcriptAssistant(messageID: "m1", uuid: "a1", blocks: [Fixture.textBlock("answer")]) + "\n", to: tree.url)
        let updates = await collect(feed) { $0.texts.count == 1 }
        feed.stopAndWait()
        await lens.close()
        let last = try #require(updates.last)
        #expect(last.model.prompts.map(\.text) == ["prompt 0", "prompt 1"])
        #expect(Set(updates.flatMap(\.delta.inserted)).isSuperset(of: ["u1", "m1#0"]))
        // No timer: the one start-up read plus the reads the writes caused.
        #expect(feed.readCount <= 3)
    }

    @Test func aBurstOfWritesIsReadInFarFewerReadsThanWrites() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append(prompt(0), to: tree.url)
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpen()
        let feed = TranscriptGrowthFeed(file: try tree.file(), lens: lens, coalescing: 0.05)
        feed.start()
        try await Task.sleep(for: .milliseconds(100))
        let writes = 60
        let writer = Task.detached {
            for index in 1...writes {
                try append(prompt(index), to: tree.url)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let updates = await collect(feed) { $0.prompts.count == writes + 1 }
        try await writer.value
        feed.stopAndWait()
        await lens.close()
        #expect(updates.last?.model.prompts.count == writes + 1)
        // 60 writes over about 0.4 s: one read per 50 ms window at most, plus the start-up read.
        #expect(feed.readCount < writes / 2)
        // Every row arrived exactly once across the deltas.
        let inserted = updates.flatMap(\.delta.inserted)
        #expect(inserted.count == Set(inserted).count)
    }

    @Test func nothingRunsBeforeStartOrAfterStop() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append(prompt(0), to: tree.url)
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpen()
        let feed = TranscriptGrowthFeed(file: try tree.file(), lens: lens)
        #expect(!feed.isWatching && feed.readCount == 0)
        try append(prompt(1), to: tree.url)
        try await Task.sleep(for: .milliseconds(200))
        #expect(feed.readCount == 0)
        feed.start()
        _ = await collect(feed) { $0.prompts.count == 2 }
        #expect(feed.isWatching)
        feed.stopAndWait()
        #expect(!feed.isWatching)
        let reads = feed.readCount
        try append(prompt(2), to: tree.url)
        try await Task.sleep(for: .milliseconds(300))
        #expect(feed.readCount == reads)
        // The lens kept its place: what was written while the feed was stopped is read by the next feed, once.
        let again = TranscriptGrowthFeed(file: try tree.file(), lens: lens)
        again.start()
        let updates = await collect(again) { $0.prompts.count == 3 }
        again.stopAndWait()
        await lens.close()
        #expect(updates.last?.model.prompts.map(\.text) == ["prompt 0", "prompt 1", "prompt 2"])
    }

    @Test func aReplacedFileIsReadAgainFromItsTail() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append(prompt(0) + prompt(1), to: tree.url)
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpen()
        let feed = TranscriptGrowthFeed(file: try tree.file(), lens: lens)
        feed.start()
        try await Task.sleep(for: .milliseconds(100))
        // Rotate: a new file takes the name.
        let replacement = tree.url.deletingLastPathComponent().appendingPathComponent("new.jsonl")
        try append(Fixture.transcriptUser("fresh", uuid: "n0") + "\n", to: replacement)
        _ = try FileManager.default.replaceItemAt(tree.url, withItemAt: replacement)
        let updates = await collect(feed) { $0.prompts.map(\.text) == ["fresh"] }
        feed.stopAndWait()
        await lens.close()
        #expect(updates.contains { $0.restarted })
        #expect(updates.last?.model.prompts.map(\.text) == ["fresh"])
    }

    @Test func theFirstReadAfterStartIsDeliveredEvenWhenEmpty() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append(prompt(0), to: tree.url)
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpen()
        // An earlier feed was stopped with a read in flight: the lens consumed these bytes, nobody received them.
        try append(prompt(1), to: tree.url)
        let lost = await lens.readGrowth()
        #expect(lost.model.prompts.count == 2)
        let feed = TranscriptGrowthFeed(file: try tree.file(), lens: lens)
        feed.start()
        let updates = await collect(feed, seconds: 3) { _ in true }
        feed.stopAndWait()
        await lens.close()
        #expect(updates.count == 1)
        #expect(updates.first?.model.prompts.map(\.text) == ["prompt 0", "prompt 1"])
    }

    @Test func aFileMissingForAWhileIsWatchedAgainWhenItAppears() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append(prompt(0) + prompt(1), to: tree.url)
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpen()
        let feed = TranscriptGrowthFeed(file: try tree.file(), lens: lens)
        feed.start()
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.removeItem(at: tree.url)
        // The new file appears only after the first re-watch attempts failed.
        try await Task.sleep(for: .milliseconds(700))
        try append(Fixture.transcriptUser("fresh", uuid: "n0") + "\n", to: tree.url)
        let updates = await collect(feed, seconds: 6) { $0.prompts.map(\.text) == ["fresh"] }
        feed.stopAndWait()
        await lens.close()
        #expect(updates.last?.model.prompts.map(\.text) == ["fresh"])
    }

    @Test func aTruncateWithNoWriteAfterItIsNoticed() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try append(prompt(0) + prompt(1) + prompt(2), to: tree.url)
        let lens = try #require(TranscriptLens(file: tree.file()))
        _ = await lens.coldOpen()
        let feed = TranscriptGrowthFeed(file: try tree.file(), lens: lens)
        feed.start()
        try await Task.sleep(for: .milliseconds(150))
        let handle = try FileHandle(forWritingTo: tree.url)
        try handle.truncate(atOffset: 0)
        try handle.close()
        let updates = await collect(feed, seconds: 4) { $0.prompts.isEmpty }
        feed.stopAndWait()
        await lens.close()
        #expect(updates.contains { $0.restarted })
        #expect(updates.last?.model.prompts.isEmpty == true)
    }

    @Test func showAllReadsAClippedResultFromTheTranscript() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let big = String(repeating: "x", count: 200 * 1024) + "THE-END"
        try append(prompt(0)
            + Fixture.transcriptAssistant(messageID: "m", uuid: "a", blocks: [Fixture.toolUse("toolu_big", "Bash", ["command": "cat big"])]) + "\n"
            + Fixture.transcriptAssistant(messageID: "m", uuid: "b", blocks: [Fixture.toolUse("toolu_other", "Bash", ["command": "ls"])]) + "\n"
            + Fixture.transcriptToolResult(id: "toolu_other", text: "small") + "\n"
            + Fixture.transcriptToolResult(id: "toolu_big", text: big) + "\n", to: tree.url)
        let lens = try #require(TranscriptLens(file: tree.file()))
        let opened = await lens.coldOpen()
        let call = try #require(opened.model.entry(id: "toolu_big"))
        guard case let .tool(tool) = call.body else { Issue.record("not a tool row"); return }
        #expect(tool.output?.isClipped == true)
        let full = await lens.fullToolResult(toolUseID: "toolu_big", from: try #require(call.sourceOffset))
        await lens.close()
        #expect(full == big)
    }
}
