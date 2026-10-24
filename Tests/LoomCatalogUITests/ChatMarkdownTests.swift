import Foundation
import Testing
@testable import LoomCatalogUI

@MainActor
struct ChatMarkdownTests {
    @Test func blocksOfEveryKind() {
        let text = """
        # Title

        A paragraph with `code` and **bold**.
        It continues here.

        - one
        - two
          - nested

        1. first
        2. second

        > quoted
        > more

        ```swift
        let x = 1
        ```

        | a | b |
        |---|--:|
        | 1 | 2 |

        ---
        """
        let blocks = ChatMarkdown.parse(text)
        #expect(blocks.count == 8)
        #expect(blocks[0] == .heading(level: 1, text: "Title"))
        #expect(blocks[1] == .paragraph("A paragraph with `code` and **bold**.\nIt continues here."))
        guard case let .list(ordered, _, items) = blocks[2] else { Issue.record("no list"); return }
        #expect(!ordered && items.count == 2)
        #expect(items[1].blocks.count == 2)
        guard case let .list(orderedSecond, start, second) = blocks[3] else { Issue.record("no ordered list"); return }
        #expect(orderedSecond && start == 1 && second.count == 2)
        #expect(blocks[4] == .quote([.paragraph("quoted\nmore")]))
        #expect(blocks[5] == .code(language: "swift", code: "let x = 1", isClosed: true))
        guard case let .table(table) = blocks[6] else { Issue.record("no table"); return }
        #expect(table.header == ["a", "b"] && table.alignments == [.leading, .trailing] && table.rows == [["1", "2"]])
        #expect(blocks[7] == .rule)
    }

    @Test func anUnclosedFenceIsAnUnfinishedCodeBlock() {
        let blocks = ChatMarkdown.parse("Intro\n\n```python\nprint(1)\nprint(2)")
        #expect(blocks.last == .code(language: "python", code: "print(1)\nprint(2)", isClosed: false))
    }

    @Test func aFenceHidesMarkdownInsideIt() {
        let blocks = ChatMarkdown.parse("```\n# not a heading\n- not a list\n```")
        #expect(blocks == [.code(language: nil, code: "# not a heading\n- not a list", isClosed: true)])
    }

    @Test func taskListItemsKeepTheirState() {
        let blocks = ChatMarkdown.parse("- [ ] open\n- [x] done")
        guard case let .list(_, _, items) = blocks[0] else { Issue.record("no list"); return }
        #expect(items.map(\.checked) == [false, true])
    }

    @Test func numberedListsKeepTheirStart() {
        guard case let .list(true, start, items) = ChatMarkdown.parse("3. c\n4. d")[0] else { Issue.record("no list"); return }
        #expect(start == 3 && items.count == 2)
    }

    @Test func deepNestingStopsAtTheDepthLimit() {
        let quotes = String(repeating: "> ", count: 200) + "deep"
        var blocks = ChatMarkdown.parse(quotes)
        var depth = 0
        while case let .quote(inner)? = blocks.first { depth += 1; blocks = inner }
        #expect(depth <= ChatMarkdown.maxDepth)
        #expect(!blocks.isEmpty)

        var list = ""
        for level in 0..<200 { list += String(repeating: "  ", count: level) + "- item\n" }
        _ = ChatMarkdown.parse(list)
    }

    @Test func garbageNeverCrashesOrHangs() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["- ", "1. ", "> ", "```", "~~~", "|", "---", "# ", "  ", "\t", "\n", "\n\n", "[ ] ", "[x] ", "**", "`", "a", "é", "\u{0}", "\r\n"]
        for _ in 0..<300 {
            var text = ""
            for _ in 0..<Int.random(in: 0..<80, using: &generator) { text += pieces.randomElement(using: &generator)! }
            _ = ChatMarkdown.parse(text)
        }
        _ = ChatMarkdown.parse(String(repeating: "- a\n  ", count: 2_000))
        _ = ChatMarkdown.parse("")
    }

    @Test func inlineTextKeepsEmphasisCodeAndFollowsOnlyWebLinks() {
        let text = ChatContent.inline("a **b** `c` [d](https://example.com)")
        #expect(String(text.characters) == "a b c d")
        #expect(text.runs.contains { $0.link?.host == "example.com" })
        #expect(ChatContent.isFollowable(URL(string: "https://example.com")!))
        #expect(ChatContent.isFollowable(URL(string: "mailto:a@b.c")!))
        #expect(!ChatContent.isFollowable(URL(string: "file:///etc/passwd")!))
        #expect(!ChatContent.isFollowable(URL(string: "loom://open")!))
    }

    @Test func aStreamingMessageIsSplitAtTheLastCompleteParagraph() {
        let text = "First paragraph.\n\nSecond paragraph\nstill going"
        let split = ChatContent.stableSplit(text)
        #expect(String(text[..<split]) == "First paragraph.\n\n")
        let streaming = ChatContent.blocks(id: "m", text: text, isStreaming: true)
        #expect(streaming == ChatMarkdown.parse(text))
        // A blank line inside a fence is not a paragraph break.
        let fenced = "Intro\n\n```\na\n\nb"
        #expect(String(fenced[..<ChatContent.stableSplit(fenced)]) == "Intro\n\n")
    }

    /// `isRule` stops at the first character that rules a rule out; it answers exactly as the filter-the-whole-line version did.
    @Test func isRuleAnswersAsTheWholeLineFilterDid() {
        func reference(_ line: Substring) -> Bool {
            var columns = 0
            for character in line {
                if character == " " { columns += 1 } else if character == "\t" { columns += 4 } else { break }
            }
            guard columns < 4 else { return false }
            let body = line.filter { $0 != " " && $0 != "\t" }
            guard body.count >= 3, let first = body.first, first == "-" || first == "*" || first == "_" else { return false }
            return body.allSatisfy { $0 == first }
        }
        let rules = ["---", "***", "___", "- - -", " * * * ", "   ___", "-----------", "_ _ _ _", "--- ", "*\t*\t*", " -\t- -"]
        let others = [
            "", " ", "--", "**", "- -", "-- ", "    ---", "\t---", "  \t---", "-*-", "--*", "**_", "__-", "--- x", "x ---", "-a-",
            "- item", "* item", "_emphasis_", "**bold**", "Plain text.", "## Heading", "> quote", "```swift", "1. first",
            "|---|---|", "---|", "-–-", "———", "+++", "===", "~~~", " - - x", "***\u{00A0}", "-\n-\n-", "    ", "\t", "- - - -x",
        ]
        let generated = (0..<4_096).map { seed -> String in
            let alphabet: [Character] = [" ", "\t", "-", "*", "_", "x"]
            var value = seed, line = ""
            for _ in 0..<6 { line.append(alphabet[value % alphabet.count]); value /= alphabet.count }
            return line
        }
        for line in rules { #expect(ChatMarkdown.isRule(Substring(line)) && reference(Substring(line)), "\(line.debugDescription) is a rule") }
        for line in others { #expect(!ChatMarkdown.isRule(Substring(line)) && !reference(Substring(line)), "\(line.debugDescription) is not a rule") }
        let mismatches = generated.filter { ChatMarkdown.isRule(Substring($0)) != reference(Substring($0)) }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).map(\.debugDescription))")
        #expect(generated.contains { ChatMarkdown.isRule(Substring($0)) } && generated.contains { !ChatMarkdown.isRule(Substring($0)) })
    }
}
