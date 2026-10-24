import AppKit
import Foundation
import Testing
import LoomChat
import LoomCore
import SwiftUI
@testable import LoomCatalogUI

extension ChatHosted {
    /// A streaming Chat answer stops laying out its settled blocks (C7): what the measuring path hands to a hosting controller
    /// per rebuild does not grow with the message, and a settled block's view is not built again by the flushes after it.
    /// Both are counts through `ChatRenderProbe`, so no load can cross them.
    @MainActor
    @Suite
    struct ChatStreamMeasureTests {
        typealias Cost = ChatHosted.ChatStreamCostTests

        /// One frame without a sleep: the table lays out and the run loop turns once.
        static func quickFrame(_ stream: ChatHostedStream) async {
            stream.controller.scrollView.layoutSubtreeIfNeeded()
            stream.controller.table.layoutSubtreeIfNeeded()
            await Task.yield()
        }

        static func median(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }

        /// The characters of a block, nested ones included.
        static func characters(of block: MarkdownBlock) -> Int {
            switch block {
            case let .paragraph(source): source.utf8.count
            case let .heading(_, text): text.utf8.count
            case let .code(_, code, _): code.utf8.count
            case let .list(_, _, items): items.reduce(0) { $0 + $1.blocks.reduce(0) { $0 + characters(of: $1) } }
            case let .quote(inner): inner.reduce(0) { $0 + characters(of: $1) }
            case let .table(table): (table.header + table.rows.flatMap { $0 }).reduce(0) { $0 + $1.utf8.count }
            case .rule: 0
            }
        }

        // MARK: A. The cost of a flush does not grow with the length

        @Test(.renderProbe) func theMeasuredCharactersOfARebuildDoNotGrowWithTheLength() async {
            let piece = 40
            let short = await Cost.stream(characters: 3_000, piece: piece, settle: Self.quickFrame)
            let long = await Cost.stream(characters: 12_000, piece: piece, settle: Self.quickFrame)
            let longest = ChatMarkdown.parse(Cost.answer(characters: 12_000)).map(Self.characters(of:)).max() ?? 0
            let shortMedian = Self.median(short.measuredCharactersPerRebuild), longMedian = Self.median(long.measuredCharactersPerRebuild)
            let shortMax = short.measuredCharactersPerRebuild.max() ?? 0, longMax = long.measuredCharactersPerRebuild.max() ?? 0
            let blocksMax = long.measuredBlocksPerRebuild.max() ?? 0
            print("BUDGET stream measure: measured characters per rebuild, 3,000 characters: median \(shortMedian) max \(shortMax) (\(short.rebuilds) rebuilds); 12,000: median \(longMedian) max \(longMax) (\(long.rebuilds) rebuilds); longest block \(longest); measured blocks per rebuild at 12,000: median \(Self.median(long.measuredBlocksPerRebuild)) max \(blocksMax)")
            #expect(short.rebuilds > 50 && long.rebuilds > 200, "the streams rebuilt \(short.rebuilds) and \(long.rebuilds) times")
            #expect(Double(longMedian) <= 1.5 * Double(shortMedian) + Double(2 * longest), "median \(longMedian) at 12,000 against \(shortMedian) at 3,000")
            #expect(Double(longMax) <= 1.5 * Double(shortMax) + Double(2 * longest), "max \(longMax) at 12,000 against \(shortMax) at 3,000")
            // The growing row is measured by its own cell (S4), so a rebuild hands the measurer nothing; it measures the row
            // only when it has no cell, and then the blocks that settled since it last did, once: never more for a longer message.
            #expect(longMax <= shortMax + 2 * longest + 2 * piece, "a rebuild measured \(longMax) characters at 12,000, \(shortMax) at 3,000")
            #expect(Self.median(long.measuredBlocksPerRebuild) <= 2, "a rebuild measured \(blocksMax) blocks at most")
        }

        // MARK: B. A settled block is not evaluated again

