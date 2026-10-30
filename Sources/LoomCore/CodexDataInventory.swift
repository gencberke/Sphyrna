import Darwin
import Dispatch
import Foundation

/// What Codex keeps for a session in its home that a deletion removes or checks (SPEC §5.1, D-121). It only reads: the native
/// `thread/delete` of the deletion's own app-server removes the data, and this finds what is still there before and after.
///
/// Two entries are kept by decision and named, never counted as leftovers: `history.jsonl` (Codex's shared prompt history,
/// which other Codex processes append to under their own lock, so Sphyrna never rewrites it, as with Claude's) and the
/// zero-byte `tui-thread-reference-capabilities/<id>` marker, which holds no content.
public struct CodexDataInventory: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// Relative to the Codex home ("sessions/2026/10/30/rollout-…-<id>.jsonl").
        public let relativePath: String
        public let bytes: Int64
    }

    /// The rollouts of the native ids, active and archived, plain and compressed.
    public let rollouts: [Item]
    /// `session_index.jsonl` records whose parsed top-level `id` is one of the native ids.
    public let indexRecords: Int
    /// Entries that exist and are kept (relative paths): the shared prompt history and the capability markers.
    public let kept: [String]

    /// Nothing the deletion removes is left: no rollout and no index record.
    public var isClear: Bool { rollouts.isEmpty && indexRecords == 0 }

    /// What is left, as the deletion's failure names it (a rollout's name, or the index).
    public var leftovers: [String] {
        rollouts.map(\.relativePath) + (indexRecords > 0 ? [CodexDataInventory.indexName] : [])
    }

    public static let historyName = "history.jsonl"
    public static let indexName = "session_index.jsonl"
    public static let markerFolder = "tui-thread-reference-capabilities"
}

public enum CodexDataError: Error, Equatable, Sendable {
    /// The home or one of its data folders is a link, someone else's, or writable by others.
    case unsafeHome
    /// The walk ended early (its entry or time budget, a folder it could not open): it cannot rule a rollout out.
    case incomplete
    /// `session_index.jsonl` exists and cannot be read whole (not a plain file of the user's, or too large).
    case indexUnreadable
}

