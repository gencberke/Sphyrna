import Foundation
import Testing
@testable import LoomCatalogUI

@MainActor
struct ChatHighlighterTests {
    @Test func swiftTokensAreClassified() {
        let pieces = ChatHighlighter.tokens("let name = \"Loom\" // note\nfoo(1)", language: "swift")
        func token(_ text: String) -> ChatHighlighter.Token? { pieces.first { $0.text == text }?.token }
        #expect(token("let") == .keyword)
        #expect(token("\"Loom\"") == .string)
        #expect(token("// note") == .comment)
        #expect(token("1") == .number)
        #expect(token("foo") == .function)
        #expect(pieces.map(\.text).joined() == "let name = \"Loom\" // note\nfoo(1)")
    }

    @Test func diffLinesAreAddedOrRemoved() {
        let pieces = ChatHighlighter.tokens("+new\n-old\n same", language: "diff")
        #expect(pieces.contains { $0.token == .added && $0.text.contains("new") })
        #expect(pieces.contains { $0.token == .removed && $0.text.contains("old") })
        #expect(pieces.map(\.text).joined() == "+new\n-old\n same")
    }

    @Test func languagesAreRecognisedByAlias() {
        #expect(ChatHighlighter.canonical("swift") != nil)
        #expect(ChatHighlighter.canonical("JS") == ChatHighlighter.canonical("javascript"))
        #expect(ChatHighlighter.canonical("sh") == ChatHighlighter.canonical("bash"))
        #expect(ChatHighlighter.canonical("klingon") == nil)
        #expect(ChatHighlighter.canonical(nil) == nil)
    }

    @Test func aStreamingBlockIsNeverHighlighted() {
        #expect(ChatHighlighter.highlighted("let x = 1", language: "swift", isStreaming: true) == nil)
        #expect(ChatHighlighter.highlighted("let x = 1", language: "swift") != nil)
    }

    @Test func anUnknownLanguageIsNotHighlighted() {
        #expect(ChatHighlighter.highlighted("whatever", language: "klingon") == nil)
        #expect(ChatHighlighter.highlighted("whatever", language: nil) == nil)
    }

    @Test func codeOverTheLimitIsNotHighlighted() {
        let big = String(repeating: "let x = 1\n", count: 3_000)
        #expect(big.count > ChatHighlighter.maximumCharacters)
        #expect(ChatHighlighter.highlighted(big, language: "swift") == nil)
        let ok = String(repeating: "x", count: ChatHighlighter.maximumCharacters)
        #expect(ChatHighlighter.highlighted(ok, language: "swift") != nil)
    }

    @Test func unterminatedStringsAndCommentsDoNotHang() {
        for language in ["swift", "python", "js", "json", "bash", "go", "rust", "c", "sql", "yaml"] {
            _ = ChatHighlighter.tokens("\"never closed\n/* never closed\n'x", language: ChatHighlighter.canonical(language) ?? language)
        }
    }
}
