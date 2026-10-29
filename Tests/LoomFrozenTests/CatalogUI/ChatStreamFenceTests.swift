import AppKit
import Foundation
import Testing
import LoomChat
import SwiftUI
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

extension ChatHosted {
    /// The streaming head parses only what settled (each piece once, a list's piece again with what follows it), and a long
    /// code fence open at the end settles in chunks of `ChatContent.fenceChunkLines` lines: drawn as one block, measured from
    /// its kept chunks, and the same blocks as a whole parse.
    @MainActor
    @Suite
    struct ChatStreamFenceTests {
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
                "Here is the file:\n```swift\n" + ChatStreamFenceShared.codeLines(95) + "\n```\n\nAfter.\n\nEnd",
                "- the item\n\n  ```swift\n" + ChatStreamFenceShared.codeLines(90).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n  ```\n\nAfter",
                "> ```swift\n" + ChatStreamFenceShared.codeLines(85).split(separator: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n> ```\n\nAfter",
                "````markdown\n" + ChatStreamFenceShared.codeLines(60) + "\n\n```swift\n" + ChatStreamFenceShared.codeLines(30) + "\n```\n````\n\nAfter",
                "\r\nCRLF\r\n\r\n- a\r\n\r\n- b\r\n\r\ntext",
            ]
            var chunked = 0
            for (number, text) in texts.enumerated() {
                chunked += ChatStreamFenceShared.expectWholeParse(text, id: "mixed-\(number)-\(UUID().uuidString)", step: text.count > 2_000 ? 7 : 1)
            }
            #expect(chunked > 0, "the long fence after a paragraph settled in chunks")
        }

        /// A fence in a list item ends with the item: a fence marker at column 0 opens a top-level fence, as the parser reads it,
        /// and does not close the item's. A streamed message is then the blocks of the finished one.
        @Test func aListItemFenceClosedAtColumnZeroIsReadAsTheParserReadsIt() {
            let text = "- item\n  ```\n  code\n```\n\nafter\n\n- more\n\n"
            let characters = Array(text)
            for cut in 0...characters.count {
                let prefix = String(characters.prefix(cut))
                let parts = ChatContent.streamingBlocks(id: "item-fence-\(UUID().uuidString)", text: prefix)
                let streamed = parts.head + parts.tail + (parts.fence.map { [$0.block] } ?? [])
                #expect(streamed == (prefix.isEmpty ? [] : ChatMarkdown.parse(prefix)), "cut \(cut): the streamed blocks are not the parse")
            }
            // The fence the column-0 marker opened has no end: nothing after it settles.
            #expect(ChatContent.stableSplit(text) == text.startIndex)
            // A close at the item's own column still closes it, and what follows settles.
            let closed = "- item\n  ```\n  code\n  ```\n\nafter\n\nend"
            #expect(String(closed[..<ChatContent.stableSplit(closed)]).hasSuffix("after\n\n"))
            // A lazy line (no blank line before it, not a block) stays in the item's fence.
            let lazy = "- item\n  ```\n  code\nlazy\n  ```\n\nafter\n\nend"
            #expect(String(lazy[..<ChatContent.stableSplit(lazy)]).hasSuffix("after\n\n"))
            ChatStreamFenceShared.expectWholeParse(closed, id: "item-closed-\(UUID().uuidString)")
            ChatStreamFenceShared.expectWholeParse(lazy, id: "item-lazy-\(UUID().uuidString)")
        }

        // MARK: A long fence settles in chunks

        @Test func aTabIsFourColumnsAndATabOnlyLineIsBlankInTheSplit() {
            // The parser keeps this fence open through the tab-indented line (4 columns, inside the item's content column of 2),
            // so the split must not close it there and cut after the paragraph break that follows.
            let text = "- item\n\n  ```\n  a\n\n\tb\n\nc"
            let split = ChatContent.stableSplit(text)
            #expect(!String(text[..<split]).hasSuffix("\tb\n\n"), "the split sits outside the fence")
            #expect(String(text[..<split]) == "- item\n\n", "only the break before the fence settled")
            // A tab-only line is blank: it is a paragraph break, as the parser reads it.
            let tabbed = "one\n\t\ntwo"
            #expect(String(tabbed[..<ChatContent.stableSplit(tabbed)]) == "one\n\t\n")
        }

        @Test func aLongOpenFenceSettlesInChunksOfCompleteLines() {
            let size = ChatStreamFenceShared.chunk
            #expect(ChatContent.fenceChunkLines == size)
            let id = "chunks-\(UUID().uuidString)"
            let lead = "Intro.\n\nThe file:\n```swift\n"
            // Fewer lines than a chunk: drawn as today.
            #expect(ChatContent.streamingBlocks(id: id, text: lead + ChatStreamFenceShared.codeLines(size - 1) + "\n").fence == nil)
            // Two chunks and a line still arriving.
            let partial = lead + ChatStreamFenceShared.codeLines(2 * size) + "\nlet partial"
            let parts = ChatContent.streamingBlocks(id: id, text: partial)
            let fence = try? #require(parts.fence)
            #expect(fence?.chunks.count == 2 && fence?.chunks.allSatisfy { $0.split(separator: "\n").count == size } == true)
            #expect(fence?.open == "let partial", "the line still arriving is not in a chunk")
            #expect(fence?.language == "swift" && fence?.index == 2 && parts.tail == [.paragraph("The file:")])
            #expect(parts.head == [.paragraph("Intro.")] && parts.isComposable)
            // At a chunk's end nothing is open; a closing line ends the chunks.
            let even = ChatContent.streamingBlocks(id: id, text: lead + ChatStreamFenceShared.codeLines(2 * size) + "\n")
            #expect(even.fence?.chunks.count == 2 && even.fence?.open == nil)
            let closed = ChatContent.streamingBlocks(id: id, text: lead + ChatStreamFenceShared.codeLines(2 * size) + "\n```\n")
            #expect(closed.fence == nil && closed.tail.last == .code(language: "swift", code: ChatStreamFenceShared.codeLines(2 * size), isClosed: true))
            // A fence in a list item or a quote, and a four-backtick fence, are drawn as today.
            for (name, text) in [
                ("list", "- item\n  ```swift\n" + ChatStreamFenceShared.codeLines(3 * size).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")),
                ("quote", "> ```swift\n" + ChatStreamFenceShared.codeLines(3 * size).split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")),
                ("four backticks", "````markdown\n```swift\n" + ChatStreamFenceShared.codeLines(3 * size) + "\n```\n\n" + ChatStreamFenceShared.codeLines(size)),
            ] {
                let other = ChatContent.streamingBlocks(id: "chunks-\(name)-\(UUID().uuidString)", text: text)
                #expect(other.fence == nil, "\(name): no chunks")
                let expected = ChatStreamFenceShared.reference(text)
                #expect(other.head == expected.head && other.tail == expected.tail, "\(name): the split parsed whole")
            }
            #expect(ChatContent.streamingBlocks(id: "chunks-nested-\(UUID().uuidString)",
                                                text: "````markdown\n```swift\n" + ChatStreamFenceShared.codeLines(3 * size)).isComposable)
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
            let size = ChatStreamFenceShared.chunk
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
                            let row = ChatStreamMeasureRig.streamingRow(id: id, text: text, flags: flags)
                            let whole = ChatStreamMeasureRig.wholeHeight(row, width: width, context: context, host: rowHost)
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
