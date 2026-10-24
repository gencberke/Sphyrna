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

    /// A streaming message as the settled head and the open tail. The head is what lies before the last blank line outside a
    /// fence; it is parsed a piece at a time as it grows (`SplitState.extendHead`) and kept. The tail is parsed again by every
    /// call that sees new text. A long code fence open at the end settles in chunks (`OpenFence`); the tail then holds only the
    /// blocks before it.
    struct StreamingBlocks {
        let head: [MarkdownBlock]
        /// Which head this is: equal tokens mean the same head, so a view of it need not compare its blocks.
        let headToken: HeadToken
        /// The content hash of each head block, the key of its cached height (`ChatRowMeasurer`).
        let headHashes: [Int]
        let tail: [MarkdownBlock]
        /// The characters of the tail's source (what a measure of the tail lays out), an open fence's unsettled lines included.
        let tailCharacters: Int
        /// The head can be drawn and measured apart from the tail. False when it holds a code block that is still open (a fence
        /// the splitter does not see, as one in a quote): the message is then drawn and measured as one.
        let isComposable: Bool
        /// The long code fence open at the end, drawn after the tail as one block; nil when there is none.
        let fence: OpenFence?

        var blocks: [MarkdownBlock] {
            let open = fence.map { tail + [$0.block] } ?? tail
            return open.isEmpty ? head : head + open
        }
    }

    /// A code fence open at the end of a streaming message that has grown past `fenceChunkLines` lines. Its complete lines settle
    /// that many at a time, each chunk parsed once and kept; only the lines after the last chunk, the one still arriving
    /// included, are parsed again. Drawn as one code block (`ChatCodeBlockView` with chunks).
    struct OpenFence: Equatable {
        let language: String?
        let chunks: [String]
        /// The content hash of each chunk, the key of its cached height.
        let chunkHashes: [Int]
        /// The code after the last chunk; nil while none of it has come.
        let open: String?
        /// The block's index among the message's top-level blocks (its wrap flag).
        let index: Int

        var code: String {
            let settled = chunks.joined(separator: "\n")
            guard let open else { return settled }
            return settled + "\n" + open
        }

        var block: MarkdownBlock { .code(language: language, code: code, isClosed: false) }
    }

    /// The lines of a chunk of an open fence. A flush lays out and measures the lines after the last chunk, so the size bounds
    /// that work: 40 lines of code are about 1,200 characters, a long paragraph's worth, which is what the open tail of prose
    /// costs. A chunk settles about every 2 s at 600 characters/s and 5 times a second at 6,000, each time one measure of its
    /// lines (kept) and one evaluation of the code block; smaller chunks would settle more often for little less per flush.
    static let fenceChunkLines = 40

    /// The identity of a head: the row, how many blocks, and a hash of its blocks' hashes. Made once when the head grows.
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
            state = SplitState(rowID: id)
            splitStates[id] = state
        }
        state.stamp = splitStamp
        if let result = state.result, state.text == text { return result }
        state.advance(to: text)
        state.extendHead(text: text, in: context)
        let tail: [MarkdownBlock]
        let tailCharacters: Int
        let fenced = openFence(state, text: text, in: context)
        if let fenced {
            tail = fenced.before
            tailCharacters = fenced.characters
        } else {
            let tailText = String(text[text.utf8.index(text.utf8.startIndex, offsetBy: state.headEnd)...])
            tail = tailText.isEmpty ? [] : parse(tailText, in: context)
            tailCharacters = tailText.utf8.count
        }
        let result = StreamingBlocks(head: state.headBlocks, headToken: state.headToken, headHashes: state.headHashes, tail: tail,
                                     tailCharacters: tailCharacters, isComposable: state.headOpenCode == 0, fence: fenced?.fence)
        state.text = text
        state.result = result
        return result
    }

    /// The chunks of the fence open at the end of `text`, when it has some and is a block of the tail's own list (a fence in a
    /// list item is drawn as today), with the blocks before it in the tail. Nil when the tail is parsed as today.
    private static func openFence(_ state: SplitState, text: String, in context: ChatRowContext?)
        -> (before: [MarkdownBlock], fence: OpenFence, characters: Int)? {
        guard let scan = state.fenceScan, let lastEnd = scan.chunkEnds.last else { return nil }
        let utf8 = text.utf8
        func slice(_ from: Int, _ to: Int) -> Substring {
            text[utf8.index(utf8.startIndex, offsetBy: from)..<utf8.index(utf8.startIndex, offsetBy: to)]
        }
        var parts: FenceParts
        if let known = state.fenceParts, known.openerStart == scan.openerStart {
            parts = known
        } else {
            let lead = parse(String(slice(state.headEnd, scan.contentStart)), in: context)
            let opener = String(slice(scan.openerStart, scan.contentStart))
            if case let .code(language, code, false)? = lead.last, code.isEmpty {
                parts = FenceParts(openerStart: scan.openerStart, opener: opener, before: Array(lead.dropLast()), language: language)
            } else {
                parts = FenceParts(openerStart: scan.openerStart, opener: opener, before: [], language: nil, isValid: false)
            }
        }
        while parts.isValid, parts.chunks.count < scan.chunkEnds.count {
            let index = parts.chunks.count
            let from = index == 0 ? scan.contentStart : scan.chunkEnds[index - 1]
            if let code = fenceCode(parts.opener + slice(from, scan.chunkEnds[index]), in: context) {
                parts.chunks.append(code)
                parts.hashes.append(code.hashValue)
            } else {
                parts.isValid = false
            }
        }
        state.fenceParts = parts
        guard parts.isValid else { return nil }
        let rest = slice(lastEnd, utf8.count)
        var open: String?
        if !rest.isEmpty {
            // The closing line still arriving closes the fence for the parser: the tail is then parsed as today.
            guard let code = fenceCode(parts.opener + rest, in: context) else { return nil }
            open = code
        }
        let fence = OpenFence(language: parts.language, chunks: parts.chunks, chunkHashes: parts.hashes, open: open,
                              index: state.headBlocks.count + parts.before.count)
        return (parts.before, fence, scan.contentStart - state.headEnd + rest.utf8.count)
    }

    /// The code of `text` when it is one open fence (its opening line and lines inside it), as the parser reads it.
    private static func fenceCode(_ text: String, in context: ChatRowContext?) -> String? {
        let blocks = parse(text, in: context)
        guard blocks.count == 1, case let .code(_, code, false) = blocks[0] else { return nil }
        return code
    }

    /// What `openFence` made of the fence that is open: its opening line, the tail's blocks before it, and the chunks so far.
    private struct FenceParts {
        let openerStart: Int
        let opener: String
        let before: [MarkdownBlock]
        let language: String?
        var isValid = true
        var chunks: [String] = []
        var hashes: [Int] = []
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
        let rowID: String
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
        private var builtHeadEnd = 0
        /// The head's blocks, their hashes, its token, and how many of its blocks hold an open code block.
        private(set) var headBlocks: [MarkdownBlock] = []
        private(set) var headHashes: [Int] = []
        private(set) var headToken: HeadToken
        private(set) var headOpenCode = 0
        /// Where the piece of the head that made its last blocks starts, and how many blocks it made.
        private var lastPiece = (start: 0, count: 0)
        /// The fence open at the end as the lines read it, when chunks may cover it (a run of three: a longer one holds shorter
        /// fences, and is drawn as today).
        private(set) var fenceScan: FenceScan?
        var fenceParts: FenceParts?

        struct FenceScan {
            /// Where its opening line starts, and where the first line inside it does.
            let openerStart: Int
            let contentStart: Int
            /// Its complete lines so far, and the end of every `fenceChunkLines`-th one.
            var lines = 0
            var chunkEnds: [Int] = []
        }

        init(rowID: String) {
            self.rowID = rowID
            headToken = HeadToken(rowID: rowID, count: 0, hash: 0)
        }

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
                let wasOpen = fence.isOpen
                fence.read(line)
                let blank = line.allSatisfy { $0 == " " }
                cursor = utf8.index(after: lineFeed)
                let next = utf8.distance(from: utf8.startIndex, to: cursor)
                if !wasOpen, let opened = fence.current {
                    fenceScan = opened.length == 3 ? FenceScan(openerStart: lineStart, contentStart: next) : nil
                } else if wasOpen, !fence.isOpen {
                    fenceScan = nil
                    fenceParts = nil
                } else if wasOpen, var scan = fenceScan {
                    scan.lines += 1
                    if scan.lines % ChatContent.fenceChunkLines == 0 { scan.chunkEnds.append(next) }
                    fenceScan = scan
                }
                if blank, !previousBlank, !fence.isOpen { headEnd = next }
                previousBlank = blank
                lineStart = next
            }
            searchedTo = utf8.count
        }

        /// Brings the head blocks up to `headEnd`: the text settled since they were made is parsed alone and its blocks appended.
        /// That is the parse of the whole head, because a blank line outside a fence ends every block but a list, which a blank
        /// line and an item or an indented line go on with: the piece after a list is parsed together with the list's piece.
        func extendHead(text: String, in context: ChatRowContext?) {
            guard headEnd != builtHeadEnd else { return }
            var start = builtHeadEnd
            if lastPiece.count > 0, case .list = headBlocks.last {
                start = lastPiece.start
                for block in headBlocks.suffix(lastPiece.count) where ChatContent.hasOpenCode(block) { headOpenCode -= 1 }
                headBlocks.removeLast(lastPiece.count)
                headHashes.removeLast(lastPiece.count)
                lastPiece.count = 0
            }
            let utf8 = text.utf8
            let piece = String(text[utf8.index(utf8.startIndex, offsetBy: start)..<utf8.index(utf8.startIndex, offsetBy: headEnd)])
            let blocks = piece.isEmpty ? [] : ChatContent.parse(piece, in: context)
            if !blocks.isEmpty { lastPiece = (start, blocks.count) }
            headBlocks += blocks
            headHashes += blocks.map(\.hashValue)
            headOpenCode += blocks.filter(ChatContent.hasOpenCode).count
            builtHeadEnd = headEnd
            var hasher = Hasher()
            hasher.combine(headHashes)
            headToken = HeadToken(rowID: rowID, count: headBlocks.count, hash: hasher.finalize())
        }

        private func restart() {
            text = ""
            result = nil
            lineStart = 0
            searchedTo = 0
            fence = SplitFence()
            previousBlank = false
            headEnd = 0
            builtHeadEnd = 0
            headBlocks = []
            headHashes = []
            headToken = HeadToken(rowID: rowID, count: 0, hash: 0)
            headOpenCode = 0
            lastPiece = (0, 0)
            fenceScan = nil
            fenceParts = nil
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
    /// A fence in a list item ends with the item, as the parser ends it: at a non-blank line left of the item's content
    /// column that follows a blank line or starts a block (a fence line included). That line is read again outside the
    /// fence, so a fence marker at column 0 opens a top-level fence instead of closing the item's.
    struct SplitFence {
        private var open: ChatMarkdown.Fence?
        /// The content column of the list item the open fence sits in (0 outside a list).
        private var container = 0
        /// The content column of the list item the last lines belong to (0 outside a list).
        private var listContent = 0
        /// Blank lines directly before the line being read.
        private var blanks = 0

        var isOpen: Bool { open != nil }
        var current: ChatMarkdown.Fence? { open }

        mutating func read(_ line: Substring) {
            let body = line.drop(while: { $0 == " " })
            let indent = line.utf8.count - body.utf8.count
            if body.isEmpty {
                blanks += 1
                return
            }
            defer { blanks = 0 }
            if let fence = open {
                if indent >= container || (blanks == 0 && !ChatMarkdown.startsBlock(line)) {
                    let base = min(indent, max(0, fence.indent - 3))
                    if ChatMarkdown.isClosingFence(line.dropFirst(base), fence: fence) { open = nil }
                    return
                }
                open = nil
                listContent = 0
            }
            if indent < listContent, blanks > 0 || ChatMarkdown.startsBlock(line) { listContent = 0 }
            if var fence = ChatMarkdown.openingFence(body) {
                fence.indent = indent
                open = fence
                container = indent >= listContent ? listContent : 0
            } else if let marker = ChatMarkdown.listMarker(line) {
                listContent = marker.contentOffset
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
