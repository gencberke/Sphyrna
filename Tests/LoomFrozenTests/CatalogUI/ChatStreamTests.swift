import AppKit
import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

extension ChatHosted {
    /// The stream in a hosted (never shown) window: where it opens, what it redraws, and where it holds the reader.
    @MainActor
    @Suite
    struct ChatStreamTests {
        /// Settled turns of two tools and a few paragraphs of answer each.
        static func lines(_ range: Range<Int>) -> [String] {
            range.flatMap { index in
                ChatFixture.turn(index, tools: [ChatFixture.bash("echo \(index)"), ChatFixture.read("/tmp/f\(index).txt")],
                                 answer: "Answer \(index).\n\nA second paragraph that is long enough to wrap onto another line when the column is narrow, for turn \(index).\n\n- first\n- second",
                                 start: index % 3000)
            }
        }

        static func rows(_ range: Range<Int>, hasOlder: Bool = false) -> [ChatRow] {
            let all = lines(range)
            return ChatFixture.rows(all, hasOlder: hasOlder, firstOffset: ChatFixture.size(of: lines(0..<range.lowerBound)))
        }

        @Test func opensAtTheEndAndKeepsItWhenRowsArrive() async {
            let stream = ChatHostedStream()
            stream.controller.apply(Self.rows(0..<60), hasOlder: false)
            await stream.settle()
            #expect(stream.controller.isFollowing)
            #expect(stream.controller.distanceFromBottom <= 1)

            stream.controller.apply(Self.rows(0..<61), fresh: ["u60"], hasOlder: false)
            await stream.settle(10)
            #expect(stream.controller.isFollowing)
            #expect(stream.controller.distanceFromBottom <= 1)
            stream.controller.stop()
        }

        @Test(.renderProbe) func growthRedrawsOnlyTheRowsThatChanged() async {
            let scope = UUID().uuidString
            let stream = ChatHostedStream(context: ChatRowContext(probeScope: scope))
            stream.controller.apply(Self.rows(0..<80), hasOlder: false)
            await stream.settle()
            RenderProbeExclusive.watchChat(scope: scope)
            defer { ChatRenderProbe.stop() }
            let before = Self.rows(0..<80)
            let after = Self.rows(0..<81)
            stream.controller.apply(after, fresh: ["u80"], hasOlder: false)
            await stream.settle(10)
            let drawn = Set(ChatRenderProbe.configured.keys)
            let newIDs = Set(after.map(\.id)).subtracting(before.map(\.id))
            #expect(!newIDs.isEmpty)
            #expect(drawn.isSubset(of: newIDs), "redrawn: \(drawn.subtracting(newIDs))")
            stream.controller.stop()
        }

        @Test(.renderProbe) func openingAFoldRedrawsThatFoldAndInsertsItsRows() async {
            let scope = UUID().uuidString
            let stream = ChatHostedStream(context: ChatRowContext(probeScope: scope))
            let lines = Self.lines(0..<30)
            let closed = ChatFixture.rows(lines)
            stream.controller.apply(closed, hasOlder: false)
            await stream.settle()
            RenderProbeExclusive.watchChat(scope: scope)
            defer { ChatRenderProbe.stop() }
            let foldID = ChatRowBuilder.foldID("turn:u29")
            let open = ChatFixture.rows(lines, toggled: [foldID])
            stream.controller.apply(open, hasOlder: false)
            await stream.settle(10)
            let allowed = Set([foldID]).union(Set(open.map(\.id)).subtracting(closed.map(\.id)))
            let drawn = Set(ChatRenderProbe.configured.keys)
            #expect(drawn.contains(foldID))
            #expect(drawn.isSubset(of: allowed), "redrawn: \(drawn.subtracting(allowed))")
            stream.controller.stop()
        }

        @Test func aReaderWhoScrolledUpStaysPutWhenTheFileGrows() async {
            let stream = ChatHostedStream()
            stream.controller.apply(Self.rows(0..<100), hasOlder: false)
            await stream.settle()
            stream.controller.handleKey(.pageUp)
            stream.controller.handleKey(.pageUp)
            await stream.settle()
            #expect(!stream.controller.isFollowing)
            let anchor = try? #require(stream.controller.captureAnchor())
            stream.controller.apply(Self.rows(0..<104), fresh: [], hasOlder: false)
            await stream.settle(10)
            #expect(!stream.controller.isFollowing)
            let held = stream.controller.captureAnchor()
            #expect(held?.rowID == anchor?.rowID)
            #expect(abs((held?.offset ?? 0) - (anchor?.offset ?? 1000)) <= 1)
            stream.controller.stop()
        }

