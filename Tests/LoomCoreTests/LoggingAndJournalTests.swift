import Foundation
import Synchronization
import Testing
@testable import LoomCore

/// H1-B: the logging rules (rate limits, content-free categories) and the diagnostic journal.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LoggingAndJournalTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: TimeInterval = 1_000
        var value: TimeInterval { lock.withLock { now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { now += seconds } }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("loom-journal-\(UUID())", isDirectory: true)
    }

    @Test func theCategoriesAreTheDocumentedOnesUnderTheDesktopSubsystem() {
        let names = Set(LoomLogCategory.allCases.map(\.rawValue))
        for required in ["Lifecycle", "Catalog", "ClaudeHooks", "Registry", "Toolchain", "Scope", "Usage",
                         "Recovery", "Quit", "Diagnostics", "HookClient"] {
            #expect(names.contains(required), "missing category \(required)")
        }
        #expect(LoomSignposts.subsystem == "local.loom.desktop")
    }

    @Test func anIdenticalErrorIsLetThroughOncePerMinuteAndTheHeldBackOnesAreCounted() {
        let clock = Clock()
        let limiter = LogRateLimiter(interval: 60, clock: { clock.value })
        #expect(limiter.admit("write") == 0)
        #expect(limiter.admit("write") == nil)
        clock.advance(30)
        #expect(limiter.admit("write") == nil)
        #expect(limiter.admit("other") == 0)          // another key is independent
        clock.advance(31)
        #expect(limiter.admit("write") == 2)          // reported again, with the two it held back
        #expect(limiter.admit("write") == nil)
    }

    @Test func theRateLimiterKeepsABoundedNumberOfKeys() {
        let clock = Clock()
        let limiter = LogRateLimiter(interval: 60, clock: { clock.value })
        for index in 0..<2_000 { _ = limiter.admit("key-\(index)"); clock.advance(0.001) }
        // The newest key is still held back; the oldest was forgotten and reports again.
        #expect(limiter.admit("key-1999") == nil)
        #expect(limiter.admit("key-0") == 0)
    }

    @Test func anErrorIsNamedByItsTypeAndCaseNeverByItsPayload() {
        let secret = "/Users/someone/Secret Project/prompt text"
        #expect(LoomLog.category(of: SessionCatalogError.sqlite(operation: "insert run", code: 5, message: secret))
            == "sqlite insert run 5")
        let message = LoomLog.category(of: LoomError.message(secret))
        #expect(!message.contains("Secret") && !message.contains("/Users"))
        #expect(message.contains("LoomError"))
        #expect(!LoomLog.category(of: SessionCatalogError.invalidRow(secret)).contains("Secret"))
    }

    // MARK: Journal

    @Test func eventsAreOneJSONObjectPerLineWithATimeAndNoNesting() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiagnosticJournal(directory: directory)
        journal.record("launch", ["version": "1.2", "count": 3, "ok": true, "options": .strings(["--a", "--b"])],
                       at: Date(timeIntervalSince1970: 1_791_374_400))
        journal.record("quit", [:])
        let lines = journal.lines()
        #expect(lines.count == 2)
        let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(first["event"] as? String == "launch")
        #expect(first["time"] as? String == "2026-10-07T12:00:00.000Z")
        #expect(first["count"] as? Int == 3)
        #expect(first["options"] as? [String] == ["--a", "--b"])
        #expect(!lines[0].contains("\n"))
        var info = stat()
        #expect(stat(journal.currentURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
    }

    @Test func aLongValueIsCutAndNothingSpansLines() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiagnosticJournal(directory: directory)
        journal.record("x", ["text": .string(String(repeating: "a\nb", count: 1_000))])
        let line = try #require(journal.lines().first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect((object["text"] as? String)?.count == JournalValue.maximumStringLength)
        #expect(journal.lines().count == 1)
    }

    @Test func atTheLimitTheFileRotatesToTheFirstAndOnlyTwoFilesStayPrunedOnWrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiagnosticJournal(directory: directory, maximumBytes: 2_048)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: directory.appendingPathComponent("journal.2.jsonl"))
        for index in 0..<60 { journal.record("event", ["index": .int(index), "pad": .string(String(repeating: "x", count: 60))]) }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(names == [DiagnosticJournal.currentName, DiagnosticJournal.previousName])
        for url in [journal.currentURL, journal.previousURL] {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
            #expect(size <= 2_048)
        }
        // The newest events survive, in order.
        let indexes = try journal.lines().map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])["index"] as? Int
        }
        #expect(indexes.last == 59)
        #expect(indexes == indexes.sorted { ($0 ?? 0) < ($1 ?? 0) })
        #expect(indexes.count < 60)
    }

    @Test func oneJournalPerDataRootSharesItsLock() {
        let root = temporaryDirectory()
        #expect(DiagnosticJournal.forDataRoot(root) === DiagnosticJournal.forDataRoot(root))
        #expect(DiagnosticJournal.forDataRoot(root).directory.lastPathComponent == "diagnostics")
    }

    @Test func aHomeFolderPathIsWrittenWithATilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(DiagnosticPaths.abbreviate(home + "/.local/bin/claude") == "~/.local/bin/claude")
        #expect(DiagnosticPaths.abbreviate("/usr/local/bin/claude") == "/usr/local/bin/claude")
    }
}
