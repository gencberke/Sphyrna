import Foundation
import Testing
@testable import LoomCore

@Suite struct CodexChangesTests {
    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }
    private func user(_ text: String) -> [String: Any] {
        ["type": "response_item", "payload": ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": text]]]]
    }

    @Test func structuredEditsUseTheirOwnTurnCwdAndIgnoreShellAndDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-changes-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project", isDirectory: true)
        let first = workspace.appendingPathComponent("one", isDirectory: true)
        let second = workspace.appendingPathComponent("two", isDirectory: true)
        let day = root.appendingPathComponent("home/sessions/2026/10/28", isDirectory: true)
        for folder in [first, second, day] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let id = UUID().uuidString.lowercased()
        let path = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(id).jsonl")
        let edit: [String: Any] = ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "turn-b", "item":
            ["type": "FileChange", "id": "edit-b", "status": "completed", "changes": ["b.swift":
                ["type": "update", "unified_diff": "@@ -1 +1 @@\n-old\n+new\n", "move_path": NSNull()]]]]]
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": workspace.path]],
            ["type": "turn_context", "payload": ["turn_id": "turn-a", "cwd": first.path]],
            user("Add A"),
            ["type": "event_msg", "payload": ["type": "patch_apply_end", "call_id": "edit-a", "turn_id": "turn-a",
                "success": true, "changes": ["a.swift": ["type": "add", "content": "a\n"]]]],
            ["type": "turn_context", "payload": ["turn_id": "turn-b", "cwd": second.path]],
            user("Edit B"), edit, edit,
            ["type": "response_item", "payload": ["type": "custom_tool_call", "name": "shell", "input": "echo fake.swift"]],
        ]
        try records.map(line).joined().write(to: path, atomically: true, encoding: .utf8)
        let file = CodexRolloutFile(path: path.path, sessionID: id)
        let whole = try #require(CodexChangesReader.scan(file: file, workspace: workspace.path, scope: .wholeSession))
        #expect(!whole.partial)
        #expect(whole.changes.map(\.path).map { URL(fileURLWithPath: $0).lastPathComponent } == ["a.swift", "b.swift"])
        #expect(whole.changes.first?.path.hasSuffix("/one/a.swift") == true)
        #expect(whole.changes.last?.path.hasSuffix("/two/b.swift") == true)
        #expect(whole.changes.map { $0.hunks.reduce(0) { $0 + $1.added } } == [1, 1])
        let last = try #require(CodexChangesReader.scan(file: file, workspace: workspace.path, scope: .lastTurn))
        #expect(!last.partial)
        #expect(last.changes.count == 1 && last.changes.first?.path.hasSuffix("/two/b.swift") == true)
    }

    @Test func unresolvedOrOutsidePathsStayPartialAndAreNotPresented() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-changes-scope-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout.jsonl")
        let records: [[String: Any]] = [
            ["type": "event_msg", "payload": ["type": "patch_apply_end", "call_id": "outside", "turn_id": "missing",
                "success": true, "changes": [root.appendingPathComponent("outside").path: ["type": "add", "content": "x\n"]]]],
            ["type": "event_msg", "payload": ["type": "patch_apply_end", "call_id": "relative", "turn_id": "missing",
                "success": true, "changes": ["unknown.txt": ["type": "add", "content": "x\n"]]]],
            ["type": "event_msg", "payload": ["type": "patch_apply_end", "call_id": "failed", "success": false,
                "changes": [workspace.appendingPathComponent("never").path: ["type": "add", "content": "x"]]]],
        ]
        try records.map(line).joined().write(to: file, atomically: true, encoding: .utf8)
        let result = try #require(CodexChangesReader.scan(file: CodexRolloutFile(path: file.path, sessionID: UUID().uuidString),
                                                        workspace: workspace.path, scope: .wholeSession))
        #expect(result.partial)
        #expect(result.changes.isEmpty)
    }
}