        @Test func olderTurnsLoadWithoutMovingTheRowTheReaderWasOn() async {
            let stream = ChatHostedStream()
            stream.controller.apply(Self.rows(50..<120, hasOlder: true), hasOlder: true)
            await stream.settle()
            stream.controller.handleKey(.pageUp)
            await stream.settle()
            #expect(!stream.controller.isFollowing)
            let anchor = try? #require(stream.controller.captureAnchor())
            stream.controller.apply(Self.rows(20..<120, hasOlder: true), hasOlder: true)
            await stream.settle(12)
            let held = stream.controller.captureAnchor()
            #expect(held?.rowID == anchor?.rowID)
            #expect(abs((held?.offset ?? 0) - (anchor?.offset ?? 1000)) <= 1)
            stream.controller.stop()
        }

        @Test func theTopAsksForOlderTurnsWithinOneScreen() async {
            let stream = ChatHostedStream()
            var asked = 0
            stream.controller.onNeedOlder = { asked += 1 }
            stream.controller.apply(Self.rows(50..<120, hasOlder: true), hasOlder: true)
            await stream.settle()
            #expect(asked == 0)
            stream.controller.handleKey(.home)
            await stream.settle(10)
            #expect(asked >= 1)
            stream.controller.stop()
        }

        @Test func jumpToLatestReturnsToTheEndAndFollowing() async {
            let stream = ChatHostedStream()
            stream.controller.apply(Self.rows(0..<100), hasOlder: false)
            await stream.settle()
            stream.controller.handleKey(.home)
            await stream.settle()
            #expect(!stream.controller.isFollowing)
            #expect(stream.controller.distanceFromBottom > 500)
            stream.controller.jumpToLatest()
            await stream.settle(10)
            #expect(stream.controller.isFollowing)
            #expect(stream.controller.distanceFromBottom <= 1)
            stream.controller.stop()
        }

        @Test func theLatchReportsLeavingAndReturning() async {
            let stream = ChatHostedStream()
            var reports: [(Bool, Bool)] = []
            stream.controller.onLatchChange = { reports.append(($0, $1)) }
            stream.controller.apply(Self.rows(0..<100), hasOlder: false)
            await stream.settle()
            stream.controller.handleKey(.home)
            try? await Task.sleep(for: .milliseconds(400))
            #expect(reports.contains { !$0.0 && $0.1 }, "the pill shows after 150 ms away from the end")
            stream.controller.jumpToLatest()
            #expect(reports.last?.0 == true && reports.last?.1 == false, "it hides at once on return")
            stream.controller.stop()
        }

        @Test func aFewRowsDoNotOverflowAndStayFollowing() async {
            let stream = ChatHostedStream()
            stream.controller.apply(Self.rows(0..<2), hasOlder: false)
            await stream.settle()
            stream.controller.handleKey(.pageUp)
            #expect(stream.controller.isFollowing)
            stream.controller.stop()
        }

        @Test func theClockRunsOnlyForALiveRowOnAVisibleStream() async {
            let stream = ChatHostedStream()
            var lines = Self.lines(0..<3)
            lines.append(ChatFixture.user("go", uuid: "ulive", at: 40))
            lines.append(ChatFixture.assistant("mlive", uuid: "clive", blocks: [ChatFixture.tool("tlive", "Bash", ["command": "sleep 9"])], at: 41))
            let live = ChatFixture.rows(lines, isWorking: true)
            #expect(live.last?.kind.tag == "live")
            stream.controller.apply(live, hasOlder: false)
            stream.controller.setAnimates(false)
            #expect(!stream.controller.context.clock.isRunning, "a hidden window runs no timer")
            stream.controller.setAnimates(true)
            #expect(stream.controller.context.clock.isRunning)
            stream.controller.apply(ChatFixture.rows(Self.lines(0..<3)), hasOlder: false)
            #expect(!stream.controller.context.clock.isRunning, "no live row, no timer")
            stream.controller.stop()
            #expect(!stream.controller.context.clock.isRunning)
        }
    }
}

extension ChatHosted.ChatStreamTests {
    @Test func marksForRowsThatNeverFadeInDoNotPileUp() async {
        let stream = ChatHostedStream()
        stream.controller.apply(Self.rows(0..<80), hasOlder: false)
        await stream.settle()
        stream.controller.handleKey(.home)
        await stream.settle()
        // The reader is at the top; rows keep arriving at the end and are never drawn.
        for count in 81...140 {
            let rows = Self.rows(0..<count)
            stream.controller.apply(rows, fresh: ["u\(count - 1)", "a\(count - 1)", "ghost\(count)"], hasOlder: false)
            #expect(stream.controller.fresh.count <= ChatStreamController.freshLimit)
        }
        stream.controller.stop()
    }
}
