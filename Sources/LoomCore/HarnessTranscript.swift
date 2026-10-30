import Darwin
import Dispatch
import Foundation

/// A provider's recorded transcript format, when this build has a reader.
public enum HarnessTranscriptKind: Equatable, Sendable {
    case claude, codex

    public init?(provider: ManagedSession.Provider) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        case .agy, .synthetic: return nil
        }
    }

    public func directory(claude: URL?, codex: URL?) -> URL? {
        switch self {
        case .claude: claude
        case .codex: codex
        }
    }

    /// The project page's usage index counts this format's sessions. It reads Claude's transcripts; no Codex rollout is
    /// scanned for it.
    public var countsInProjectUsage: Bool {
        switch self {
        case .claude: true
        case .codex: false
        }
    }
}

public struct CodexRolloutFile: Equatable, Sendable {
    public let path: String
    public let sessionID: String

    package init(path: String, sessionID: String) {
        self.path = path
        self.sessionID = sessionID
    }
}

public struct CodexRolloutLookup: Sendable {
    public var files: [String: CodexRolloutFile]
    /// False when cancellation or the discovery budget prevents a complete search.
    public var complete: Bool
    /// What the lookup cost: directories it opened and entries it read (tests count these, not time).
    public var directoriesOpened = 0
    public var entriesRead = 0
}

