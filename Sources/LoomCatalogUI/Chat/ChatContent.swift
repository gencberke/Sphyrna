import Foundation
import SwiftUI

/// Inline markdown to attributed text, and the caches around parsing: a block list per finished message (keyed by the
/// row id and the text, so a streaming block is parsed again, a settled one never), and the inline text of each block.
@MainActor
enum ChatContent {
    // MARK: Inline

    /// Inline markdown (emphasis, code, links) as attributed text. Links open only when they are web or mail links.
    static func inline(_ source: String, in context: ChatRowContext? = nil) -> AttributedString {
        let key = source as NSString
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        ChatRenderProbe.inlineParsed(in: context)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var result = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        var codeRanges: [Range<AttributedString.Index>] = []
        var linkRanges: [Range<AttributedString.Index>] = []
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true { codeRanges.append(run.range) }
            if run.link != nil { linkRanges.append(run.range) }
        }
        for range in codeRanges {
            result[range].font = LoomTheme.Chat.readingMono
            result[range].backgroundColor = LoomTheme.Chat.inlineCodeFill
            result[range].foregroundColor = LoomTheme.Chat.inlineCode
        }
        for range in linkRanges {
            result[range].foregroundColor = LoomTheme.Accent.high
        }
        inlineCache.setObject(Box(result), forKey: key, cost: source.utf8.count * 8)
        return result
    }

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let inlineCache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 4_000
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// Only web and mail links are followed (a transcript is not a trusted source of `file:` or app URLs).
    static func isFollowable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }

    // MARK: Blocks

    private final class Blocks {
        let value: [MarkdownBlock]
        init(_ value: [MarkdownBlock]) { self.value = value }
    }

    private static let blockCache: NSCache<NSString, Blocks> = {
        let cache = NSCache<NSString, Blocks>()
        cache.countLimit = 600
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    /// The parsed blocks of a message. While it streams, everything up to the last blank line outside a fence is parsed
    /// once and kept, and only the tail is parsed again.
    static func blocks(id: String, text: String, isStreaming: Bool, in context: ChatRowContext? = nil) -> [MarkdownBlock] {
        if !isStreaming {
            let key = "\(id)#\(text.hashValue)#\(text.utf8.count)" as NSString
            if let cached = blockCache.object(forKey: key) { return cached.value }
            let parsed = parse(text, in: context)
            blockCache.setObject(Blocks(parsed), forKey: key, cost: text.utf8.count * 4)
            return parsed
        }
        return streamingBlocks(id: id, text: text, in: context).blocks
    }

    // MARK: Streaming

    /// A streaming message as the settled head and the open tail: the head is what lies before the last blank line outside a
    /// fence, parsed once and kept; the tail is parsed again by every call that sees new text.
    struct StreamingBlocks {
        let head: [MarkdownBlock]
        /// Which head this is: equal tokens mean the same head, so a view of it need not compare its blocks.
        let headToken: HeadToken
        /// The content hash of each head block, the key of its cached height (`ChatRowMeasurer`).
        let headHashes: [Int]
        let tail: [MarkdownBlock]
        /// The characters of the tail's source (what a measure of the tail lays out).
        let tailCharacters: Int
        /// The head can be drawn and measured apart from the tail. False when it holds a code block that is still open (a fence
        /// the splitter does not see, as one in a quote): the message is then drawn and measured as one.
        let isComposable: Bool

        var blocks: [MarkdownBlock] { tail.isEmpty ? head : head + tail }
    }

    /// The identity of a head: the row, how many blocks, and the hash of its text. Made once when the head grows.
    struct HeadToken: Hashable {
        let rowID: String
        let count: Int
        let hash: Int
    }

    /// The head and the tail of a streaming message. The split is kept per message and moves on by the characters that came
    /// since the last call (`SplitState`); a call with the text it already saw returns what it made.
    static func streamingBlocks(id: String, text: String, in context: ChatRowContext? = nil) -> StreamingBlocks {
        splitStamp += 1
        let state: SplitState
        if let known = splitStates[id] {
            state = known
        } else {
            if splitStates.count >= splitLimit, let oldest = splitStates.min(by: { $0.value.stamp < $1.value.stamp })?.key {
                splitStates[oldest] = nil
            }
            state = SplitState()
            splitStates[id] = state
        }
        state.stamp = splitStamp
        if let result = state.result, state.text == text { return result }
        state.advance(to: text)

        if state.headEnd != state.builtHeadEnd || state.head == nil {
            let headText = String(text[..<text.utf8.index(text.utf8.startIndex, offsetBy: state.headEnd)])
            let hash = headText.hashValue
            let key = "\(id)#head#\(hash)#\(headText.utf8.count)" as NSString
            // Only the newest head is kept: an older one of the same message is never asked for again.
            if let old = state.headKey, old != key { blockCache.removeObject(forKey: old) }
            state.headKey = key
            var blocks: [MarkdownBlock] = []
            if !headText.isEmpty {
                if let cached = blockCache.object(forKey: key) {
                    blocks = cached.value
                } else {
                    blocks = parse(headText, in: context)
                    blockCache.setObject(Blocks(blocks), forKey: key, cost: headText.utf8.count * 4)
                }
            }
            state.builtHeadEnd = state.headEnd
            state.head = HeadParts(blocks: blocks, hashes: blocks.map { $0.hashValue },
                                   token: HeadToken(rowID: id, count: blocks.count, hash: hash),
                                   isComposable: !blocks.contains(where: hasOpenCode))
        }
        let tailText = String(text[text.utf8.index(text.utf8.startIndex, offsetBy: state.headEnd)...])
        let head = state.head!
        let result = StreamingBlocks(head: head.blocks, headToken: head.token, headHashes: head.hashes,
                                     tail: tailText.isEmpty ? [] : parse(tailText, in: context),
                                     tailCharacters: tailText.utf8.count, isComposable: head.isComposable)
        state.text = text
        state.result = result
        return result
    }

    private struct HeadParts {
        let blocks: [MarkdownBlock]
        let hashes: [Int]
        let token: HeadToken
        let isComposable: Bool
    }

    private static func hasOpenCode(_ block: MarkdownBlock) -> Bool {
        switch block {
        case let .code(_, _, isClosed): !isClosed
        case let .list(_, _, items): items.contains { $0.blocks.contains(where: hasOpenCode) }
        case let .quote(inner): inner.contains(where: hasOpenCode)
        default: false
        }
    }

    /// The scan of one streaming message: where `stableSplit` stands after the lines that are complete (they never change while
    /// text is appended). A call that sees more text continues from the offset the last one stopped at, so what it costs is
    /// the new characters, plus one comparison of the old text with the new that proves nothing before was edited. Any text that
    /// does not start with the old one is scanned from the start. The offsets are UTF-8.
    @MainActor
    private final class SplitState {
        var stamp = 0
        /// The text the state and its `result` are for.
        var text = ""
        var result: StreamingBlocks?
        /// The start of the first line that is not complete, and how far a line break was looked for.
        private var lineStart = 0
        private var searchedTo = 0
        private var fence = SplitFence()
        private var previousBlank = false
        /// The end of the head (the offset of `stableSplit`), and the one the head blocks were made for.
        private(set) var headEnd = 0
        var builtHeadEnd = -1
        var head: HeadParts?
        /// The `blockCache` key of the newest head; kept over a restart, so the next head still replaces it.
        var headKey: NSString?

        func advance(to new: String) {
            if !Self.startsWith(new, prefix: text) { restart() }
            let utf8 = new.utf8
            var cursor = utf8.index(utf8.startIndex, offsetBy: searchedTo)
            while let lineFeed = utf8[cursor...].firstIndex(of: 10) {
                // A carriage return and a line feed are one Character: `stableSplit` does not end a line there.
                if lineFeed > utf8.startIndex, utf8[utf8.index(before: lineFeed)] == 13 {
                    cursor = utf8.index(after: lineFeed)
                    continue
                }
                let first = utf8.index(utf8.startIndex, offsetBy: lineStart)
                let line = new[first..<lineFeed]
                fence.read(line)
                let blank = line.allSatisfy { $0 == " " }
                cursor = utf8.index(after: lineFeed)
                if blank, !previousBlank, !fence.isOpen { headEnd = utf8.distance(from: utf8.startIndex, to: cursor) }
                previousBlank = blank
                lineStart = utf8.distance(from: utf8.startIndex, to: cursor)
            }
            searchedTo = utf8.count
        }

        private func restart() {
            text = ""
            result = nil
            lineStart = 0
            searchedTo = 0
            fence = SplitFence()
            previousBlank = false
            headEnd = 0
            builtHeadEnd = -1
            head = nil
        }

        private static func startsWith(_ string: String, prefix: String) -> Bool {
            var string = string, prefix = prefix
            return prefix.withUTF8 { old in
                string.withUTF8 { new in
                    old.count <= new.count && (old.count == 0 || memcmp(old.baseAddress!, new.baseAddress!, old.count) == 0)
                }
            }
        }
    }

    private static var splitStates: [String: SplitState] = [:]
    private static var splitStamp = 0
    /// Messages that stream at once are few; the least recently used state goes first.
    private static let splitLimit = 24

    private static func parse(_ text: String, in context: ChatRowContext?) -> [MarkdownBlock] {
        ChatRenderProbe.markdownParsed(characters: text.utf8.count, in: context)
        return ChatMarkdown.parse(text)
    }

    /// The code fence a split is inside, read line by line with the parser's own rules (`ChatMarkdown.openingFence` and
    /// `isClosingFence`): a fence closes only on its own character, in a run at least as long, with nothing after it.
    /// Unlike the parser, it opens at any indent, as a fence in a list item does; it closes within three columns of the
    /// fence's own indent (the parser's rule when the fence sits at the item's content column or at the top level).
    struct SplitFence {
        private var open: ChatMarkdown.Fence?

        var isOpen: Bool { open != nil }

        mutating func read(_ line: Substring) {
            let body = line.drop(while: { $0 == " " })
            let indent = line.utf8.count - body.utf8.count
            if let fence = open {
                let base = min(indent, max(0, fence.indent - 3))
                if ChatMarkdown.isClosingFence(line.dropFirst(base), fence: fence) { open = nil }
            } else if var fence = ChatMarkdown.openingFence(body) {
                fence.indent = indent
                open = fence
            }
        }
    }

    /// The index after the last paragraph break that is outside a code fence: everything before it is complete.
    static func stableSplit(_ text: String) -> String.Index {
        var fence = SplitFence()
        var lastBreak = text.startIndex
        var lineStart = text.startIndex
        var previousBlank = false
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            fence.read(line)
            let blank = line.allSatisfy { $0 == " " }
            if blank, !previousBlank, !fence.isOpen, lineEnd < text.endIndex { lastBreak = text.index(after: lineEnd) }
            previousBlank = blank
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return lastBreak
    }
}

