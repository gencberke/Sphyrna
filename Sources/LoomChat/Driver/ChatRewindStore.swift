import CryptoKit
import Foundation

/// What a files rewind (V21) kept and what it left: one entry per file the dry run listed.
public struct ChatRewindManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        /// The absolute path the CLI listed.
        public var path: String
        /// The file was there when the copy was made (a file the rewind would bring back was not).
        public var existed: Bool
        public var size: Int?
        public var sha256: String?
        public var mode: Int?
        /// The copy's name in the rewind's `files` folder; nil when the file did not exist.
        public var copy: String?
        /// As the rewind left it, recorded after the call: whether the file exists and its hash.
        public var existsAfter: Bool?
        public var sha256After: String?
    }

    public var rewindID: String
    public var sessionID: String
    public var userMessageID: String
    public var createdAt: Date
    /// The hashes after the rewind are recorded: the call returned.
    public var completed: Bool
    /// Undo restored the copies.
    public var undone: Bool
    public var files: [File]
}

public enum ChatRewindStoreError: Error, Equatable, Sendable {
    /// A file is over `maximumFileBytes`, or the files together are over `maximumRewindBytes`.
    case tooLarge
    /// A listed file exists and cannot be copied: not a regular file, or not readable.
    case cannotCopy([String])
    /// The copy or the manifest is not there, or a copy no longer matches its hash.
    case damaged(String)
}

/// The copies a files rewind keeps for Undo (V21): `<directory>/<session id>/<rewind id>/manifest.json` and
/// `files/<n>` beside it, owner-only (folders 0700, files 0600). Loom copies every listed file that exists before the rewind
/// is called, records each file's hash as the rewind left it, and restores the copies on Undo. A session keeps its newest
/// `retainedRewinds`; deleting the session through Loom deletes the rest (`forget`).
///
/// Nothing here talks to Claude: the driver decides when to copy, when to call and what to record.
public struct ChatRewindStore: Sendable {
    public let directory: URL
    /// How a file that did not exist before the rewind leaves on Undo. The app moves it to the Trash; a test replaces it.
    let trash: @Sendable (URL) throws -> Void

    /// A copy of one file is at most 64 MiB, and the copies of one rewind together 256 MiB.
    public static let maximumFileBytes = 64 << 20
    public static let maximumRewindBytes = 256 << 20
    /// How many rewinds a session keeps.
    public static let retainedRewinds = 3

    private static let lock = NSRecursiveLock()

    public init(directory: URL, trash: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) {
        self.directory = directory
        self.trash = trash
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }

    // MARK: Paths

    func sessionFolder(_ sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
    }

    func folder(_ sessionID: UUID, _ rewindID: String) -> URL {
        sessionFolder(sessionID).appendingPathComponent(rewindID, isDirectory: true)
    }

    private func manifestURL(_ sessionID: UUID, _ rewindID: String) -> URL {
        folder(sessionID, rewindID).appendingPathComponent("manifest.json")
    }

    private func copyURL(_ sessionID: UUID, _ rewindID: String, _ name: String) -> URL {
        folder(sessionID, rewindID).appendingPathComponent("files", isDirectory: true).appendingPathComponent(name)
    }

    // MARK: Before the rewind

    /// Whether Loom can keep a copy of these files: stats only, nothing is read. A path that does not exist is fine (the
    /// rewind would bring it back).
    public func verdict(for paths: [String]) -> CopyVerdict {
        var total = 0
        var unreadable: [String] = []
        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeRegular, FileManager.default.isReadableFile(atPath: path) else {
                unreadable.append(path)
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size > Self.maximumFileBytes { return .tooLarge }
            total += size
        }
        if !unreadable.isEmpty { return .cannotCopy(unreadable) }
        return total > Self.maximumRewindBytes ? .tooLarge : .ok(totalBytes: total)
    }

    public enum CopyVerdict: Equatable, Sendable {
        case ok(totalBytes: Int)
        case tooLarge
        case cannotCopy([String])
    }

