import AppKit
import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

extension ChatHosted {
    /// The model over real transcript files in a temporary Claude config directory (never the real `~/.claude`).
    @MainActor
    @Suite
    struct ChatTranscriptModelTests {
        struct Profile {
            let root: URL
            let id: String
            let file: URL

            init(id: String = UUID().uuidString.lowercased(), lines: [String]) throws {
                self.id = id
                root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-test-\(UUID().uuidString)", isDirectory: true)
                let folder = root.appendingPathComponent("projects/-tmp-chat-test", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                file = folder.appendingPathComponent("\(id).jsonl")
                try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            }

            func append(_ lines: [String]) throws {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            }

            /// Another session's transcript in the same config directory.
        @discardableResult
        func addSession(id: String, lines: [String]) throws -> URL {
            let url = file.deletingLastPathComponent().appendingPathComponent("\(id).jsonl")
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        }

        private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        private func opened(_ profile: Profile, working: String? = nil) async -> ChatTranscriptModel {
            let model = ChatTranscriptModel(sessionID: profile.id, configDirectory: profile.root, workingDirectory: working)
            model.setOnScreen(true)
            _ = await waitUntil { model.phase != .resolving }
            return model
        }

        @Test func aTranscriptOpensAndItsRowsAreDerived() async throws {
            ChatSessionMemoryStore.removeAll()
            let profile = try Profile(lines: ChatFixture.turn(1, tools: [ChatFixture.bash("ls")]) + ChatFixture.turn(2, answer: "Second."))
            defer { profile.remove() }
            let model = await opened(profile)
            #expect(model.phase == .ready)
            #expect(model.controller.rows.map(\.kind.tag) == ["start", "user", "fold", "answer", "user", "answer"])
            model.close()
        }

        @Test func aMissingTranscriptLeavesTheFallbackToTheOwner() async throws {
            let profile = try Profile(lines: ChatFixture.turn(1))
            defer { profile.remove() }
            let model = ChatTranscriptModel(sessionID: "00000000-0000-0000-0000-000000000000", configDirectory: profile.root, workingDirectory: nil)
            model.setOnScreen(true)
            _ = await waitUntil { model.phase != .resolving }
            #expect(model.phase == .unavailable)
            #expect(!model.isFeeding)
            model.close()
        }

        @Test func aRunningSessionIsFollowedWhileTheWindowIsVisible() async throws {
            ChatSessionMemoryStore.removeAll()
            let profile = try Profile(lines: ChatFixture.turn(1))
            defer { profile.remove() }
            let model = await opened(profile)
            model.setWindowVisible(true)
            #expect(model.isFeeding)
            try profile.append(ChatFixture.turn(2, answer: "Arrived.", start: 30))
            let arrived = await waitUntil { model.controller.rows.contains { $0.id == "u2" } }
            #expect(arrived)
            model.close()
        }

        @Test func aHiddenWindowStopsTheFeedAndCatchesUpWhenShown() async throws {
            ChatSessionMemoryStore.removeAll()
            let profile = try Profile(lines: ChatFixture.turn(1))
            defer { profile.remove() }
            let model = await opened(profile)
            model.setWindowVisible(true)
            #expect(model.isFeeding)
            model.setWindowVisible(false)
            #expect(!model.isFeeding)
            #expect(!model.controller.context.clock.isRunning)
            try profile.append(ChatFixture.turn(2, answer: "While hidden.", start: 30))
            try? await Task.sleep(for: .milliseconds(300))
            #expect(!model.controller.rows.contains { $0.id == "u2" }, "nothing is read while hidden")
            model.setWindowVisible(true)
            let caught = await waitUntil { model.controller.rows.contains { $0.id == "u2" } }
            #expect(caught, "showing the window reads what was written meanwhile")
            model.close()
        }

        @Test func aViewThatLeavesTheScreenWatchesNothing() async throws {
            let profile = try Profile(lines: ChatFixture.turn(1))
            defer { profile.remove() }
            let model = await opened(profile)
            model.setWindowVisible(true)
            #expect(model.isFeeding)
            model.setOnScreen(false)
            #expect(!model.isFeeding)
            model.close()
        }

        @Test func viewAndOpenFoldsComeBackWhenTheSessionIsOpenedAgain() async throws {
            ChatSessionMemoryStore.removeAll()
            let profile = try Profile(lines: ChatFixture.turn(1, tools: [ChatFixture.bash("ls")]) + ChatFixture.turn(2, tools: [ChatFixture.bash("pwd")]))
            defer { profile.remove() }
            let first = await opened(profile)
            first.toggle(ChatRowBuilder.foldID("turn:u1"))
            first.setViewMode(.thinking)
            first.close()
            let second = await opened(profile)
            #expect(second.viewMode == .thinking)
            let fold = second.controller.rows.first { $0.id == ChatRowBuilder.foldID("turn:u1") }
            #expect(fold?.open == true)
            second.close()
        }

        @Test func cyclingTheViewRebuildsTheRows() async throws {
            ChatSessionMemoryStore.removeAll()
            let profile = try Profile(lines: ChatFixture.turn(1, tools: [ChatFixture.bash("a"), ChatFixture.bash("b")]))
            defer { profile.remove() }
            let model = await opened(profile)
            #expect(model.controller.rows.map(\.kind.tag) == ["start", "user", "fold", "answer"])
            model.cycleViewMode()
            model.cycleViewMode()
            #expect(model.viewMode == .verbose)
            #expect(model.controller.rows.map(\.kind.tag) == ["start", "user", "fold", "group", "tool", "tool", "answer"])
            model.cycleViewMode()
            #expect(model.viewMode == .normal)
            model.close()
        }

        @Test func workingTurnsEndInTheLiveRowAndStoppedOnesDoNot() async throws {
            ChatSessionMemoryStore.removeAll()
            var lines = [ChatFixture.user("go", uuid: "u1")]
            lines.append(ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("t1", "Bash", ["command": "sleep 9"])], at: 1))
            let profile = try Profile(lines: lines)
            defer { profile.remove() }
            let model = await opened(profile)
            #expect(model.controller.rows.last?.kind.tag == "tool")
            model.setWorking(true)
            #expect(model.controller.rows.last?.kind.tag == "live")
            model.setWorking(false)
            #expect(model.controller.rows.last?.kind.tag == "tool")
            model.close()
        }

        @Test func aLineOfUnknownShapeShowsAsARawRowAndCountsAsDrift() async throws {
            ChatSessionMemoryStore.removeAll()
            let weird = ChatFixture.line(["type": "mystery-record", "uuid": "x1", "sessionId": "s1", "timestamp": "2026-10-17T10:00:05.000Z",
                                          "payload": ["a": 1]])
            let profile = try Profile(lines: [ChatFixture.user("hi", uuid: "u1"), weird, ChatFixture.assistant("m", uuid: "a1", blocks: [ChatFixture.text("ok")], at: 6)])
            defer { profile.remove() }
            let model = await opened(profile)
            #expect(model.phase == .ready)
            #expect(model.unknownRecordCount == 1)
            #expect(!model.controller.rows.contains { $0.kind.tag == "raw" }, "folded with the turn's work")
            model.setViewMode(.verbose)
            #expect(model.controller.rows.contains { $0.kind.tag == "raw" })
            model.close()
        }
    }
}
