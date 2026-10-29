import Foundation
import Testing
@testable import LoomCore

/// Synthetic records shaped by P0's schema; no profile or executable is read.
@Suite struct CodexUsageParserTests {
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func counts(_ input: Int, _ cached: Int, _ write: Int, _ output: Int) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": write,
         "output_tokens": output, "reasoning_output_tokens": output / 2, "total_tokens": input + output]
    }
    private func event(total: [String: Int], last: [String: Int]) -> [String: Any] {
        ["type": "event_msg", "timestamp": "2026-10-28T19:24:03.915Z",
         "payload": ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last,
                                                     "model_context_window": 1_000]]]
    }

    @Test func cumulativeAndLastSamplesAreNotDoubleCountedAndKeepTheirModels() throws {
        var parser = CodexUsageParser()
        func put(_ object: [String: Any]) throws { parser.consume(try data(object)) }
        let first = counts(100, 20, 5, 10)
        let second = counts(250, 50, 10, 30)
        let final = counts(300, 60, 15, 35)
        try put(["type": "turn_context", "payload": ["model": "gpt-test-a"]])
        try put(event(total: first, last: first))
        try put(event(total: first, last: first))
        try put(["type": "token_usage_record", "payload": ["usage": first]])
        try put(["type": "turn_context", "payload": ["model": "gpt-test-b"]])
        try put(event(total: second, last: counts(150, 30, 5, 20)))
        try put(event(total: final, last: counts(50, 10, 5, 5)))
        let reading = parser.reading
        #expect(reading.hasUsage && reading.complete)
        #expect(reading.total == UsageTokens(input: 225, output: 35, cacheWrite5m: 15, cacheRead: 60))
        #expect(reading.total.total == 335)
        #expect(reading.increments.map(\.model) == ["gpt-test-a", "gpt-test-b", "gpt-test-b"])
        #expect(reading.increments.map(\.tokens.total) == [110, 170, 55])
        #expect(reading.context == ContextUsage(tokens: 50, window: 1_000, model: "gpt-test-b"))
    }

    @Test func unknownHistoricalAttributionAndRegressionsRemainPartial() throws {
        var parser = CodexUsageParser()
        parser.consume(try data(["type": "turn_context", "payload": ["model": "gpt-test"]]))
        parser.consume(try data(event(total: counts(300, 60, 15, 35), last: counts(50, 10, 5, 5))))
        let prior = parser.reading
        #expect(prior.hasUsage && !prior.complete)
        #expect(prior.increments.first?.model == nil)
        #expect(prior.increments.last?.model == "gpt-test")
        parser.consume(try data(event(total: counts(10, 1, 0, 1), last: counts(10, 1, 0, 1))))
        #expect(parser.reading.total == prior.total, "a counter regression must not duplicate earlier usage")
        #expect(!parser.reading.complete)
    }
    @Test func aMalformedUsageRecordCannotProduceACompleteReading() {
        var parser = CodexUsageParser()
        parser.consume(Data(#"{"type":"event_msg","payload":{"type":"token_count",broken"#.utf8))
        #expect(!parser.reading.complete)
    }

    @Test func anOmittedNativeCacheWriteCounterDefaultsToZero() throws {
        var parser = CodexUsageParser()
        var native = counts(100, 20, 0, 10)
        native["cache_write_input_tokens"] = nil
        parser.consume(try data(["type": "turn_context", "payload": ["model": "gpt-test"]]))
        parser.consume(try data(event(total: native, last: native)))
        #expect(parser.reading.hasUsage && parser.reading.complete)
        #expect(parser.reading.total == UsageTokens(input: 80, output: 10, cacheRead: 20))
    }
}
