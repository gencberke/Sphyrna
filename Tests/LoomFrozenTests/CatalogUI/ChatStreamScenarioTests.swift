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
    /// Streamed into Chat's split cut by cut, each fixture's head is the parse of its settled text and its tail the parse of
    /// the rest; the 300-line fence settles in chunks, the nested one does not.
    @Test func theStreamingSplitOfEachFixtureIsItsWholeParse() async throws {
        for variant in ["plain", "fence300", "nested-fence"] {
            let texts = try await ChatStreamScenarioShared.streamedMessages("0.12 100000 \(variant)")
            var chunked = 0
            for (number, text) in texts.enumerated() {
                chunked += ChatStreamFenceShared.expectWholeParse(text, id: "fixture-\(variant)-\(number)-\(UUID().uuidString)", step: 41)
            }
            #expect(texts.joined().count >= 12_000, "\(variant)")
            #expect((chunked > 0) == (variant == "fence300"), "\(variant): \(chunked) cuts in chunks")
        }
    }
}
