import Darwin
import Foundation

// Pure filesystem component (CP4-A, default scope of DP-CP4-1): plans and performs the
// deletion of exactly the named Claude sessions' local files. No UI, no catalog access.
// Every traversal is descriptor-relative with O_NOFOLLOW, stays on one device and never
// follows a symlink; a symlink is removed as a link.

public enum ClaudeDataError: Error, Equatable, Sendable {
    case invalidSessionID(String)
    case unsafeDirectory(String)
    /// A live Claude process holds this session (lowercase id).
    case liveSession(String)
    case sessionRegistryUnreadable
}

public struct DeletionPlan: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case transcript, transcriptVariant, conversationFolder, fileHistory, sessionEnvironment
        case debugLog, taskList, imageCache, upload, legacyTodo
        /// Tier 2, outside the config directory.
        case temporaryOutput
    }

    public struct Item: Sendable, Equatable, Hashable {
        public let sessionID: String
        public let kind: Kind
        /// Relative to the config directory (or, for tier 2, to the temporary root).
        public let relativePath: String
        /// Bytes of the file, or of everything inside a folder; a symlink counts its own size.
        public let byteSize: Int64
        public let isSymbolicLink: Bool
    }

    /// Normalized (lowercase) session ids.
    public let sessionIDs: [String]
    /// Real path of the config directory the plan was made for.
    public let configDirectory: String
    public let temporaryRoot: String?
    public let items: [Item]
    /// Tier 2: reported separately from `items`.
    public let temporaryItems: [Item]
    /// Existing entries that deletion never touches, relative to the config directory.
    public let residual: [String]
    public var totalBytes: Int64 { (items + temporaryItems).reduce(0) { $0 + $1.byteSize } }
}

public struct DeletionResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case removed
        /// Already gone: counts as done.
        case alreadyAbsent
        case failed(code: Int32, reason: String)
        /// Nothing was attempted because the whole operation was refused.
        case refused
    }

    public struct Entry: Sendable, Equatable {
        public let item: DeletionPlan.Item
        public let outcome: Outcome
    }

    public let entries: [Entry]
    /// Set when nothing was deleted: live session, unsafe or swapped directory.
    public let refusal: ClaudeDataError?
    public var isComplete: Bool {
        refusal == nil && !entries.contains { if case .failed = $0.outcome { return true }; return false }
    }
}

public enum ClaudeDataInventory {
    public static var defaultTemporaryRoot: URL { URL(fileURLWithPath: "/private/tmp/claude-\(getuid())") }

    /// Throws for a non-UUID id, an unsafe config directory or a live session holding an id.
    /// `temporaryRoot` nil skips tier 2.
    public static func plan(sessionIDs: [String], configDirectory: URL,
                            temporaryRoot: URL? = defaultTemporaryRoot) throws -> DeletionPlan {
        let ids = try ClaudeDataFiles.normalize(sessionIDs)
        let root = try ClaudeDataFiles.openRoot(configDirectory.path)
        defer { close(root.fd) }
        if let live = try ClaudeDataFiles.liveSession(root: root.fd, ids: Set(ids)) { throw ClaudeDataError.liveSession(live) }
        let scan = ClaudeDataFiles.scan(ids: Set(ids), config: root, temporaryRoot: temporaryRoot?.path)
        return DeletionPlan(sessionIDs: ids, configDirectory: root.path, temporaryRoot: scan.temporaryRoot,
                            items: scan.items, temporaryItems: scan.temporaryItems, residual: scan.residual)
    }
}

public enum ClaudeDataDeleter {
    /// Removes the planned items, re-validating every one; never throws. Absent items count as
    /// done, one failing item does not stop the others, and a re-run finishes what is left.
    public static func execute(_ plan: DeletionPlan) -> DeletionResult {
        let all = plan.items.map { ($0, false) } + plan.temporaryItems.map { ($0, true) }
        func refused(_ error: ClaudeDataError) -> DeletionResult {
            DeletionResult(entries: all.map { .init(item: $0.0, outcome: .refused) }, refusal: error)
        }
        guard let ids = try? ClaudeDataFiles.normalize(plan.sessionIDs) else {
            return refused(.invalidSessionID(plan.sessionIDs.joined(separator: ",")))
        }
        guard let config = try? ClaudeDataFiles.openRoot(plan.configDirectory), config.path == plan.configDirectory else {
            return refused(.unsafeDirectory(plan.configDirectory))
        }
        defer { close(config.fd) }
        do {
            if let live = try ClaudeDataFiles.liveSession(root: config.fd, ids: Set(ids)) { return refused(.liveSession(live)) }
        } catch let error as ClaudeDataError {
            return refused(error)
        } catch { return refused(.sessionRegistryUnreadable) }
        var temporary: ClaudeDataFiles.Root?
        if let path = plan.temporaryRoot, !plan.temporaryItems.isEmpty {
            if let root = try? ClaudeDataFiles.openRoot(path), root.path == path { temporary = root }
        }
        defer { if let temporary { close(temporary.fd) } }
        let entries = all.map { item, isTemporary -> DeletionResult.Entry in
            let root = isTemporary ? temporary : config
            guard let root else {
                // A temporary root that no longer opens: ENOENT means nothing is left to remove.
                var info = stat()
                let gone = plan.temporaryRoot.map { lstat($0, &info) != 0 && errno == ENOENT } ?? true
                return .init(item: item, outcome: gone ? .alreadyAbsent : .failed(code: EACCES, reason: "temporary root is not usable"))
            }
            return .init(item: item, outcome: ClaudeDataFiles.remove(item, ids: Set(ids), root: root, temporary: isTemporary))
        }
        return DeletionResult(entries: entries, refusal: nil)
    }

