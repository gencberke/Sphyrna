import AppKit
import Foundation
import Testing
import LoomChat
import SwiftUI
@testable import LoomCatalogUI

extension ChatHosted {
    /// The streaming head parses only what settled (each piece once, a list's piece again with what follows it), and a long
    /// code fence open at the end settles in chunks of `ChatContent.fenceChunkLines` lines: drawn as one block, measured from
    /// its kept chunks, and the same blocks as a whole parse.
    @MainActor
    @Suite
    struct ChatStreamFenceTests {
        typealias Measure = ChatHosted.ChatStreamMeasureTests

        /// The chunk size the texts below are written for (`ChatContent.fenceChunkLines`).
        static let chunk = 40

        static func codeLines(_ count: Int, from first: Int = 1) -> String {
            (first..<(first + count)).map { "let value\($0) = compute(\($0), limit: 64) // the line \($0) of the block" }
                .joined(separator: "\n")
        }

        /// The head and the tail of a fresh split, parsed whole.
        static func reference(_ text: String) -> (head: [MarkdownBlock], tail: [MarkdownBlock]) {
            let split = ChatContent.stableSplit(text)
            let head = String(text[..<split]), tail = String(text[split...])
            return (head.isEmpty ? [] : ChatMarkdown.parse(head), tail.isEmpty ? [] : ChatMarkdown.parse(tail))
        }

        /// Streams `text` into one split, cut by cut, and checks every cut against a fresh split parsed whole: the head is the
        /// parse of the settled text and the tail, with an open fence's block after it, the parse of the rest. Returns how many
        /// cuts had an open fence in chunks.
        @discardableResult
        static func expectWholeParse(_ text: String, id: String, step: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) -> Int {
            let characters = Array(text)
            var cuts = Set(stride(from: 0, through: characters.count, by: step))
            cuts.insert(characters.count)
            for (index, character) in characters.enumerated() where character == "\n" {
                cuts.insert(index + 1)
                cuts.insert(min(characters.count, index + 2))
            }
            var chunked = 0
            for cut in cuts.sorted() {
                let prefix = String(characters.prefix(cut))
                let parts = ChatContent.streamingBlocks(id: id, text: prefix)
                let expected = reference(prefix)
                let tail = parts.tail + (parts.fence.map { [$0.block] } ?? [])
                if parts.fence != nil { chunked += 1 }
                #expect(parts.head == expected.head, "\(id) cut \(cut): the head is not the parse of the settled text", sourceLocation: sourceLocation)
                #expect(tail == expected.tail, "\(id) cut \(cut): the tail is not the parse of the rest", sourceLocation: sourceLocation)
                let open = expected.head.contains { if case .code(_, _, false) = $0 { true } else { false } }
                #expect(parts.isComposable == !open, "\(id) cut \(cut): composable", sourceLocation: sourceLocation)
            }
            return chunked
        }

        // MARK: The head parses only what settled

        @Test func theIncrementalHeadIsTheWholeParseOfAMixedCorpus() {
            let texts = [
                // Lists a blank line goes on with: loose items, an indented paragraph, a nested list, a fence in an item.
                "Intro.\n\n- one\n\n- two\n\n  more of two\n\n- three\n  - nested\n\n    deeper\n\nAfter the list.\n\nEnd",
                "1. first\n\n2. second\n\n3) other kind\n\n- bullets\n\n\n- after two blanks\n\nParagraph.\n\n* star\n\nx",
                "- item\n\n  ```swift\n  let a = 1\n\n  let b = 2\n  ```\n\n- next\n\nDone.\n\nTail",
                // Quotes, a lazy line, a table, a rule, headings.
                "> quoted\n> more\n\n> another quote\nlazy line\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\n## Head\n\nText",
                // Fences with blank lines inside, tildes, four backticks holding three.
                "Look:\n\n```sh\necho one\n\necho two\n```\n\n~~~\na\n\nb\n~~~\n\n````markdown\n```swift\nx\n\ny\n```\n````\n\nEnd",
                // A long fence after a paragraph with no blank line, one in a list item, one in a quote, a long four-backtick one.
                "Here is the file:\n```swift\n" + Self.codeLines(95) + "\n```\n\nAfter.\n\nEnd",
                "- the item\n\n  ```swift\n" + Self.codeLines(90).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n  ```\n\nAfter",
                "> ```swift\n" + Self.codeLines(85).split(separator: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n> ```\n\nAfter",
                "````markdown\n" + Self.codeLines(60) + "\n\n```swift\n" + Self.codeLines(30) + "\n```\n````\n\nAfter",
                "\r\nCRLF\r\n\r\n- a\r\n\r\n- b\r\n\r\ntext",
            ]
            var chunked = 0
            for (number, text) in texts.enumerated() {
                chunked += Self.expectWholeParse(text, id: "mixed-\(number)-\(UUID().uuidString)", step: text.count > 2_000 ? 7 : 1)
            }
            #expect(chunked > 0, "the long fence after a paragraph settled in chunks")
        }

