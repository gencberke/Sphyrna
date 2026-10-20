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
/// is called, records each file's hash as the rewind left it, and restores the copies on Undo. The copies live only while
/// their Undo can be offered (D-72): the driver deletes a rewind's copies (`discard`) when its Undo closes (a message was sent,
/// a newer rewind came, or it was undone), and the host removes every copy left by an earlier run when it starts (`removeAll`),
/// since an Undo lives only in memory. A copy is an APFS clone of the file (nothing is read into memory) and a hash is
/// computed by streaming.
///
/// Nothing here talks to Claude: the driver decides when to copy, when to call and what to record.
public struct ChatRewindStore: Sendable {
    public let directory: URL
    /// How a file that did not exist before the rewind leaves on Undo. The app moves it to the Trash; a test replaces it.
    let trash: @Sendable (URL) throws -> Void

    /// A copy of one file is at most 64 MiB, and the copies of one rewind together 256 MiB.
    public static let maximumFileBytes = 64 << 20
    public static let maximumRewindBytes = 256 << 20
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
    /// over the bounds, cannot be copied or the folder cannot be written. Older rewinds of the session are not touched: the
    /// previous one's Undo is still offered until this one's marker replaces it, and its copies go then (`discard`).
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
                    // The bounds are checked on sizes before anything is copied (stats only); the clone is the same size.
                    let attributes = try FileManager.default.attributesOfItem(atPath: path)
                    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                    total += size
                    guard size <= Self.maximumFileBytes, total <= Self.maximumRewindBytes else {
                        throw ChatRewindStoreError.tooLarge
                    }
                    let name = String(index)
                    let url = files.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    guard let digest = Self.fileHash(url) else { throw ChatRewindStoreError.cannotCopy([path]) }
                    let copySize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? size
                    entries.append(.init(path: path, existed: true, size: copySize, sha256: digest,
                                         mode: (attributes[.posixPermissions] as? NSNumber)?.intValue, copy: name))
                }
                let manifest = ChatRewindManifest(
                    rewindID: rewindID, sessionID: sessionID.uuidString.lowercased(), userMessageID: userMessageID, createdAt: now,
                    completed: false, undone: false, files: entries)
                try write(manifest, sessionID: sessionID)
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

    /// The rewind's copies are of no use: the CLI refused it, or its Undo is no longer offered (a message was sent, a newer rewind
    /// came, or it was undone). The session's folder goes with its last rewind.
    public func discard(sessionID: UUID, rewindID: String) {
        locked {
            try? FileManager.default.removeItem(at: folder(sessionID, rewindID))
            let session = sessionFolder(sessionID)
            if ((try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? ["-"]).isEmpty {
                try? FileManager.default.removeItem(at: session)
            }
        }
    }

    /// Every copy goes. The host calls it once when it starts: an Undo lives only in memory, so what an earlier run left is
    /// unreachable.
    public func removeAll() {
        locked {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
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
            var copies: [(ChatRewindManifest.File, URL)] = []
            for file in manifest.files where file.existed {
                guard let name = file.copy, case let url = copyURL(sessionID, rewindID, name),
                      Self.fileHash(url) == file.sha256 else {
                    throw ChatRewindStoreError.damaged("The copy of \(file.path) is missing or changed.")
                }
                copies.append((file, url))
            }
            var report = RestoreReport()
            for (file, copy) in copies {
                let url = URL(fileURLWithPath: file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A clone of the copy beside the file, then an atomic rename over it: the file is whole or as it was.
                let staged = url.deletingLastPathComponent().appendingPathComponent(".loom-undo-\(UUID().uuidString.prefix(8))")
                do {
                    try FileManager.default.copyItem(at: copy, to: staged)
                    if let mode = file.mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path) }
                    guard rename(staged.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    throw error
                }
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

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The hash of a file, read in chunks (a file of 64 MiB is never held in memory); nil when it cannot be read.
    static func fileHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the path holds a file, and its hash.
    static func state(of path: String) -> (exists: Bool, hash: String?) {
        guard FileManager.default.fileExists(atPath: path) else { return (false, nil) }
        return (true, fileHash(URL(fileURLWithPath: path)))
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