// MARK: Size of a block

extension ChatContent {
    /// The characters of a block's source, nested blocks included (what the render probe says a measure laid out).
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
}

// MARK: Hashing

/// The blocks are hashed by their content: a settled block's height is cached under it (`ChatRowMeasurer`) and the render
/// probe counts a block's evaluations under it. The equality is the one the types already have.
extension MarkdownBlock: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case let .paragraph(source):
            hasher.combine(0)
            hasher.combine(source)
        case let .heading(level, text):
            hasher.combine(1)
            hasher.combine(level)
            hasher.combine(text)
        case let .code(language, code, isClosed):
            hasher.combine(2)
            hasher.combine(language)
            hasher.combine(code)
            hasher.combine(isClosed)
        case let .list(ordered, start, items):
            hasher.combine(3)
            hasher.combine(ordered)
            hasher.combine(start)
            hasher.combine(items)
        case let .quote(inner):
            hasher.combine(4)
            hasher.combine(inner)
        case let .table(table):
            hasher.combine(5)
            hasher.combine(table)
        case .rule:
            hasher.combine(6)
        }
    }
}

extension MarkdownListItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(blocks)
        hasher.combine(checked)
    }
}

extension MarkdownTable: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(header)
        for alignment in alignments {
            switch alignment {
            case .leading: hasher.combine(0)
            case .center: hasher.combine(1)
            case .trailing: hasher.combine(2)
            }
        }
        hasher.combine(rows)
    }
}
