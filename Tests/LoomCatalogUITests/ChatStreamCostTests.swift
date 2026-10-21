import AppKit
import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI

extension ChatHosted {
    /// What a visible Chat session that streams costs per delta (V2-CONCEPT §5.7, first row), as counts: rows drawn again,
    /// rows measured, body evaluations, markdown and inline parses for a stream of 12-character deltas (600 characters a
    /// second is 50 of them a second). Counts are the same in every build and on every Mac, so the numbers are ceilings with
    /// a margin and need no clock; the CPU itself is measured by `scripts/perf/chat_stream_cost.py`.
    @MainActor
    @Suite
    struct ChatStreamCostTests {
        /// Markdown the way a Claude answer reads (paragraphs, a heading, a list, a fenced block), repeated to `count` characters.
        static func answer(characters count: Int) -> String {
            let section = """
            ## Findings

            The feed batches the deltas of one read of the pipe and hands them to the presentation, which derives the rows of the newest turn and gives the table what differs.

            - the first item names the file that holds the **delta** loop
            - the second item says why `apply` is called once per read
            - the third item is a little longer so that it wraps onto a second line in a narrow column

            ```swift
            func apply(_ change: ModelChange) -> Bool {
                guard change.sequence > lastSequence else { return false }
                return rebuild(change)
            }
            ```

            After that the stream measures the row again, and the table scrolls to the end while the reader follows.


            """
            var out = ""
            while out.count < count { out += section }
            return String(out.prefix(count))
        }

        struct Run {
            var deltas = 0
            var configured = 0
            var measured = 0
            var bodies = 0
            var parses = 0
            var parsedCharacters = 0
            var inlineParses = 0
            var rebuilds = 0
            var milliseconds = 0.0
            var rows: [ChatRow] = []
            /// The time the stream spent on each rebuild (applying rows, measuring, laying out), in order.
            var streamMs: [Double] = []
            var perRow: [String] = []
            var rowReloads = 0
            /// The characters and blocks the measuring path laid out between one rebuild and the next, in order (C7).
            var measuredCharactersPerRebuild: [Int] = []
            var measuredBlocksPerRebuild: [Int] = []
            /// How often each top-level markdown block's view was built, and its body evaluated, over the whole stream, by `"<index>#<content hash>"` (C7).
            var blockBuilds: [String: Int] = [:]
            var blockBodies: [String: Int] = [:]
        }

        /// A live turn that streams `characters` of text in deltas of `piece` characters, a frame apart, into a hosted stream.
        /// `frame` runs after every delta (the run loop of one frame).
        static func stream(characters: Int, piece: Int = 12, interval: Duration? = nil, wait: Duration = .zero,
                           settle: (ChatHostedStream) async -> Void) async -> Run {
            ChatSessionMemoryStore.removeAll()
            let scope = "cost-\(UUID().uuidString)"
            let presentation = ChatPresentation(sessionID: scope, workingDirectory: nil, isWorking: true)
            // As in a live chat: the live row follows the driver's clock, not every change.
            presentation.activityFromSource = true
            if let interval { presentation.rowsInterval = interval }
            let stream = ChatHostedStream(width: 900, height: 700, context: ChatRowContext(probeScope: scope))
            presentation.attach(stream.controller)
            var source = SyntheticSource()
            _ = presentation.apply(source.snapshot())
            _ = presentation.apply(source.prompt("u1", "write the report"))
            _ = presentation.apply(source.message(LiveScript.start("m1")))
            _ = presentation.apply(source.message(LiveScript.block(0, ["type": "text", "text": ""])))
            await stream.settle(4)

            let text = Array(answer(characters: characters))
            RenderProbeExclusive.watchChat(scope: scope)
            defer { ChatRenderProbe.stop() }
            let rebuildsBefore = presentation.rebuilds
            let reloadsBefore = stream.controller.table.rowReloads
            var run = Run()
            let began = ContinuousClock.now
            var position = 0
            var lastCharacters = 0, lastBlocks = 0
            while position < text.count {
                let end = min(position + piece, text.count)
                let before = presentation.rebuilds
                _ = presentation.apply(source.message(LiveScript.textDelta(0, String(text[position..<end]))))
                if presentation.rebuilds > before { run.streamMs.append(presentation.lastTimings.stream) }
                position = end
                run.deltas += 1
                await settle(stream)
                if presentation.rebuilds > before {
                    run.measuredCharactersPerRebuild.append(ChatRenderProbe.measuredCharacters - lastCharacters)
                    run.measuredBlocksPerRebuild.append(ChatRenderProbe.measuredBlocks - lastBlocks)
                    lastCharacters = ChatRenderProbe.measuredCharacters
                    lastBlocks = ChatRenderProbe.measuredBlocks
                }
            }
            if wait > .zero { try? await Task.sleep(for: wait) }
            await stream.settle(2)
            let elapsed = ContinuousClock.now - began
            run.milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            run.configured = ChatRenderProbe.configured.values.reduce(0, +)
            run.measured = ChatRenderProbe.measuredRows.values.reduce(0, +)
            run.bodies = ChatRenderProbe.proseBodies
            run.parses = ChatRenderProbe.markdownParses
            run.parsedCharacters = ChatRenderProbe.markdownCharacters
            run.inlineParses = ChatRenderProbe.inlineParses
            run.blockBuilds = ChatRenderProbe.blockBuilds
            run.blockBodies = ChatRenderProbe.blockBodies
            run.perRow = ChatRenderProbe.configured.map { String(format: "%@: configured %d, measured %d in %.0f ms", $0.key, $0.value, ChatRenderProbe.measuredRows[$0.key] ?? 0, ChatRenderProbe.measureTime[$0.key] ?? 0) }.sorted()
            run.rowReloads = stream.controller.table.rowReloads - reloadsBefore
            run.rebuilds = presentation.rebuilds - rebuildsBefore
            run.rows = stream.controller.rows
            stream.controller.stop()
            return run
        }

