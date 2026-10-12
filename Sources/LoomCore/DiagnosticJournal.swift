import Darwin
import Foundation

/// A value the journal accepts. No nested objects: an event is a flat line, and nothing here can
/// hold a session's content because call sites pass ids, counts, names of capabilities and
/// error categories only.
public enum JournalValue: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                          ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case strings([String])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }

    static let maximumStringLength = 400

    var json: Any {
        switch self {
        case let .string(value): String(value.prefix(Self.maximumStringLength))
        case let .int(value): value
        case let .double(value): value.isFinite ? value : 0
        case let .bool(value): value
        case let .strings(values): values.prefix(32).map { String($0.prefix(Self.maximumStringLength)) }
        }
    }
}

/// `<data root>/diagnostics/journal.jsonl`: rare events only (launch summary, quit report summary,
/// recovery report, CLI compatibility warnings, catalog backup and restore), one JSON object per
/// line, no content. At 512 KB the file becomes `journal.1.jsonl` and a new one starts; two files
/// are kept and anything older is pruned on the write. It is read by the diagnostics export and by
/// people; nothing reads it back to make a decision.
public final class DiagnosticJournal: @unchecked Sendable {
    public static let maximumFileBytes = 512 * 1024
    public static let currentName = "journal.jsonl"
    public static let previousName = "journal.1.jsonl"

    public let directory: URL
    private let maximumBytes: Int
    private let lock = NSLock()

    private static let registry = NSLock()
    nonisolated(unsafe) private static var shared: [String: DiagnosticJournal] = [:]

    /// The journal of a data root: one instance per root, so every component writing to it takes
    /// the same lock.
    public static func forDataRoot(_ root: URL) -> DiagnosticJournal {
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true).standardizedFileURL
        return registry.withLock {
            if let existing = shared[directory.path] { return existing }
            let created = DiagnosticJournal(directory: directory)
            shared[directory.path] = created
            return created
        }
    }

    public init(directory: URL, maximumBytes: Int = DiagnosticJournal.maximumFileBytes) {
        self.directory = directory
        self.maximumBytes = max(maximumBytes, 1_024)
    }

    public var currentURL: URL { directory.appendingPathComponent(Self.currentName) }
    public var previousURL: URL { directory.appendingPathComponent(Self.previousName) }

    /// Appends one event. Never throws and never blocks the caller on anything but a local file.
    public func record(_ event: String, _ fields: [String: JournalValue] = [:], at date: Date = Date()) {
        var object: [String: Any] = [:]
        for (key, value) in fields { object[key] = value.json }
        object["event"] = String(event.prefix(64))
        object["time"] = ISO8601DateFormatter.journalString(from: date)
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let failure: Int32? = lock.withLock { write(line) }
        if let failure {
            LoomLog.error(.diagnostics, key: "journal-write", "The diagnostic journal could not be written (errno \(failure))")
        }
    }

    /// Both files' lines, oldest first (the previous file, then the current one).
    public func lines() -> [String] {
        lock.withLock {
            [previousURL, currentURL].flatMap { url -> [String] in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
                return text.split(separator: "\n").map(String.init)
            }
        }
    }

    /// Nil on success, the errno otherwise. Caller holds the lock.
    private func write(_ line: Data) -> Int32? {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return errno == 0 ? EIO : errno }
        let size = (try? FileManager.default.attributesOfItem(atPath: currentURL.path)[.size] as? NSNumber)?
            .map(\.intValue) ?? 0
        if size + line.count > maximumBytes, size > 0 {
            // rename replaces an existing previous file atomically.
            if rename(currentURL.path, previousURL.path) != 0 { return errno }
        }
        prune()
        let descriptor = open(currentURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        let written = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        return written == line.count ? nil : (errno == 0 ? EIO : errno)
    }

    /// Only the two named files belong in this folder's journal set; a journal of an earlier layout
    /// (`journal.2.jsonl`, ...) is removed.
    private func prune() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("journal.") && name.hasSuffix(".jsonl")
            && name != Self.currentName && name != Self.previousName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

extension ISO8601DateFormatter {
    /// UTC with milliseconds; a formatter per call keeps this free of shared mutable state.
    static func journalString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum DiagnosticPaths {
    /// The user's home folder reads as `~`; a journal and an export should not carry the account name.
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
