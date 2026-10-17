import AppKit
import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI

extension ChatHosted {
    /// The stream's performance budgets as tests (V2-CONCEPT §5.7, CHAT-SPEC → Cold open, Scrolling): a cold open of a long
    /// session reads about 1.5 MiB; rows are virtualized; scrolling through a long session costs little per frame; a delta
    /// touches only what changed. The numbers print as `BUDGET ...` lines. These run in a debug build, so the limits are
    /// generous (about three times the measured values); the printed numbers are the ones to read.
    @MainActor
    @Suite
    struct ChatBudgetTests {
        /// A synthetic transcript of about `megabytes` MB: turns with two tool calls of 8 KB output each, thinking and an answer.
        static func writeLongTranscript(megabytes: Int, to file: URL) throws -> (turns: Int, bytes: Int) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let blob = (0..<400).map { "output line \($0) of a long command result, with some text to fill the line\n" }.joined()
            var turns = 0
            var bytes = 0
            while bytes < megabytes * 1_000_000 {
                let lines = ChatFixture.turn(turns, tools: [("Bash", ["command": .string("make step\(turns)")], blob),
                                                             ("Read", ["file_path": .string("/proj/src/file\(turns).swift")], blob)],
                                             answer: "Done with step \(turns).\n\n- the first point\n- the second point, with `code`\n\nA closing sentence for the step.",
                                             thought: "Thinking about step \(turns) for a while.", start: turns % 3000)
                let data = Data((lines.joined(separator: "\n") + "\n").utf8)
                try handle.write(contentsOf: data)
                bytes += data.count
                turns += 1
            }
            return (turns, bytes)
        }

        private func milliseconds(_ since: ContinuousClock.Instant) -> Double {
            let d = ContinuousClock.now - since
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }

        @Test func coldOpenOfALongSessionReadsAboutOnePointFiveMiB() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-budget-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("projects/-tmp-budget", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID().uuidString.lowercased()
            let file = folder.appendingPathComponent("\(id).jsonl")
            let made = try Self.writeLongTranscript(megabytes: 60, to: file)
            #expect(made.bytes >= 50_000_000)

            // The lens alone: bytes read and time to the first model.
            let located = try #require(ClaudeTranscriptLocator.locate(sessionID: id, configDirectory: root))
            let lens = try #require(TranscriptLens(file: located))
            let start = ContinuousClock.now
            let update = await lens.coldOpen()
            let lensMs = milliseconds(start)
            await lens.close()
            print(String(format: "BUDGET cold-open file=%.1f MB (%d turns) bytesRead=%.2f MiB turns=%d lens=%.0f ms (debug build)",
                         Double(made.bytes) / 1e6, made.turns, Double(update.bytesRead) / 1_048_576, update.model.turns.count, lensMs))
            #expect(update.bytesRead <= 1_800_000, "about 1.5 MiB from the tail")
            #expect(update.hasOlder)
            #expect(lensMs < 1500)

            // The model: from open to the first rows.
            ChatSessionMemoryStore.removeAll()
            let model = ChatTranscriptModel(sessionID: id, configDirectory: root, workingDirectory: nil)
            let openStart = ContinuousClock.now
            model.setOnScreen(true)
            while model.phase == .resolving { try await Task.sleep(for: .milliseconds(5)) }
            let openMs = milliseconds(openStart)
            print(String(format: "BUDGET cold-open model-ready=%.0f ms rows=%d (debug build)", openMs, model.controller.rows.count))
            #expect(model.phase == .ready)
            #expect(openMs < 2500)
            #expect(model.controller.rows.count < 200, "only the newest turns became rows")
            model.close()
        }

