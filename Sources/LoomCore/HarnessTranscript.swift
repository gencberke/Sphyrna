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
}

public enum CodexRolloutLocator {
    /// A bounded walk through the three date directories. Only an exact UUID filename and matching session_meta qualify.
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

        let started = DispatchTime.now().uptimeNanoseconds
        var entries = 0
        var complete = true
        var files: [String: CodexRolloutFile] = [:]
        var ambiguous: Set<String> = []
        func visit(_ descriptor: Int32, path: String, depth: Int) {
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
                    if safeDirectory(child) { visit(child, path: path + "/" + name, depth: depth + 1) }
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
                        && info.st_uid == getuid() && matchesHeader(file, id: id)
                    close(file)
                    guard matches else { continue }
                    if files[id] != nil { files[id] = nil; ambiguous.insert(id) }
                    else { files[id] = CodexRolloutFile(path: path + "/" + name, sessionID: id) }
                }
            }
        }
        visit(sessions, path: home.appendingPathComponent("sessions", isDirectory: true).path, depth: 0)
        // A partial walk cannot rule out another file with the same UUID.
        return CodexRolloutLookup(files: complete ? files : [:], complete: complete)
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
