import Darwin
import Foundation
import Synchronization

/// How many hook messages reached Loom and what became of them. Counts only; no event content.
public struct HookCounterSnapshot: Codable, Equatable, Sendable {
    /// Messages with a valid token that the server handed on.
    public var received = 0
    public var applied = 0
    /// Messages refused for a wrong token.
    public var rejectedToken = 0
    public var malformedMessages = 0
    /// Messages lost because the intake was full (the run's state became unknown).
    public var lostToOverflow = 0
    /// Messages that arrived but were not applied, by reason.
    public var dropped: [String: Int] = [:]

    public init() {}
}

public enum HookDiagnostics {
    enum Counter { case received, applied, rejectedToken, malformedMessage, lostToOverflow }

    private static let state = Mutex(HookCounterSnapshot())

    static func note(_ counter: Counter) {
        state.withLock {
            switch counter {
            case .received: $0.received += 1
            case .applied: $0.applied += 1
            case .rejectedToken: $0.rejectedToken += 1
            case .malformedMessage: $0.malformedMessages += 1
            case .lostToOverflow: $0.lostToOverflow += 1
            }
        }
    }

    static func noteDropped(reason: String) {
        state.withLock { $0.dropped[reason, default: 0] += 1 }
    }

    /// Since this process started.
    public static func snapshot() -> HookCounterSnapshot { state.withLock { $0 } }
}

/// What the usage index reports about itself, for the Usage settings and the export.
public struct UsageDiagnostics: Codable, Equatable, Sendable {
    /// The most recent scan, nil before the first one.
    public var lastScan: UsageScanReport?
    public var lastScanAt: Date?
    /// Lines the scans could not understand, summed over this process's scans.
    public var linesNotUnderstood: Int

    public init(lastScan: UsageScanReport? = nil, lastScanAt: Date? = nil, linesNotUnderstood: Int = 0) {
        self.lastScan = lastScan
        self.lastScanAt = lastScanAt
        self.linesNotUnderstood = linesNotUnderstood
    }
}

/// The last time asking the Claude CLI for plan limits failed.
public struct PlanLimitsFailure: Codable, Equatable, Sendable {
    public enum Category: String, Codable, Sendable {
        /// No Claude CLI could be resolved to ask.
        case noToolchain
        case spawnFailed
        case writeFailed
        case timedOut
        /// The CLI ended without answering.
        case endedWithoutAnswer
        case outputTooLarge
        /// The CLI answered that there are no limits for this account or the request failed.
        case notAvailable
        case cancelled
    }

    public let category: Category
    public let at: Date

    public init(category: Category, at: Date) {
        self.category = category
        self.at = at
    }
}

public struct DiagnosticsSummary: Codable, Equatable, Sendable {
    public struct Application: Codable, Equatable, Sendable {
        public var version: String
        public var build: String?
        public var macOS: String
    }

    public struct ClaudeCLI: Codable, Equatable, Sendable {
        public var path: String
        public var version: String
        /// Options found in `--help`.
        public var detectedOptions: [String]
        /// Options a start needs that `--help` did not list.
        public var missingRequiredOptions: [String]
    }

    public struct Catalog: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var sessions: Int
        public var projects: Int
        public var runs: Int
        public var openRuns: Int
        public var skippedRows: Int
        public var pendingDeletions: Int
        public var backups: Int
    }

    public struct LogExport: Codable, Equatable, Sendable {
        public var included: Bool
        public var bytes: Int
        public var truncated: Bool
        public var failure: String?
    }

    public var generatedAt: Date
    public var application: Application
    public var claudeCLI: ClaudeCLI?
    public var catalog: Catalog?
    public var usage: UsageDiagnostics?
    public var planLimitsFailure: PlanLimitsFailure?
    public var hooks: HookCounterSnapshot
    public var log: LogExport?
}

/// The outcome of one `log show` run.
public enum DiagnosticsLogResult: Equatable, Sendable {
    case collected(bytes: Int, truncated: Bool)
    case failed(String)
}

/// Writes the diagnostics folder: `summary.json`, the journal files and the last day of Loom's
/// unified log. It holds ids, counts, versions and error categories, never a prompt, message,
/// title or transcript text, and it is written only where the caller points it; nothing leaves the
/// machine by itself.
public enum DiagnosticsExport {
    public static let keepCount = 3
    public static let folderPrefix = "loom-diagnostics-"
    static let markerName = ".loom-diagnostics-export"
    public static let logByteCap = 5 * 1024 * 1024
    public static let logTimeout: TimeInterval = 30

