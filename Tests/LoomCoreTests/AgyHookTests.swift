import Foundation
import Testing
@testable import LoomCore

struct AgyHookTests {
    private func payload(extra: [String: Any] = [:]) throws -> Data {
        let id = UUID().uuidString.lowercased()
        var value: [String: Any] = ["conversationId": id, "workspacePaths": ["/tmp/project", "/tmp/app-root"],
            "transcriptPath": "/tmp/profile/brain/\(id)/.system_generated/logs/transcript.jsonl",
            "artifactDirectoryPath": "/tmp/profile/brain/\(id)", "modelName": "fake-model"]
        value.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }

    @Test func helperPrunesToolArgumentsAndNeverApprovesNativePermissions() throws {
        let raw = try payload(extra: ["toolCall": ["name": "run_command", "args": ["CommandLine": "PRIVATE-SYNTHETIC"]], "stepIdx": 1])
        let event = try #require(AgyHookEvent.parse(kind: .preToolUse, payload: raw))
        #expect(event.isWellFormed)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE-SYNTHETIC") && !encoded.contains("toolCall"))
        #expect(AgyHookCommand.run(event: "PreToolUse", environment: [:], payload: raw) == #"{"decision":"allow"}"#)
        #expect(AgyHookCommand.run(event: "Stop", environment: [:], payload: raw) == #"{"decision":""}"#)
        #expect(AgyHookCommand.run(event: "SessionStart", environment: [:], payload: raw) == "{}")
    }

    @Test func malformedOrOversizedMetadataCannotBecomeAStatusEvent() throws {
        let malformed = try payload(extra: ["conversationId": "not-a-uuid"])
        #expect(AgyHookEvent.parse(kind: .sessionStart, payload: malformed) == nil)
        #expect(AgyHookEvent.parse(kind: .sessionStart, payload: Data(repeating: 0x20, count: 64 * 1024 + 1)) == nil)
        #expect(AgyHookEvent.parse(kind: .stop, payload: try payload(extra: ["executionNum": true,
            "terminationReason": "model_stop", "fullyIdle": true])) == nil)
        #expect(AgyHookEvent.parse(kind: .stop, payload: try payload(extra: ["executionNum": 1,
            "terminationReason": "model_stop", "fullyIdle": "true"])) == nil)
        #expect(AgyHookEvent.parse(kind: .preInvocation, payload: try payload(extra: ["invocationNum": -1,
            "initialNumSteps": 0])) == nil)
        #expect(AgyHookEvent.parse(kind: .preToolUse, payload: try payload()) == nil)
        #expect(AgyHookCommand.run(event: "PreToolUse", environment: [:], payload: malformed) == #"{"decision":"allow"}"#)
    }
}