    /// What is still claimable for these sessions (empty when deletion is complete).
    /// Does not check for live sessions.
    public static func verify(sessionIDs: [String], configDirectory: URL,
                              temporaryRoot: URL? = ClaudeDataInventory.defaultTemporaryRoot) throws -> [DeletionPlan.Item] {
        let ids = try ClaudeDataFiles.normalize(sessionIDs)
        let root = try ClaudeDataFiles.openRoot(configDirectory.path)
        defer { close(root.fd) }
        let scan = ClaudeDataFiles.scan(ids: Set(ids), config: root, temporaryRoot: temporaryRoot?.path)
        return scan.items + scan.temporaryItems
    }
}

/// Descriptor-level helpers; the claim rules live here so planning and execution cannot disagree.
enum ClaudeDataFiles {
    struct Root { let fd: Int32; let device: dev_t; let path: String }

    static let maximumDepth = 64
    static let maximumRegistryBytes = 64 * 1024
    /// Existing top-level entries that are listed as "not removed".
    static let protectedNames = ["history.jsonl", "paste-cache", "plans", "shell-snapshots", "backups",
                                 ".claude.json", "sessions", "jobs", "daemon"]

    // MARK: ids and names

    static func normalize(_ ids: [String]) throws -> [String] {
        var result: [String] = []
        for id in ids {
            guard isUUID(id) else { throw ClaudeDataError.invalidSessionID(id) }
            let lower = id.lowercased()
            if !result.contains(lower) { result.append(lower) }
        }
        return result
    }