    /// Writes the log's last 24 hours to the given file, within the cap and the timeout.
    public typealias LogRunner = @Sendable (_ output: URL) async -> DiagnosticsLogResult

    /// Where an export goes when the caller has no better place: `<data root>/diagnostics/exports/`.
    public static func defaultFolder(dataRoot: URL, now: Date = Date()) -> URL {
        dataRoot.appendingPathComponent("diagnostics/exports", isDirectory: true)
            .appendingPathComponent(folderPrefix + CatalogRecovery.stamp(now), isDirectory: true)
    }

    /// `log show` for this app only. The subsystem is shared with `swift test` processes and with the
    /// other flavor (Loom and Loom Dev), so the predicate also requires the process image to live
    /// inside the running app's bundle (the app and its bundled helpers, nothing else).
    static func logArguments(bundlePath: String = Bundle.main.bundleURL.path) -> [String] {
        let prefix = (bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let predicate = "subsystem == \"\(LoomSignposts.subsystem)\" && processImagePath BEGINSWITH \"\(prefix)\""
        return ["show", "--last", "24h", "--predicate", predicate, "--style", "ndjson"]
    }

    /// The real `log show`, with a timeout and an output cap.
    public static let systemLog: LogRunner = { output in
        await Task.detached(priority: .utility) {
            runLogShow(to: output, cap: logByteCap, timeout: logTimeout)
        }.value
    }

    static func runLogShow(
        to output: URL, cap: Int, timeout: TimeInterval,
        executable: String = "/usr/bin/log", arguments: [String] = DiagnosticsExport.logArguments()
    ) -> DiagnosticsLogResult {
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let sink = try? FileHandle(forWritingTo: output) else { return .failed("create log file") }
        defer { try? sink.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed("spawn") }
        let timedOut = Mutex(false)
        let watchdog = DispatchWorkItem {
            timedOut.withLock { $0 = true }
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let reader = pipe.fileHandleForReading
        var written = 0
        var truncated = false
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            if truncated { continue }
            let room = cap - written
            if chunk.count >= room {
                try? sink.write(contentsOf: chunk.prefix(room))
                written += room
                truncated = true
                if process.isRunning { process.terminate() }
            } else {
                try? sink.write(contentsOf: chunk)
                written += chunk.count
            }
        }
        process.waitUntilExit()
        watchdog.cancel()
        if timedOut.withLock({ $0 }) { return .failed("timed out") }
        if !truncated, process.terminationStatus != 0 { return .failed("log exited \(process.terminationStatus)") }
        return .collected(bytes: written, truncated: truncated)
    }

    /// Creates `folder` (it must not exist, or be empty) with `summary.json`, `journal.jsonl`,
    /// `journal.1.jsonl` and `log.ndjson`, then removes older exports beside it so at most
    /// `keepCount` remain. Only folders carrying this function's marker file are ever removed.
    @discardableResult
    public static func collect(
        to folder: URL, dataRoot: URL, summary: DiagnosticsSummary,
        log: LogRunner = DiagnosticsExport.systemLog
    ) async throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.path) {
            guard (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true else {
                throw LoomError.message("The diagnostics folder already exists and is not empty")
            }
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        do {
            try Data().write(to: folder.appendingPathComponent(markerName))
            let journal = DiagnosticJournal.forDataRoot(dataRoot)
            for source in [journal.currentURL, journal.previousURL] where fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
            }
            var finished = summary
            switch await log(folder.appendingPathComponent("log.ndjson")) {
            case let .collected(bytes, truncated):
                finished.log = .init(included: true, bytes: bytes, truncated: truncated, failure: nil)
            case let .failed(category):
                try? fileManager.removeItem(at: folder.appendingPathComponent("log.ndjson"))
                finished.log = .init(included: false, bytes: 0, truncated: false, failure: category)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(finished).write(to: folder.appendingPathComponent("summary.json"), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        prune(beside: folder)
        LoomLog.notice(.diagnostics, "Diagnostics exported")
        DiagnosticJournal.forDataRoot(dataRoot).record("diagnostics_export", [:])
        return folder
    }

    /// Exports are named by their creation stamp, so the name orders them.
    static func prune(beside folder: URL) {
        let parent = folder.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        let exports = names.filter { name in
            name.hasPrefix(folderPrefix)
                && FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).appendingPathComponent(markerName).path)
        }.sorted(by: >)
        for stale in exports.dropFirst(keepCount) where stale != folder.lastPathComponent {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(stale))
        }
    }
}