        @Test(.renderProbe) func aSettledBlockIsNotBuiltAgainByTheFlushesAfterIt() async {
            let characters = 3_000
            let run = await Cost.stream(characters: characters, settle: Self.quickFrame)
            let blocks = ChatMarkdown.parse(Cost.answer(characters: characters))
            #expect(blocks.count > 8)
            var builds: [Int] = [], bodies: [Int] = []
            for (index, block) in blocks.enumerated().dropLast(2) {
                builds.append(run.blockBuilds["\(index)#\(block.hashValue)"] ?? 0)
                bodies.append(run.blockBodies["\(index)#\(block.hashValue)"] ?? 0)
            }
            let worst = builds.max() ?? 0
            print("BUDGET stream measure: view builds of the settled blocks over \(run.rebuilds) rebuilds: max \(worst), median \(Self.median(builds)), per block \(builds); body evaluations: max \(bodies.max() ?? 0), per block \(bodies)")
            // A settled block is built when it is measured, in the flush it settles in, and again each time the head grows (a new
            // paragraph settled): once per paragraph at most, never once per flush (that was twice the flushes after it settled).
            #expect(worst <= blocks.count + 12, "a settled block's view was built \(worst) times in \(run.rebuilds) rebuilds: \(builds)")
            #expect(Self.median(builds) * 4 <= run.rebuilds, "median \(Self.median(builds)) builds in \(run.rebuilds) rebuilds")
            #expect((bodies.max() ?? 0) <= 8, "a settled block's body ran \(bodies.max() ?? 0) times: \(bodies)")
        }

        // MARK: Rig

        /// A live stream hosted in a window, with `characters` of the answer in it and settled.
        @MainActor struct Rig {
            let presentation: ChatPresentation
            let stream: ChatHostedStream
            var source: SyntheticSource
            let scope: String
            let context: ChatRowContext
            var sent = 0
            let text: [Character]

            /// Sends the next `count` characters as one delta.
            mutating func send(_ count: Int) async {
                let end = min(sent + count, text.count)
                guard end > sent else { return }
                _ = presentation.apply(source.message(LiveScript.textDelta(0, String(text[sent..<end]))))
                sent = end
                await Self.settle(stream)
            }

            static func settle(_ stream: ChatHostedStream) async { await ChatStreamMeasureTests.quickFrame(stream) }
        }

        static func rig(characters: Int, total: Int = 6_000, width: CGFloat = 900) async -> Rig {
            ChatSessionMemoryStore.removeAll()
            let scope = "measure-\(UUID().uuidString)"
            let presentation = ChatPresentation(sessionID: scope, workingDirectory: nil, isWorking: true)
            presentation.activityFromSource = true
            let context = ChatRowContext(probeScope: scope)
            let stream = ChatHostedStream(width: width, height: 700, context: context)
            presentation.attach(stream.controller)
            var source = SyntheticSource()
            _ = presentation.apply(source.snapshot())
            _ = presentation.apply(source.prompt("u1", "write the report"))
            _ = presentation.apply(source.message(LiveScript.start("m1")))
            _ = presentation.apply(source.message(LiveScript.block(0, ["type": "text", "text": ""])))
            await stream.settle(4)
            var rig = Rig(presentation: presentation, stream: stream, source: source, scope: scope, context: context, text: Array(Cost.answer(characters: total)))
            while rig.sent < characters { await rig.send(40) }
            await stream.settle(4)
            return rig
        }

        // MARK: E. What still redraws the settled blocks

        /// The pixels of a view as drawn.
        static func pixels(of view: NSView) -> NSBitmapImageRep? {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }

        /// Lays the stream out and draws it now, without giving up the main actor.
        @MainActor static func flush(_ rig: Rig) {
            rig.stream.controller.scrollView.layoutSubtreeIfNeeded()
            rig.stream.controller.table.layoutSubtreeIfNeeded()
            rig.stream.window.displayIfNeeded()
        }

        /// The share of pixels that differ by more than `tolerance` in a channel; 1 when the sizes differ.
        static func difference(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?, tolerance: Int = 1) -> Double {
            guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
                  let x = a.bitmapData, let y = b.bitmapData, a.bytesPerRow == b.bytesPerRow else { return 1 }
            let samples = a.bytesPerRow * a.pixelsHigh
            var differing = 0
            var index = 0
            while index + 3 < samples {
                if abs(Int(x[index]) - Int(y[index])) > tolerance || abs(Int(x[index + 1]) - Int(y[index + 1])) > tolerance
                    || abs(Int(x[index + 2]) - Int(y[index + 2])) > tolerance { differing += 1 }
                index += 4
            }
            return Double(differing) / Double(samples / 4)
        }