    private static func isUUID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) { if byte != UInt8(ascii: "-") { return false } }
            else if !(byte >= 48 && byte <= 57 || byte >= 65 && byte <= 70 || byte >= 97 && byte <= 102) { return false }
        }
        return true
    }

    /// The id a name belongs to: it equals the id or starts with `<id>.` or `<id>-`
    /// (case-insensitive). A name that merely contains an id elsewhere matches nothing.
    static func owner(of name: String, ids: Set<String>) -> String? {
        guard name.utf8.count >= 36 else { return nil }
        let lower = name.lowercased()
        let id = String(lower.prefix(36))
        guard ids.contains(id) else { return nil }
        let rest = lower.dropFirst(36)
        return rest.isEmpty || rest.hasPrefix(".") || rest.hasPrefix("-") ? id : nil
    }

    private static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Kind of a claimed entry, or nil when the path is not claimable for `id`.
    static func classify(_ components: [String], id: String, temporary: Bool) -> DeletionPlan.Kind? {
        guard !components.isEmpty, components.allSatisfy(validComponent) else { return nil }
        let name = components[components.count - 1].lowercased()
        let exact = name == id
        let owned = exact || name.hasPrefix(id + ".") || name.hasPrefix(id + "-")
        if temporary { return components.count == 2 && exact ? .temporaryOutput : nil }
        switch (components.count, components[0]) {
        case (3, "projects"):
            if name == id + ".jsonl" { return .transcript }
            if name.hasPrefix(id + ".orphaned-") && name.hasSuffix(".jsonl") { return .transcriptVariant }
            if name.hasPrefix(id + ".jsonl.superseded-") { return .transcriptVariant }
            return exact ? .conversationFolder : nil
        case (2, "file-history"): return exact ? .fileHistory : nil
        case (2, "session-env"): return exact ? .sessionEnvironment : nil
        case (2, "debug"): return owned ? .debugLog : nil
        case (2, "tasks"): return exact ? .taskList : nil
        case (2, "image-cache"): return exact ? .imageCache : nil
        case (2, "uploads"): return exact ? .upload : nil
        case (2, "todos"): return name.hasPrefix(id + "-agent-") && name.hasSuffix(".json") ? .legacyTodo : nil
        default: return nil
        }
    }

    // MARK: directories

    /// A directory is opened only when it is owned by the user and not group/world writable,
    /// as `ClaudeRegistryReader` requires, after resolving the path (the leaf never as a link).
    static func openRoot(_ path: String) throws -> Root {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { throw ClaudeDataError.unsafeDirectory(path) }
        let real = String(cString: resolved)
        free(resolved)
        let fd = open(real, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClaudeDataError.unsafeDirectory(real) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(fd)
            throw ClaudeDataError.unsafeDirectory(real)
        }
        return Root(fd: fd, device: info.st_dev, path: real)
    }

    /// A directory child on the same device, never through a symlink; nil otherwise.
    private static func openDirectory(_ parent: Int32, _ name: String, device: dev_t) -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device else { close(fd); return nil }
        return fd
    }

    /// Entry names (valid UTF-8 only). Consumes `fd`.
    private static func list(_ fd: Int32) -> [String] {
        guard let stream = fdopendir(fd) else { close(fd); return [] }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            if let name, name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private static func entryInfo(_ parent: Int32, _ name: String) -> stat? {
        var info = stat()
        return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? info : nil
    }

    /// Bytes of regular files under a directory; links and other entries count their own size.
    private static func treeSize(_ fd: Int32, device: dev_t, depth: Int) -> Int64 {
        guard depth < maximumDepth else { close(fd); return 0 }
        var total: Int64 = 0
        let parent = fd
        let names = list(dup(fd))
        defer { close(parent) }
        for name in names {
            guard let info = entryInfo(parent, name) else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                if let child = openDirectory(parent, name, device: device) { total += treeSize(child, device: device, depth: depth + 1) }
            } else { total += Int64(info.st_size) }
        }
        return total
    }

    private static func item(_ parent: Int32, _ name: String, _ path: [String], id: String,
                             kind: DeletionPlan.Kind, device: dev_t) -> DeletionPlan.Item? {
        guard let info = entryInfo(parent, name) else { return nil }
        var size = Int64(info.st_size)
        if info.st_mode & S_IFMT == S_IFDIR {
            size = openDirectory(parent, name, device: device).map { treeSize($0, device: device, depth: 0) } ?? 0
        }
        return DeletionPlan.Item(sessionID: id, kind: kind, relativePath: path.joined(separator: "/"),
                                 byteSize: size, isSymbolicLink: info.st_mode & S_IFMT == S_IFLNK)
    }

    // MARK: scan

    struct Scan {
        var items: [DeletionPlan.Item] = []
        var temporaryItems: [DeletionPlan.Item] = []
        var residual: [String] = []
        var temporaryRoot: String?
    }

    static func scan(ids: Set<String>, config: Root, temporaryRoot: String?) -> Scan {
        var scan = Scan()
        func claim(_ parent: Int32, _ directory: [String], device: dev_t, temporary: Bool) -> [DeletionPlan.Item] {
            var found: [DeletionPlan.Item] = []
            for name in list(dup(parent)) {
                guard let id = owner(of: name, ids: ids) else { continue }
                let path = directory + [name]
                guard let kind = classify(path, id: id, temporary: temporary),
                      let entry = item(parent, name, path, id: id, kind: kind, device: device) else { continue }
                found.append(entry)
            }
            return found
        }
        if let projects = openDirectory(config.fd, "projects", device: config.device) {
            for project in list(dup(projects)) {
                guard validComponent(project), let folder = openDirectory(projects, project, device: config.device) else { continue }
                scan.items += claim(folder, ["projects", project], device: config.device, temporary: false)
                if entryInfo(folder, "memory") != nil { scan.residual.append("projects/\(project)/memory") }
                close(folder)
            }
            close(projects)
        }
        for name in ["file-history", "session-env", "debug", "tasks", "image-cache", "uploads", "todos"] {
            guard let folder = openDirectory(config.fd, name, device: config.device) else { continue }
            scan.items += claim(folder, [name], device: config.device, temporary: false)
            close(folder)
        }
        for name in protectedNames where entryInfo(config.fd, name) != nil { scan.residual.append(name) }
        scan.items.sort { $0.relativePath < $1.relativePath }
        scan.residual.sort()
        if let temporaryRoot, let root = try? openRoot(temporaryRoot) {
            scan.temporaryRoot = root.path
            for middle in list(dup(root.fd)) {
                guard validComponent(middle), let folder = openDirectory(root.fd, middle, device: root.device) else { continue }
                scan.temporaryItems += claim(folder, [middle], device: root.device, temporary: true)
                    .filter { entryInfo(folder, URL(fileURLWithPath: $0.relativePath).lastPathComponent)?.st_uid == getuid() }
                close(folder)
            }
            close(root.fd)
            scan.temporaryItems.sort { $0.relativePath < $1.relativePath }
        }
        return scan
    }

    // MARK: live sessions

    private static let startFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return format
    }()

    /// The id of a session held by a live process according to `sessions/*.json`, if any.
    /// A recorded start time that is not the process's means a reused pid (stale file);
    /// without one the file counts as live.
    static func liveSession(root: Int32, ids: Set<String>) throws -> String? {
        let fd = openat(root, "sessions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ClaudeDataError.sessionRegistryUnreadable
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(fd)
            throw ClaudeDataError.sessionRegistryUnreadable
        }
        let folder = fd
        defer { close(folder) }
        for name in list(dup(folder)) where name.hasSuffix(".json") {
            let file = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { continue }
            defer { close(file) }
            var attributes = stat()
            guard fstat(file, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
                  attributes.st_size > 0, attributes.st_size <= maximumRegistryBytes else { continue }
            var bytes = [UInt8](repeating: 0, count: maximumRegistryBytes + 1)
            let count = Darwin.read(file, &bytes, bytes.count)
            guard count > 0, count <= maximumRegistryBytes,
                  let object = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any],
                  let session = (object["sessionId"] as? String)?.lowercased(), ids.contains(session) else { continue }
            let pid = (object["pid"] as? NSNumber)?.int32Value ?? Int32(name.dropLast(5))
            guard let pid, pid > 0, let process = ProcessTable.record(pid: pid), !process.zombie else { continue }
            if let started = object["procStart"] as? String, let date = startFormat.date(from: started),
               Int64(date.timeIntervalSince1970) != process.identity.startSeconds { continue }
            return session
        }
        return nil
    }

    // MARK: removal

    static func remove(_ item: DeletionPlan.Item, ids: Set<String>, root: Root, temporary: Bool) -> DeletionResult.Outcome {
        let components = item.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard ids.contains(item.sessionID), classify(components, id: item.sessionID, temporary: temporary) == item.kind,
              owner(of: components[components.count - 1], ids: ids) == item.sessionID else {
            return .failed(code: EINVAL, reason: "not a claimed path of this session")
        }
        // Walk to the parent through real directories on the root's device only.
        var parent = dup(root.fd)
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(parent)
            guard next >= 0 else { return code == ENOENT ? .alreadyAbsent : .failed(code: code, reason: "cannot open \(component)") }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_dev == root.device else { close(next); return .failed(code: EXDEV, reason: "other device") }
            parent = next
        }
        defer { close(parent) }
        let name = components[components.count - 1]
        guard let info = entryInfo(parent, name) else {
            return errno == ENOENT ? .alreadyAbsent : .failed(code: errno, reason: "cannot inspect \(name)")
        }
        if temporary, info.st_uid != getuid() { return .failed(code: EPERM, reason: "not owned by this user") }
        let code = info.st_mode & S_IFMT == S_IFDIR
            ? removeTree(parent, name, device: root.device, depth: 0)
            : (unlinkat(parent, name, 0) == 0 ? 0 : errno)
        return code == 0 || code == ENOENT ? .removed : .failed(code: code, reason: String(cString: strerror(code)))
    }

    /// Removes a directory and everything in it; links are unlinked, never followed.
    /// Returns 0 or the first errno.
    private static func removeTree(_ parent: Int32, _ name: String, device: dev_t, depth: Int) -> Int32 {
        guard depth < maximumDepth else { return ENAMETOOLONG }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            // Replaced by a link or file since the check: unlink what is there.
            let code = errno
            return code == ENOENT ? 0 : (code == ENOTDIR || code == ELOOP ? (unlinkat(parent, name, 0) == 0 ? 0 : errno) : code)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device else { close(fd); return EXDEV }
        var failure: Int32 = 0
        for child in list(dup(fd)) {
            guard let entry = entryInfo(fd, child) else { continue }
            let code = entry.st_mode & S_IFMT == S_IFDIR
                ? removeTree(fd, child, device: device, depth: depth + 1)
                : (unlinkat(fd, child, 0) == 0 || errno == ENOENT ? 0 : errno)
            if code != 0, failure == 0 { failure = code }
        }
        close(fd)
        if unlinkat(parent, name, AT_REMOVEDIR) != 0, errno != ENOENT, failure == 0 { failure = errno }
        return failure
    }
}
