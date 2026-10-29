import Foundation
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `ChatStreamScenarioTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ChatStreamScenarioShared {
    /// One `/scenario stream …` turn of the fake provider in chat mode, run to its result: the assistant text of each message.
    /// A high rate over a short time hands out the same text as the measurement cells do (the text depends on the characters
    /// sent only), in well under a second.
    static func streamedMessages(_ arguments: String) async throws -> [String] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-stream-scenario-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = Products.directory
            .appendingPathComponent("loom-fake-provider")
        process.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
            "--session-id", UUID().uuidString.lowercased(),
        ]
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": config.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lines = LineCollector()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { lines.append(data) }
        }
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            output.fileHandleForReading.readabilityHandler = nil
        }
        let user: [String: Any] = ["type": "user", "message": ["role": "user", "content": "/scenario stream " + arguments],
                                   "parent_tool_use_id": NSNull(), "uuid": UUID().uuidString.lowercased(), "origin": ["kind": "human"]]
        try input.fileHandleForWriting.write(contentsOf: try JSONSerialization.data(withJSONObject: user) + Data([0x0A]))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let records = lines.records()
            if let result = records.first(where: { $0["type"] as? String == "result" }) {
                #expect(result["subtype"] as? String == "success")
                return records.filter { $0["type"] as? String == "assistant" }.flatMap { record in
                    ((record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [])
                        .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ScenarioTimeout()
    }

    struct ScenarioTimeout: Error {}

    final class LineCollector: @unchecked Sendable {
        let lock = NSLock()
        var buffer = Data()
        var parsed: [[String: Any]] = []

        func append(_ data: Data) {
            lock.withLock {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    if let object = (try? JSONSerialization.jsonObject(with: buffer[buffer.startIndex..<newline])) as? [String: Any] {
                        parsed.append(object)
                    }
                    buffer = Data(buffer[buffer.index(after: newline)...])
                }
            }
        }

        func records() -> [[String: Any]] { lock.withLock { parsed } }
    }
}