        @Test func rowsAreVirtualizedAndScrollingALongSessionIsCheap() async throws {
            // 2,400 turns are 7,000+ rows; only the ones near the viewport get a view.
            var lines: [String] = []
            for index in 0..<2_400 {
                lines += ChatFixture.turn(index, tools: [ChatFixture.bash("make \(index)"), ChatFixture.read("/tmp/f\(index)")],
                                          answer: "Answer \(index).\n\nA second paragraph that is long enough to wrap onto another line when the column is narrow, for turn \(index).\n\n- first\n- second",
                                          start: index % 3000)
            }
            let buildStart = ContinuousClock.now
            let model = ChatFixture.model(lines)
            let modelMs = milliseconds(buildStart)
            let rowsStart = ContinuousClock.now
            let rows = ChatRowBuilder.rows(ChatBuildInput(model: model))
            let rowsMs = milliseconds(rowsStart)
            print(String(format: "BUDGET rows model(%d entries)=%.0f ms derive(%d rows)=%.0f ms (debug build)", model.entries.count, modelMs, rows.count, rowsMs))
            #expect(rows.count > 6_000)

            let stream = ChatHostedStream(width: 900, height: 700)
            ChatRenderProbe.watch()
            defer { ChatRenderProbe.stop() }
            let applyStart = ContinuousClock.now
            stream.controller.apply(rows, hasOlder: false)
            await stream.settle()
            let applyMs = milliseconds(applyStart)
            let cells = Self.cellCount(in: stream.controller.table)
            print(String(format: "BUDGET open rows=%d apply+settle=%.0f ms configured=%d measured=%d cells=%d (debug build)",
                         rows.count, applyMs, ChatRenderProbe.configured.count, ChatRenderProbe.measuredRows.count, cells))
            #expect(cells < 60, "no hidden bodies are mounted")
            #expect(ChatRenderProbe.configured.count < 80)
            #expect(ChatRenderProbe.measuredRows.count < 200)
            #expect(stream.controller.distanceFromBottom <= 1)

            // Scroll from the end towards the top. Small steps are the reader's wheel (a fifth of a viewport); big steps are a
            // drag of the scroller (ten viewports). Each step's layout is timed.
            stream.controller.handleKey(.pageUp)
            var peakCells = 0
            func run(step: CGFloat, count: Int) async throws -> (p50: Double, p95: Double, worst: Double) {
                var times: [Double] = []
                var y = stream.visibleOffset
                for _ in 0..<count {
                    y = max(-stream.controller.topInset, y - step)
                    let begin = ContinuousClock.now
                    stream.scroll(to: y)
                    stream.controller.scrollView.layoutSubtreeIfNeeded()
                    stream.controller.table.layoutSubtreeIfNeeded()
                    times.append(milliseconds(begin))
                    try await Task.sleep(for: .milliseconds(1))
                    peakCells = max(peakCells, Self.cellCount(in: stream.controller.table))
                }
                times.sort()
                return (times[times.count / 2], times[Int(Double(times.count) * 0.95)], times.last ?? 0)
            }
            let wheel = try await run(step: 140, count: 200)
            let drag = try await run(step: 7_000, count: 60)
            print(String(format: "BUDGET scroll wheel(140 pt x200) p50=%.1f p95=%.1f max=%.1f ms; drag(7000 pt x60) p50=%.1f p95=%.1f max=%.1f ms; peakCells=%d configured=%d measured=%d (debug build)",
                         wheel.p50, wheel.p95, wheel.worst, drag.p50, drag.p95, drag.worst, peakCells,
                         ChatRenderProbe.configured.count, ChatRenderProbe.measuredRows.count))
            #expect(peakCells < 70)
            #expect(wheel.p95 < 50, "a wheel step lays out only the rows it brings into view")
            #expect(drag.p95 < 150)
            stream.controller.stop()
        }

