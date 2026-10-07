import Darwin
import Foundation
import Synchronization

/// A private CLI capability, never a conversation identity authority.
struct ClaudeRegistrySnapshot: Sendable, Equatable {
    let sessionID: String
    let startedAt: Double
    let status: String?
    let statusUpdatedAt: Double?
}

enum ClaudeRegistryRead: Sendable {
    case snapshot(ClaudeRegistrySnapshot)
    case missing
    case unavailable
}

struct ClaudeRegistryReader: Sendable {
    let config: URL
    let leader: ProcessIdentity
    let directory: String
    static let maximumBytes = 16 * 1024

    func read(now: Date = Date()) -> ClaudeRegistryRead {
        guard let process = ProcessTable.record(pid: leader.pid), process.identity == leader,
              process.userID == getuid(), !process.zombie else { return .unavailable }
        let root = open(config.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return errno == ENOENT ? .missing : .unavailable }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { return .unavailable }
        let folder = openat(root, "sessions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return errno == ENOENT ? .missing : .unavailable }
        defer { close(folder) }
        guard fstat(folder, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { return .unavailable }
        let fd = openat(folder, "\(leader.pid).json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .unavailable }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0,
              info.st_size > 0, info.st_size <= Self.maximumBytes else { return .unavailable }
        var bytes = [UInt8](repeating: 0, count: Self.maximumBytes + 1)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count <= Self.maximumBytes else { return .unavailable }
        return decode(Data(bytes.prefix(count)), now: now)
    }

    /// Identity of the registry file's current version, or nil while it does not
    /// exist. Equal values mean a vnode notification changed nothing we read.
    struct FileFingerprint: Equatable, Sendable {
        let inode: UInt64
        let seconds: Int
        let nanoseconds: Int
        let size: Int64
    }

    func fingerprint() -> FileFingerprint? {
        var info = stat()
        let path = config.appendingPathComponent("sessions/\(leader.pid).json").path
        guard lstat(path, &info) == 0 else { return nil }
        return FileFingerprint(inode: UInt64(info.st_ino), seconds: info.st_mtimespec.tv_sec,
                               nanoseconds: info.st_mtimespec.tv_nsec, size: Int64(info.st_size))
    }

    func decode(_ data: Data, now: Date) -> ClaudeRegistryRead {
        guard data.count <= Self.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["pidDomain"] as? String == "darwin", object["kind"] as? String == "interactive",
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/"),
              object["pid"] == nil || number(object["pid"]) == Double(leader.pid),
              URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path == directory,
              let session = object["sessionId"] as? String, !session.isEmpty,
              let started = number(object["startedAt"]),
              started >= Double(leader.startSeconds) * 1_000,
              started <= now.timeIntervalSince1970 * 1_000,
              let birth = object["procStart"] as? String else { return .unavailable }
        guard let date = ClaudeRegistryFields.processStart(birth),
              Int64(date.timeIntervalSince1970) == leader.startSeconds else { return .unavailable }
        let status = object["status"] as? String
        guard object["status"] == nil || object["status"] is NSNull || status != nil else { return .unavailable }
        guard status == nil || ["idle", "busy", "waiting"].contains(status!) else { return .unavailable }
        let updated = number(object["statusUpdatedAt"])
        guard status == nil || updated != nil else { return .unavailable }
        return .snapshot(ClaudeRegistrySnapshot(sessionID: session, startedAt: started,
            status: status, statusUpdatedAt: updated))
    }

    private func number(_ value: Any?) -> Double? { ClaudeRegistryFields.number(value) }
}

/// Field parsing shared by everything that reads Claude's `sessions/<pid>.json`
/// (the registry reader and the deletion inventory), so the two cannot disagree.
enum ClaudeRegistryFields {
    // DateFormatter parsing is thread-safe once configured; the lock keeps the
    // shared instance from ever being used concurrently anyway.
    private static let procStartLock = NSLock()
    nonisolated(unsafe) private static let procStartFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        // Claude obtains procStart with LC_ALL=C, TZ=UTC ps lstart.
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return format
    }()

    /// The process start time Claude recorded (`procStart`), nil when unreadable.
    static func processStart(_ text: String) -> Date? {
        procStartLock.lock()
        defer { procStartLock.unlock() }
        return procStartFormat.date(from: text)
    }

    /// A finite, non-negative JSON number. A boolean is not a number (NSNumber
    /// would read `true` as 1, which is pid 1).
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
        return value.doubleValue
    }
}

/// At most four vnode descriptors and one pending bounded read. Notifications
/// coalesce into full snapshots; no idle timer or process/CLI polling is used.
final class ClaudeRegistryWatch: @unchecked Sendable {
    private struct Seen { var fingerprint: ClaudeRegistryReader.FileFingerprint? }
    let id = UUID()
    private let reader: ClaudeRegistryReader
    private let queue = DispatchQueue(label: "loom.claude.registry", qos: .utility)
    private let state = Mutex<(stopped: Bool, queued: Bool, generation: UUID?, explicit: Bool)>((false, false, nil, false))
    // Version of the file behind the last delivered stable result (queue-confined).
    private var lastRead: Seen?
    // Reads/attaches counted for tests: vnode noise must not cost reads.
    private let reads = Mutex(0)
    var readCount: Int { reads.withLock { $0 } }
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private let deliver: @Sendable (UUID, UUID?, ClaudeRegistryRead) -> Void

