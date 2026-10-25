import Foundation
import Testing
@testable import LoomCore

/// Claude Code adds record types and `system` subtypes without notice (2.1.300 wrote `system/permission_check_status`). The
/// readers that run for terminal sessions skip what they do not know: no error, no entry, nothing counted as not understood.
@Suite(.timeLimit(.minutes(1)))
struct TolerantTranscriptReaderTests {
    /// A new `system` subtype and an unknown top-level type, each carrying the words the usage gate looks for and fields in
    /// shapes the known records do not have, around one real assistant line and one brief.
    private static let unknownRecords = [
        #"{"type":"system","subtype":"permission_check_status","timestamp":"2026-10-05T10:00:00.000Z","sessionId":"sess-1","#
            + #""message":"assistant usage check","status":{"usage":"assistant","allowed":true},"isSidechain":"no"}"#,
        #"{"type":"loom_future_record","timestamp":12,"message":42,"usage":{"input_tokens":"many"},"role":"assistant"}"#,
    ]

    private static func transcript() -> [String] {
        [#"{"type":"user","message":{"role":"user","content":"Map the core module"}}"#]
            + unknownRecords
            + [UsageLine(id: "ok1", request: "r1", input: 3, output: 2).json]
    }

    @Test func theUsageIndexSkipsUnknownRecordsWithoutCountingThem() async throws {
        let fixture = try UsageFixture()
        try fixture.write(Self.transcript(), to: fixture.transcript())
        try fixture.write(Self.transcript(), to: fixture.subagent())
        let index = fixture.makeIndex()
        let report = try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.tokens == UsageTokens(input: 3, output: 2), "only the assistant line counts, once")
        #expect(report.linesMalformed == 0, "a record of an unknown type is not a line not understood")
        #expect(await index.diagnostics().linesNotUnderstood == 0)
    }

    @Test func theSubagentReaderGivesNoEntryForUnknownRecords() {
        let parser = SubagentTranscriptParser()
        for line in Self.unknownRecords {
            #expect(parser.parse(line).isEmpty, "\(line)")
        }
        let entries = Self.transcript().flatMap { parser.parse($0) }
        #expect(entries == [.brief("Map the core module"), .text("hi")])
    }
}
