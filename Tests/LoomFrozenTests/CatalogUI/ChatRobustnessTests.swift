import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

extension ChatHosted {
    /// Edge cases of content that arrives from a transcript: a huge "Show all", a cut-off escape, a long line, a long detail.
    @MainActor
    struct ChatRobustnessTests {
        // MARK: Show all

        @Test func aHugeResultIsCutAtAboutOneMiBWithANote() {
            let line = String(repeating: "x", count: 99) + "\n"
            let huge = String(repeating: line, count: 320_000) // 32 MB
            guard case let .text(shown) = ChatFullOutput.prepared(huge) else { Issue.record("not text"); return }
            #expect(shown.utf8.count < ChatFullOutput.maximumBytes + 400)
            #expect(ChatText.lineCount(shown) <= ChatFullOutput.maximumLines + 2)
            #expect(shown.contains("Cut here"))
            #expect(shown.hasPrefix("xxxx"))
        }

        @Test func linesAreCutAtTenThousand() {
            let many = String(repeating: "a\n", count: 50_000)
            guard case let .text(shown) = ChatFullOutput.prepared(many) else { Issue.record("not text"); return }
            #expect(ChatText.lineCount(shown.components(separatedBy: "\n\u{2026}")[0]) == ChatFullOutput.maximumLines)
            #expect(shown.contains("Cut here"))
        }

        @Test func aResultThatFitsIsKeptWholeAndAMultibyteCutStaysValid() {
            #expect(ChatFullOutput.prepared("small\nresult") == .text("small\nresult"))
            let wide = String(repeating: "\u{1F600}", count: 600_000) // no line breaks, 2.4 MB
            guard case let .text(shown) = ChatFullOutput.prepared(wide) else { Issue.record("not text"); return }
            #expect(shown.utf8.count < ChatFullOutput.maximumBytes + 400)
            #expect(!shown.contains("\u{FFFD}") || shown.hasPrefix("\u{1F600}"))
        }

        @Test func showAllOnAHugeResultIsCutAndDoesNotBlockTheMainThread() async throws {
            ChatSessionMemoryStore.removeAll()
            let big = String(repeating: "output line of a very long command result, with filler\n", count: 11_000) // 600 KB: more than the 10,000 lines shown, within what a cold open reads
            let lines = [ChatFixture.user("go", uuid: "u1"),
                         ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("t1", "Bash", ["command": "cat huge"])], at: 1),
                         ChatFixture.result("t1", big, at: 2),
                         ChatFixture.assistant("m2", uuid: "a1", blocks: [ChatFixture.text("done")], at: 3)]
            let profile = try ChatTranscriptModelTests.Profile(lines: lines)
            defer { profile.remove() }
            let model = ChatTranscriptModel(sessionID: profile.id, configDirectory: profile.root, workingDirectory: nil)
            model.setOnScreen(true)
            while model.phase == .resolving { try await Task.sleep(for: .milliseconds(5)) }
            model.setViewMode(.verbose)
            let entry = try #require(model.model.entry(id: "t1"))
            guard case let .tool(call) = entry.body else { Issue.record("not a tool"); return }
            #expect(call.output?.isClipped == true)

            // A heartbeat on the main actor: the longest gap shows how long the main thread was blocked.
            var longestGap = 0.0
            let beating = Task { @MainActor in
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                    let now = ContinuousClock.now
                    let gap = now - last
                    longestGap = max(longestGap, Double(gap.components.seconds) * 1000 + Double(gap.components.attoseconds) / 1e15)
                    last = now
                }
            }
            model.showAll(entry)
            let deadline = Date().addingTimeInterval(20)
            var text: String?
            while text == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
                text = model.controller.rows.first { $0.id == "t1" }?.fullText
            }
            beating.cancel()
            let shown = try #require(text, "Show all produced text")
            print(String(format: "BUDGET show-all result=%.1f MB shown=%.2f MB longest main-thread gap=%.0f ms (debug build)",
                         Double(big.utf8.count) / 1e6, Double(shown.utf8.count) / 1e6, longestGap))
            #expect(shown.utf8.count < ChatFullOutput.maximumBytes + 400)
            #expect(shown.contains("Cut here"))
            #expect(ChatText.lineCount(shown) <= ChatFullOutput.maximumLines + 2)
            #expect(longestGap < 400, "the main thread stayed free while the result was read and cut")
            model.close()
        }

        @Test func showAllThatFindsNothingSaysSo() async throws {
            ChatSessionMemoryStore.removeAll()
            // The result is further than the scan goes (more than 400 lines between the call and its result).
            var lines = [ChatFixture.user("go", uuid: "u1"),
                         ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("t1", "Bash", ["command": "cat huge"])], at: 1)]
            for index in 0..<450 { lines.append(ChatFixture.assistant("n\(index)", uuid: "x\(index)", blocks: [ChatFixture.text("filler \(index)")], at: 2)) }
            lines.append(ChatFixture.result("t1", String(repeating: "y", count: 100_000), at: 3))
            let profile = try ChatTranscriptModelTests.Profile(lines: lines)
            defer { profile.remove() }
            let model = ChatTranscriptModel(sessionID: profile.id, configDirectory: profile.root, workingDirectory: nil)
            model.setOnScreen(true)
            while model.phase == .resolving { try await Task.sleep(for: .milliseconds(5)) }
            model.setViewMode(.verbose)
            let entry = try #require(model.model.entry(id: "t1"))
            model.showAll(entry)
            var output: ChatFullOutput?
            for _ in 0..<300 where output == nil {
                try await Task.sleep(for: .milliseconds(10))
                output = model.controller.rows.first { $0.id == "t1" }?.fullOutput
            }
            #expect(output == .missing)
            model.close()
        }

        // MARK: Escapes

        @Test func anUnterminatedEscapeKeepsTheRestOfTheOutput() {
            // No character after the introducer ends the sequence (it takes letters and symbols to end one).
            let text = "before \u{1B}[31mred\u{1B}[0m middle \u{1B}[1;2 3 4 5 6\n77 88 99\n100 200"
            let attributed = String(ChatANSI.attributed(text).characters)
            #expect(attributed.contains("77 88 99"))
            #expect(attributed.contains("100 200"))
            #expect(attributed.contains("red"))
            #expect(!attributed.contains("\u{1B}[31m"))
            let longParameters = "x\u{1B}[" + String(repeating: "1;", count: 400) + " the rest"
            #expect(String(ChatANSI.attributed(longParameters).characters).contains("the rest"))
        }

        // MARK: Subagent detail

        @Test func theSubagentDetailReadsOnlyTheStartOfALongResult() throws {
            let filler = String(repeating: "[ [ [ [ [ not a link ", count: 50_000) // quadratic for the link pattern if read whole
            let lines = [ChatFixture.user("go", uuid: "u1"),
                         ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("agent_1", "Agent",
                             ["description": "Review", "subagent_type": "reviewer", "prompt": "Look"])], at: 1),
                         ChatFixture.result("agent_1", "**Summary:** all fine. " + filler, at: 2)]
            let entry = try #require(ChatFixture.model(lines).entry(id: "agent_1"))
            guard case let .subagent(run) = entry.body else { Issue.record("not a subagent"); return }
            let start = ContinuousClock.now
            let first = ChatWork.subagentDetail(run)
            let second = ChatWork.subagentDetail(run)
            let elapsed = ContinuousClock.now - start
            #expect(first?.hasPrefix("Summary: all fine.") == true)
            #expect((first?.count ?? 0) <= 280)
            #expect(first == second)
            #expect(elapsed < .milliseconds(500))
        }
    }
}
