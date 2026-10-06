import Foundation
import Testing
@testable import LoomCore

struct CodexWireDiagnosticsTests {
    @Test func metadataIsContentFreeAndZeroIsARequest() async throws {
        let diagnostic = CodexWireDiagnostics(connection: "A", threadID: "private-thread")
        let token = diagnostic.observe(Data(#"{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"private-thread","turnId":"private-turn","command":"private-command"}}"#.utf8))
        diagnostic.decoded(token, outcome: "request")
        await diagnostic.route(.request(sequence: 1, CodexServerRequest(id: .number(0), method: "item/commandExecution/requestApproval", params: .object([:]), threadID: "private-thread", kind: .commandExecution)), token: token)
        let entry = try #require(diagnostic.snapshot().entries.first)
        #expect(entry.envelope == "request" && entry.idType == "number")
        #expect(entry.routing == "target-run")
        let output = String(decoding: try JSONEncoder().encode(diagnostic.snapshot()), as: UTF8.self)
        #expect(!output.contains("private-"))
    }
    @Test func unknownNotificationAndWrongThreadRemainDistinct() async {
        let diagnostic = CodexWireDiagnostics(connection: "B", threadID: "target")
        let token = diagnostic.observe(Data(#"{"method":"private-unknown","params":{"secret":"private-content"}}"#.utf8))
        diagnostic.decoded(token, outcome: "event")
        await diagnostic.route(.event(sequence: 1, .unknown(method: "private-unknown")), token: token)
        #expect(diagnostic.snapshot().entries.first?.method == "other")
        #expect(diagnostic.snapshot().entries.first?.routing == "unmatched")
        let wrong = diagnostic.observe(Data(#"{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"wrong"}}"#.utf8))
        diagnostic.decoded(wrong, outcome: "request")
        await diagnostic.route(.request(sequence: 2, CodexServerRequest(id: .number(0), method: "item/commandExecution/requestApproval", params: .object([:]), threadID: "wrong", kind: .commandExecution)), token: wrong)
        #expect(diagnostic.snapshot().entries.last?.threadMatch == false)
        #expect(diagnostic.snapshot().entries.last?.routing == "unmatched")
    }
    @Test func overflowAndFailuresInvalidateNegativeEvidence() {
        let diagnostic = CodexWireDiagnostics(connection: "A", threadID: "target", capacity: 1)
        diagnostic.observe(Data("[]".utf8))
        diagnostic.observe(Data("{}".utf8))
        #expect(diagnostic.snapshot().dropped == 1)
        #expect(diagnostic.snapshot().invalidated)
        diagnostic.invalidate("private-error")
        diagnostic.invalidate("timeout")
        #expect(diagnostic.snapshot().failures == ["protocol", "timeout"])
    }
}
