import AppKit
import Foundation
@testable import LoomChat
import LoomCore
import Testing
@testable import LoomCatalogUI

extension ChatHosted {
    /// V22 part 3: a side chat's thread is the main chat's stream over the fork's driver, cut at the fork's first question.
    /// The fork's file begins with a copy of the parent's records and the CLI's repair records for what the parent left
    /// open; none of that is shown. A side chat that runs and the same side chat read again (a resumed fork) show the same rows.
    @MainActor
    @Suite
    struct SideThreadTests {
        /// A fork's transcript: the parent's two turns (the second with a tool), a repair record for a call the parent left
        /// open, then the side chat's own two questions.
        private static func fork() throws -> LiveChatFeedTests.Profile {
            try LiveChatFeedTests.Profile(lines: ChatFixture.turn(1) + ChatFixture.turn(2, tools: [("Bash", ["command": "ls"], "a\nb")], start: 10) + [
                ChatFixture.result("toolu_left_open", "Request interrupted by user", isError: true, at: 20),
                ChatFixture.user("side q1", uuid: "sq1", at: 30),
                ChatFixture.assistant("sm1", uuid: "sa1", blocks: [ChatFixture.text("side answer 1")], at: 31),
                ChatFixture.user("side q2", uuid: "sq2", at: 40),
                ChatFixture.assistant("sm2", uuid: "sa2", blocks: [ChatFixture.text("side answer 2")], at: 41),
            ])
        }

        private func waitUntil(_ timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        private static func prompts(_ model: TurnModel) -> [String] {
            model.entries.compactMap { if case let .user(prompt) = $0.body { prompt.text } else { nil } }
        }

        /// What a row says, whatever id the live model or the transcript gave it.
        private static func shown(_ rows: [ChatRow]) -> [String] {
            rows.map { row in
                switch row.kind {
                case let .user(entry):
                    if case let .user(prompt) = entry.body { "user: \(prompt.text)" } else { "user" }
                case let .prose(entry, settled):
                    if case let .assistantText(text) = entry.body { "prose\(settled ? " (settled)" : ""): \(text.text)" } else { "prose" }
                default: row.kind.tag
                }
            }
        }

        @Test func theThreadStartsAtTheFirstQuestionAndTheParentsCopyIsNeverShown() async throws {
            let profile = try Self.fork()
            defer { profile.remove() }
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: profile.id)
            let feed = LiveChatFeed(source: source, card: card, conversationID: profile.id, configDirectory: profile.root,
                                    workingDirectory: nil)
            feed.sideFirstUUID = { "sq1" }
            let stream = ChatHostedStream()
            feed.attach(stream.controller)
            feed.start()
            #expect(await waitUntil { feed.phase == .ready && Self.prompts(feed.presentation.model).count == 2 })
            #expect(Self.prompts(feed.presentation.model) == ["side q1", "side q2"])
            let model = feed.presentation.model
            #expect(model.entries.allSatisfy { entry in
                if case let .tool(call) = entry.body { call.id != "toolu_2_0" && call.id != "toolu_left_open" } else { true }
            }, "no tool call, result or repair record of the copy")
            #expect(Self.shown(stream.controller.rows).filter { $0.hasPrefix("user") } == ["user: side q1", "user: side q2"])

