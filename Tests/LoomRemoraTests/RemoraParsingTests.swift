import Foundation
import Testing
@testable import LoomChat
@testable import LoomRemora

/// The pure parts: the fence stripper, the block's validation and the stream reader (no process).
struct RemoraParsingTests {
    // MARK: AnswerSplitter

    private func split(_ pieces: [String]) -> (shown: [String], block: String?) {
        var splitter = AnswerSplitter()
        var shown = pieces.map { splitter.feed($0) }
        shown.append(splitter.finish())
        return (shown, splitter.block)
    }

    @Test func aFenceArrivingInPiecesNeverShows() {
        let text = "The answer.\n\n```remora\n{\"cited\":[]}\n```"
        for size in [1, 2, 3, 5, 7, 100] {
            var pieces: [String] = []
            var rest = Substring(text)
            while !rest.isEmpty { pieces.append(String(rest.prefix(size))); rest = rest.dropFirst(size) }
            let result = split(pieces)
            #expect(result.shown.joined() == "The answer.", "size \(size): \(result.shown)")
            #expect(result.block == "```remora\n{\"cited\":[]}\n```", "size \(size)")
        }
    }

    @Test func textThatOnlyLooksLikeTheStartOfAFenceIsReleased() {
        var splitter = AnswerSplitter()
        var shown = splitter.feed("Intro\n``")
        #expect(shown == "Intro", "the line break and the pair of backticks are held until they are settled")
        shown += splitter.feed("`js\nlet a\n```\n")
        shown += splitter.finish()
        #expect(shown == "Intro\n```js\nlet a\n```")
        #expect(splitter.block == nil)
    }

    @Test func aFenceInTheMiddleOfALineOrOfAnotherLanguageIsText() {
        let text = "Run it as ```remora``` inline.\n\n```json\n{\"a\":1}\n```\nDone."
        let result = split([text])
        #expect(result.shown.joined() == text)
        #expect(result.block == nil)
    }

    @Test func trailingWhitespaceIsNeverShown() {
        let result = split(["Done.", "\n", "\n"])
        #expect(result.shown.joined() == "Done.")
        let withBlock = split(["Done.\n\n", "```remora\n{}\n```\n"])
        #expect(withBlock.shown.joined() == "Done.")
    }

    @Test func aBlockThatStartsTheTextIsStillTheBlock() {
        let result = split(["```remora\n{}\n```"])
        #expect(result.shown.joined().isEmpty)
        #expect(result.block != nil)
    }

    // MARK: RemoraBlock

    private func parse(_ json: String, known: Set<String> = ["a", "b"]) -> RemoraBlock? {
        RemoraBlock.parse("```remora\n\(json)\n```", knownSessionIDs: known)
    }