    init(reader: ClaudeRegistryReader, deliver: @escaping @Sendable (UUID, UUID?, ClaudeRegistryRead) -> Void) {
        self.reader = reader
        self.deliver = deliver
        request(generation: nil)
    }

    func request(generation: UUID?) {
        let enqueue = state.withLock { value in
            guard !value.stopped else { return false }
            value.generation = generation
            value.explicit = true
            guard !value.queued else { return false }
            value.queued = true
            return true
        }
        if enqueue {
            queue.async { [weak self] in
                self?.state.withLock { $0.queued = false }
                self?.scheduleRead()
            }
        }
    }

    func stop() {
        state.withLock { $0.stopped = true; $0.generation = nil }
        queue.async { [weak self] in
            self?.pending?.cancel(); self?.pending = nil
            self?.sources.values.forEach { $0.cancel() }; self?.sources.removeAll()
        }
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// The parent is watched only until the config directory exists, and the
    /// config directory only until `sessions` does: a busy `~` must not wake us.
    private func attach() {
        let config = reader.config
        let sessions = config.appendingPathComponent("sessions").path
        let sessionsExist = Self.exists(sessions)
        let configExists = sessionsExist || Self.exists(config.path)
        var paths = [config.appendingPathComponent("sessions/\(reader.leader.pid).json").path]
        if sessionsExist { paths.append(sessions) }
        else if configExists { paths.append(config.path) }
        else { paths.append(config.deletingLastPathComponent().path) }
        for (path, source) in sources where !paths.contains(path) {
            source.cancel(); sources[path] = nil
        }
        for path in paths where sources[path] == nil {
            let fd = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .revoke], queue: queue)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    self.sources[path] = nil; source.cancel()
                }
                self.scheduleRead(vnode: true)
            }
            sources[path] = source
            source.resume()
        }
    }

    private func scheduleRead(vnode: Bool = false) {
        guard !state.withLock({ $0.stopped }) else { return }
        attach()
        // A hook-driven request always reads; a vnode notification reads only
        // when the registry file is not the version already delivered.
        let explicit = state.withLock { value in
            defer { value.explicit = false }
            return value.explicit || !vnode
        }
        guard pending == nil else { return }
        let seen = reader.fingerprint()
        if !explicit, let lastRead, lastRead.fingerprint == seen { return }
        read(attempt: 0, generation: state.withLock { $0.generation }, seen: seen)
    }

    private func read(attempt: Int, generation: UUID?, seen: ClaudeRegistryReader.FileFingerprint?) {
        let generation = state.withLock { $0.generation }
        guard !state.withLock({ $0.stopped }) else { return }
        reads.withLock { $0 += 1 }
        let result = reader.read()
        if case let .snapshot(snapshot) = result, snapshot.status != nil || generation == nil {
            lastRead = Seen(fingerprint: seen)
            pending = nil; deliver(id, generation, result); return
        }
        if attempt < 2 {
            let work = DispatchWorkItem { [weak self] in self?.pending = nil; self?.read(attempt: attempt + 1, generation: generation, seen: seen) }
            pending = work
            queue.asyncAfter(deadline: .now() + (attempt == 0 ? 0.02 : 0.1), execute: work)
        } else {
            switch result {
            case .unavailable: lastRead = nil
            case .snapshot, .missing: lastRead = Seen(fingerprint: seen)
            }
            pending = nil; deliver(id, generation, result)
        }
    }

    deinit { sources.values.forEach { $0.cancel() }; pending?.cancel() }
}