public enum CodexRolloutLocator {
    /// Codex puts a new rollout in `sessions/YYYY/MM/DD/` by its local time when it creates the thread (the pinned rollout
    /// recorder's `precompute_new_rollout_path`, `OffsetDateTime::now_local()`), and its thread ids are UUIDv7, whose first
    /// 48 bits are that moment in Unix milliseconds. So a v7 id is looked for first in its local day and the days on either
    /// side (time zones, midnight); the duplicate rule then covers what those folders hold. An id that is not v7, or not
    /// found there, falls back to a bounded walk through the three date directories. Only an exact UUID filename and a
    /// matching session_meta qualify.
    public static func locate(sessionIDs: [String], home: URL, maximumEntries: Int = 30_000,
                              maximumSeconds: Double = 1) -> CodexRolloutLookup {
        let wanted = Set(sessionIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        guard !wanted.isEmpty else { return CodexRolloutLookup(files: [:], complete: true) }
        guard home.isFileURL else { return CodexRolloutLookup(files: [:], complete: false) }
        let root = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return CodexRolloutLookup(files: [:], complete: false) }
        defer { close(root) }
        guard safeDirectory(root) else { return CodexRolloutLookup(files: [:], complete: false) }
        let sessions = openat(root, "sessions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sessions >= 0 else { return CodexRolloutLookup(files: [:], complete: false) }
        defer { close(sessions) }
        guard safeDirectory(sessions) else { return CodexRolloutLookup(files: [:], complete: false) }

        var search = Search(path: home.appendingPathComponent("sessions", isDirectory: true).path,
                            maximumEntries: maximumEntries, maximumSeconds: maximumSeconds)
        var days: [[String]] = []
        for id in wanted.sorted() {
            for day in probeDays(id) where !days.contains(day) { days.append(day) }
        }
        let probed = wanted.filter { !probeDays($0).isEmpty }
        search.wanted = probed
        for day in days {
            search.probe(sessions, day: day)
            guard search.complete else { return search.lookup(files: [:]) }
        }
        let hits = search.files
        let remaining = wanted.subtracting(hits.keys).subtracting(search.ambiguous)
        guard !remaining.isEmpty else { return search.lookup(files: hits) }
        search.wanted = remaining
        search.files = [:]
        search.ambiguous = []
        search.visit(sessions, path: search.path, depth: 0)
        // A partial walk cannot rule out another file with the same UUID; the ids found in their own day are kept.
        return search.lookup(files: search.complete ? hits.merging(search.files) { first, _ in first } : hits)
    }

    /// The local `YYYY`, `MM`, `DD` of a UUIDv7's timestamp, then of the days before and after it; none for another id.
    static func probeDays(_ id: String) -> [[String]] {
        guard let uuid = UUID(uuidString: id)?.uuid, uuid.6 >> 4 == 7, uuid.8 & 0xC0 == 0x80 else { return [] }
        let milliseconds = [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let seconds = time_t(milliseconds / 1000)
        var days: [[String]] = []
        for offset in [0, -86_400, 86_400] as [time_t] {
            var moment = seconds + offset
            var local = tm()
            guard localtime_r(&moment, &local) != nil else { continue }
            let day = [String(format: "%04d", local.tm_year + 1900), String(format: "%02d", local.tm_mon + 1),
                       String(format: "%02d", local.tm_mday)]
            if !days.contains(day) { days.append(day) }
        }
        return days
    }

    /// One lookup's reads under `sessions`, against one entry and time budget.
    private struct Search {
        let path: String
        let maximumEntries: Int
        let maximumSeconds: Double
        let started = DispatchTime.now().uptimeNanoseconds
        var wanted: Set<String> = []
        var entries = 0
        var opened = 2
        var complete = true
        var files: [String: CodexRolloutFile] = [:]
        var ambiguous: Set<String> = []

        func lookup(files: [String: CodexRolloutFile]) -> CodexRolloutLookup {
            CodexRolloutLookup(files: files, complete: complete, directoriesOpened: opened, entriesRead: entries)
        }

        /// Reads one day folder, reached by name with the walk's checks; a missing folder holds nothing.
        mutating func probe(_ sessions: Int32, day: [String]) {
            var descriptor = sessions
            var path = self.path
            var owned: [Int32] = []
            defer { owned.forEach { close($0) } }
            for name in day {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return }
                owned.append(child)
                opened += 1
                guard CodexRolloutLocator.safeDirectory(child) else { complete = false; return }
                descriptor = child
                path += "/" + name
            }
            visit(descriptor, path: path, depth: 3)
        }

        mutating func visit(_ descriptor: Int32, path: String, depth: Int) {
            guard complete else { return }
            let duplicate = dup(descriptor)
            guard duplicate >= 0, let directory = fdopendir(duplicate) else {
                if duplicate >= 0 { close(duplicate) }
                complete = false
                return
            }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                if Task.isCancelled || entries >= max(0, maximumEntries)
                    || Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9 >= maximumSeconds {
                    complete = false
                    break
                }
                entries += 1
                if depth < 3 {
                    let digits = depth == 0 ? 4 : 2
                    guard name.utf8.count == digits, name.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { continue }
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { continue }
                    opened += 1
                    if CodexRolloutLocator.safeDirectory(child) { visit(child, path: path + "/" + name, depth: depth + 1) }
                    else { complete = false }
                    close(child)
                    if !complete { break }
                } else {
                    guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
                    let stem = String(name.dropLast(6))
                    guard stem.count >= 37 else { continue }
                    let id = String(stem.suffix(36)).lowercased()
                    guard wanted.contains(id), stem.lowercased().hasSuffix("-" + id), !ambiguous.contains(id) else { continue }
                    let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard file >= 0 else { continue }
                    var info = stat()
                    let matches = fstat(file, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                        && info.st_uid == getuid() && CodexRolloutLocator.matchesHeader(file, id: id)
                    close(file)
                    guard matches else { continue }
                    if files[id] != nil { files[id] = nil; ambiguous.insert(id) }
                    else { files[id] = CodexRolloutFile(path: path + "/" + name, sessionID: id) }
                }
            }
        }
    }

    private static func safeDirectory(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o022 == 0
    }

    private static func matchesHeader(_ fd: Int32, id: String) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count > 0, let newline = bytes[..<count].firstIndex(of: 0x0A), newline > 0,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes[..<newline])) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
              let text = payload["id"] as? String, let parsed = UUID(uuidString: text) else { return false }
        return parsed.uuidString.lowercased() == id
    }
}
