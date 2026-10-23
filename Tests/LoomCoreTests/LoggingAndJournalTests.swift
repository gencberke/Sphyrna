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
        #expect(names == ["Lifecycle", "Catalog", "ClaudeHooks", "Registry", "Toolchain", "Scope", "Usage",
                          "Recovery", "Quit", "Diagnostics", "HookClient", "Session", "Chat", "Remora", "Deletion", "Sidebar"])
        #expect(LoomSignposts.subsystem == "local.loom.desktop")
    }

    @Test func aSessionsRefIsSAndTheFirstEightHexDigitsOfItsID() throws {
        let id = try #require(UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
        #expect(LoomLog.ref(id) == "s:0a1b2c3d")
    }

    @Test func aRunsWaitStatusReadsAsItsExitCodeOrSignal() {
        #expect(ProcessSupervisor.exitName(0) == "exit code 0")
        #expect(ProcessSupervisor.exitName(256) == "exit code 1")
        #expect(ProcessSupervisor.exitName(SIGKILL) == "signal 9")
        #expect(ProcessSupervisor.exitName(nil) == "exit unknown")
    }

    // MARK: Source guards

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every `.swift` file under `Sources/` (the vendored code is not under it), by its path from the repository.
    private static func sources() throws -> [(path: String, text: String)] {
        let root = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append((String(url.path.dropFirst(repoRoot.path.count + 1)), try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    /// A `LoomLog` call, or a call on a `Logger` kept in a `log`, `hookLog` or `logger` (as `LoomLog.logger(_:)` gives).
    static let logCallPattern = #"(LoomLog\.(notice|error|debug)|(?<![A-Za-z])(log|hookLog|logger)\.(info|notice|error|debug|fault|warning|trace|critical))\("#

    /// The argument list of each log call in `text` (`logCallPattern`): from its `(` to the matching `)`, string literals and
    /// their interpolations followed, so a parenthesis inside a message does not end it.
    static func logCalls(in text: String) -> [String] {
        let characters = Array(text)
        var calls: [String] = []
        var searchFrom = text.startIndex
        while let range = text.range(of: Self.logCallPattern, options: .regularExpression,
                                     range: searchFrom..<text.endIndex) {
            searchFrom = range.upperBound
            var index = text.distance(from: text.startIndex, to: range.upperBound)
            let start = index
            // A stack of contexts: code (counts parentheses) or a string literal.
            var stack: [(string: Bool, depth: Int)] = [(false, 1)]
            while index < characters.count, !stack.isEmpty {
                let character = characters[index]
                if stack[stack.count - 1].string {
                    if character == "\\", index + 1 < characters.count {
                        if characters[index + 1] == "(" { stack.append((false, 1)); index += 2; continue }
                        index += 2
                        continue
                    }
                    if character == "\"" { stack.removeLast() }
                } else {
                    switch character {
                    case "\"": stack.append((true, 0))
                    case "(": stack[stack.count - 1].depth += 1
                    case ")":
                        stack[stack.count - 1].depth -= 1
                        if stack[stack.count - 1].depth == 0 { stack.removeLast() }
                    default: break
                    }
                }
                index += 1
            }
            calls.append(String(characters[start..<min(index, characters.count)]))
        }
        return calls
    }

    @Test func theCallScannerFollowsParenthesesInsideMessages() {
        let calls = Self.logCalls(in: #"""
        LoomLog.error(.chat, "A (b) failed (\(LoomLog.category(of: error))) (\(x))") ; other(error)
        LoomLog.notice(.session, "Start (no card") ; String(describing: error)
        """#)
        #expect(calls.count == 2)
        #expect(calls.first?.hasSuffix(#"(\(x))")"#) == true)
        #expect(calls.last?.contains("describing") == false)
        #expect(Self.logCalls(in: #"Self.hookLog.error("x \(String(describing: error))"); catalog.error("y")"#).count == 1)
    }

    @Test func noLoggerIsMadeOutsideLoomLogAndTheSignposts() throws {
        let allowed: Set<String> = ["Sources/LoomCore/LoomLog.swift", "Sources/LoomCore/LoomSignposts.swift"]
        let offenders = try Self.sources().filter { !allowed.contains($0.path) && $0.text.contains("Logger(subsystem:") }
        #expect(offenders.map(\.path).isEmpty, "make loggers through LoomLog: \(offenders.map(\.path))")
    }

    /// An error's description, `RemoraFailure.detail` and the like can carry a path, a title or the CLI's own words: a log
    /// message names an error only by `LoomLog.category(of:)`.
    @Test func noLogMessageInterpolatesAnErrorsDescriptionOrADetail() throws {
        let forbidden = [#"String\(describing:"#, #"\\\((error|failure|refusal)\s*[\),]"#, #"\.detail\b"#,
                         #"localizedDescription"#]
        var offenders: [String] = []
        for file in try Self.sources() {
            for call in Self.logCalls(in: file.text) where forbidden.contains(where: {
                call.range(of: $0, options: .regularExpression) != nil
            }) {
                offenders.append("\(file.path): \(call.prefix(160))")
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
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

    private func line(_ event: String, at date: Date) -> String {
        "{\"event\":\"\(event)\",\"time\":\"\(ISO8601DateFormatter.journalString(from: date))\"}"
    }

    @Test func entriesOlderThanThreeDaysAreDroppedWhenTheJournalOpensAndNewerOnesStay() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        let hour: TimeInterval = 3600
        try (line("old-previous", at: now - 80 * hour) + "\n" + line("kept-previous", at: now - 70 * hour) + "\n")
            .write(to: directory.appendingPathComponent(DiagnosticJournal.previousName), atomically: true, encoding: .utf8)
        try (line("old-current", at: now - 73 * hour) + "\n" + line("kept-current", at: now - 1 * hour) + "\n")
            .write(to: directory.appendingPathComponent(DiagnosticJournal.currentName), atomically: true, encoding: .utf8)
        let journal = DiagnosticJournal(directory: directory, now: { now })
        let events = try journal.lines().map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])["event"] as? String
        }
        #expect(events == ["kept-previous", "kept-current"])
        var info = stat()
        #expect(stat(journal.currentURL.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    @Test func entriesOlderThanThreeDaysAreDroppedWhenTheJournalRotates() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let journal = DiagnosticJournal(directory: directory, maximumBytes: 2_048,
                                        now: { Date(timeIntervalSince1970: clock.value) })
        journal.record("old", ["pad": .string(String(repeating: "x", count: 60))], at: Date(timeIntervalSince1970: clock.value))
        // Four days on, in the same process: the opening's pruning has run, the rotation's has not yet.
        clock.advance(96 * 3600)
        var index = 0
        while journal.lines().contains(where: { $0.contains("\"old\"") }) && index < 200 {
            journal.record("new", ["index": .int(index), "pad": .string(String(repeating: "x", count: 60))],
                           at: Date(timeIntervalSince1970: clock.value))
            index += 1
        }
        // It went at the first rotation, when the file passed 2 KB, not on every write.
        #expect(index > 10 && index < 40, "after \(index) writes")
        #expect(!journal.lines().contains { $0.contains("\"old\"") })
        #expect(journal.lines().contains { $0.contains("\"index\":0") })
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