        @MainActor static func proseRow(_ rig: Rig) -> (index: Int, row: ChatRow)? {
            let rows = rig.stream.controller.rows
            guard let index = rows.firstIndex(where: { if case .prose = $0.kind { true } else { false } }) else { return nil }
            return (index, rows[index])
        }

        @MainActor static func cellPixels(_ rig: Rig) -> NSBitmapImageRep? {
            guard let (index, _) = proseRow(rig), let cell = rig.stream.controller.table.view(atColumn: 0, row: index, makeIfNecessary: false) else { return nil }
            return pixels(of: cell)
        }

        /// The same row in a view made now, in a window with the same appearance and width: nothing in it is kept.
        @MainActor static func freshPixels(_ rig: Rig, appearance: NSAppearance?) -> NSBitmapImageRep? {
            guard let (index, row) = proseRow(rig) else { return nil }
            let size = rig.stream.controller.table.rect(ofRow: index).size
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let hosting = NSHostingView(rootView: ChatRowView(row: row, context: rig.context))
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            window.appearance = appearance
            return pixels(of: hosting)
        }

        // MARK: E. What still redraws the settled blocks

        /// The settled head is `.equatable()`: a flush that only grows the tail builds none of its blocks, and what changes how
        /// they look without changing the head (the appearance, the tone, the width) still draws them anew. Seen in the pixels of the
        /// stream's cell against the same row in a view made after the change.
        @Test(.renderProbe) func theSettledHeadIsNotBuiltByAFlushButStillFollowsAppearanceToneAndWidth() async {
            var rig = await Self.rig(characters: 2_000)
            defer { rig.stream.controller.stop(); ChatRenderProbe.stop() }
            RenderProbeExclusive.watchChat(scope: rig.scope)
            let headBlocks = ChatContent.streamingBlocks(id: "m1", text: String(rig.text[0..<rig.sent])).head.count
            #expect(headBlocks >= 6, "the answer has a settled head of \(headBlocks) blocks")
            await rig.send(40)
            let built = ChatRenderProbe.blockBuilds.values.reduce(0, +), bodies = ChatRenderProbe.blockBodies.values.reduce(0, +)
            print("BUDGET stream measure: a plain flush with \(headBlocks) settled blocks built \(built) block views and ran \(bodies) block bodies")
            #expect(built <= 4 && bodies <= 4, "a flush that grew the open block built \(built) and ran \(bodies) block views of \(headBlocks) settled")

            func check(_ label: String, appearance: NSAppearance?) {
                let drawn = Self.cellPixels(rig), fresh = Self.freshPixels(rig, appearance: appearance)
                let gap = Self.difference(drawn, fresh)
                print("BUDGET stream measure: \(label): the drawn cell differs from a fresh one in \(String(format: "%.3f", gap * 100)) % of its pixels")
                #expect(drawn != nil && gap < 0.002, "after \(label) the cell differs from a fresh one in \(gap * 100) % of its pixels")
            }
            rig.stream.window.appearance = NSAppearance(named: .darkAqua)
            await rig.stream.settle(4)
            check("a plain flush", appearance: NSAppearance(named: .darkAqua))
            let before = Self.cellPixels(rig)
            rig.stream.window.appearance = NSAppearance(named: .aqua)
            await rig.stream.settle(4)
            #expect(Self.difference(before, Self.cellPixels(rig)) > 0.01, "the light appearance draws the cell differently from the dark one")
            check("an appearance change", appearance: NSAppearance(named: .aqua))
            rig.stream.window.appearance = NSAppearance(named: .darkAqua)
            await rig.stream.settle(4)
            check("the appearance changing back", appearance: NSAppearance(named: .darkAqua))

            // The tone is one global that other suites read: it is flipped and restored in one synchronous stretch on the main
            // actor, with no suspension in between, so nothing else can run while it is wrong.
            let neutral = Self.cellPixels(rig)
            let tone = LoomTheme.ThemeState.shared.tone
            LoomTheme.ThemeState.shared.tone = tone == .warm ? .cool : .warm
            Self.flush(rig)
            let flipped = Self.cellPixels(rig), fresh = Self.freshPixels(rig, appearance: NSAppearance(named: .darkAqua))
            LoomTheme.ThemeState.shared.tone = tone
            let moved = Self.difference(neutral, flipped), toneGap = Self.difference(flipped, fresh)
            print("BUDGET stream measure: a change of tone moves \(String(format: "%.3f", moved * 100)) % of the cell's pixels; the drawn cell then differs from a fresh one in \(String(format: "%.3f", toneGap * 100)) %")
            #expect(moved > 0.01, "the tone change moved \(moved * 100) % of the cell's pixels")
            #expect(flipped != nil && toneGap < 0.002, "after a change of tone the cell differs from a fresh one in \(toneGap * 100) % of its pixels")
            Self.flush(rig)

            rig.stream.window.setContentSize(NSSize(width: 620, height: 700))
            await rig.stream.settle(6)
            check("a change of width", appearance: NSAppearance(named: .darkAqua))
        }