    @Test func unknownIdsRepeatsAndEmptiesAreDropped() throws {
        let block = try #require(parse("""
        {"cited":["a","a","zz","b"],"chips":[{"session":"a","why":" Needs\\nyou "},{"session":"a","why":"again"},{"session":"q","why":"x"}],\
        "drafts":[{"session":"b","text":"  "},{"session":"b","text":"Go on\\nwith it"}],"facts":["x","x",""]}
        """))
        #expect(block.cited == ["a", "b"])
        #expect(block.chips == [RemoraChip(sessionID: "a", why: "Needs you")])
        #expect(block.drafts == [RemoraDraft(sessionID: "b", text: "Go on with it")])
        #expect(block.facts == ["x"])
    }

    @Test func sizesAreBounded() throws {
        let many = (0..<30).map { "\"s\($0)\"" }.joined(separator: ",")
        let ids = Set((0..<30).map { "s\($0)" })
        let chips = (0..<8).map { "{\"session\":\"s\($0)\",\"why\":\"\(String(repeating: "w", count: 300))\"}" }.joined(separator: ",")
        let drafts = (0..<8).map { "{\"session\":\"s\($0)\",\"text\":\"\(String(repeating: "t", count: 700))\"}" }.joined(separator: ",")
        let facts = (0..<8).map { "\"\($0)\(String(repeating: "f", count: 300))\"" }.joined(separator: ",")
        let block = try #require(parse("{\"cited\":[\(many)],\"chips\":[\(chips)],\"drafts\":[\(drafts)],\"facts\":[\(facts)]}", known: ids))
        #expect(block.cited.count == RemoraBlock.Limits.cited)
        #expect(block.chips.count == RemoraBlock.Limits.chips)
        #expect(block.chips.allSatisfy { $0.why.count == RemoraBlock.Limits.whyCharacters })
        #expect(block.drafts.count == RemoraBlock.Limits.drafts)
        #expect(block.drafts.allSatisfy { $0.text.count == RemoraBlock.Limits.draftCharacters })
        #expect(block.facts.count == RemoraBlock.Limits.facts)
        #expect(block.facts.allSatisfy { $0.count == RemoraBlock.Limits.factCharacters })
        let huge = "{\"facts\":[\"\(String(repeating: "x", count: RemoraBlock.Limits.blockBytes))\"]}"
        #expect(parse(huge) == nil, "a block over its byte bound is invalid as a whole")
    }

    @Test func malformedBlocksAreInvalid() {
        #expect(parse("{not json") == nil)
        #expect(parse("[1,2]") == nil)
        #expect(parse("") == nil)
        #expect(parse("{\"chips\":\"a\"}") == nil, "a field of the wrong type")
        #expect(parse("{\"cited\":{\"a\":1}}") == nil)
        #expect(parse("{}") == RemoraBlock())
        #expect(RemoraBlock.parse("{\"cited\":[]}", knownSessionIDs: []) == nil, "no opening fence")
    }

    @Test func aBlockTheModelNeverClosedStandsOnItsJSON() {
        #expect(RemoraBlock.parse("```remora\n{\"cited\":[\"a\"]}", knownSessionIDs: ["a"])?.cited == ["a"])
        #expect(RemoraBlock.parse("```remora\n{\"cited\":[\"a\"", knownSessionIDs: ["a"]) == nil)
    }

    // MARK: Stream reader

    private func lines(_ objects: [[String: Any]]) -> Data {
        objects.reduce(into: Data()) { data, object in
            data.append((try? JSONSerialization.data(withJSONObject: object)) ?? Data())
            data.append(0x0A)
        }
    }

    private func delta(_ text: String) -> [String: Any] {
        ["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
                                            "delta": ["type": "text_delta", "text": text]]]
    }

    private func result(isError: Bool, subtype: String = "success", terminal: String? = "completed", text: String = "") -> [String: Any] {
        var object: [String: Any] = ["type": "result", "subtype": subtype, "is_error": isError, "result": text,
                                     "usage": ["input_tokens": 1, "output_tokens": 2]]
        if let terminal { object["terminal_reason"] = terminal }
        return object
    }

    @Test func failureIsIsErrorOrTerminalReasonNeverSubtype() {
        var errored = RemoraStreamReader(knownSessionIDs: [])
        _ = errored.feed(lines([result(isError: true, terminal: "api_error", text: "API Error: x")]))
        guard case let .failure(first)? = errored.outcome else { Issue.record("is_error with subtype success must fail"); return }
        #expect(first.kind == .apiError)

        var aborted = RemoraStreamReader(knownSessionIDs: [])
        _ = aborted.feed(lines([result(isError: false, terminal: "blocking_limit")]))
        guard case .failure? = aborted.outcome else { Issue.record("a non-completed terminal_reason must fail"); return }

        // A subtype that is not "success" with is_error false and a completed turn is not what the CLI sends; the
        // judgement does not read it either way.
        var odd = RemoraStreamReader(knownSessionIDs: [])
        _ = odd.feed(lines([delta("Hi"), result(isError: false, subtype: "something_new", text: "Hi")]))
        guard case let .answer(answer)? = odd.outcome else { Issue.record("subtype must not decide"); return }
        #expect(answer.text == "Hi")
    }

    @Test func thinkingIsDroppedAndFramesAfterTheResultAreIgnored() {
        var reader = RemoraStreamReader(knownSessionIDs: [])
        let thinking: [String: Any] = ["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
            "delta": ["type": "thinking_delta", "thinking": "secret thoughts"]]]
        let pieces = reader.feed(lines([thinking, delta("Hello "), delta("world"), result(isError: false, text: "Hello world"), delta("late")]))
        #expect(pieces.joined() == "Hello world")
        guard case let .answer(answer)? = reader.outcome else { Issue.record("no answer"); return }
        #expect(answer.text == "Hello world")
        #expect(answer.usage == RemoraTokenUsage(input: 1, cacheCreation: 0, cacheRead: 0, output: 2))
    }

    @Test func withoutPartialMessagesTheResultTextIsTheAnswer() {
        var reader = RemoraStreamReader(knownSessionIDs: ["a"])
        let pieces = reader.feed(lines([result(isError: false, text: "Short.\n\n```remora\n{\"cited\":[\"a\"]}\n```")]))
        #expect(pieces.joined() == "Short.")
        guard case let .answer(answer)? = reader.outcome else { Issue.record("no answer"); return }
        #expect(answer.cited == ["a"])
    }

    @Test func linesSplitAcrossChunksAndGarbageAreHandled() {
        var reader = RemoraStreamReader(knownSessionIDs: [])
        let data = lines([delta("Hi")]) + Data("this is not json\n".utf8) + lines([result(isError: false, text: "Hi")])
        var pieces: [String] = []
        for byte in data { pieces += reader.feed(Data([byte])) }
        #expect(pieces.joined() == "Hi")
        #expect(reader.outcome != nil)
    }
}