        // MARK: A long fence settles in chunks

        @Test func aLongOpenFenceSettlesInChunksOfCompleteLines() {
            let size = Self.chunk
            #expect(ChatContent.fenceChunkLines == size)
            let id = "chunks-\(UUID().uuidString)"
            let lead = "Intro.\n\nThe file:\n```swift\n"
            // Fewer lines than a chunk: drawn as today.
            #expect(ChatContent.streamingBlocks(id: id, text: lead + Self.codeLines(size - 1) + "\n").fence == nil)
            // Two chunks and a line still arriving.
            let partial = lead + Self.codeLines(2 * size) + "\nlet partial"
            let parts = ChatContent.streamingBlocks(id: id, text: partial)
            let fence = try? #require(parts.fence)
            #expect(fence?.chunks.count == 2 && fence?.chunks.allSatisfy { $0.split(separator: "\n").count == size } == true)
            #expect(fence?.open == "let partial", "the line still arriving is not in a chunk")
            #expect(fence?.language == "swift" && fence?.index == 2 && parts.tail == [.paragraph("The file:")])
            #expect(parts.head == [.paragraph("Intro.")] && parts.isComposable)
            // At a chunk's end nothing is open; a closing line ends the chunks.
            let even = ChatContent.streamingBlocks(id: id, text: lead + Self.codeLines(2 * size) + "\n")
            #expect(even.fence?.chunks.count == 2 && even.fence?.open == nil)
            let closed = ChatContent.streamingBlocks(id: id, text: lead + Self.codeLines(2 * size) + "\n```\n")
            #expect(closed.fence == nil && closed.tail.last == .code(language: "swift", code: Self.codeLines(2 * size), isClosed: true))
            // A fence in a list item or a quote, and a four-backtick fence, are drawn as today.
            for (name, text) in [
                ("list", "- item\n  ```swift\n" + Self.codeLines(3 * size).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")),
                ("quote", "> ```swift\n" + Self.codeLines(3 * size).split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")),
                ("four backticks", "````markdown\n```swift\n" + Self.codeLines(3 * size) + "\n```\n\n" + Self.codeLines(size)),
            ] {
                let other = ChatContent.streamingBlocks(id: "chunks-\(name)-\(UUID().uuidString)", text: text)
                #expect(other.fence == nil, "\(name): no chunks")
                let expected = Self.reference(text)
                #expect(other.head == expected.head && other.tail == expected.tail, "\(name): the split parsed whole")
            }
            #expect(ChatContent.streamingBlocks(id: "chunks-nested-\(UUID().uuidString)",
                                                text: "````markdown\n```swift\n" + Self.codeLines(3 * size)).isComposable)
        }

        /// Draws `view` in an off-screen window until its bodies have run.
        static func draw(_ view: some View, width: CGFloat = 800) async {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
        }

        @Test(.renderProbe) func theOpenFenceIsDrawnAsOneBlockWithNoCopyUntilItCloses() async {
            let scope = "fence-draw-\(UUID().uuidString)"
            let context = ChatRowContext(probeScope: scope)
            RenderProbeExclusive.watchChat(scope: scope)
            ChatSelectionProbe.reset()
            defer { ChatRenderProbe.stop(); ChatSelectionProbe.reset() }
            let id = "fence-draw-\(UUID().uuidString)"
            let open = "Intro.\n\n```swift\n" + Self.codeLines(2 * Self.chunk + 10)
            let parts = ChatContent.streamingBlocks(id: id, text: open, in: context)
            await Self.draw(ChatStreamingMarkdownView(parts: parts, flags: [], rowID: id, context: context))
            // One card for the whole fence: its chunks and the open lines in it, no other code block, and no Copy yet.
            #expect(ChatSelectionProbe.codeBlocks == [1: ChatSelectionProbe.CodeBlock(chunks: 2, offersCopy: false)])
            ChatSelectionProbe.reset()
            let finished = ChatContent.blocks(id: id, text: open + "\n```", isStreaming: false, in: context)
            await Self.draw(ChatMarkdownView(blocks: finished, flags: [], rowID: id, isStreaming: false, context: context))
            #expect(ChatSelectionProbe.codeBlocks == [1: ChatSelectionProbe.CodeBlock(chunks: 0, offersCopy: true)], "closed: whole, with Copy")
        }

