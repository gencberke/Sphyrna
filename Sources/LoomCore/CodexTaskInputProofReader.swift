import CryptoKit
import Darwin
import Dispatch
import Foundation

/// A single, fresh rollout named by this run's owned thread/started event.
/// This is not a transcript reader: no directory walk, tail polling, or history
/// replay is permitted, and only an exact first-input record is considered.
struct CodexTaskInputProofCandidate: Equatable, Sendable {
    let home: URL
    let directories: [String]
    let filename: String
    let threadID: String
    let workingDirectory: String
    let clientMessageID: String
}

struct CodexTaskInputProof: Sendable {
    fileprivate let candidate: CodexTaskInputProofCandidate
    fileprivate let stamp: CodexTaskFileStamp
}

fileprivate struct CodexTaskFileStamp: Sendable {
    let device: dev_t, inode: ino_t, mode: mode_t, uid: uid_t, links: nlink_t, size: off_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    let birthSeconds: Int, birthNanos: Int
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; mode = info.st_mode; uid = info.st_uid
        links = info.st_nlink; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        birthSeconds = info.st_birthtimespec.tv_sec; birthNanos = info.st_birthtimespec.tv_nsec
    }
    func matches(_ info: stat) -> Bool {
        device == info.st_dev && inode == info.st_ino && mode == info.st_mode && uid == info.st_uid &&
            links == info.st_nlink && size == info.st_size &&
            modifiedSeconds == info.st_mtimespec.tv_sec && modifiedNanos == info.st_mtimespec.tv_nsec &&
            changedSeconds == info.st_ctimespec.tv_sec && changedNanos == info.st_ctimespec.tv_nsec &&
            birthSeconds == info.st_birthtimespec.tv_sec && birthNanos == info.st_birthtimespec.tv_nsec
    }
}

enum CodexTaskInputProofReader {
    static let byteLimit = 256 * 1024
    static let lineLimit = 512
    private static let lineByteLimit = 64 * 1024
    private static let timeLimit: UInt64 = 500_000_000

    /// Capture only an absent prospective file before sending the input. A
    /// present, inaccessible, or nonconforming path disables this fallback.
    static func prepare(home: URL, path: String, threadID: String, workingDirectory: String,
                        clientMessageID: String) -> CodexTaskInputProofCandidate? {
        guard home.isFileURL, path.hasPrefix("/"), workingDirectory.hasPrefix("/"),
              let threadUUID = UUID(uuidString: threadID),
              !clientMessageID.isEmpty, clientMessageID.utf8.count <= 256,
              !clientMessageID.utf8.contains(0),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return nil }
        let root = home.standardizedFileURL
        let base = root.pathComponents, parts = URL(fileURLWithPath: path).pathComponents
        guard parts.starts(with: base), parts.count == base.count + 5 else { return nil }
        let rest = Array(parts.dropFirst(base.count))
        guard rest[0] == "sessions", digits(rest[1], count: 4), digits(rest[2], count: 2),
              digits(rest[3], count: 2), rest[4].hasPrefix("rollout-"), rest[4].utf8.count <= 255,
              !rest[4].utf8.contains(0), rest[4].lowercased().hasSuffix("-" + threadUUID.uuidString.lowercased() + ".jsonl") else { return nil }
        let candidate = CodexTaskInputProofCandidate(home: root, directories: Array(rest.prefix(4)), filename: rest[4],
            threadID: threadUUID.uuidString.lowercased(), workingDirectory: workingDirectory, clientMessageID: clientMessageID)
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard safeDirectory(fd) else { return nil }
        for component in candidate.directories {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 { return errno == ENOENT ? candidate : nil }
            guard safeDirectory(next) else { close(next); return nil }
            close(fd); fd = next
        }
        var info = stat()
        guard fstatat(fd, candidate.filename, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { return nil }
        return candidate
    }

    /// Read one bounded snapshot, off the runtime actor. The caller must still
    /// revalidate its current run, operation, admission and ingress afterward.
    static func proves(_ candidate: CodexTaskInputProofCandidate, nativeTurnID: String, digest: Data) -> Bool {
        proof(candidate, nativeTurnID: nativeTurnID, digest: digest) != nil
    }