        // MARK: Corpus

        struct Message {
            let name: String
            let text: String
            /// Whether the composed measure must take it (a message it does not cover falls back to the whole layout).
            var composes = true
            /// Sets of wrap flags to try; a code block's index.
            var wrapIndexes: [Int] = []
        }

        static let corpus: [Message] = [
            Message(name: "prose", text: """
            The feed batches the deltas of one read of the pipe and hands them to the presentation, which derives the rows of the newest turn and gives the table what differs.

            A second paragraph, shorter than the first.

            A third one that is long enough to wrap onto several lines in a narrow column, with a few more words so that a wide one wraps too, and then some, because the reading size is generous.

            The last paragraph of the prose message, still open
            """),
            Message(name: "markdown", text: """
            # A heading

            Some **bold** words, `inline code`, and a [link](https://example.com/page) in a paragraph that goes on for a while so that it wraps in the narrow case.

            ## A second heading

            - the first item
            - the second item with `code`
              - a nested item
              - another nested item that is long enough to wrap onto a second line in a narrow column
            - the third item

            1. one
            2. two

            > A quote that spans a couple of lines
            > and says something worth quoting.

            ### Third level

            The closing paragraph, still going
            """),
            Message(name: "code", text: """
            Before the code.

            ```swift
            func apply(_ change: ModelChange) -> Bool {
                guard change.sequence > lastSequence else { return false }
                let summary = "a long line of code that is wider than the narrow column and so scrolls sideways or wraps with the flag"
                return rebuild(change)
            }
            ```

            Between the blocks.

            ```
            plain
            text
            ```

            After the code, the last words
            """, wrapIndexes: [1, 3]),
            Message(name: "unbroken", text: "Before.\n\n" + String(repeating: "abcdefghij", count: 40) + "\n\nhttps://example.com/" + String(repeating: "path/", count: 30)
                + "\n\nAfter, still going"),
            Message(name: "emoji", text: """
            Done \u{2705} \u{1F389} shipped \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} with the family and the flags \u{1F1F9}\u{1F1F7} \u{1F1EC}\u{1F1E7}.

            - \u{1F680} launch the thing that is long enough to wrap around once the column is narrow
            - \u{1F6A7} work in progress

            Still writing \u{1F4DD}
            """),
            Message(name: "cjk", text: """
            \u{8FD9}\u{662F}\u{4E00}\u{6BB5}\u{4E2D}\u{6587}\u{FF0C}\u{7528}\u{6765}\u{68C0}\u{67E5}\u{957F}\u{884C}\u{5728}\u{7A84}\u{5217}\u{4E2D}\u{7684}\u{6362}\u{884C}\u{3002}\u{8FD9}\u{91CC}\u{8FD8}\u{6709}\u{66F4}\u{591A}\u{7684}\u{6587}\u{5B57}\u{FF0C}\u{4E00}\u{76F4}\u{5199}\u{5230}\u{884C}\u{5C3E}\u{FF0C}\u{518D}\u{6362}\u{884C}\u{3002}

            \u{65E5}\u{672C}\u{8A9E}\u{306E}\u{6BB5}\u{843D}\u{3067}\u{3059}\u{3002}\u{3053}\u{308C}\u{306F}\u{9577}\u{3044}\u{6587}\u{7AE0}\u{306E}\u{4F8B}\u{3067}\u{3001}\u{6298}\u{308A}\u{8FD4}\u{3057}\u{3092}\u{78BA}\u{304B}\u{3081}\u{307E}\u{3059}\u{3002}

            \u{D55C}\u{AD6D}\u{C5B4} \u{BB38}\u{C7A5}\u{B3C4} \u{C788}\u{C2B5}\u{B2C8}\u{B2E4}.
            """),
            Message(name: "rule and table", text: """
            Before the rule.

            ---

            | name | value |
            | --- | ---: |
            | alpha | 1 |
            | beta | 22 |

            After the table, still going
            """),
        ]