        /// The fence in chunks is as high as the same blocks drawn as one list and as the fence once it closed, at every line
        /// count, width and wrap; and the measurer's composed height (kept chunks) is the row laid out whole.
        @Test func chunkedAndWholeFencesMeasureTheSame() {
            let context = ChatRowContext()
            let measurer = ChatRowMeasurer(context: context)
            let rowHost = NSHostingController(rootView: ChatRowView(row: ChatRow(id: "-", kind: .empty), context: context))
            rowHost.sizingOptions = []
            let chunked = NSHostingController(rootView: AnyView(EmptyView()))
            chunked.sizingOptions = []
            var cases = 0, worst: CGFloat = 0
            let size = Self.chunk
            let long = "Intro paragraph.\n\n```swift\n" + (1...(3 * size + 7)).map {
                $0 % 9 == 0 ? "let wide\($0) = " + String(repeating: "segment ", count: 18) : "let value\($0) = \($0)"
            }.joined(separator: "\n")
            let lines = long.split(separator: "\n", omittingEmptySubsequences: false)
            var stamp = 0
            // Three lines lead the code; a chunk settles once `size` lines of it are complete.
            for count in stride(from: size + 4, through: lines.count, by: 9) {
                for partial in ["", "\nlet half"] {
                    let text = lines.prefix(count).joined(separator: "\n") + partial
                    for flags in [Set<String>(), ["wrap:1"]] {
                        for width in [CGFloat(420), 1100] {
                            stamp += 1
                            let id = "fence-measure-\(stamp)"
                            let parts = ChatContent.streamingBlocks(id: id, text: text)
                            guard parts.fence != nil else { Issue.record("no chunks at \(count) lines"); continue }
                            let row = Measure.streamingRow(id: id, text: text, flags: flags)
                            let whole = Measure.wholeHeight(row, width: width, context: context, host: rowHost)
                            let composed = measurer.composedHeight(of: row, width: width) ?? 0
                            // The same blocks drawn as one code block, as before the chunks.
                            let content = ChatRowGeometry.contentWidth(rowWidth: width, columnPadding: context.columnPadding, foldGuide: nil)
                            chunked.rootView = AnyView(ChatStreamingMarkdownView(parts: parts, flags: flags, rowID: id, context: context))
                            let inChunks = chunked.sizeThatFits(in: CGSize(width: content, height: 100_000)).height
                            chunked.rootView = AnyView(ChatMarkdownView(blocks: parts.blocks, flags: flags, rowID: id, isStreaming: true, context: context))
                            let asOne = chunked.sizeThatFits(in: CGSize(width: content, height: 100_000)).height
                            // The fence closed: the settled block, highlighted, at the same height.
                            let closedBlocks = ChatMarkdown.parse(text + "\n```")
                            chunked.rootView = AnyView(ChatMarkdownView(blocks: closedBlocks, flags: flags, rowID: id, isStreaming: false, context: context))
                            let closed = chunked.sizeThatFits(in: CGSize(width: content, height: 100_000)).height
                            #expect(abs(inChunks - closed) <= 0.5, "\(count) lines width \(width) \(flags): open \(inChunks), closed \(closed)")
                            cases += 1
                            worst = max(worst, abs(inChunks - asOne), abs(composed - whole), abs(inChunks - closed))
                            #expect(abs(inChunks - asOne) <= 0.5, "\(count) lines\(partial.isEmpty ? "" : " and a part") width \(width) \(flags): chunks \(inChunks), one block \(asOne)")
                            #expect(abs(composed - whole) <= 0.5, "\(count) lines width \(width) \(flags): composed \(composed), whole \(whole)")
                        }
                    }
                }
            }
            print("BUDGET stream fence: chunked against whole heights: \(cases) cases, worst gap \(String(format: "%.3f", worst)) pt")
            #expect(cases > 40)
        }
    }
}
