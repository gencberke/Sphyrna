import AppKit
import Foundation
import LoomChat
import LoomCore
import Testing
@testable import LoomCatalogUI

extension ChatHosted {
    /// V20: the changed-files card's "Open in Changes" asks for the last turn when the card is the newest turn's and for the
    /// whole session when it is an older one's. The model is the stopped-session stream over a real transcript file in a
    /// temporary Claude config directory (never the real `~/.claude`).
    @MainActor
    @Suite
    struct ChangesCardTests {
        private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        @Test func openInChangesPicksTheLastTurnForTheNewestCardAndTheWholeSessionForAnOlderOne() async throws {
            ChatSessionMemoryStore.removeAll()
            let id = UUID().uuidString.lowercased()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-changes-card-\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = root.appendingPathComponent("projects/-tmp-changes-card", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let input: JSONValue = ["file_path": "/tmp/card/a.txt", "old_string": "a", "new_string": "b"]
            let edit = (name: "Edit", input: input, output: "ok")
            let lines = ChatFixture.turn(1, tools: [edit], answer: "First.") + ChatFixture.turn(2, tools: [edit], answer: "Second.", start: 30)
            try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)

            let model = ChatTranscriptModel(sessionID: id, configDirectory: root, workingDirectory: "/tmp/card")
            defer { model.close() }
            var asked: [Bool] = []
            model.onOpenChanges = { asked.append($0) }
            model.setOnScreen(true)
            #expect(await waitUntil { model.phase == .ready })
            let cards = model.controller.rows.compactMap { row -> ChangedFiles? in
                if case let .changedFiles(card) = row.kind { card } else { nil }
            }
            #expect(cards.count == 2, "a card for each turn")
            let open = try #require(model.controller.context.openChanges)
            for card in cards { open(card.turnID) }
            #expect(asked == [false, true], "the older card opens the whole session, the newest turn's the last turn")
        }
    }
}
