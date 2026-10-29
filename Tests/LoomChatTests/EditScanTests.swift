import Foundation
import LoomCore
import Testing
@testable import LoomChat
@testable import LoomChatTestRigs

/// The Changes tab's source for the turn scopes (V20): Claude's own edits, read from the end of the session's transcript.
/// Every file is made in a temporary folder and removed.
@Suite(.timeLimit(.minutes(2)))
struct EditScanTests {
    private struct Tree {
        let root: URL
        var url: URL { root.appendingPathComponent("projects/-tmp-work/sess1.jsonl") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-editscan-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-tmp-work"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func write(_ lines: [String]) throws -> ClaudeTranscriptFile {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return try #require(ClaudeTranscriptLocator.locate(sessionID: "sess1", configDirectory: root))
        }
    }

    // MARK: Records

    private static func prompt(_ text: String, _ n: Int) -> String {
        Fixture.transcriptUser(text, uuid: "u\(n)", time: "2026-10-17T10:0\(n):00.000Z")
    }

    private static func call(_ id: String, _ name: String, _ input: JSONValue, sidechain: Bool = false) -> String {
        Fixture.line(["type": "assistant", "uuid": .string("a-" + id), "sessionId": "s1", "timestamp": "2026-10-17T10:00:05.000Z",
                      "isSidechain": .bool(sidechain),
                      "message": ["id": .string("m-" + id), "role": "assistant", "model": "claude-opus-5-5",
                                  "content": [Fixture.toolUse(id, name, input)]]])
    }

