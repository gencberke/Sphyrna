import Foundation
import Testing
@testable import LoomCatalogUI

@MainActor
struct ChatMarkdownTests {
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
}
