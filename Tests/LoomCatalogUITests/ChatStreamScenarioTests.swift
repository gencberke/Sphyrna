import Foundation
import Testing
@testable import LoomCatalogUI

private final class ScenarioBundleAnchor: NSObject {}

/// One `/scenario stream …` turn of the fake provider in chat mode, run to its result: the assistant text of each message.
/// A high rate over a short time hands out the same text as the measurement cells do (the text depends on the characters
/// sent only), in well under a second.
private func streamedMessages(_ arguments: String) async throws -> [String] {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("loom-stream-scenario-\(UUID().uuidString)", isDirectory: true)
    let config = root.appendingPathComponent("config", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = Bundle(for: ScenarioBundleAnchor.self).bundleURL.deletingLastPathComponent()
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

private struct ScenarioTimeout: Error {}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var parsed: [[String: Any]] = []

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
        let texts = try await streamedMessages("0.5 100000 fence300")
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
        let texts = try await streamedMessages("0.3 100000 nested-fence")
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

    /// Streamed into Chat's split cut by cut, each fixture's head is the parse of its settled text and its tail the parse of
    /// the rest; the 300-line fence settles in chunks, the nested one does not.
    @Test func theStreamingSplitOfEachFixtureIsItsWholeParse() async throws {
        for variant in ["plain", "fence300", "nested-fence"] {
            let texts = try await streamedMessages("0.12 100000 \(variant)")
            var chunked = 0
            for (number, text) in texts.enumerated() {
                chunked += ChatHosted.ChatStreamFenceTests.expectWholeParse(text, id: "fixture-\(variant)-\(number)-\(UUID().uuidString)", step: 41)
            }
            #expect(texts.joined().count >= 12_000, "\(variant)")
            #expect((chunked > 0) == (variant == "fence300"), "\(variant): \(chunked) cuts in chunks")
        }
    }

    @Test func everyFenceIsClosedWhereverTheTimeEnds() async throws {
        var endings: [String] = []
        for (variant, totals) in [("nested-fence", Array(stride(from: 400, through: 3_000, by: 200))), ("fence300", [1_000, 5_000])] {
            for total in totals {
                let texts = try await streamedMessages("0.1 \(total * 10) \(variant)")
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