        private static func frame(_ stream: ChatHostedStream) async {
            stream.controller.scrollView.layoutSubtreeIfNeeded()
            stream.controller.table.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }

        private static func report(_ label: String, _ run: Run) {
            print("BUDGET stream cost \(label) rows: " + run.perRow.joined(separator: " | "))
            let tenth = max(1, run.streamMs.count / 10)
            let early = run.streamMs.prefix(tenth).reduce(0, +) / Double(tenth), late = run.streamMs.suffix(tenth).reduce(0, +) / Double(tenth)
            print(String(format: "BUDGET stream cost %@ per rebuild (stream update): first tenth %.2f ms, last tenth %.2f ms", label, early, late))
            print(String(format: "BUDGET stream cost %@: %d deltas of 12 characters in %.0f ms: rebuilds=%d configured=%d measured=%d proseBodies=%d markdownParses=%d (%d characters) inlineParses=%d",
                         label, run.deltas, run.milliseconds, run.rebuilds, run.configured, run.measured, run.bodies, run.parses,
                         run.parsedCharacters, run.inlineParses))
        }

        /// The rows the stream holds are the rows of a full rebuild.
        private func expectRows(_ presentation: ChatPresentation, _ stream: ChatHostedStream, _ note: String,
                                sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(stream.controller.rows == ChatRowBuilder.rows(presentation.buildInput()), "rows differ from a full rebuild \(note)",
                    sourceLocation: sourceLocation)
        }

        /// A presentation as a live chat makes it, with a stream attached and a message that has started streaming.
        private func streamingPresentation(interval: Duration?, attached: Bool = true)
            -> (presentation: ChatPresentation, stream: ChatHostedStream, source: SyntheticSource) {
            ChatSessionMemoryStore.removeAll()
            let presentation = ChatPresentation(sessionID: "interval-\(UUID().uuidString)", workingDirectory: nil, isWorking: true)
            presentation.activityFromSource = true
            presentation.rowsInterval = interval
            let stream = ChatHostedStream()
            if attached { presentation.attach(stream.controller) }
            var source = SyntheticSource()
            _ = presentation.apply(source.snapshot())
            _ = presentation.apply(source.prompt("u1", "write the report"))
            _ = presentation.apply(source.message(LiveScript.start("m1")))
            _ = presentation.apply(source.message(LiveScript.block(0, ["type": "text", "text": ""])))
            return (presentation, stream, source)
        }

        // MARK: Streaming text is shown once per interval

