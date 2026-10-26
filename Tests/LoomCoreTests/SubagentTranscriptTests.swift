import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore

/// The subagent panel's reading side (FB4-5): where a transcript may be read from, what a line turns into,
/// how the tail of a file is read and how the feed delivers it. Line shapes follow 39 real subagent files
/// (15,689 lines) with the content replaced; every file here is made in a temporary folder.
@Suite(.timeLimit(.minutes(1)))
struct SubagentTranscriptTests {
    // MARK: Files

    private struct Tree {
        let root: URL
        var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
        var subagents: URL { projects.appendingPathComponent("-tmp-ws/session-1/subagents", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-transcript-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-tmp-ws/session-1/subagents"),
                                                    withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func write(_ text: String, to url: URL) throws -> URL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func transcript(_ id: String = "a1", _ text: String = "") throws -> URL {
            try write(text, to: subagents.appendingPathComponent("agent-\(id).jsonl"))
        }
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func resolve(_ url: URL, _ id: String = "a1", in tree: Tree) -> SubagentTranscriptFile? {
        SubagentTranscriptLocation.resolve(path: url.path, agentID: id, projectsDirectory: tree.projects)
    }

    // MARK: Location

    @Test func bothLayoutsAreAcceptedAndResolveToRealPaths() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let plain = try tree.transcript()
        let workflow = try tree.write("", to: tree.subagents.appendingPathComponent("workflows/wf_1/agent-w1.jsonl"))
        let accepted = try #require(resolve(plain, in: tree))
        #expect(accepted.agentID == "a1")
        #expect(accepted.path == URL(fileURLWithPath: realpathString(plain.path)).path)
        #expect(resolve(workflow, "w1", in: tree) != nil)
    }

    @Test func aPathOutsideTheShapeOrTheProfileIsRefused() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let good = try tree.transcript()
        // Traversal: the path climbs out of the projects folder to a file of the right shape.
        let outside = try tree.write("", to: tree.root.appendingPathComponent("outside/subagents/agent-a1.jsonl"))
        let climbing = tree.subagents.appendingPathComponent("../../../../outside/subagents/agent-a1.jsonl")
        #expect(FileManager.default.fileExists(atPath: climbing.path))
        #expect(resolve(climbing, in: tree) == nil)
        #expect(resolve(outside, in: tree) == nil)
        // A bad id never reaches the filesystem.
        for id in ["", "../a1", "a 1", "a/1", String(repeating: "a", count: 81)] {
            #expect(resolve(good, id, in: tree) == nil)
        }
        // The name must be the agent's own transcript, in a subagents folder.
        #expect(resolve(good, "a2", in: tree) == nil)
        let meta = try tree.write("{}", to: tree.subagents.appendingPathComponent("agent-a1.meta.json"))
        #expect(resolve(meta, in: tree) == nil)
        let stray = try tree.write("", to: tree.projects.appendingPathComponent("-tmp-ws/session-1/agent-a1.jsonl"))
        #expect(resolve(stray, in: tree) == nil)
        let deep = try tree.write("", to: tree.subagents.appendingPathComponent("workflows/wf_1/extra/agent-a1.jsonl"))
        #expect(resolve(deep, in: tree) == nil)
        #expect(resolve(tree.subagents.appendingPathComponent("agent-missing.jsonl"), "missing", in: tree) == nil)
        #expect(SubagentTranscriptLocation.resolve(path: "agent-a1.jsonl", agentID: "a1", projectsDirectory: tree.projects) == nil)
    }

    @Test func aSymlinkCannotLeadOutOfTheProfile() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let target = try tree.write("secret\n", to: tree.root.appendingPathComponent("outside/subagents/agent-a1.jsonl"))
        // The file itself is a link.
        let link = tree.subagents.appendingPathComponent("agent-a1.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(resolve(link, in: tree) == nil)
        try FileManager.default.removeItem(at: link)
        // A folder on the way is a link.
        let folder = tree.projects.appendingPathComponent("-tmp-ws/session-2", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: folder, withDestinationURL: tree.root.appendingPathComponent("outside", isDirectory: true))
        #expect(resolve(folder.appendingPathComponent("subagents/agent-a1.jsonl"), in: tree) == nil)
    }