        @Test func aDeltaOnALongStreamTouchesOnlyWhatChanged() async throws {
            var lines: [String] = []
            for index in 0..<1_500 {
                lines += ChatFixture.turn(index, tools: [ChatFixture.bash("make \(index)")], answer: "Answer \(index).", start: index % 3000)
            }
            let before = ChatRowBuilder.rows(ChatBuildInput(model: ChatFixture.model(lines)))
            lines += ChatFixture.turn(1_500, tools: [ChatFixture.bash("make last")], answer: "The newest answer.", start: 10)
            let after = ChatRowBuilder.rows(ChatBuildInput(model: ChatFixture.model(lines)))

            let stream = ChatHostedStream()
            stream.controller.apply(before, hasOlder: false)
            await stream.settle()
            ChatRenderProbe.watch()
            defer { ChatRenderProbe.stop() }
            let start = ContinuousClock.now
            stream.controller.apply(after, fresh: ["u1500"], hasOlder: false)
            let applyMs = milliseconds(start)
            await stream.settle(10)
            let newIDs = Set(after.map(\.id)).subtracting(before.map(\.id))
            print(String(format: "BUDGET delta rows=%d apply=%.1f ms redrawn=%d new=%d (debug build)",
                         after.count, applyMs, ChatRenderProbe.configured.count, newIDs.count))
            #expect(Set(ChatRenderProbe.configured.keys).isSubset(of: newIDs))
            #expect(applyMs < 150, "a delta is applied well inside a 50 ms frame budget in release; debug is slower")
            stream.controller.stop()
        }

        @Test func aHiddenWindowHasNoFeedAndNoClock() async throws {
            ChatSessionMemoryStore.removeAll()
            let profile = try ChatHosted.ChatTranscriptModelTests.Profile(lines: ChatFixture.turn(1) + [
                ChatFixture.user("go", uuid: "ulive", at: 40),
                ChatFixture.assistant("m", uuid: "clive", blocks: [ChatFixture.tool("tlive", "Bash", ["command": "sleep 9"])], at: 41),
            ])
            defer { profile.remove() }
            let model = ChatTranscriptModel(sessionID: profile.id, configDirectory: profile.root, workingDirectory: nil, isWorking: true)
            model.setOnScreen(true)
            while model.phase == .resolving { try await Task.sleep(for: .milliseconds(5)) }
            model.setWindowVisible(true)
            #expect(model.isFeeding && model.controller.context.clock.isRunning)
            model.setWindowVisible(false)
            #expect(!model.isFeeding && !model.controller.context.clock.isRunning)
            model.setWindowVisible(true)
            model.close()
            #expect(!model.isFeeding && !model.controller.context.clock.isRunning, "a closed view has no watcher and no timer")
        }

        /// The row views the table holds now.
        private static func cellCount(in view: NSView) -> Int {
            view.subviews.reduce(view is ChatRowCell ? 1 : 0) { $0 + cellCount(in: $1) }
        }
    }
}

