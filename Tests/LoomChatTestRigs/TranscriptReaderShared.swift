import Darwin
import Foundation
import LoomCore
import Testing
@testable import LoomChat
import LoomTestSupport

/// What both halves of `TranscriptReaderTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum TranscriptReaderShared {
    struct Tree {
        let root: URL
        var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
        var folder: URL { projects.appendingPathComponent("-tmp-work", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-tmp-work"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func url(_ id: String = "sess1") -> URL { folder.appendingPathComponent("\(id).jsonl") }

        func file(_ id: String = "sess1") throws -> ClaudeTranscriptFile {
            try #require(ClaudeTranscriptLocator.locate(sessionID: id, configDirectory: root))
        }
    }
}

/// `TranscriptReaderTests`'s fixtures, for both halves of the suite.
protocol TranscriptReaderFixtures {}

extension TranscriptReaderFixtures {
    typealias Tree = TranscriptReaderShared.Tree

    func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
