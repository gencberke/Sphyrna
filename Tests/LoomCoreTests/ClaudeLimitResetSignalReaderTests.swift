import Foundation
import Testing
@testable import LoomCore

@Suite struct ClaudeLimitResetSignalReaderTests {
    private let now = Date(timeIntervalSince1970: 1_791_600_000)

    private func line(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    private struct Rig {
        let root: URL
        let file: URL
        let context: ClaudeLimitResetContext
        let userID: UUID
    }

    private func rig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-reset-tail-\(UUID())", isDirectory: true)
        let working = "/tmp/loom-reset-test"
        let directory = root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(ClaudeTranscriptLocator.folderName(forWorkingDirectory: working), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let native = UUID().uuidString.lowercased()
        let context = ClaudeLimitResetContext(sessionID: UUID(), nativeSessionID: native, runID: UUID(), promptID: UUID(),
            runStartedAt: now.addingTimeInterval(-30), failedAt: now, configDirectory: root, workingDirectory: working)
        return Rig(root: root, file: directory.appendingPathComponent(native + ".jsonl"), context: context, userID: UUID())
    }

    private func user(_ rig: Rig, prompt: UUID? = nil, timestamp: Date? = nil) -> [String: Any] {
        ["type": "user", "uuid": rig.userID.uuidString, "sessionId": rig.context.nativeSessionID,
         "promptId": (prompt ?? rig.context.promptID).uuidString,
         "timestamp": ISO8601DateFormatter().string(from: timestamp ?? now.addingTimeInterval(-4)),
         "isSidechain": false, "message": ["role": "user", "content": "fixture"]]
    }

    private func failure(_ rig: Rig, window: String = "five_hour", status: String = "rejected",
                         reason: String = "usage_limit_reached", timestamp: Date? = nil) -> [String: Any] {
        ["type": "assistant", "uuid": UUID().uuidString, "parentUuid": rig.userID.uuidString,
         "sessionId": rig.context.nativeSessionID, "isSidechain": false, "isApiErrorMessage": true,
         "apiError": reason, "timestamp": ISO8601DateFormatter().string(from: timestamp ?? now.addingTimeInterval(-1)),
         "apiErrorParams": ["rate_limit_info": ["status": status, "rateLimitType": window,
             "resetsAt": Int(now.addingTimeInterval(3_600).timeIntervalSince1970), "isUsingOverage": false]]]
    }

    private func write(_ rows: [[String: Any]], to file: URL) throws {
        try rows.map(line).joined().write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func typedErrorMatchesTheAuthenticatedRunAndLatestPrompt() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try write([user(rig), failure(rig)], to: rig.file)
        let signal = try #require(await ClaudeLimitResetSignalReader.read(rig.context))
        #expect(signal.sessionID == rig.context.sessionID && signal.runID == rig.context.runID)
        #expect(signal.nativeSessionID == rig.context.nativeSessionID && signal.promptID == rig.context.promptID)
        #expect(signal.windowID == "five_hour" && signal.resetsAt == now.addingTimeInterval(3_600))
    }

    @Test func unrelatedOldOrUnstructuredFailuresCannotScheduleAReset() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let candidates: [[[String: Any]]] = [
            [user(rig, prompt: UUID()), failure(rig)],
            [user(rig, timestamp: now.addingTimeInterval(-90)), failure(rig, timestamp: now.addingTimeInterval(-80))],
            [user(rig), failure(rig), user(rig, prompt: UUID())],
            [user(rig), failure(rig, reason: "other_rate_limit")],
            [user(rig), failure(rig, status: "allowed_warning")],
            [user(rig), failure(rig, window: "overage")],
        ]
        for rows in candidates {
            try write(rows, to: rig.file)
            #expect(await ClaudeLimitResetSignalReader.read(rig.context) == nil)
        }
    }

    @Test func aRefusalCanFollowEarlierAssistantWorkButNotANewerAssistantAnswer() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let assistant: [String: Any] = ["type": "assistant", "uuid": UUID().uuidString,
            "sessionId": rig.context.nativeSessionID, "isSidechain": false,
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-3)),
            "message": ["role": "assistant", "content": []]]
        try write([user(rig), assistant, failure(rig)], to: rig.file)
        #expect(await ClaudeLimitResetSignalReader.read(rig.context)?.windowID == "five_hour")
        try write([user(rig), failure(rig), assistant], to: rig.file)
        #expect(await ClaudeLimitResetSignalReader.read(rig.context) == nil)
    }

    @Test func incompleteAndOversizedTailsNeverBorrowEarlierEvidence() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try write([user(rig), failure(rig)], to: rig.file)
        let handle = try FileHandle(forWritingTo: rig.file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{incomplete".utf8))
        #expect(await ClaudeLimitResetSignalReader.read(rig.context) == nil)
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data((try line(user(rig)) + line(failure(rig))
            + "{\"type\":\"user\",\"text\":\"" + String(repeating: "x", count: 70_000) + "\"}\n").utf8))
        #expect(await ClaudeLimitResetSignalReader.read(rig.context) == nil)
    }

    @Test func theExactFileIsBoundedAndASymlinkIsNotFollowed() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let prefix = String(repeating: "x", count: ClaudeLimitResetSignalReader.maximumTailBytes + 10_000) + "\n"
        try (prefix + line(user(rig)) + line(failure(rig))).write(to: rig.file, atomically: true, encoding: .utf8)
        #expect(await ClaudeLimitResetSignalReader.read(rig.context)?.windowID == "five_hour")
        let other = rig.root.appendingPathComponent("target.jsonl")
        try FileManager.default.moveItem(at: rig.file, to: other)
        try FileManager.default.createSymbolicLink(at: rig.file, withDestinationURL: other)
        #expect(await ClaudeLimitResetSignalReader.read(rig.context) == nil)
    }

    @Test func malformedIdentityAndBooleanFieldsCannotAuthorizeAReset() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        var agent = failure(rig)
        agent["agentId"] = 7
        var errorFlag = failure(rig)
        errorFlag["isApiErrorMessage"] = 1
        var sidechain = failure(rig)
        sidechain["isSidechain"] = 0
        var noUUID = failure(rig)
        noUUID["uuid"] = "not-a-uuid"
        var overage = failure(rig)
        var params = try #require(overage["apiErrorParams"] as? [String: Any])
        var rate = try #require(params["rate_limit_info"] as? [String: Any])
        rate["isUsingOverage"] = 0
        params["rate_limit_info"] = rate
        overage["apiErrorParams"] = params
        var fractional = failure(rig)
        var fractionalParams = try #require(fractional["apiErrorParams"] as? [String: Any])
        var fractionalRate = try #require(fractionalParams["rate_limit_info"] as? [String: Any])
        fractionalRate["resetsAt"] = now.addingTimeInterval(3_600.5).timeIntervalSince1970
        fractionalParams["rate_limit_info"] = fractionalRate
        fractional["apiErrorParams"] = fractionalParams
        for row in [agent, errorFlag, sidechain, noUUID, overage, fractional] {
            try write([user(rig), row], to: rig.file)
            #expect(await ClaudeLimitResetSignalReader.read(rig.context) == nil)
        }
    }
}