extension CodexDataInventory {
    /// The native Codex ids among a session's provider ids: each UUID other than the Loom id, lowercased, once.
    public static func nativeIDs(of providerIDs: [String], sessionID: UUID) -> [String] {
        let own = sessionID.uuidString.lowercased()
        let ids = providerIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() }.filter { $0 != own }
        return Array(Set(ids)).sorted()
    }

    /// Reads the home for `nativeIDs`. Bounded by `maximumEntries` directory entries and `maximumSeconds`; a walk that cannot
    /// finish throws `.incomplete` rather than report less than is there. `readsIndex: false` leaves `session_index.jsonl`
    /// unread (`indexRecords` is then 0): a preview shows only the rollouts and what is kept.
    public static func scan(nativeIDs: [String], home: URL, readsIndex: Bool = true, maximumEntries: Int = 200_000,
                            maximumSeconds: Double = 10,
                            maximumIndexBytes: Int = 64 * 1024 * 1024) throws -> CodexDataInventory {
        let wanted = Set(nativeIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        guard home.isFileURL else { throw CodexDataError.unsafeHome }
        let root = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw CodexDataError.unsafeHome }
        defer { close(root) }
        guard safeDirectory(root) else { throw CodexDataError.unsafeHome }
        guard !wanted.isEmpty else { return CodexDataInventory(rollouts: [], indexRecords: 0, kept: []) }

        var walk = Walk(wanted: wanted, maximumEntries: maximumEntries, maximumSeconds: maximumSeconds)
        for folder in ["sessions", "archived_sessions"] {
            let descriptor = openat(root, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT { continue }
                throw CodexDataError.unsafeHome
            }
            defer { close(descriptor) }
            guard safeDirectory(descriptor) else { throw CodexDataError.unsafeHome }
            walk.visit(descriptor, path: folder, depth: 0)
        }
        guard walk.complete else { throw CodexDataError.incomplete }

        let records = try readsIndex ? indexRecords(root, wanted: wanted, maximumBytes: maximumIndexBytes) : 0
        var kept: [String] = []
        if exists(root, historyName) { kept.append(historyName) }
        for id in wanted.sorted() where exists(root, "\(markerFolder)/\(id)") { kept.append("\(markerFolder)/\(id)") }
        return CodexDataInventory(rollouts: walk.items.sorted { $0.relativePath < $1.relativePath },
                                  indexRecords: records, kept: kept)
    }

    /// The part of a scan of many sessions' ids that is `nativeIDs`', as a scan of those ids alone with `readsIndex: false`
    /// reads it: one walk of the home serves every session of a cleanup review or of Storage.
    func restricted(to nativeIDs: [String]) -> CodexDataInventory {
        let wanted = Set(nativeIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        guard !wanted.isEmpty else { return CodexDataInventory(rollouts: [], indexRecords: 0, kept: []) }
        let own = rollouts.filter { item in
            Self.rolloutID(String(item.relativePath.split(separator: "/").last ?? "")).map(wanted.contains) ?? false
        }
        let marker = Self.markerFolder + "/"
        let keptHere = kept.filter {
            $0 == Self.historyName || ($0.hasPrefix(marker) && wanted.contains(String($0.dropFirst(marker.count))))
        }
        return CodexDataInventory(rollouts: own, indexRecords: 0, kept: keptHere)
    }

    /// The id a rollout's file name carries ("rollout-<time>-<uuid>.jsonl" or ".jsonl.zst"), lowercased; nil otherwise.
    static func rolloutID(_ name: String) -> String? {
        guard name.hasPrefix("rollout-") else { return nil }
        let stem: Substring
        if name.hasSuffix(".jsonl") { stem = name.dropLast(6) }
        else if name.hasSuffix(".jsonl.zst") { stem = name.dropLast(10) }
        else { return nil }
        guard stem.count >= 37, stem.dropLast(36).hasSuffix("-"),
              let id = UUID(uuidString: String(stem.suffix(36))) else { return nil }
        return id.uuidString.lowercased()
    }

    private struct Walk {
        let wanted: Set<String>
        let maximumEntries: Int
        let maximumSeconds: Double
        let started = DispatchTime.now().uptimeNanoseconds
        var entries = 0
        var complete = true
        var items: [Item] = []

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
                entries += 1
                if Task.isCancelled || entries > max(0, maximumEntries)
                    || Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9 >= maximumSeconds {
                    complete = false
                    return
                }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }   // removed while the walk ran
                    complete = false
                    return
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    // Codex nests rollouts as YYYY/MM/DD; deeper folders are not its own.
                    guard depth < 3 else { continue }
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { complete = false; return }
                    let safe = Self.safe(child)
                    if safe { visit(child, path: path + "/" + name, depth: depth + 1) } else { complete = false }
                    close(child)
                    if !complete { return }
                } else if let id = CodexDataInventory.rolloutID(name), wanted.contains(id) {
                    // Whatever its type, an entry with the target's rollout name is the target's.
                    items.append(Item(relativePath: path + "/" + name, bytes: Int64(info.st_size)))
                }
            }
        }

        private static func safe(_ fd: Int32) -> Bool { CodexDataInventory.safeDirectory(fd) }
    }

    private static func indexRecords(_ root: Int32, wanted: Set<String>, maximumBytes: Int) throws -> Int {
        let fd = openat(root, indexName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return 0 }
            throw CodexDataError.indexUnreadable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maximumBytes else { throw CodexDataError.indexUnreadable }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var filled = 0
        while filled < bytes.count {
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + filled, $0.count - filled, off_t(filled)) }
            if count < 0 { throw CodexDataError.indexUnreadable }
            if count == 0 { break }
            filled += count
        }
        var records = 0
        for line in bytes[..<filled].split(separator: 0x0A) {
            // Parsed, never matched as text: the record is the target's only when its own top-level id is.
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let text = object["id"] as? String, let id = UUID(uuidString: text) else { continue }
            if wanted.contains(id.uuidString.lowercased()) { records += 1 }
        }
        return records
    }

    private static func exists(_ root: Int32, _ relative: String) -> Bool {
        var info = stat()
        return fstatat(root, relative, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    static func safeDirectory(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o022 == 0
    }
}