extension ChatHosted.ChatBudgetTests {
    /// The whole path of one growth delta on a long loaded session: `ChatTranscriptModel.apply(update)` derives the rows,
    /// diffs them against the stream's, updates the table and the clock. About 20,000 rows are loaded (every older page
    /// read), the way a reader who scrolled to the top has them.
    @Test func aGrowthDeltaOnAboutTwentyThousandRowsStaysInsideAFrame() async throws {
        ChatSessionMemoryStore.removeAll()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-delta-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("projects/-tmp-delta", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let url = folder.appendingPathComponent("\(id).jsonl")
        var text = ""
        for index in 0..<7_000 {
            text += ChatFixture.turn(index, tools: [ChatFixture.bash("make \(index)")], answer: "Answer \(index).", start: index % 3000)
                .joined(separator: "\n") + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        let located = try #require(ClaudeTranscriptLocator.locate(sessionID: id, configDirectory: root))
        let lens = try #require(TranscriptLens(file: located))
        var latest = await lens.coldOpen()
        while latest.hasOlder, let older = await lens.loadOlder() { latest = older }

        let model = ChatTranscriptModel(sessionID: id, configDirectory: root, workingDirectory: nil, isWorking: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        model.controller.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(model.controller.scrollView)
        window.contentView!.layoutSubtreeIfNeeded()
        model.setWindowVisible(true)

        let loadStart = ContinuousClock.now
        model.apply(latest)
        let loadMs = Double((ContinuousClock.now - loadStart).components.attoseconds) / 1e15
            + Double((ContinuousClock.now - loadStart).components.seconds) * 1000
        for _ in 0..<8 { model.controller.scrollView.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
        let rowCount = model.controller.rows.count
        #expect(rowCount > 20_000, "rows loaded: \(rowCount)")

        // One more turn arrives.
        let next = ChatFixture.turn(7_000, tools: [ChatFixture.bash("make last")], answer: "The newest answer.", start: 10)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((next.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let growth = await lens.readGrowth()
        #expect(!growth.delta.isEmpty)
        ChatRenderProbe.watch()
        defer { ChatRenderProbe.stop() }
        var times: [Double] = []
        let start = ContinuousClock.now
        model.apply(growth)
        let elapsed = ContinuousClock.now - start
        times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        for _ in 0..<8 { model.controller.scrollView.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
        print(String(format: "BUDGET delta-end-to-end rows=%d first-load=%.0f ms model.apply(update)=%.1f ms redrawn=%d (debug build)",
                     model.controller.rows.count, loadMs, times[0], ChatRenderProbe.configured.count))
        #expect(model.controller.rows.count > rowCount)
        #expect(times[0] < 400, "builder, diff plan, table update and clock for one delta")
        #expect(ChatRenderProbe.configured.count <= 6, "only the new rows were drawn: \(ChatRenderProbe.configured.keys.sorted())")
        model.close()
        await lens.close()
    }
}

extension ChatHosted.ChatBudgetTests {
    /// A "Show all" row holds up to 1 MiB or 10,000 lines. Measuring it uses a stand-in (a scrolling box is as high as 16
    /// lines whatever its text); drawing it lays the text out once.
    @Test func aShowAllRowIsCheapToMeasureAndDrawnOnce() async throws {
        let line = "output line of a long command result, with filler to make the line longer\n"
        let huge = ChatFullOutput.prepared(String(repeating: line, count: 40_000))
        guard case let .text(shown) = huge else { Issue.record("not text"); return }
        let lines = [ChatFixture.user("go", uuid: "u1"),
                     ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("t1", "Bash", ["command": "cat huge"])], at: 1),
                     ChatFixture.result("t1", "head of the output", at: 2),
                     ChatFixture.assistant("m2", uuid: "a1", blocks: [ChatFixture.text("done")], at: 3)]
        var rows = ChatFixture.rows(lines, mode: .verbose)
        let index = try #require(rows.firstIndex { $0.id == "t1" })
        rows[index].fullOutput = huge
        rows[index].open = true

        let context = ChatRowContext()
        let measurer = ChatRowMeasurer(context: context)
        let begin = ContinuousClock.now
        let height = measurer.height(of: rows[index], width: 900)
        let measureMs = Double((ContinuousClock.now - begin).components.seconds) * 1000 + Double((ContinuousClock.now - begin).components.attoseconds) / 1e15

        let stream = ChatHostedStream(width: 900, height: 700, context: context)
        let drawBegin = ContinuousClock.now
        stream.controller.apply(rows, hasOlder: false)
        await stream.settle(8)
        let drawMs = Double((ContinuousClock.now - drawBegin).components.seconds) * 1000 + Double((ContinuousClock.now - drawBegin).components.attoseconds) / 1e15
        print(String(format: "BUDGET show-all-row text=%.2f MB (%d lines) measure=%.0f ms height=%.0f draw+settle=%.0f ms (debug build)",
                     Double(shown.utf8.count) / 1e6, ChatText.lineCount(shown), measureMs, height, drawMs))
        #expect(height < 700, "a scrolling box, not the whole text")
        #expect(measureMs < 300)
        #expect(drawMs < 3000)
        stream.controller.stop()
    }
}
