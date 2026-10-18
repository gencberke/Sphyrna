import Foundation

/// Loom's own queue of messages for "After this turn" (CHAT-SPEC → Queue). The CLI's `priority: later` is not used: it
/// cannot be edited or reordered. Items go out one at a time, the first when a turn's `result` arrives and no request
/// waits. An interrupt, a failed turn, a process that ended on its own and a relaunch of Loom pause it; a message queued
/// while it is paused waits. It is kept with the session in Loom's data folder, so it survives Stop, Quit and a crash.
public struct ChatQueue: Sendable, Equatable, Codable {
    public struct Item: Sendable, Equatable, Codable, Identifiable {
        public var id: String
        public var text: String
        public var queuedAt: Date

        public init(id: String = UUID().uuidString.lowercased(), text: String, queuedAt: Date = Date()) {
            self.id = id
            self.text = text
            self.queuedAt = queuedAt
        }
    }

    public enum PauseReason: String, Sendable, Equatable, Codable {
        /// "Queue paused because you interrupted".
        case interrupted
        /// A turn ended with an error (an interrupt's own result is not one).
        case failedTurn
        /// The process ended without Loom stopping it.
        case processEnded
        /// Loom was started again with items still queued.
        case relaunch
    }

    /// At most this many items wait (CHAT-SPEC → Queue): one more is refused, not dropped.
    public static let maximumItems = 100
    /// At most this many bytes of text wait, all items together.
    public static let maximumBytes = 1 << 20

    public internal(set) var items: [Item] = []
    public internal(set) var paused: PauseReason?

    public init(items: [Item] = [], paused: PauseReason? = nil) {
        self.items = items
        self.paused = paused
    }

    public var isEmpty: Bool { items.isEmpty }

    /// The UTF-8 size of every item's text.
    public var byteCount: Int { items.reduce(0) { $0 + $1.text.utf8.count } }

    /// Whether `text` still fits, as one more item (`replacing` an item it takes the place of).
    func admits(_ text: String, replacing id: String? = nil) -> Bool {
        let replaced = id.flatMap { id in items.first { $0.id == id } }
        let count = items.count + (replaced == nil ? 1 : 0)
        let bytes = byteCount - (replaced?.text.utf8.count ?? 0) + text.utf8.count
        return count <= Self.maximumItems && bytes <= Self.maximumBytes
    }
}

public enum ChatQueueStoreError: Error, Equatable, Sendable {
    /// The file could not be read as a queue. It was renamed aside to `keptAs` (nothing is overwritten).
    case unreadable(keptAs: String?)
}

/// The queue's file: `<directory>/<session id>.json`, owner-only (the items are what the user wrote). Written whole on
/// every change, atomically. A missing file is an empty queue; a file that cannot be read is renamed aside (never
/// overwritten) and reported. Deleting the session through Loom deletes its file (`remove`).
public struct ChatQueueStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    func url(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString.lowercased() + ".json")
    }

    /// The saved queue, or an empty one when there is no file. A file that is there but cannot be read (or is over
    /// the queue's bounds by more than a file of it can be) is renamed to `<id>.unreadable-<time>.json` and throws.
    public func load(sessionID: UUID) throws -> ChatQueue {
        let url = url(for: sessionID)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileReadNoSuchFileError {
                return ChatQueue()
            }
            throw ChatQueueStoreError.unreadable(keptAs: setAside(url))
        }
        guard data.count <= 2 * ChatQueue.maximumBytes + 64 * 1024,
              let queue = try? JSONDecoder.chatQueue.decode(ChatQueue.self, from: data) else {
            throw ChatQueueStoreError.unreadable(keptAs: setAside(url))
        }
        return queue
    }

    private func setAside(_ url: URL) -> String? {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return aside.lastPathComponent
        } catch {
            return nil
        }
    }

    /// An empty, unpaused queue removes its file.
    func save(_ queue: ChatQueue, sessionID: UUID) throws {
        let url = url(for: sessionID)
        guard !queue.isEmpty || queue.paused != nil else {
            try remove(sessionID: sessionID)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder.chatQueue.encode(queue).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes the session's queue file, if there is one (the session was deleted, or its queue emptied).
    public func remove(sessionID: UUID) throws {
        do { try FileManager.default.removeItem(at: url(for: sessionID)) } catch {
            let code = (error as NSError).code
            guard code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError else { throw error }
        }
    }

    /// The session was deleted: its queue file goes, and any unreadable one set aside (they hold what the user wrote).
    public func forget(sessionID: UUID) throws {
        try remove(sessionID: sessionID)
        let prefix = sessionID.uuidString.lowercased() + ".unreadable-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// The sessions that have a queue file here (or one set aside).
    public func sessionIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { UUID(uuidString: String($0.prefix(36))) })
    }
}

private extension JSONEncoder {
    static var chatQueue: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var chatQueue: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
