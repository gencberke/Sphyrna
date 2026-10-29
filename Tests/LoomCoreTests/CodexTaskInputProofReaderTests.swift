import CryptoKit
import Foundation
import Testing
@testable import LoomCore

@Suite struct CodexTaskInputProofReaderTests {
    private struct Fixture {
        let root: URL
        let home: URL
        let cwd: URL
        let file: URL
        let thread: String
        let turn = "native-turn-1"
        let client = "client-operation-1"
        let text = "synthetic task pointer"
        let candidate: CodexTaskInputProofCandidate
        var digest: Data { Data(SHA256.hash(data: Data(text.utf8))) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-task-proof-\(UUID())")
            home = root.appendingPathComponent("profile")
            cwd = root.appendingPathComponent("workspace")
            for dir in [home, cwd] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            thread = UUID().uuidString.lowercased()
            file = home.appendingPathComponent("sessions/2026/10/29/rollout-2026-10-29T00-00-00-\(thread).jsonl")
            candidate = try #require(CodexTaskInputProofReader.prepare(home: home, path: file.path, threadID: thread,
                                                                       workingDirectory: cwd.path, clientMessageID: client))
        }
        func row(_ type: String, _ payload: [String: Any]) throws -> Data {
            var result = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload], options: [.sortedKeys])
            result.append(0x0a)
            return result
        }
        func records(paginated: Bool = false, turnID: String? = nil, clientID: String? = nil,
                     message: String? = nil, attachments: Bool = false, secondInput: Bool = false) throws -> Data {
            var data = try row("session_meta", ["id": thread, "cwd": cwd.path])
            data += try row("event_msg", ["type": "task_started", "turn_id": turnID ?? turn])
            if paginated {
                let item: [String: Any] = ["type": "UserMessage", "id": "native-item", "client_id": clientID ?? client,
                    "content": [["type": attachments ? "image" : "text", "text": message ?? text, "text_elements": []]]]
                data += try row("event_msg", ["type": "item_completed", "thread_id": thread, "turn_id": turn, "item": item])
            } else {
                let input: [String: Any] = ["type": "user_message", "client_id": clientID ?? client,
                    "message": message ?? text, "images": attachments ? ["image"] : [],
                    "local_images": [], "audio": [], "local_audio": [], "text_elements": []]
                data += try row("event_msg", input)
                if secondInput { data += try row("event_msg", input) }
            }
            return data
        }
        func write(_ data: Data) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func matches() -> Bool { CodexTaskInputProofReader.proves(candidate, nativeTurnID: turn, digest: digest) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test(arguments: [false, true])
    func exactFirstInputWithNativeBoundaryAndClientIDProvesConsumption(paginated: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.write(fixture.records(paginated: paginated))
        #expect(fixture.matches())
        #expect(CodexTaskInputProofReader.prepare(home: fixture.home, path: fixture.file.path,
            threadID: fixture.thread, workingDirectory: fixture.cwd.path, clientMessageID: fixture.client) == nil)
    }

    @Test(arguments: ["turn", "client", "text", "attachment", "second", "partial", "large"])
    func missingOrConflictingEvidenceFailsClosed(caseName: String) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let data: Data
        switch caseName {
        case "turn": data = try fixture.records(turnID: "other-turn")
        case "client": data = try fixture.records(clientID: "other-client")
        case "text": data = try fixture.records(message: "other text")
        case "attachment": data = try fixture.records(attachments: true)
        case "second": data = try fixture.records(secondInput: true)
        case "partial": data = try fixture.records().dropLast()
        default: data = Data(repeating: 0x61, count: CodexTaskInputProofReader.byteLimit + 1)
        }
        try fixture.write(data)
        #expect(!fixture.matches())
    }

    @Test func aFileChangedAfterTheInputReadCannotBeUsedAfterJoin() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.write(fixture.records())
        let proof = try #require(CodexTaskInputProofReader.proof(fixture.candidate, nativeTurnID: fixture.turn,
                                                                digest: fixture.digest))
        #expect(CodexTaskInputProofReader.remainsCurrent(proof))
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        #expect(!CodexTaskInputProofReader.remainsCurrent(proof))
    }

    @Test func symlinkOrUnexpectedRootNeverProvidesProof() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let actual = fixture.root.appendingPathComponent("different.jsonl")
        try fixture.records().write(to: actual)
        try FileManager.default.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: actual)
        #expect(!fixture.matches())
        #expect(CodexTaskInputProofReader.prepare(home: fixture.home, path: actual.path, threadID: fixture.thread,
                                                  workingDirectory: fixture.cwd.path, clientMessageID: fixture.client) == nil)
    }
}