    /// Copies every listed file that exists and writes the manifest. Throws, and leaves nothing behind, when the files are
    /// over the bounds, cannot be copied or the folder cannot be written. Older rewinds of the session beyond the newest
    /// `retainedRewinds` (this one included) go.
    public func begin(sessionID: UUID, userMessageID: String, paths: [String], now: Date = Date()) throws -> ChatRewindManifest {
        try locked {
            switch verdict(for: paths) {
            case .ok: break
            case .tooLarge: throw ChatRewindStoreError.tooLarge
            case let .cannotCopy(files): throw ChatRewindStoreError.cannotCopy(files)
            }
            let rewindID = String(format: "%013ld-", Int(now.timeIntervalSince1970 * 1000)) + UUID().uuidString.lowercased().prefix(8)
            let root = folder(sessionID, rewindID)
            let files = root.appendingPathComponent("files", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                // The session's and the rewinds' folders may have been made with the default mode by the line above.
                for url in [directory, sessionFolder(sessionID), root, files] {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
                var entries: [ChatRewindManifest.File] = []
                var total = 0
                for (index, path) in paths.enumerated() {
                    guard FileManager.default.fileExists(atPath: path) else {
                        entries.append(.init(path: path, existed: false))
                        continue
                    }
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    total += data.count
                    guard data.count <= Self.maximumFileBytes, total <= Self.maximumRewindBytes else {
                        throw ChatRewindStoreError.tooLarge
                    }
                    let name = String(index)
                    let url = files.appendingPathComponent(name)
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
                    entries.append(.init(path: path, existed: true, size: data.count, sha256: Self.hash(data), mode: mode?.intValue,
                                         copy: name))
                }
                let manifest = ChatRewindManifest(
                    rewindID: rewindID, sessionID: sessionID.uuidString.lowercased(), userMessageID: userMessageID, createdAt: now,
                    completed: false, undone: false, files: entries)
                try write(manifest, sessionID: sessionID)
                prune(sessionID: sessionID)
                return manifest
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }
    }

    // MARK: After the rewind

    /// Records each file's state as the rewind left it, in the same manifest.
    @discardableResult
    public func finish(sessionID: UUID, rewindID: String) throws -> ChatRewindManifest {
        try locked {
            var manifest = try load(sessionID: sessionID, rewindID: rewindID)
            for index in manifest.files.indices {
                let state = Self.state(of: manifest.files[index].path)
                manifest.files[index].existsAfter = state.exists
                manifest.files[index].sha256After = state.hash
            }
            manifest.completed = true
            try write(manifest, sessionID: sessionID)
            return manifest
        }
    }

    /// The rewind did not happen (the CLI refused it): its copies are of no use.
    public func discard(sessionID: UUID, rewindID: String) {
        locked { try? FileManager.default.removeItem(at: folder(sessionID, rewindID)) }
    }

    // MARK: Undo

    /// The files whose content is not what the rewind left: Undo would overwrite changes made since.
    public func changedSinceRewind(sessionID: UUID, rewindID: String) throws -> [String] {
        let manifest = try load(sessionID: sessionID, rewindID: rewindID)
        guard manifest.completed else { throw ChatRewindStoreError.damaged("The rewind did not finish.") }
        return manifest.files.filter { file in
            let now = Self.state(of: file.path)
            return now.exists != (file.existsAfter ?? false) || now.hash != file.sha256After
        }.map(\.path)
    }

    /// Puts every copied file back (written atomically, with its mode) and moves a file that did not exist before the rewind
    /// and exists now to the Trash. All copies are checked against their hashes before anything is written.
    @discardableResult
    public func restore(sessionID: UUID, rewindID: String) throws -> RestoreReport {
        try locked {
            var manifest = try load(sessionID: sessionID, rewindID: rewindID)
            guard !manifest.undone else { throw ChatRewindStoreError.damaged("This rewind was undone already.") }
            var copies: [(ChatRewindManifest.File, Data)] = []
            for file in manifest.files where file.existed {
                guard let name = file.copy, let data = try? Data(contentsOf: copyURL(sessionID, rewindID, name)),
                      Self.hash(data) == file.sha256 else {
                    throw ChatRewindStoreError.damaged("The copy of \(file.path) is missing or changed.")
                }
                copies.append((file, data))
            }
            var report = RestoreReport()
            for (file, data) in copies {
                let url = URL(fileURLWithPath: file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                if let mode = file.mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
                report.restored.append(file.path)
            }
            for file in manifest.files where !file.existed && FileManager.default.fileExists(atPath: file.path) {
                try trash(URL(fileURLWithPath: file.path))
                report.trashed.append(file.path)
            }
            manifest.undone = true
            try write(manifest, sessionID: sessionID)
            return report
        }
    }

    public struct RestoreReport: Equatable, Sendable {
        public var restored: [String] = []
        public var trashed: [String] = []
    }

    // MARK: Reading

    public func load(sessionID: UUID, rewindID: String) throws -> ChatRewindManifest {
        guard let data = try? Data(contentsOf: manifestURL(sessionID, rewindID)),
              let manifest = try? JSONDecoder.chatRewind.decode(ChatRewindManifest.self, from: data) else {
            throw ChatRewindStoreError.damaged("The rewind's record is missing.")
        }
        return manifest
    }

    /// The session's rewinds, oldest first.
    public func rewindIDs(sessionID: UUID) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionFolder(sessionID).path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// The sessions that have rewinds here.
    public func sessionIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { UUID(uuidString: $0) })
    }

    /// The session was deleted: all its copies go.
    public func forget(sessionID: UUID) throws {
        try locked {
            do { try FileManager.default.removeItem(at: sessionFolder(sessionID)) } catch {
                let code = (error as NSError).code
                guard code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError else { throw error }
            }
        }
    }

    // MARK: Private

    private func write(_ manifest: ChatRewindManifest, sessionID: UUID) throws {
        let url = manifestURL(sessionID, manifest.rewindID)
        try JSONEncoder.chatRewind.encode(manifest).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Older rewinds beyond the newest `retainedRewinds` go (the names sort by time).
    private func prune(sessionID: UUID) {
        let ids = rewindIDs(sessionID: sessionID)
        for id in ids.dropLast(Self.retainedRewinds) {
            try? FileManager.default.removeItem(at: folder(sessionID, id))
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the path holds a file, and its hash.
    static func state(of path: String) -> (exists: Bool, hash: String?) {
        guard FileManager.default.fileExists(atPath: path) else { return (false, nil) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return (true, nil) }
        return (true, hash(data))
    }
}

private extension JSONEncoder {
    static var chatRewind: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var chatRewind: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