        /// The offsets (in characters) a stream of `text` is cut at: after each paragraph break and a few characters past it, a
        /// few in the middle of blocks, and the whole.
        static func cuts(of text: String) -> [Int] {
            let characters = Array(text)
            var cuts: Set<Int> = [characters.count]
            var index = 0
            while index + 1 < characters.count {
                if characters[index] == "\n", characters[index + 1] == "\n" {
                    cuts.insert(index + 2)
                    cuts.insert(min(characters.count, index + 7))
                }
                index += 1
            }
            for fraction in [0.2, 0.45, 0.7] { cuts.insert(Int(Double(characters.count) * fraction)) }
            return cuts.filter { $0 > 0 }.sorted()
        }

        @MainActor static func baseRow() -> ChatRow {
            ChatFixture.rows(ChatFixture.turn(1, answer: "base")).first { if case .prose = $0.kind { true } else { false } }!
        }

        @MainActor static func streamingRow(id: String, text: String, flags: Set<String> = [], fold: ChatTreePosition? = nil) -> ChatRow {
            var row = baseRow()
            guard case var .prose(entry, _) = row.kind, case var .assistantText(body) = entry.body else { return row }
            entry.id = id
            body.text = text
            body.isStreaming = true
            entry.body = .assistantText(body)
            row = ChatRow(id: id, kind: .prose(entry, settled: false), flags: flags)
            row.foldGuide = fold
            return row
        }

        /// The row laid out whole, unceiled: what the composition has to match.
        @MainActor static func wholeHeight(_ row: ChatRow, width: CGFloat, context: ChatRowContext,
                                           host: NSHostingController<ChatRowView>) -> CGFloat {
            host.rootView = ChatRowView(row: row, context: context, measuring: true)
            return host.sizeThatFits(in: CGSize(width: width, height: 100_000)).height
        }

        // MARK: C. The composed height is the whole row's height