        @Test func streamingTextWaitsForTheIntervalAndIsThenShownWhole() {
            var rig = streamingPresentation(interval: .seconds(3600))
            defer { rig.stream.controller.stop() }
            let presentation = rig.presentation
            let before = presentation.rebuilds
            for index in 0..<40 { #expect(presentation.apply(rig.source.message(LiveScript.textDelta(0, "word\(index) ")))) }
            #expect(presentation.rebuilds == before, "40 deltas inside one interval derive no rows")
            #expect(presentation.deferredChanges == 40)
            #expect(presentation.hasPendingRows)
            #expect(presentation.model.entries.last.map { entry in
                if case let .assistantText(text) = entry.body { text.text.hasSuffix("word39 ") } else { false }
            } == true, "the model has every delta at once; only the rows wait")
            presentation.flushRows()
            #expect(presentation.rebuilds == before + 1, "the interval's end derives the rows once")
            #expect(!presentation.hasPendingRows)
            expectRows(presentation, rig.stream, "after the interval")
        }

        @Test func aChangeThatIsNotStreamingTextShowsTheWaitingTextWithIt() {
            var rig = streamingPresentation(interval: .seconds(3600))
            defer { rig.stream.controller.stop() }
            let presentation = rig.presentation
            for index in 0..<10 { _ = presentation.apply(rig.source.message(LiveScript.textDelta(0, "word\(index) "))) }
            #expect(presentation.hasPendingRows)
            // The end of the block, then a tool: each shows at once, and the text that waited is in them.
            var before = presentation.rebuilds
            _ = presentation.apply(rig.source.message(LiveScript.stop(0)))
            #expect(presentation.rebuilds == before + 1)
            #expect(!presentation.hasPendingRows)
            expectRows(presentation, rig.stream, "after the block ended")
            _ = presentation.apply(rig.source.message(LiveScript.block(1, ["type": "text", "text": ""])))
            for index in 0..<10 { _ = presentation.apply(rig.source.message(LiveScript.textDelta(1, "again\(index) "))) }
            #expect(presentation.hasPendingRows)
            // The reader's state, and the end of the work, also take the text with them.
            before = presentation.rebuilds
            presentation.setWorking(false)
            #expect(presentation.rebuilds == before + 1)
            #expect(!presentation.hasPendingRows)
            expectRows(presentation, rig.stream, "after the work stopped")
        }

        @Test func theFirstDeltaAfterAQuietIntervalIsShownAtOnce() async throws {
            var rig = streamingPresentation(interval: .milliseconds(60))
            defer { rig.stream.controller.stop() }
            let presentation = rig.presentation
            try await Task.sleep(for: .milliseconds(150))
            let before = presentation.rebuilds
            _ = presentation.apply(rig.source.message(LiveScript.textDelta(0, "first words")))
            #expect(presentation.rebuilds == before + 1, "after a quiet interval a delta is not made to wait")
            #expect(!presentation.hasPendingRows)
            expectRows(presentation, rig.stream, "first delta")
        }

        @Test func theTimerShowsTheWaitingTextAndSustainedStreamingCostsOneRebuildPerInterval() async throws {
            let interval = Duration.milliseconds(80)
            var rig = streamingPresentation(interval: interval)
            defer { rig.stream.controller.stop() }
            let presentation = rig.presentation
            try await Task.sleep(for: .milliseconds(150))
            let before = presentation.rebuilds
            let began = ContinuousClock.now
            // 600 characters a second as 12-character deltas every 20 ms, for about 2 seconds.
            for index in 0..<100 {
                _ = presentation.apply(rig.source.message(LiveScript.textDelta(0, "abcdefghi\(index % 10)  ")))
                try await Task.sleep(for: .milliseconds(20))
            }
            // The last words are shown by the timer, not by a later change.
            var waited = 0
            while presentation.hasPendingRows, waited < 400 {
                try await Task.sleep(for: .milliseconds(10))
                waited += 1
            }
            #expect(!presentation.hasPendingRows, "the timer shows the text that was waiting")
            expectRows(presentation, rig.stream, "after the timer")
            let elapsed = ContinuousClock.now - began
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let rebuilds = presentation.rebuilds - before
            // Two rebuilds are never closer than the interval, so no load can make this bound false (a slow Mac only lengthens `seconds`).
            let bound = Int(seconds / 0.080) + 2
            print("BUDGET interval: 100 deltas in \(String(format: "%.2f", seconds)) s: \(rebuilds) rebuilds (at most \(bound)), \(presentation.deferredChanges) deferred")
            #expect(rebuilds <= bound, "\(rebuilds) rebuilds in \(seconds) s")
            // How many fewer rebuilds than deltas depends on the load: a starved main thread spaces the deltas out past the
            // interval, and each then shows at once. The deterministic tests above prove the wait; this one the timer and the bound.
        }