    static func proof(_ candidate: CodexTaskInputProofCandidate, nativeTurnID: String, digest: Data) -> CodexTaskInputProof? {
        guard !nativeTurnID.isEmpty, nativeTurnID.utf8.count <= 256, !nativeTurnID.utf8.contains(0), digest.count == 32 else {
            return nil
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var chain: [Int32] = []
        defer { for fd in chain.reversed() { close(fd) } }
        let root = open(candidate.home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return nil }
        chain.append(root)
        guard safeDirectory(root) else { return nil }
        for component in candidate.directories {
            let child = openat(chain.last!, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return nil }
            chain.append(child)
            guard safeDirectory(child) else { return nil }
        }
        let parent = chain.last!
        let file = openat(parent, candidate.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_mode & 0o022 == 0, before.st_nlink == 1,
              before.st_size > 0, before.st_size <= Int64(byteLimit) else { return nil }
        var data = Data(count: Int(before.st_size))
        let count = data.withUnsafeMutableBytes { bytes in pread(file, bytes.baseAddress, bytes.count, 0) }
        guard count == data.count, data.last == 0x0a else { return nil }
        var after = stat(), named = stat(), rootNamed = stat(), rootOpened = stat()
        guard fstat(file, &after) == 0, sameFile(before, after),
              fstatat(parent, candidate.filename, &named, AT_SYMLINK_NOFOLLOW) == 0, sameFile(before, named),
              lstat(candidate.home.path, &rootNamed) == 0, fstat(root, &rootOpened) == 0,
              sameIdentity(rootNamed, rootOpened) else { return nil }
        for index in candidate.directories.indices {
            var opened = stat(), entry = stat()
            guard fstat(chain[index + 1], &opened) == 0,
                  fstatat(chain[index], candidate.directories[index], &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  sameIdentity(opened, entry) else { return nil }
        }
        let lines = data.split(separator: 0x0a, omittingEmptySubsequences: false)
        guard lines.count >= 2, lines.count - 1 <= lineLimit, lines.last?.isEmpty == true else { return nil }
        var sawHeader = false, sawBoundary = false, sawInput = false
        for line in lines.dropLast() {
            guard !line.isEmpty, line.count <= lineByteLimit,
                  DispatchTime.now().uptimeNanoseconds &- started <= timeLimit,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { return nil }
            if !sawHeader {
                guard type == "session_meta", let id = payload["id"] as? String,
                      UUID(uuidString: id)?.uuidString.lowercased() == candidate.threadID,
                      let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"),
                      canonical(cwd) == canonical(candidate.workingDirectory) else { return nil }
                sawHeader = true
                continue
            }
            guard type == "event_msg", let kind = payload["type"] as? String else { continue }
            if kind == "task_started" || kind == "turn_started" {
                guard !sawBoundary, !sawInput, payload["turn_id"] as? String == nativeTurnID else { return nil }
                sawBoundary = true
            } else if kind == "user_message" {
                guard sawBoundary, !sawInput, legacyInput(payload, clientID: candidate.clientMessageID, digest: digest) else { return nil }
                sawInput = true
            } else if kind == "item_completed", let item = payload["item"] as? [String: Any],
                      item["type"] as? String == "UserMessage" {
                guard sawBoundary, !sawInput, payload["thread_id"] as? String == candidate.threadID,
                      payload["turn_id"] as? String == nativeTurnID,
                      paginatedInput(item, clientID: candidate.clientMessageID, digest: digest) else { return nil }
                sawInput = true
            }
        }
        guard sawHeader && sawBoundary && sawInput else { return nil }
        var final = stat(), finalNamed = stat()
        guard fstat(file, &final) == 0, sameFile(before, final),
              fstatat(parent, candidate.filename, &finalNamed, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(before, finalNamed) else { return nil }
        return CodexTaskInputProof(candidate: candidate, stamp: CodexTaskFileStamp(before))
    }

    /// A metadata-only post-join fence. Any intervening write or path change
    /// invalidates the proof; there is no retry, polling or second history read.
    static func remainsCurrent(_ proof: CodexTaskInputProof) -> Bool {
        let candidate = proof.candidate
        var chain: [Int32] = []
        defer { for fd in chain.reversed() { close(fd) } }
        let root = open(candidate.home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return false }
        chain.append(root)
        guard safeDirectory(root) else { return false }
        for component in candidate.directories {
            let child = openat(chain.last!, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return false }
            chain.append(child)
            guard safeDirectory(child) else { return false }
        }
        let parent = chain.last!
        let file = openat(parent, candidate.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return false }
        defer { close(file) }
        var opened = stat(), named = stat(), rootOpened = stat(), rootNamed = stat()
        guard fstat(file, &opened) == 0, proof.stamp.matches(opened),
              fstatat(parent, candidate.filename, &named, AT_SYMLINK_NOFOLLOW) == 0, proof.stamp.matches(named),
              fstat(root, &rootOpened) == 0, lstat(candidate.home.path, &rootNamed) == 0,
              sameIdentity(rootOpened, rootNamed) else { return false }
        for index in candidate.directories.indices {
            var child = stat(), entry = stat()
            guard fstat(chain[index + 1], &child) == 0,
                  fstatat(chain[index], candidate.directories[index], &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  sameIdentity(child, entry) else { return false }
        }
        return true
    }

    private static func legacyInput(_ payload: [String: Any], clientID: String, digest: Data) -> Bool {
        let allowed: Set<String> = ["type", "client_id", "message", "images", "local_images", "audio", "local_audio", "text_elements"]
        guard Set(payload.keys).isSubset(of: allowed), payload["client_id"] as? String == clientID,
              let text = payload["message"] as? String,
              ["images", "local_images", "audio", "local_audio", "text_elements"].allSatisfy({ emptyArray(payload[$0]) }) else {
            return false
        }
        return Data(SHA256.hash(data: Data(text.utf8))) == digest
    }

    private static func paginatedInput(_ item: [String: Any], clientID: String, digest: Data) -> Bool {
        guard Set(item.keys).isSubset(of: ["type", "id", "client_id", "content"]),
              let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
              item["client_id"] as? String == clientID, let content = item["content"] as? [[String: Any]],
              content.count == 1, Set(content[0].keys).isSubset(of: ["type", "text", "text_elements"]),
              content[0]["type"] as? String == "text", emptyArray(content[0]["text_elements"]),
              let text = content[0]["text"] as? String else { return false }
        return Data(SHA256.hash(data: Data(text.utf8))) == digest
    }

    private static func emptyArray(_ value: Any?) -> Bool { (value as? [Any])?.isEmpty == true }
    private static func digits(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func canonical(_ value: String) -> String {
        URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
    }
    private static func safeDirectory(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) &&
            info.st_uid == geteuid() && info.st_mode & 0o022 == 0
    }
    private static func sameIdentity(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
    }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        sameIdentity(a, b) && a.st_size == b.st_size && a.st_nlink == b.st_nlink &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec &&
            a.st_birthtimespec.tv_sec == b.st_birthtimespec.tv_sec && a.st_birthtimespec.tv_nsec == b.st_birthtimespec.tv_nsec
    }
}