        @Test func theComposedHeightOfAStreamingRowIsThatOfTheWholeRow() {
            let context = ChatRowContext()
            let measurer = ChatRowMeasurer(context: context)
            let host = NSHostingController(rootView: ChatRowView(row: ChatRow(id: "-", kind: .empty), context: context))
            host.sizingOptions = []
            var worst: CGFloat = 0, cases = 0, fellBack: Set<String> = []
            var worstCase = ""
            var stamp = 0
            for message in Self.corpus {
                let flagSets: [Set<String>] = [[]] + message.wrapIndexes.map { ["wrap:\($0)"] } + (message.wrapIndexes.count > 1 ? [Set(message.wrapIndexes.map { "wrap:\($0)" })] : [])
                for flags in flagSets {
                    for fold in [nil, ChatTreePosition.middle] as [ChatTreePosition?] {
                        for width in [CGFloat(360), 900, 1500] {
                            stamp += 1
                            let id = "equivalence-\(stamp)"
                            for cut in Self.cuts(of: message.text) {
                                let text = String(Array(message.text).prefix(cut))
                                let row = Self.streamingRow(id: id, text: text, flags: flags, fold: fold)
                                let whole = Self.wholeHeight(row, width: width, context: context, host: host)
                                guard let composed = measurer.composedHeight(of: row, width: width) else {
                                    fellBack.insert(message.name)
                                    continue
                                }
                                cases += 1
                                let gap = abs(composed - whole)
                                if gap > worst { worst = gap; worstCase = "\(message.name) cut \(cut) width \(width) fold \(fold != nil) flags \(flags): composed \(composed) whole \(whole)" }
                                #expect(gap <= 0.5, "\(message.name) cut \(cut) width \(width) fold \(fold != nil) flags \(flags): composed \(composed), whole \(whole)")
                                #expect(measurer.height(of: row, width: width) == max(1, ceil(composed)))
                            }
                        }
                    }
                }
            }
            // A narrower padding, as a side chat's column has.
            context.columnPadding = 14
            for cut in Self.cuts(of: Self.corpus[1].text) {
                let row = Self.streamingRow(id: "equivalence-padding", text: String(Array(Self.corpus[1].text).prefix(cut)))
                guard let composed = measurer.composedHeight(of: row, width: 500) else { continue }
                cases += 1
                #expect(abs(composed - Self.wholeHeight(row, width: 500, context: context, host: host)) <= 0.5, "narrow padding, cut \(cut)")
            }
            print("BUDGET stream measure: composed against whole height: \(cases) cases, worst gap \(String(format: "%.3f", worst)) pt (\(worstCase)); fell back to the whole layout: \(fellBack.sorted())")
            #expect(cases > 300)
            #expect(fellBack.isEmpty, "messages the composition did not take: \(fellBack.sorted())")
        }

        @Test func aSettledRowAndAMessageWithAnOpenFenceInItsHeadAreMeasuredWhole() {
            let context = ChatRowContext()
            let measurer = ChatRowMeasurer(context: context)
            var settled = Self.streamingRow(id: "whole-settled", text: "One.\n\nTwo.")
            if case var .prose(entry, _) = settled.kind, case var .assistantText(body) = entry.body {
                body.isStreaming = false
                entry.body = .assistantText(body)
                settled.kind = .prose(entry, settled: true)
            }
            #expect(measurer.composedHeight(of: settled, width: 900) == nil, "a settled answer is measured whole")
            // The splitter does not look into a quote; the parser opens a fence there: the head then holds an open block.
            let odd = "> ```\n> code\n\nnext\n\n"
            #expect(!ChatContent.streamingBlocks(id: "whole-odd", text: odd).isComposable)
            #expect(measurer.composedHeight(of: Self.streamingRow(id: "whole-odd", text: odd), width: 900) == nil)
            #expect(measurer.composedHeight(of: ChatRow(id: "x", kind: .empty), width: 900) == nil)
        }

        // MARK: D. The incremental split is the fresh split

        @MainActor static func reference(_ text: String) -> (head: [MarkdownBlock], tail: [MarkdownBlock], headCharacters: Int) {
            let split = ChatContent.stableSplit(text)
            let head = String(text[..<split]), tail = String(text[split...])
            return (head.isEmpty ? [] : ChatMarkdown.parse(head), tail.isEmpty ? [] : ChatMarkdown.parse(tail), head.utf8.count)
        }