    @Test func theFileIsOpenedReadOnlyAndOnlyAsARegularFile() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript()
        let file = try #require(resolve(url, in: tree))
        let descriptor = try #require(file.openDescriptor())
        defer { close(descriptor) }
        #expect(fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
        // Swapped for a link after the check: the open refuses it.
        let target = try tree.write("x\n", to: tree.root.appendingPathComponent("elsewhere.jsonl"))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(file.openDescriptor() == nil)
    }

    private func realpathString(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Parser

    private let parser = SubagentTranscriptParser()

    private let briefLine = #"{"parentUuid":null,"isSidechain":true,"agentId":"a1","type":"user","message":{"role":"user","content":"Map the core module and write the result to _next/00-modules.md"},"uuid":"u1","timestamp":"2026-10-08T10:00:00.000Z","sessionId":"s1"}"#
    private let thinkingLine = #"{"parentUuid":"u1","isSidechain":true,"agentId":"a1","type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"EqoB"}]},"thinkingDurationMs":806,"uuid":"u2","requestId":"r1"}"#
    private let textLine = #"{"type":"assistant","agentId":"a1","message":{"role":"assistant","content":[{"type":"text","text":"I'll map the core module first."}]}}"#

    private func toolUse(_ name: String, _ input: String) -> String {
        #"{"type":"assistant","agentId":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":\#(input)}]},"wireToolInputs":{"toolu_1":{"bulk":"\#(String(repeating: "x", count: 200))"}}}"#
    }

    private func toolResult(_ content: String, error: Bool = false) -> String {
        #"{"type":"user","agentId":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":\#(content)\#(error ? #","is_error":true"# : "")}]},"toolUseResult":{"stdout":"duplicate of the result","bulk":[1,2,3]}}"#
    }

    @Test func eachKindOfLineBecomesItsEntry() {
        #expect(parser.parse(briefLine) == [.brief("Map the core module and write the result to _next/00-modules.md")])
        #expect(parser.parse(thinkingLine) == [.thought(milliseconds: 806)])
        #expect(parser.parse(textLine) == [.text("I'll map the core module first.")])
        #expect(parser.parse(toolUse("Read", #"{"file_path":"edd-core/CoreConfig.java","limit":200}"#))
                == [.toolCall(name: "Read", argument: "edd-core/CoreConfig.java")])
        #expect(parser.parse(toolResult(#""line one\nline two\nline three\n""#))
                == [.toolResult(lines: ["line one", "line two", "line three"], lineCount: 3, isError: false)])
    }

    @Test func anAttachmentLineIsSkippedBeforeAnyDecoding() {
        let attachment = #"{"parentUuid":"u1","isSidechain":true,"agentId":"a1","attachment":{"type":"skill_listing","content":"..."},"type":"attachment","uuid":"u3"}"#
        #expect(parser.parse(attachment).isEmpty)
        // The gate is a byte test: even a line that would decode as an assistant message is not decoded.
        let disguised = #"{"type":"attachment","message":{"role":"assistant","content":[{"type":"text","text":"x"}]}}"#
        #expect(parser.parse(disguised).isEmpty)
    }

    @Test func aToolCallShowsItsMainArgument() {
        func argument(_ tool: String, _ input: String) -> String? {
            guard case let .toolCall(_, value)? = parser.parse(toolUse(tool, input)).first else { return nil }
            return value
        }
        #expect(argument("Bash", #"{"command":"rg -n \"class .*Service\" edd-core | head -40\nls","description":"Find services"}"#)
                == #"rg -n "class .*Service" edd-core | head -40"#)
        for tool in ["Read", "Edit", "Write", "NotebookEdit"] {
            #expect(argument(tool, #"{"file_path":"/a/b.swift","old_string":"x","notebook_path":"/a/n.ipynb"}"#)
                    == (tool == "NotebookEdit" ? "/a/n.ipynb" : "/a/b.swift"))
        }
        #expect(argument("Grep", #"{"pattern":"TODO|FIXME","path":"Sources"}"#) == "TODO|FIXME")
        #expect(argument("Glob", #"{"pattern":"**/*.swift"}"#) == "**/*.swift")
        #expect(argument("WebFetch", #"{"url":"https://example.com/a","prompt":"summarize"}"#) == "https://example.com/a")
        #expect(argument("WebSearch", #"{"query":"swift vnode source"}"#) == "swift vnode source")
        #expect(argument("Agent", #"{"description":"Check the deps","prompt":"long brief"}"#) == "Check the deps")
        #expect(argument("Task", #"{"description":"Check the deps"}"#) == "Check the deps")
        // Another tool: the first short text field (by name, so it does not depend on dictionary order); a long
        // field, a number and a nested object are not candidates.
        #expect(argument("mcp__x__lookup", #"{"zeta":"last","alpha":"first","count":3,"long":"\#(String(repeating: "y", count: 300))","n":{"a":"b"}}"#)
                == "first")
        #expect(argument("mcp__x__lookup", #"{"count":3}"#) == "")
    }

    @Test func aResultShowsItsFirstLineItsLineCountAndWhetherItFailed() {
        func result(_ content: String, error: Bool = false) -> SubagentTranscriptEntry? { parser.parse(toolResult(content, error: error)).first }
        #expect(result(#""Wrote 96 lines""#) == .toolResult(lines: ["Wrote 96 lines"], lineCount: 1, isError: false))
        // A list of parts: the text parts count, others (an image) do not.
        #expect(result(#"[{"type":"text","text":"first\nsecond"},{"type":"image","source":{}},{"type":"text","text":"third"}]"#)
                == .toolResult(lines: ["first", "second", "third"], lineCount: 3, isError: false))
        #expect(result(#""File does not exist.""#, error: true) == .toolResult(lines: ["File does not exist."], lineCount: 1, isError: true))
        #expect(result(#""""#) == .toolResult(lines: [], lineCount: 0, isError: false))
        #expect(result(#"[{"type":"image","source":{}}]"#) == .toolResult(lines: [], lineCount: 0, isError: false))
    }

    @Test func aHugeLineIsClippedAtParseTimeOnACharacterBoundary() {
        let huge = String(repeating: "é", count: 20_000) // 40 KB of UTF-8
        let entries = parser.parse(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(huge)"}]}}"#)
        guard case let .text(whole)? = entries.first else { Issue.record("no text entry"); return }
        #expect(whole.utf8.count == 40_000, "the agent's words are cut later than a tool's output (64 KiB, FB6-18)")
        let enormous = String(repeating: "é", count: 40_000) // 80 KB
        guard case let .text(clipped)? = parser.parse(
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(enormous)"}]}}"#).first
        else { Issue.record("no text entry"); return }
        #expect(clipped.utf8.count <= parser.maximumTextBytes + "…".utf8.count)
        #expect(clipped.hasSuffix("…") && clipped.dropLast().allSatisfy { $0 == "é" })
        // A brief and a result's first line are clipped the same way.
        guard case let .brief(brief)? = parser.parse(#"{"type":"user","message":{"role":"user","content":"\#(huge)"}}"#).first else {
            Issue.record("no brief"); return
        }
        #expect(brief.utf8.count <= parser.maximumStringBytes + 3)
        guard case let .toolResult(lines, count, _)? = parser.parse(toolResult("\"\(huge)\\nmore\"")).first else {
            Issue.record("no result"); return
        }
        #expect((lines.first?.utf8.count ?? 0) <= parser.maximumStringBytes + 3 && count == 2)
    }

    @Test func aReadNamesItsRangeAndAResultKeepsMoreThanThreeLines() {
        #expect(parser.parse(toolUse("Read", #"{"file_path":"A.swift","offset":120,"limit":40}"#))
                == [.toolCall(name: "Read", argument: "A.swift (lines 120–159)")])
        #expect(parser.parse(toolUse("Read", #"{"file_path":"A.swift"}"#)) == [.toolCall(name: "Read", argument: "A.swift")])
        let output = (1...60).map { "line \($0)" }.joined(separator: "\n")
        guard case let .toolResult(lines, count, _)? = parser.parse(toolResult("\"\(output.replacingOccurrences(of: "\n", with: "\\n"))\"")).first
        else { Issue.record("no result"); return }
        #expect(count == 60 && lines.count == SubagentTranscriptParser.maximumResultLines && lines.first == "line 1")
    }

    @Test func linesThatAreNotUsableYieldNothingAndNeverThrow() {
        for line in ["", "not json", "{}", #"{"type":"assistant"}"#, #"{"type":"assistant","message":{"content":"text"}}"#,
                     #"{"type":"assistant","message":{"content":[1,"two",{"type":"tool_use"}]}}"#, #"{"type":"system","message":{}}"#] {
            let entries = parser.parse(line)
            if line.contains("tool_use") { #expect(entries == [.toolCall(name: "Tool", argument: "")]) } else { #expect(entries.isEmpty) }
        }
        // Thinking whose duration is missing, and a text block that is only whitespace.
        #expect(parser.parse(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#) == [.thought(milliseconds: nil)])
        #expect(parser.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"  \n"}]}}"#).isEmpty)
    }

    @Test func parsingALineIsCheapAndTheBulkyKeysAreNeverDecoded() {
        // A realistic assistant tool call carrying a 12 KB duplicate of its input under wireToolInputs.
        let bulky = #"{"type":"assistant","agentId":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},"wireToolInputs":{"toolu_1":{"command":"\#(String(repeating: "z", count: 12_000))"}}}"#
        let lines = [briefLine, thinkingLine, textLine, bulky, toolResult(#""ok""#)]
        let rounds = 2_000
        let clock = ContinuousClock()
        var produced = 0
        let elapsed = clock.measure {
            for index in 0..<rounds { produced += parser.parse(lines[index % lines.count]).count }
        }
        #expect(produced == rounds)
        let perLine = elapsed / rounds
        print("subagent transcript parse: \(perLine) per line over \(rounds) lines (debug build)")
        #expect(perLine < .milliseconds(5))
    }

    // MARK: Tail

    private func lines(_ tail: SubagentTranscriptTail) -> (lines: [String], outcome: SubagentTranscriptTail.Outcome) {
        var collected: [String] = []
        let outcome = tail.read { collected.append(String(decoding: $0, as: UTF8.self)) }
        return (collected, outcome)
    }

    private func tail(_ url: URL, _ id: String = "a1", in tree: Tree, window: Int = SubagentTranscriptTail.defaultColdWindowBytes,
                      maximumLine: Int = SubagentTranscriptTail.defaultMaximumLineBytes) throws -> SubagentTranscriptTail {
        let file = try #require(resolve(url, id, in: tree))
        return try #require(SubagentTranscriptTail(file: file, coldWindowBytes: window, maximumLineBytes: maximumLine))
    }

    @Test func aPartialLastLineIsNotConsumedUntilItsNewlineArrives() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", "one\ntwo\nthr")
        let tail = try tail(url, in: tree)
        #expect(lines(tail).lines == ["one", "two"])
        #expect(lines(tail).lines.isEmpty, "nothing new: the partial line stays held back")
        try append("ee\nfour", to: url)
        #expect(lines(tail).lines == ["three"])
        try append("\n", to: url)
        #expect(lines(tail).lines == ["four"])
        #expect(lines(tail).lines.isEmpty)
    }

    @Test func onlyNewBytesAreRead() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", String(repeating: "0123456789\n", count: 1_000))
        let tail = try tail(url, in: tree)
        #expect(lines(tail).lines.count == 1_000)
        let before = tail.bytesRead
        #expect(before == 11_000)
        try append("abc\n", to: url)
        #expect(lines(tail).lines == ["abc"])
        #expect(tail.bytesRead - before == 4)
        _ = lines(tail)
        #expect(tail.bytesRead - before == 4, "an idle read costs no bytes")
    }

    @Test func aLineOverTheBoundIsNamedNotDropped() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", "one\n" + String(repeating: "z", count: 300) + "\ntwo\n")
        let tail = try tail(url, in: tree, maximumLine: 100)
        var collected: [String] = []
        var oversized = 0
        _ = tail.read(oversized: { oversized += 1 }) { collected.append(String(decoding: $0, as: UTF8.self)) }
        #expect(collected == ["one", "two"] && oversized == 1, "the long line is told, not read")
    }

    @Test func aShrinkedFileIsReadAgainFromItsTail() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", "old one\nold two\nold three\n")
        let tail = try tail(url, in: tree)
        let first = lines(tail)
        #expect(first.outcome.restarted && first.lines.count == 3)
        // Rewritten in place, shorter.
        try Data("new\n".utf8).write(to: url)
        let after = lines(tail)
        #expect(after.outcome.restarted)
        #expect(after.lines == ["new"])
        #expect(!lines(tail).outcome.restarted)
    }

    @Test func aReplacedFileIsFollowedAndReadAgain() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", "old one\nold two\n")
        let tail = try tail(url, in: tree)
        #expect(lines(tail).lines.count == 2)
        // A new inode under the same name, larger than the old file so size alone would not show it.
        let replacement = try tree.write("fresh one\nfresh two\nfresh three\nfresh four\n",
                                         to: tree.subagents.appendingPathComponent("replacement.tmp"))
        _ = rename(replacement.path, url.path)
        let after = lines(tail)
        #expect(after.outcome.restarted)
        #expect(after.lines == ["fresh one", "fresh two", "fresh three", "fresh four"])
        try append("fresh five\n", to: url)
        #expect(lines(tail).lines == ["fresh five"])
    }

    @Test func aLineOverTheCapIsSkippedUpToItsNewline() throws {
        let tree = try Tree()
        defer { tree.remove() }
        // Inside one read.
        var url = try tree.transcript("a1", "short\n" + String(repeating: "x", count: 300) + "\nafter\n")
        var tail = try tail(url, in: tree, maximumLine: 100)
        #expect(lines(tail).lines == ["short", "after"])
        // Longer than a read chunk and than the default cap: bytes are dropped as they come, the buffer never
        // grows, and the line that follows is intact. The huge line is still arriving when it is first read.
        let huge = String(repeating: "y", count: SubagentTranscriptTail.defaultMaximumLineBytes + 3 * SubagentTranscriptTail.chunkBytes)
        url = try tree.transcript("a2", "before\n" + huge.prefix(150_000))
        tail = try self.tail(url, "a2", in: tree)
        #expect(lines(tail).lines == ["before"])
        try append(String(huge.dropFirst(150_000)) + "\nafter\npartial", to: url)
        #expect(lines(tail).lines == ["after"])
        try append(" done\n", to: url)
        #expect(lines(tail).lines == ["partial done"])
    }

    @Test func aColdOpenStartsAtALineBoundaryInsideTheTailWindowAndKeepsTheBrief() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let content = (0..<400).map { "line \($0) " + String(repeating: "x", count: $0 % 17) }
        let text = content.joined(separator: "\n") + "\n"
        let url = try tree.transcript("a1", text)
        let size = text.utf8.count
        let window = 1_000
        let tail = try tail(url, in: tree, window: window)
        let (delivered, outcome) = lines(tail)
        #expect(outcome.restarted && outcome.omittedEarlier)
        // The brief (first line), then exactly the lines that start inside the window; none is cut.
        var offsets: [Int] = [], running = 0
        for line in content { offsets.append(running); running += line.utf8.count + 1 }
        let expected = [content[0]] + zip(content, offsets).filter { $0.1 >= size - window }.map(\.0)
        #expect(delivered == expected)
        #expect(delivered.count < content.count / 2)
        #expect(tail.bytesRead < window + SubagentTranscriptTail.headBytes + 2)
    }

    @Test func aColdOpenWhoseWindowStartsExactlyOnALineKeepsThatLine() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let text = (0..<100).map { String(format: "line-%04d\n", $0) }.joined() // 10 bytes each
        let url = try tree.transcript("a1", text)
        let tail = try tail(url, in: tree, window: 100)
        let delivered = lines(tail).lines
        #expect(delivered == ["line-0000"] + (90..<100).map { String(format: "line-%04d", $0) })
    }

    @Test func aColdOpenOfALargeFileReadsOnlyItsTail() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript()
        // About 6 MB, the largest transcript seen: 2,600 lines of about 2.3 KB.
        let filler = String(repeating: "x", count: 2_200)
        let text = (0..<2_600).map { #"{"type":"assistant","message":{"content":[{"type":"text","text":"line \#($0) \#(filler)"}]}}"# }
            .joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let size = text.utf8.count
        let file = try #require(SubagentTranscriptLocation.resolve(path: url.path, agentID: "a1", projectsDirectory: tree.projects))
        let tail = try #require(SubagentTranscriptTail(file: file))
        var delivered = 0
        let outcome = tail.read { _ in delivered += 1 }
        print("cold open of \(size) bytes read \(tail.bytesRead) bytes and delivered \(delivered) lines")
        #expect(outcome.omittedEarlier && tail.bytesRead <= SubagentTranscriptTail.defaultColdWindowBytes + SubagentTranscriptTail.headBytes + 1)
        #expect(delivered < 260 && delivered > 200)
    }

    @Test func aFileSmallerThanTheWindowIsReadWhole() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", "a\nb\nc\n")
        let (delivered, outcome) = lines(try tail(url, in: tree))
        #expect(delivered == ["a", "b", "c"] && outcome.restarted && !outcome.omittedEarlier)
    }

    // MARK: Feed

    private final class Collector: Sendable {
        private final class Box: Sendable {
            let state = Mutex<(batches: [SubagentTranscriptBatch], finished: Bool)>(([], false))
        }

        private let box = Box()

        init(_ feed: SubagentTranscriptFeed) {
            let stream = feed.batches
            let box = box
            Task {
                for await batch in stream { box.state.withLock { $0.batches.append(batch) } }
                box.state.withLock { $0.finished = true }
            }
        }

        var batches: [SubagentTranscriptBatch] { box.state.withLock { $0.batches } }
        var finished: Bool { box.state.withLock { $0.finished } }
    }

    private func wait(_ seconds: TimeInterval = 3, until condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func feed(_ url: URL, in tree: Tree, coalescing: TimeInterval = 0.05) throws -> SubagentTranscriptFeed {
        let file = try #require(resolve(url, in: tree))
        return try #require(SubagentTranscriptFeed(file: file, coalescing: coalescing))
    }

    @Test func theFeedDeliversTheTailAtOnceThenOneBatchPerAppend() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", briefLine + "\n" + textLine + "\n")
        let feed = try feed(url, in: tree)
        let collector = Collector(feed)
        feed.start()
        defer { feed.stop() }
        #expect(await wait { collector.batches.count == 1 })
        let first = try #require(collector.batches.first)
        #expect(first.replacesEarlier && !first.omitsEarlier)
        #expect(first.entries == [.brief("Map the core module and write the result to _next/00-modules.md"),
                                  .text("I'll map the core module first.")])

        // Two lines written back to back, an attachment among them: one batch, the attachment skipped.
        try append(thinkingLine + "\n" + #"{"type":"attachment","attachment":{}}"# + "\n" + toolUse("Bash", #"{"command":"ls"}"#) + "\n", to: url)
        #expect(await wait { collector.batches.count == 2 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(collector.batches.count == 2)
        #expect(collector.batches[1].replacesEarlier == false)
        #expect(collector.batches[1].entries == [.thought(milliseconds: 806), .toolCall(name: "Bash", argument: "ls")])
    }

    @Test func anIdleFileDeliversNothing() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", textLine + "\n")
        let feed = try feed(url, in: tree)
        let collector = Collector(feed)
        feed.start()
        defer { feed.stop() }
        #expect(await wait { collector.batches.count == 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(collector.batches.count == 1)
        // A write that completes no line is an event with nothing to deliver.
        try append(#"{"type":"assistant","mess"#, to: url)
        try await Task.sleep(for: .milliseconds(300))
        #expect(collector.batches.count == 1)
    }

    @Test func aBurstOfWritesIsCoalescedIntoFewReads() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", "")
        let feed = try feed(url, in: tree, coalescing: 0.2)
        let collector = Collector(feed)
        feed.start()
        defer { feed.stop() }
        #expect(await wait { collector.batches.count == 1 })
        let clock = ContinuousClock(), began = clock.now
        for _ in 0..<20 {
            try append(textLine + "\n", to: url)
            try await Task.sleep(for: .milliseconds(10))
        }
        let spent = clock.now - began
        #expect(await wait { collector.batches.dropFirst().reduce(0) { $0 + $1.entries.count } == 20 })
        // At most one read per coalescing window the writes spanned, plus the one after the last write. About
        // 200 ms of writes gives a few batches, not 20; a loaded machine that stretches the loop gets more windows.
        let windows = Int((spent / .milliseconds(200)).rounded(.up)) + 1
        #expect(collector.batches.count - 1 <= max(3, windows),
                "20 writes over \(spent) are read once per window at most, not once per write")
    }

    @Test func afterStopNothingArrivesAndTheFilesAreClosed() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", textLine + "\n")
        let feed = try feed(url, in: tree)
        let collector = Collector(feed)
        feed.start()
        #expect(await wait { collector.batches.count == 1 })
        let descriptors = feed.openDescriptors
        let transcript = try #require(FileIdentity(path: url.path))
        #expect(descriptors.count == 2 && descriptors.allSatisfy { FileIdentity(descriptor: $0) == transcript })
        feed.stopAndWait()
        #expect(descriptors.allSatisfy { FileIdentity(descriptor: $0) != transcript }, "both descriptors are closed")
        #expect(await wait { collector.finished }, "the stream ends")
        try append(textLine + "\n", to: url)
        try await Task.sleep(for: .milliseconds(300))
        #expect(collector.batches.count == 1)
        // Idempotent, and a stopped feed does not start again.
        feed.stop()
        feed.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(collector.batches.count == 1 && feed.openDescriptors.isEmpty)
    }

    @Test func aPlainStopLetsNothingMoreThroughAndClosesTheFilesSoon() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", textLine + "\n")
        let feed = try feed(url, in: tree)
        let collector = Collector(feed)
        feed.start()
        #expect(await wait { collector.batches.count == 1 })
        let descriptors = feed.openDescriptors
        let transcript = try #require(FileIdentity(path: url.path))
        #expect(descriptors.count == 2)
        feed.stop() // returns without waiting for the teardown
        #expect(await wait { descriptors.allSatisfy { FileIdentity(descriptor: $0) != transcript } },
                "both descriptors are closed")
        #expect(await wait { collector.finished }, "the stream ends")
        try append(textLine + "\n", to: url)
        try await Task.sleep(for: .milliseconds(300))
        #expect(collector.batches.count == 1)
        feed.stop() // idempotent, with the waiting form too
        feed.stopAndWait()
        #expect(feed.openDescriptors.isEmpty)
    }

    @Test func aReplacedFileIsFollowedByTheFeed() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let url = try tree.transcript("a1", textLine + "\n")
        let feed = try feed(url, in: tree)
        let collector = Collector(feed)
        feed.start()
        defer { feed.stop() }
        #expect(await wait { collector.batches.count == 1 })
        let replacement = try tree.write(briefLine + "\n" + textLine + "\n" + textLine + "\n",
                                         to: tree.subagents.appendingPathComponent("replacement.tmp"))
        _ = rename(replacement.path, url.path)
        #expect(await wait { collector.batches.count == 2 })
        #expect(collector.batches[1].replacesEarlier && collector.batches[1].entries.count == 3)
        try append(thinkingLine + "\n", to: url)
        #expect(await wait { collector.batches.count == 3 })
        #expect(collector.batches[2].entries == [.thought(milliseconds: 806)] && !collector.batches[2].replacesEarlier)
    }

    @Test func aBurstLargerThanABatchKeepsItsNewestEntries() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        let count = SubagentTranscriptFeed.maximumEntriesPerBatch + 50
        let text = (0..<count).map {
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"entry \#($0)"}]}}"#
        }.joined(separator: "\n") + "\n"
        let url = try tree.transcript("a1", text)
        let feed = try feed(url, in: tree)
        let collector = Collector(feed)
        feed.start()
        defer { feed.stop() }
        #expect(await wait { collector.batches.count == 1 })
        let batch = try #require(collector.batches.first)
        #expect(batch.entries.count == SubagentTranscriptFeed.maximumEntriesPerBatch && batch.omitsEarlier)
        #expect(batch.entries.last == .text("entry \(count - 1)"))
    }
}

/// The file a descriptor refers to. The suites run in parallel in one process, so the kernel can hand a
/// closed descriptor's number to another test's file at once: a descriptor is closed when it no longer
/// refers to its file, not when its number is unused.
private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        (device, inode) = (info.st_dev, info.st_ino)
    }

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        (device, inode) = (info.st_dev, info.st_ino)
    }
}
