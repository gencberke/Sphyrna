import Foundation

/// The block kinds Claude's prose needs (CHAT-SPEC → Content): paragraphs, headings, lists, quotes, fenced code, tables
/// and rules. Inline text stays as source and is turned into attributed text by `ChatInline` (Apple's
/// `AttributedString(markdown:)`). No dependency: a small line-based parser, enough for what the model writes, and
/// tolerant of text that is still streaming (an unclosed fence is a code block that is not finished).
indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, code: String, isClosed: Bool)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    case rule
}

struct MarkdownListItem: Equatable, Sendable {
    var blocks: [MarkdownBlock]
    /// A task list item: nil for a plain one.
    var checked: Bool?
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }
    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

enum ChatMarkdown {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var lines: [Substring] = []
        text.enumerateLines { line, _ in lines.append(Substring(line)) }
        return parse(lines: lines[...], depth: 0)
    }

    /// Quotes and lists nest at most this deep; what lies deeper is kept as one paragraph, so no input can recurse far.
    static let maxDepth = 8

    // MARK: Blocks

    private static func parse(lines: ArraySlice<Substring>, depth: Int) -> [MarkdownBlock] {
        if depth >= maxDepth {
            let flat = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.isEmpty ? [] : [.paragraph(flat)]
        }
        var blocks: [MarkdownBlock] = []
        var i = lines.startIndex
        let end = lines.endIndex
        while i < end {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }

            if let fence = openingFence(line) {
                var code: [Substring] = []
                var j = i + 1
                var closed = false
                while j < end {
                    if isClosingFence(lines[j], fence: fence) { closed = true; j += 1; break }
                    code.append(stripIndent(lines[j], upTo: fence.indent))
                    j += 1
                }
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n"), isClosed: closed))
                i = j
                continue
            }
            if let heading = headingParts(line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }
            if isRule(line) {
                blocks.append(.rule)
                i += 1
                continue
            }
            if isQuote(line) {
                var inner: [Substring] = []
                var j = i
                while j < end {
                    let current = lines[j]
                    if isQuote(current) {
                        inner.append(stripQuoteMark(current))
                    } else if !isBlank(current), !startsBlock(current) {
                        inner.append(current) // a lazy continuation of the quoted paragraph
                    } else {
                        break
                    }
                    j += 1
                }
                blocks.append(.quote(parse(lines: inner[...], depth: depth + 1)))
                i = j
                continue
            }
            if listMarker(line) != nil {
                let (block, next) = parseList(lines: lines, from: i, depth: depth)
                blocks.append(block)
                i = next
                continue
            }
            if i + 1 < end, line.contains("|"), let alignments = tableSeparator(lines[i + 1]) {
                let header = tableCells(line)
                var rows: [[String]] = []
                var j = i + 2
                while j < end, !isBlank(lines[j]), lines[j].contains("|") {
                    rows.append(tableCells(lines[j]))
                    j += 1
                }
                blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
                i = j
                continue
            }
            // A paragraph: lines up to a blank line or the start of another block.
            var paragraph: [Substring] = [line.trimmingTrailingSpaces]
            var j = i + 1
            while j < end, !isBlank(lines[j]), !startsBlock(lines[j]) {
                if j + 1 < end, lines[j].contains("|"), tableSeparator(lines[j + 1]) != nil { break }
                paragraph.append(lines[j].trimmingTrailingSpaces)
                j += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            i = j
        }
        return blocks
    }

    // MARK: Lists

    private struct Marker {
        var indent: Int
        var ordered: Bool
        var number: Int
        /// The column where the item's content starts: continuation lines are indented at least this far.
        var contentOffset: Int
        /// Where the content starts in the marker's own line.
        var contentStart: Substring.Index
    }

    private static func listMarker(_ line: Substring) -> Marker? {
        var indent = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indent += line[index] == "\t" ? 4 : 1
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let character = line[index]
        var width = 0
        var ordered = false
        var number = 0
        var scan = index
        if character == "-" || character == "*" || character == "+" {
            if isRule(line) { return nil }
            width = 1
            scan = line.index(after: index)
        } else {
            var digits = ""
            while scan < line.endIndex, line[scan].isASCII, line[scan].isNumber, digits.count < 9 {
                digits.append(line[scan])
                scan = line.index(after: scan)
            }
            guard !digits.isEmpty, scan < line.endIndex, line[scan] == "." || line[scan] == ")" else { return nil }
            scan = line.index(after: scan)
            width = digits.count + 1
            ordered = true
            number = Int(digits) ?? 1
        }
        // One to four spaces after the marker belong to it; more than four, and the content starts after the first.
        guard scan < line.endIndex, line[scan] == " " || line[scan] == "\t" else { return nil }
        var spaces = 0
        var after = scan
        while after < line.endIndex, line[after] == " " || line[after] == "\t" {
            spaces += line[after] == "\t" ? 4 : 1
            after = line.index(after: after)
        }
        if spaces > 4 {
            return Marker(indent: indent, ordered: ordered, number: number, contentOffset: indent + width + 1,
                          contentStart: line.index(after: scan))
        }
        if after == line.endIndex { spaces = 1 }
        return Marker(indent: indent, ordered: ordered, number: number, contentOffset: indent + width + spaces, contentStart: after)
    }

    private static func parseList(lines: ArraySlice<Substring>, from start: Int, depth: Int) -> (MarkdownBlock, Int) {
        guard let first = listMarker(lines[start]) else { return (.paragraph(String(lines[start])), start + 1) }
        var items: [MarkdownListItem] = []
        var i = start
        let end = lines.endIndex
        while i < end {
            // A sibling: the same kind of marker, not indented into the previous item's content.
            guard let marker = listMarker(lines[i]), marker.ordered == first.ordered, marker.indent < first.contentOffset else { break }
            var content: [Substring] = [lines[i][marker.contentStart...]]
            var j = i + 1
            var blanks = 0
            while j < end {
                let line = lines[j]
                if isBlank(line) {
                    blanks += 1
                    j += 1
                    continue
                }
                if leadingColumns(line) >= marker.contentOffset {
                    content.append(contentsOf: Array(repeating: Substring(""), count: blanks))
                    content.append(dropColumns(line, marker.contentOffset))
                } else if blanks == 0, !startsBlock(line) {
                    content.append(line) // a lazy continuation of the item's last paragraph
                } else {
                    break
                }
                blanks = 0
                j += 1
            }
            var checked: Bool?
            let head = content[0]
            if head.hasPrefix("[ ] ") {
                checked = false
                content[0] = head.dropFirst(4)
            } else if head.hasPrefix("[x] ") || head.hasPrefix("[X] ") {
                checked = true
                content[0] = head.dropFirst(4)
            }
            items.append(MarkdownListItem(blocks: parse(lines: content[...], depth: depth + 1), checked: checked))
            i = j
        }
        return (.list(ordered: first.ordered, start: first.number, items: items), max(i, start + 1))
    }

    // MARK: Line tests

    private static func isBlank(_ line: Substring) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func leadingColumns(_ line: Substring) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 } else if character == "\t" { columns += 4 } else { break }
        }
        return columns
    }

    private static func dropColumns(_ line: Substring, _ count: Int) -> Substring {
        var columns = 0
        var index = line.startIndex
        while index < line.endIndex, columns < count {
            if line[index] == " " { columns += 1 } else if line[index] == "\t" { columns += 4 } else { break }
            index = line.index(after: index)
        }
        return line[index...]
    }

    private static func stripIndent(_ line: Substring, upTo count: Int) -> Substring {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < count, line[index] == " " {
            removed += 1
            index = line.index(after: index)
        }
        return line[index...]
    }

    /// A code fence as the parser reads it; the streaming split reads fences by the same rules (`ChatContent.SplitFence`).
    struct Fence {
        var character: Character
        var length: Int
        var indent: Int
        var language: String?
    }

    static func openingFence(_ line: Substring) -> Fence? {
        let indent = leadingColumns(line)
        guard indent < 4 else { return nil }
        let body = line.drop(while: { $0 == " " })
        guard let character = body.first, character == "`" || character == "~" else { return nil }
        let length = body.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        let info = body.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if character == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(character: character, length: length, indent: indent, language: language?.isEmpty == true ? nil : language)
    }

    static func isClosingFence(_ line: Substring, fence: Fence) -> Bool {
        guard leadingColumns(line) < 4 else { return false }
        let body = line.drop(while: { $0 == " " })
        let run = body.prefix(while: { $0 == fence.character }).count
        return run >= fence.length && body.dropFirst(run).allSatisfy { $0 == " " }
    }

    private static func headingParts(_ line: Substring) -> (level: Int, text: String)? {
        guard leadingColumns(line) < 4 else { return nil }
        let body = line.drop(while: { $0 == " " })
        let level = body.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = body.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of hashes: "## Title ##".
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func isRule(_ line: Substring) -> Bool {
        guard leadingColumns(line) < 4 else { return false }
        let body = line.filter { $0 != " " && $0 != "\t" }
        guard body.count >= 3, let first = body.first, first == "-" || first == "*" || first == "_" else { return false }
        return body.allSatisfy { $0 == first }
    }

    private static func isQuote(_ line: Substring) -> Bool {
        leadingColumns(line) < 4 && line.drop(while: { $0 == " " }).first == ">"
    }

    private static func stripQuoteMark(_ line: Substring) -> Substring {
        var body = line.drop(while: { $0 == " " })
        body = body.dropFirst()
        if body.first == " " { body = body.dropFirst() }
        return body
    }

    private static func startsBlock(_ line: Substring) -> Bool {
        openingFence(line) != nil || headingParts(line) != nil || isRule(line) || isQuote(line) || listMarker(line) != nil
    }

    // MARK: Tables

    private static func tableCells(_ line: Substring) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func tableSeparator(_ line: Substring) -> [MarkdownTable.Alignment]? {
        guard line.contains("-") else { return nil }
        let cells = tableCells(line)
        var alignments: [MarkdownTable.Alignment] = []
        for cell in cells {
            guard !cell.isEmpty else { return nil }
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":")
            let dashes = cell.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(leading && trailing ? .center : trailing ? .trailing : .leading)
        }
        return alignments.isEmpty ? nil : alignments
    }
}

private extension Substring {
    var trimmingTrailingSpaces: Substring {
        var end = endIndex
        while end > startIndex, self[index(before: end)] == " " || self[index(before: end)] == "\t" { end = index(before: end) }
        return self[startIndex..<end]
    }
}