            // The same file read as a main session's transcript shows the copy: the cut is what hides it.
            let main = LiveChatFeed(source: ScriptedLiveSource(card: card, conversationID: profile.id), card: card,
                                    conversationID: profile.id, configDirectory: profile.root, workingDirectory: nil)
            let mainStream = ChatHostedStream()
            main.attach(mainStream.controller)
            main.start()
            #expect(await waitUntil { main.phase == .ready && Self.prompts(main.presentation.model).count == 4 })
            #expect(Self.prompts(main.presentation.model) == ["prompt 1", "prompt 2", "side q1", "side q2"])
            stream.controller.stop()
            mainStream.controller.stop()
        }

        @Test func aSideChatWithNoQuestionYetShowsNothingOfTheCopy() async throws {
            let profile = try Self.fork()
            defer { profile.remove() }
            let card = UUID()
            let feed = LiveChatFeed(source: ScriptedLiveSource(card: card, conversationID: profile.id), card: card,
                                    conversationID: profile.id, configDirectory: profile.root, workingDirectory: nil)
            feed.sideFirstUUID = { nil }
            let stream = ChatHostedStream()
            feed.attach(stream.controller)
            feed.start()
            #expect(await waitUntil { feed.phase == .ready })
            await stream.settle()
            #expect(feed.presentation.model.entries.isEmpty)
            #expect(!feed.presentation.hasOlder, "nothing older is asked for")
            stream.controller.stop()
        }

        @Test func aReadThatBeginsInsideTheSideChatLoadsOlderTurnsUntilTheFirstQuestionAndNoFurther() async throws {
            let profile = try Self.fork()
            defer { profile.remove() }
            let card = UUID()
            var limits = TranscriptLens.Limits()
            limits.coldOpenTurns = 1
            limits.olderTurns = 1
            let feed = LiveChatFeed(source: ScriptedLiveSource(card: card, conversationID: profile.id), card: card,
                                    conversationID: profile.id, configDirectory: profile.root, workingDirectory: nil, limits: limits)
            feed.sideFirstUUID = { "sq1" }
            let stream = ChatHostedStream()
            feed.attach(stream.controller)
            feed.start()
            // The newest turn only, to begin with: the first question is further back.
            #expect(await waitUntil { feed.phase == .ready && Self.prompts(feed.presentation.model) == ["side q2"] })
            #expect(feed.presentation.hasOlder)
            feed.loadOlder(stream.controller)
            #expect(await waitUntil { Self.prompts(feed.presentation.model) == ["side q1", "side q2"] })
            #expect(!feed.presentation.hasOlder, "the copy before the first question is not older turns of the side chat")
            feed.loadOlder(stream.controller)
            try await Task.sleep(for: .milliseconds(200))
            #expect(Self.prompts(feed.presentation.model) == ["side q1", "side q2"])
            stream.controller.stop()
        }

        @Test func aLiveSideChatAndTheSameForkReadAgainShowTheSameRows() async throws {
            let profile = try Self.fork()
            defer { profile.remove() }
            @Sendable func message(_ value: JSONValue) -> StreamMessage { LiveScript.message(value) }

            // Resumed: a driver with nothing live, the history from the file.
            let resumedCard = UUID()
            let resumed = LiveChatFeed(source: ScriptedLiveSource(card: resumedCard, conversationID: profile.id), card: resumedCard,
                                       conversationID: profile.id, configDirectory: profile.root, workingDirectory: nil)
            resumed.sideFirstUUID = { "sq1" }
            let resumedStream = ChatHostedStream()
            resumed.attach(resumedStream.controller)
            resumed.start()
            #expect(await waitUntil { resumed.phase == .ready && Self.prompts(resumed.presentation.model).count == 2 })
            await resumedStream.settle()

            // Live: the same two turns as the driver delivered them, with the file holding them too (and the copy).
            let liveCard = UUID()
            let source = ScriptedLiveSource(card: liveCard, conversationID: profile.id)
            for (n, uuid) in [(1, "sq1"), (2, "sq2")] {
                await source.change { $0.appendPendingUser(uuid: uuid, text: "side q\(n)") }
                await source.change {
                    $0.apply(message(["type": "user", "uuid": .string(uuid), "session_id": "s1", "isReplay": true,
                                      "message": ["role": "user", "content": .string("side q\(n)")]]))
                }
                await source.change {
                    $0.apply(message(["type": "assistant", "uuid": .string("la\(n)"), "session_id": "s1", "parent_tool_use_id": .null,
                                      "message": ["id": .string("sm\(n)"), "role": "assistant", "model": "m",
                                                  "content": [["type": "text", "text": .string("side answer \(n)")]]]]))
                }
                await source.change { $0.apply(LiveScript.result()) }
            }
            let live = LiveChatFeed(source: source, card: liveCard, conversationID: profile.id, configDirectory: profile.root,
                                    workingDirectory: nil)
            live.sideFirstUUID = { "sq1" }
            let liveStream = ChatHostedStream()
            live.attach(liveStream.controller)
            live.start()
            #expect(await waitUntil { live.phase == .ready && Self.prompts(live.presentation.model).count == 2 })
            await liveStream.settle()

            let expected = ["user: side q1", "prose (settled): side answer 1", "user: side q2", "prose (settled): side answer 2"]
            let resumedRows = Self.shown(resumedStream.controller.rows).filter { $0.hasPrefix("user") || $0.hasPrefix("prose") }
            let liveRows = Self.shown(liveStream.controller.rows).filter { $0.hasPrefix("user") || $0.hasPrefix("prose") }
            #expect(resumedRows == expected, "\(resumedRows)")
            #expect(liveRows == expected, "\(liveRows)")
            #expect(Self.prompts(live.presentation.model) == Self.prompts(resumed.presentation.model))
            resumedStream.controller.stop()
            liveStream.controller.stop()
        }
    }
}