        @Test func aStreamNobodyShowsDerivesNoRowsAndStartsNoTimer() {
            var rig = streamingPresentation(interval: .milliseconds(80), attached: false)
            defer { rig.stream.controller.stop() }
            let presentation = rig.presentation
            let before = presentation.rebuilds
            for index in 0..<50 { _ = presentation.apply(rig.source.message(LiveScript.textDelta(0, "hidden \(index) "))) }
            #expect(presentation.rebuilds == before)
            #expect(presentation.deferredChanges == 0 && !presentation.hasPendingRows, "a window nobody sees keeps no timer or wait")
            presentation.attach(rig.stream.controller)
            expectRows(presentation, rig.stream, "after attaching")
            // Detaching while text waits drops the wait; the next attach shows everything.
            for index in 0..<5 { _ = presentation.apply(rig.source.message(LiveScript.textDelta(0, "more \(index) "))) }
            presentation.detach()
            #expect(!presentation.hasPendingRows)
            _ = presentation.apply(rig.source.message(LiveScript.textDelta(0, "while hidden")))
            presentation.attach(rig.stream.controller)
            expectRows(presentation, rig.stream, "after attaching again")
        }

        @Test func aLiveChatShowsStreamingTextAtTheInterval() {
            let card = UUID()
            let feed = LiveChatFeed(source: ScriptedLiveSource(card: card, conversationID: nil), card: card, conversationID: nil,
                                    configDirectory: nil, workingDirectory: nil)
            #expect(feed.presentation.rowsInterval == ChatPresentation.streamingRowsInterval)
            #expect(ChatPresentation.streamingRowsInterval <= .milliseconds(100), "text appears within about 100 ms")
            // A transcript follower has no interval: it shows what it reads at once.
            #expect(ChatPresentation(sessionID: "plain", workingDirectory: nil).rowsInterval == nil)
        }

        // MARK: What a delta costs the stream

        /// The record of the stream's cost off screen (3,000 characters, 250 deltas): a rebuild per delta, and once per interval.
        /// The stream update is the controller's time per rebuild in this debug build, forced through layout; nothing asserts it.
        @Test(.renderProbe) func streamCostRecord() async {
            let immediate = await Self.stream(characters: 3_000, settle: Self.frame)
            Self.report("immediate", immediate)
            let throttled = await Self.stream(characters: 3_000, interval: ChatPresentation.streamingRowsInterval, wait: .milliseconds(200),
                                              settle: Self.frame)
            Self.report("throttled", throttled)
            #expect(throttled.rebuilds <= throttled.deltas && immediate.rebuilds == immediate.deltas)
        }

        @Test(.renderProbe) func aDeltaConfiguresAndMeasuresTheGrowingRowOnce() async {
            let run = await Self.stream(characters: 1_800) { stream in
                stream.controller.scrollView.layoutSubtreeIfNeeded()
                stream.controller.table.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            Self.report("per delta", run)
            #expect(run.rebuilds == run.deltas, "no interval: a rebuild per delta")
            // The row that grows is configured once and measured once per rebuild, not reloaded (a reload walks the cell's
            // views, and asks for the cell and for the height a second time). The live row is not touched by text.
            #expect(run.configured <= run.rebuilds + 4, "rows configured: \(run.configured) for \(run.rebuilds) rebuilds")
            #expect(run.measured <= run.rebuilds + 4, "rows measured: \(run.measured) for \(run.rebuilds) rebuilds")
            // Markdown is parsed per block: the finished blocks of the message are parsed when they finish and kept, and each
            // delta parses the open block. Parsing the whole message for every delta would hand the parser about 150 times
            // the message (150 deltas of an average half message, in two views); this hands it about 20 times.
            #expect(run.parsedCharacters < 40 * 1_800, "characters handed to the markdown parser: \(run.parsedCharacters) for 1,800")
            #expect(run.rowReloads == 0, "a row on screen is configured where it stands; it was reloaded \(run.rowReloads) times")
            #expect(run.perRow.count <= 2, "rows touched by the stream of one message: \(run.perRow)")
        }
    }
}
