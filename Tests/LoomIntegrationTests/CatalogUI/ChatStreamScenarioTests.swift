import Foundation
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

private typealias ScenarioTimeout = ChatStreamScenarioShared.ScenarioTimeout
private typealias LineCollector = ChatStreamScenarioShared.LineCollector

private extension MarkdownBlock {
    var codeBlock: (language: String?, code: String, isClosed: Bool)? {
        if case let .code(language, code, isClosed) = self { return (language, code, isClosed) }
        return nil
    }

    var paragraphText: String? {
        if case let .paragraph(text) = self { return text }
        return nil
    }
}

/// The long-block variants of the stream scenario (`fence300`, `nested-fence`) that the Chat cost cells name: their text, as
/// the product's parser reads it, and the fence the fixture closes when the time ends inside one.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct ChatStreamScenarioTests {
    @Test func theLongFenceIsOneCodeBlockOf300Lines() async throws {
        let texts = try await ChatStreamScenarioShared.streamedMessages("0.5 100000 fence300")
        let blocks = texts.flatMap(ChatMarkdown.parse)
        let codes = blocks.compactMap(\.codeBlock)
        let long = codes.filter { $0.code.split(separator: "\n", omittingEmptySubsequences: false).count > 20 }
        // Every long fence but the one the time cut is whole: 300 lines in one closed block; the short ones are the plain
        // stream's (at most 12 lines).
        #expect(long.count >= 3)
        for fence in long.dropLast() {
            #expect(fence.code.split(separator: "\n", omittingEmptySubsequences: false).count == 300 && fence.isClosed)
        }
        #expect(codes.allSatisfy { $0.isClosed })
        #expect(blocks.contains { $0.paragraphText != nil })
    }

    @Test func theNestedFenceIsOneOuterBlock() async throws {
        let texts = try await ChatStreamScenarioShared.streamedMessages("0.3 100000 nested-fence")
        let whole = texts.joined()
        let blocks = texts.flatMap(ChatMarkdown.parse)
        let outer = blocks.compactMap(\.codeBlock).filter { $0.code.contains("```") }
        let opened = whole.components(separatedBy: "````markdown\n").count - 1
        #expect(opened >= 3 && outer.count == opened)
        for block in outer {
            #expect(block.language == "markdown" && block.isClosed)
            #expect(block.code.contains("\n\n```") && block.code.contains("```\n\n"))
        }
        // No inner fence or blank line breaks the outer one open: no backticks reach a paragraph.
        #expect(!blocks.contains { $0.paragraphText?.contains("```") == true })
    }

    @Test func everyFenceIsClosedWhereverTheTimeEnds() async throws {
        var endings: [String] = []
        for (variant, totals) in [("nested-fence", Array(stride(from: 400, through: 3_000, by: 200))), ("fence300", [1_000, 5_000])] {
            for total in totals {
                let texts = try await ChatStreamScenarioShared.streamedMessages("0.1 \(total * 10) \(variant)")
                for text in texts {
                    #expect(ChatMarkdown.parse(text).compactMap(\.codeBlock).allSatisfy { $0.isClosed }, "\(variant) at \(total)")
                }
                endings.append(texts.last ?? "")
            }
        }
        // The cuts land inside the four-backtick fence and inside the long three-backtick one.
        #expect(endings.contains { $0.hasSuffix("\n````") })
        #expect(endings.contains { $0.hasSuffix("\n```") })
    }
}