        @Test func theIncrementalSplitGivesTheHeadTheTailAndTheTokenOfAFreshSplit() {
            var checked = 0
            var fresh = 0
            let texts = Self.corpus.map(\.text) + [
                "one\r\n\r\ntwo\r\n\r\nthree", "a\r\n\r\n```\r\nx\r\n\r\ny\r\n```\r\n\r\nb", "   \n\n  \nx\n \n\ny", "```\na\n\nb\n```\n\n~~~\nc\n\n~~~\n\nd\n\n",
                "\n\n\nlead\n\n\n\nmore", "> q\n>\n> r\n\n- a\n\n- b\n\ntail", "e\u{301}\u{301}\n\n\u{1F468}\u{200D}\u{1F469}\n\nx",
            ]
            for (number, text) in texts.enumerated() {
                let characters = Array(text)
                let id = "split-\(number)"
                for cut in 0...characters.count {
                    let prefix = String(characters.prefix(cut))
                    let incremental = ChatContent.streamingBlocks(id: id, text: prefix)
                    fresh += 1
                    let alone = ChatContent.streamingBlocks(id: "split-fresh-\(fresh)", text: prefix)
                    let expected = Self.reference(prefix)
                    #expect(incremental.head == expected.head && incremental.tail == expected.tail, "text \(number), cut \(cut): head or tail differ from the whole parse of the split")
                    #expect(incremental.head == alone.head && incremental.tail == alone.tail, "text \(number), cut \(cut): differs from a fresh state")
                    #expect(incremental.headToken.count == alone.headToken.count && incremental.headToken.hash == alone.headToken.hash && incremental.headHashes == alone.headHashes
                            && incremental.tailCharacters == alone.tailCharacters && incremental.isComposable == alone.isComposable, "text \(number), cut \(cut): token differs from a fresh state")
                    #expect(incremental.blocks == ChatContent.blocks(id: "split-whole-\(fresh)", text: prefix, isStreaming: true))
                    checked += 1
                    // The same text again is answered from what was made.
                    #expect(ChatContent.streamingBlocks(id: id, text: prefix).headToken == incremental.headToken)
                }
            }
            // Text that does not continue the old one (an edit in the middle, a shorter one) starts over.
            for (first, second) in [("alpha\n\nbeta\n\ngamma", "alpha\n\nBETA\n\ngamma"), ("alpha\n\nbeta\n\ngamma", "alp"), ("x\n\ny", "z\n\nw\n\nv"), ("p\r", "p\r\n\r\nq")] {
                let id = "split-edit"
                _ = ChatContent.streamingBlocks(id: id, text: first)
                let after = ChatContent.streamingBlocks(id: id, text: second)
                let expected = Self.reference(second)
                #expect(after.head == expected.head && after.tail == expected.tail, "\(first.debugDescription) then \(second.debugDescription)")
            }
            print("BUDGET stream measure: incremental split against fresh: \(checked) cut points of \(texts.count) texts")
            #expect(checked > 2_000)
        }

        /// Fences the split once read apart from the parser: a four-backtick fence holding three-backtick ones (a README shown
        /// whole), a tilde line in a backtick fence, and a code line that starts with three backticks and goes on. Streamed in
        /// steps, the head never ends inside a block the parser has open, the head stays composable, and the split's blocks are
        /// the whole parse.
        @Test func theSplitReadsFencesByTheParsersRules() {
            let texts = [
                "Here is the file.\n\n````markdown\n# Title\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nMore.\n````\n\nAfter.\n\nEnd.",
                "Look:\n\n```sh\necho one\n~~~\n\necho two\n```\n\nAfter.\n\nEnd.",
                "Look:\n\n```text\nfirst\n```not a close\n\nsecond\n```\n\nAfter.\n\nEnd.",
            ]
            for (number, text) in texts.enumerated() {
                let characters = Array(text)
                let id = "fence-rules-\(number)"
                for cut in 0...characters.count {
                    let prefix = String(characters.prefix(cut))
                    let parts = ChatContent.streamingBlocks(id: id, text: prefix)
                    let openInHead = parts.head.contains { if case .code(_, _, false) = $0 { true } else { false } }
                    #expect(!openInHead, "text \(number), cut \(cut): the head ends inside an open fence")
                    #expect(parts.isComposable, "text \(number), cut \(cut): the head is not composable")
                    #expect(parts.blocks == ChatMarkdown.parse(prefix), "text \(number), cut \(cut): the split's blocks are not the whole parse")
                }
                // The head moved past the fence once it closed.
                #expect(ChatContent.streamingBlocks(id: id, text: text).head.last == .paragraph("After."), "text \(number)")
            }
        }

        @Test func theSplitStateKeepsFewMessages() {
            for number in 0..<60 { _ = ChatContent.streamingBlocks(id: "many-\(number)", text: "a\n\nb") }
            // The newest is still answered without a new parse of its head, and an evicted one is simply made again.
            let again = ChatContent.streamingBlocks(id: "many-0", text: "a\n\nb")
            #expect(again.head.count == 1 && again.tail.count == 1)
        }
    }
}
