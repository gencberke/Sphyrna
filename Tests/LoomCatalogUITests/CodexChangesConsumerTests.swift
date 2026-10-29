import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

@MainActor
@Suite struct CodexChangesConsumerTests {
    actor ReadGate {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered = true
            }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    @Test func changesModelShowsOnlyVerifiedScopedCodexEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-changes-model-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project", isDirectory: true)
        let turn = workspace.appendingPathComponent("subfolder", isDirectory: true)
        let home = root.appendingPathComponent("codex", isDirectory: true)
        let day = home.appendingPathComponent("sessions/2026/10/28", isDirectory: true)
        for folder in [turn, day] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let id = UUID().uuidString.lowercased()
        let file = day.appendingPathComponent("rollout-2026-10-28T19-24-03-\(id).jsonl")
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": workspace.path]],
            ["type": "turn_context", "payload": ["turn_id": "turn-1", "cwd": turn.path]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content":
                [["type": "input_text", "text": "Add a file"]]]],
            ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "turn-1", "item":
                ["type": "FileChange", "id": "edit-1", "status": "completed", "changes":
                    ["added.swift": ["type": "add", "content": "hello\n"]]]]],
            ["type": "event_msg", "payload": ["type": "patch_apply_end", "turn_id": "turn-1", "call_id": "outside",
                "success": true, "changes": [root.appendingPathComponent("outside.txt").path:
                    ["type": "add", "content": "outside\n"]]]],
            ["type": "response_item", "payload": ["type": "custom_tool_call", "name": "shell", "input": "echo fake.swift"]],
        ]
        try records.map(line).joined().write(to: file, atomically: true, encoding: .utf8)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .codex, providerConversationID: id, workingDirectory: workspace.path)
        try await catalog.insertSession(session, title: "Codex", createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui.json")))
        defer { model.stop() }
        await model.start()
        model.select(session.id)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.selectedRow == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let row = try #require(model.selectedRow)
        model.openChanges(.lastTurn, for: session.id)
        await model.runChangesRead()
        enableAccessibilityTree()
        func overviewLabels() throws -> [String] {
            let host = NSHostingView(rootView: InspectorOverview(model: model, row: row).frame(width: 400, height: 1_200))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 1_200)
            host.layoutSubtreeIfNeeded()
            let elements = accessibilityElements(in: host)
            _ = try #require(elements.first { $0.accessibilityIdentifier?() == "overview-changes" }, "the Changes card must be hosted")
            return elements.flatMap { [InkAX.label($0), InkAX.value($0), InkAX.text($0, "accessibilityTitle")].compactMap { $0 } }
        }
        #expect(try overviewLabels().contains("Codex's session files have not been located."))
        model.openChanges(.wholeSession, for: session.id)
        await model.runChangesRead()
        if case .off = model.changes.session(for: session.id).currentState {} else {
            Issue.record("An unknown Codex home must not be reported as an empty scan")
        }
        model.changes.session(for: session.id).setState(.ready(ChangesScopeData(files: [])), for: .wholeSession)
        let changesHost = NSHostingView(rootView: ChangesTab(model: model, row: row).frame(width: 400, height: 800))
        changesHost.frame = NSRect(x: 0, y: 0, width: 400, height: 800)
        changesHost.layoutSubtreeIfNeeded()
        let emptyLabels = accessibilityElements(in: changesHost).flatMap {
            [InkAX.label($0), InkAX.value($0), InkAX.text($0, "accessibilityTitle")].compactMap { $0 }
        }
        #expect(emptyLabels.contains("Codex has not edited files in this session."))
        model.setCodexConfigDirectory(home)
        await model.runChangesRead()
        let state = model.changes.session(for: session.id).currentState
        let data = try #require(state.data)
        #expect(data.files.count == 1)
        #expect(data.files.first?.displayPath == "subfolder/added.swift")
        #expect(data.files.first?.status == .added)
        #expect(data.files.first?.added == 1 && data.partial)
        model.changes.session(for: session.id).setState(.ready(data), for: .lastTurn)
        let labels = try overviewLabels()
        #expect(labels.contains { $0.contains("added.swift") })
        #expect(labels.contains("Some edits could not be read."))
        #expect(ChangesBodyWords.note(scope: .wholeSession, state: state, harnessName: "Codex")
                == "Codex's file edits. Shell commands and subagents show under Branch. Some edits could not be read.")
        #expect(model.changesSendAvailability(for: session.id) == .notChat)
        let held = model.changes.session(for: session.id)
        let anchor = ChangeAnchor(fileID: try #require(data.files.first?.id), line: 1, removed: false, text: "hello")
        held.saveComment("draft", at: anchor, displayPath: "subfolder/added.swift", in: .wholeSession)
        let previousTrigger = model.changesTrigger
        let oldResult = try #require(CodexChangesReader.scan(
            file: CodexRolloutFile(path: file.path, sessionID: id), workspace: workspace.path, scope: .wholeSession))
        let gate = ReadGate()
        defer { Task { await gate.release() } }
        var reader = model.changes.reader
        reader.codexScan = { _, _ in await gate.hold(); return oldResult }
        model.changes.reader = reader
        let staleRead = Task { await model.runChangesRead() }
        let waitUntil = ContinuousClock.now + .seconds(5)
        while !(await gate.entered) && ContinuousClock.now < waitUntil { try await Task.sleep(for: .milliseconds(10)) }
        _ = try #require(await gate.entered)
        model.setCodexConfigDirectory(nil)
        #expect(held.currentState == .idle)
        model.setCodexConfigDirectory(home)
        #expect(held.currentState == .idle)
        #expect(model.changesTrigger != previousTrigger, "A→B→A must not accept a late read from the first A")
        #expect(held.comments(in: .wholeSession).map(\.text) == ["draft"])
        await gate.release()
        await staleRead.value
        #expect(held.currentState == .idle, "the held read from the first profile must not restore old bytes")
        model.changes.reader = .live(git: nil)
        await model.runChangesRead()
        #expect(held.currentState.data?.files.count == 1)
        #expect(held.comments(in: .wholeSession).map(\.text) == ["draft"])
    }
}