    private static func result(_ id: String, _ structured: JSONValue?, isError: Bool = false, time: String = "2026-10-17T10:00:06.000Z",
                               sidechain: Bool = false) -> String {
        var fields: [String: JSONValue] = [
            "type": "user", "uuid": .string("r-" + id), "sessionId": "s1", "timestamp": .string(time), "isSidechain": .bool(sidechain),
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": "ok",
                                                    "is_error": .bool(isError)]]],
        ]
        if let structured { fields["toolUseResult"] = structured }
        return Fixture.line(.object(fields))
    }

    private static func hunk(_ oldStart: Int, _ oldLines: Int, _ newStart: Int, _ newLines: Int, _ lines: [String]) -> JSONValue {
        ["oldStart": .number(Double(oldStart)), "oldLines": .number(Double(oldLines)),
         "newStart": .number(Double(newStart)), "newLines": .number(Double(newLines)), "lines": .array(lines.map(JSONValue.string))]
    }

    private static func edit(_ id: String, _ path: String, _ hunks: [JSONValue], time: String = "2026-10-17T10:00:06.000Z") -> [String] {
        [call(id, "Edit", ["file_path": .string(path), "old_string": "a", "new_string": "b"]),
         result(id, ["filePath": .string(path), "structuredPatch": .array(hunks)], time: time)]
    }

    // MARK: Tests

    @Test func writeEditMultiEditAndNotebookEditGiveHunksPerFileInFirstEditOrder() throws {
        let tree = try Tree()
        defer { tree.remove() }
        var lines = [Self.prompt("make it", 1)]
        // A Write that makes a file: its patch is empty and its content is the hunk.
        lines += [Self.call("w1", "Write", ["file_path": "/w/a.txt", "content": "one\ntwo\n"]),
                  Self.result("w1", ["type": "create", "filePath": "/w/a.txt", "content": "one\ntwo\n", "structuredPatch": []])]
        lines += Self.edit("e1", "/w/b.txt", [Self.hunk(3, 4, 3, 5, [" c", "-old", "+new", "+extra", " d", " e"])])
        // A Write over an existing file (an update) has a real patch; a second edit of the first file.
        lines += [Self.call("w2", "Write", ["file_path": "/w/a.txt", "content": "one\nTWO\n"]),
                  Self.result("w2", ["type": "update", "filePath": "/w/a.txt", "content": "one\nTWO\n",
                                     "structuredPatch": [Self.hunk(1, 2, 1, 2, [" one", "-two", "+TWO"])]],
                              time: "2026-10-17T10:00:09.000Z")]
        lines += [Self.call("m1", "MultiEdit", ["file_path": "/w/c.txt", "edits": []]),
                  Self.result("m1", ["filePath": "/w/c.txt", "structuredPatch": [Self.hunk(1, 1, 1, 1, ["-x", "+y"])]])]
        lines += [Self.call("n1", "NotebookEdit", ["notebook_path": "/w/n.ipynb", "new_source": "x = 1\ny = 2"]),
                  Self.result("n1", ["notebook_path": "/w/n.ipynb", "new_source": "x = 1\ny = 2", "edit_mode": "replace", "cell_id": "c1"])]
        let result = EditScan.scan(file: try tree.write(lines), scope: .wholeSession)

        #expect(result.files.map(\.path) == ["/w/a.txt", "/w/b.txt", "/w/c.txt", "/w/n.ipynb"])
        #expect(!result.truncated)
        let a = try #require(result.files.first)
        #expect(a.edits.map(\.toolName) == ["Write", "Write"] && a.edits.map(\.toolUseID) == ["w1", "w2"])
        #expect(a.edits[0].isCreate && !a.edits[1].isCreate)
        #expect(a.edits[0].hunks == [DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 2, lines: ["+one", "+two"])])
        #expect(a.edits[1].hunks == [DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [" one", "-two", "+TWO"])])
        #expect(a.added == 3 && a.removed == 1)
        #expect(a.lastEdit?.toolUseID == "w2")
        #expect(a.edits[1].timestamp.map { $0 > (a.edits[0].timestamp ?? .distantFuture) } == true)
        // The numbers of an edit's hunk are the patch's: context and added lines on the new side, removed on the old.
        let b = result.files[1].hunks[0]
        #expect(b.rows.map(\.newNumber) == [3, nil, 4, 5, 6, 7] && b.rows.map(\.oldNumber) == [3, 4, nil, nil, 5, 6])
        #expect(result.files[2].edits[0].toolName == "MultiEdit" && result.files[2].added == 1)
        // A notebook edit has no patch: the cell's source is shown as added lines, without line numbers.
        let notebook = result.files[3].hunks[0]
        #expect(notebook.lines == ["+x = 1", "+y = 2"] && !notebook.isNumbered && notebook.rows.allSatisfy { $0.newNumber == nil })
    }

    @Test func lastTurnBeginsAtTheNewestPromptAndTheWholeSessionReadsOnPastIt() throws {
        let tree = try Tree()
        defer { tree.remove() }
        var lines = [Self.prompt("first", 1)]
        lines += Self.edit("e1", "/w/old.txt", [Self.hunk(1, 1, 1, 1, ["-a", "+b"])])
        lines += [Self.prompt("second", 2)]
        lines += Self.edit("e2", "/w/new.txt", [Self.hunk(1, 1, 1, 1, ["-a", "+b"])])
        // A tool result is not a prompt, and neither is a meta record: the turn goes on past them.
        lines += Self.edit("e3", "/w/new2.txt", [Self.hunk(1, 1, 1, 1, ["-a", "+b"])])
        let file = try tree.write(lines)
        #expect(EditScan.scan(file: file, scope: .lastTurn).files.map(\.path) == ["/w/new.txt", "/w/new2.txt"])
        #expect(EditScan.scan(file: file, scope: .wholeSession).files.map(\.path) == ["/w/old.txt", "/w/new.txt", "/w/new2.txt"])
        // Before the first prompt there is nothing yet: the last turn is empty.
        #expect(EditScan.scan(file: try tree.write([Self.prompt("only", 1)]), scope: .lastTurn).files.isEmpty)
    }

    @Test func aPromptSentByLoomIsAPromptAndASubagentsOrAMetaRecordIsNot() throws {
        let tree = try Tree()
        defer { tree.remove() }
        var lines = [Self.prompt("first", 1)]
        lines += Self.edit("e1", "/w/before.txt", [Self.hunk(1, 1, 1, 1, ["-a", "+b"])])
        // The prompt Loom sent echoes with origin human; a task notification and a meta record begin no turn.
        lines += [Fixture.transcriptUser("from loom", uuid: "u2", extra: ["origin": ["kind": "human"]])]
        lines += Self.edit("e2", "/w/after.txt", [Self.hunk(1, 1, 1, 1, ["-a", "+b"])])
        lines += [Fixture.transcriptUser("<task-notification>done</task-notification>", uuid: "u3", extra: ["origin": ["kind": "task-notification"]]),
                  Fixture.transcriptUser("injected skill text", uuid: "u4", extra: ["isMeta": true])]
        lines += Self.edit("e3", "/w/later.txt", [Self.hunk(1, 1, 1, 1, ["-a", "+b"])])
        #expect(EditScan.scan(file: try tree.write(lines), scope: .lastTurn).files.map(\.path) == ["/w/after.txt", "/w/later.txt"])
    }

    @Test func theByteBoundStopsTheReadAndSaysOlderEditsWereNotRead() throws {
        let tree = try Tree()
        defer { tree.remove() }
        var lines = [Self.prompt("go", 1)]
        for index in 0..<40 {
            lines += Self.edit("e\(index)", "/w/f\(index).txt", [Self.hunk(1, 1, 1, 1, ["-a", "+b"])])
        }
        let file = try tree.write(lines)
        let size = try FileManager.default.attributesOfItem(atPath: tree.url.path)[.size] as! Int
        let whole = EditScan.scan(file: file, scope: .wholeSession, byteLimit: size + 1_000, pageBytes: 1_024)
        #expect(whole.files.count == 40 && !whole.truncated)

        let bounded = EditScan.scan(file: file, scope: .wholeSession, byteLimit: size / 4, pageBytes: 1_024)
        #expect(bounded.truncated)
        #expect(bounded.files.count > 0 && bounded.files.count < 40)
        // What it has is the newest part, whole: the last file is there, the first is not.
        #expect(bounded.files.last?.path == "/w/f39.txt" && !bounded.files.contains { $0.path == "/w/f0.txt" })
        #expect(bounded.bytesCovered <= size / 4 + 1_024)
        // The last turn that is longer than the bound is cut the same way.
        #expect(EditScan.scan(file: file, scope: .lastTurn, byteLimit: size / 4, pageBytes: 1_024).truncated)
    }

    @Test func failedCallsAndRecordsOfUnknownShapeAreSkipped() throws {
        let tree = try Tree()
        defer { tree.remove() }
        var lines = [Self.prompt("go", 1)]
        let patch = [Self.hunk(1, 1, 1, 1, ["-a", "+b"])]
        // A failed call (is_error) is not an edit, even with a patch in its result.
        lines += [Self.call("f1", "Edit", ["file_path": "/w/failed.txt"]),
                  Self.result("f1", ["filePath": "/w/failed.txt", "structuredPatch": .array(patch)], isError: true)]
        // A result that is not an object, one without a patch, a hunk that lacks its lines, a relative path.
        lines += [Self.call("u1", "Edit", ["file_path": "/w/string.txt"]), Self.result("u1", "ok")]
        lines += [Self.call("u2", "Edit", ["file_path": "/w/nopatch.txt"]), Self.result("u2", ["filePath": "/w/nopatch.txt"])]
        lines += [Self.call("u3", "Edit", ["file_path": "/w/badhunk.txt"]),
                  Self.result("u3", ["filePath": "/w/badhunk.txt", "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1]]])]
        lines += [Self.call("u4", "Edit", ["file_path": "relative.txt"]), Self.result("u4", ["filePath": "relative.txt", "structuredPatch": .array(patch)])]
        // A call whose result never came, a tool that is not an edit tool, and a subagent's edit.
        lines += [Self.call("p1", "Edit", ["file_path": "/w/pending.txt"])]
        lines += [Self.call("r1", "Read", ["file_path": "/w/read.txt"]), Self.result("r1", ["structuredPatch": .array(patch), "filePath": "/w/read.txt"])]
        lines += [Self.call("s1", "Edit", ["file_path": "/w/sub.txt"], sidechain: true),
                  Self.result("s1", ["filePath": "/w/sub.txt", "structuredPatch": .array(patch)], sidechain: true)]
        lines += Self.edit("good", "/w/good.txt", patch)
        // A line that is not JSON at all.
        lines += ["{not json"]
        let result = EditScan.scan(file: try tree.write(lines), scope: .wholeSession)
        #expect(result.files.map(\.path) == ["/w/good.txt"])
    }
}
