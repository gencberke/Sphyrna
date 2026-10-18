import Foundation

/// What the user had typed in a session's composer and not sent (CHAT-SPEC → Delivery and drafts): the text, and the
/// attachments that wait with it (images, large pastes). Saved 300 ms after the last change, on blur, on send and on
/// Quit, so a crash or a relaunch loses at most the last 300 ms.
public struct ChatDraft: Codable, Equatable, Sendable {
    public struct Attachment: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case image
            case pastedText
        }

        /// Names the attachment's file in the draft's folder.
        public var id: String
        public var kind: Kind
        public var mediaType: String?
        /// The file's name for an image that came from a file, shown on its chip.
        public var name: String?

        public init(id: String, kind: Kind, mediaType: String? = nil, name: String? = nil) {
            self.id = id
            self.kind = kind
            self.mediaType = mediaType
            self.name = name
        }
    }

    /// A message Loom wrote to the CLI that Claude has not read yet. The driver owns these (the composer's save never
    /// touches them): it records one when it is written and drops it when Claude reads it, so a crash or a Quit loses none.
    /// A driver made after a crash moves what it finds into the text (`ChatDraftStore.recoverHeld`).
    public struct Held: Codable, Equatable, Sendable {
        /// The message's row id in the driver's model.
        public var id: String
        public var text: String
        public var attachments: [Attachment]

        public init(id: String, text: String, attachments: [Attachment] = []) {
            self.id = id
            self.text = text
            self.attachments = attachments
        }
    }

    public var text: String
    public var attachments: [Attachment]
    public var updatedAt: Date
    public var held: [Held]

    public init(text: String = "", attachments: [Attachment] = [], updatedAt: Date = Date(), held: [Held] = []) {
        self.text = text
        self.attachments = attachments
        self.updatedAt = updatedAt
        self.held = held
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decode([Attachment].self, forKey: .attachments)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        held = try container.decodeIfPresent([Held].self, forKey: .held) ?? []
    }

    /// Nothing worth keeping: a blank text, no attachment and no unread message.
    public var isEmpty: Bool {
        attachments.isEmpty && held.isEmpty && text.allSatisfy(\.isWhitespace)
    }

    /// Every attachment file the draft lists, the held messages' included.
    var listedAttachmentIDs: Set<String> {
        Set(attachments.map(\.id)).union(held.flatMap { $0.attachments.map(\.id) })
    }
}

/// Taking one message's text out of a draft's text, where `prepend` and the composer joined messages with a blank line.
public enum ChatDraftText {
    /// `text` without the first occurrence of `piece` that is a whole message of it (at the start or after a blank line, and
    /// at the end or before one), and one blank-line separator beside it (the one after it, else the one before). A
    /// prefix of the user's own words ("yes" in "yesterday's build failed") is not a message. Unchanged when `piece` is
    /// empty or is not there as a message.
    public static func removing(_ piece: String, from text: String) -> String {
        guard !piece.isEmpty else { return text }
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex, let range = text.range(of: piece, range: searchFrom..<text.endIndex) {
            var lower = range.lowerBound
            var upper = range.upperBound
            let startsMessage = lower == text.startIndex || text[..<lower].hasSuffix("\n\n")
            let endsMessage = upper == text.endIndex || text[upper...].hasPrefix("\n\n")
            if startsMessage, endsMessage {
                if text[upper...].hasPrefix("\n\n") {
                    upper = text.index(upper, offsetBy: 2)
                } else if text[..<lower].hasSuffix("\n\n") {
                    lower = text.index(lower, offsetBy: -2)
                }
                var result = text
                result.removeSubrange(lower..<upper)
                return result
            }
            searchFrom = text.index(after: range.lowerBound)
        }
        return text
    }
}

public enum ChatDraftStoreError: Error, Equatable, Sendable {
    /// The file could not be read as a draft. It was renamed aside to `keptAs` (nothing is overwritten).
    case unreadable(keptAs: String?)
}

/// The drafts of the Chat composers: `<directory>/<session id>.json`, with the attachments' bytes in the folder
/// `<directory>/<session id>/<attachment id>` beside it (so a change of the text rewrites only the small file). Owner-only
/// (the files are what the user wrote); written atomically. A missing file is no draft; a file that cannot be read is
/// renamed aside, never overwritten, and reported. Deleting the session through Loom deletes its draft (`forget`).
///
/// Two writers share a file: the composer (the text and the attachments it shows: `save`) and the driver (the messages it
/// wrote that Claude has not read: `hold`, `release`, `recoverHeld`, and the messages it hands back: `prepend`). Each owns
/// its part, so a save of the text never drops a held message and a hold never drops the typed text, and every operation
/// reads and writes under one lock, so none loses another's change (V17 fix round 2).
public struct ChatDraftStore: Sendable {
    public let directory: URL

    /// The most an attachment file may hold; a draft never keeps more than this per file.
    public static let maximumAttachmentBytes = 64 << 20
    /// The most a draft's own file may hold (text and the list of attachments; their bytes are files of their own). A
    /// bigger one is not read: it is set aside like an unreadable one.
    public static let maximumDraftBytes = 8 << 20

    /// Held by every operation on any draft file. One lock for all sessions: the files are small and the operations short.
    private static let lock = NSRecursiveLock()

    public init(directory: URL) {
        self.directory = directory
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }

    func url(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString.lowercased() + ".json")
    }

    func folder(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
    }

    /// The saved draft, or nil when there is none.
    public func load(sessionID: UUID) throws -> ChatDraft? {
        try locked {
            let url = url(for: sessionID)
            let data: Data
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maximumDraftBytes {
                throw ChatDraftStoreError.unreadable(keptAs: setAside(url))
            }
            do { data = try Data(contentsOf: url) } catch {
                if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileReadNoSuchFileError { return nil }
                throw ChatDraftStoreError.unreadable(keptAs: setAside(url))
            }
            guard let draft = try? JSONDecoder.chatDraft.decode(ChatDraft.self, from: data) else {
                throw ChatDraftStoreError.unreadable(keptAs: setAside(url))
            }
            return draft
        }
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

    /// Writes the composer's part of the draft: its text and attachments. The messages the driver holds unread stay as the
    /// file has them (`draft.held` is not read). A draft with nothing in it, held messages included, removes its file and
    /// its attachments.
    public func save(_ draft: ChatDraft, sessionID: UUID) throws {
        try locked {
            var next = draft
            next.held = (try? load(sessionID: sessionID))?.held ?? []
            try write(next, sessionID: sessionID)
        }
    }

    /// Writes `draft` whole (the caller holds the lock and has set `held`). An empty draft removes its file and attachments.
    private func write(_ draft: ChatDraft, sessionID: UUID) throws {
        guard !draft.isEmpty else {
            try forget(sessionID: sessionID, keepingUnreadable: true)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = url(for: sessionID)
        try JSONEncoder.chatDraft.encode(draft).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try removeAttachments(except: draft.listedAttachmentIDs, sessionID: sessionID)
    }

    /// Writes an outgoing attachment's bytes as a file of the draft and lists it.
    private func store(_ attachments: [ChatOutgoingAttachment], sessionID: UUID) throws -> [ChatDraft.Attachment] {
        var listed: [ChatDraft.Attachment] = []
        for attachment in attachments {
            let id = UUID().uuidString.lowercased()
            switch attachment {
            case let .pastedText(text):
                try writeAttachment(Data(text.utf8), id: id, sessionID: sessionID)
                listed.append(ChatDraft.Attachment(id: id, kind: .pastedText))
            case let .image(mediaType, base64):
                guard let data = Data(base64Encoded: base64) else { continue }
                try writeAttachment(data, id: id, sessionID: sessionID)
                listed.append(ChatDraft.Attachment(id: id, kind: .image, mediaType: mediaType))
            }
        }
        return listed
    }

    /// Puts messages in front of what the draft holds (they were written first): their text, then a blank line, then the
    /// draft's; their images and pasted texts go in front of its attachments, each with its file. What the user typed
    /// stays. Used by the driver when a run ends or is interrupted with messages Claude never read, so they are on disk
    /// even when no composer exists. `settling` names held messages (by row id) that these are the text of: they leave the
    /// held list in the same write.
    public func prepend(texts: [String], attachments: [ChatOutgoingAttachment], sessionID: UUID,
                        settling: [String] = []) throws {
        try locked {
            var existing = try load(sessionID: sessionID) ?? ChatDraft()
            existing.held.removeAll { settling.contains($0.id) }
            let listed = try store(attachments, sessionID: sessionID)
            let front = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let joined = front.isEmpty ? existing.text : existing.text.isEmpty ? front : front + "\n\n" + existing.text
            existing.text = joined
            existing.attachments = listed + existing.attachments
            existing.updatedAt = Date()
            try write(existing, sessionID: sessionID)
        }
    }

    /// Records a message just written to the CLI that Claude has not read: it is in the file until `release` (Claude read
    /// it) or `prepend(settling:)` (it came back), or until a driver made after a crash moves it to the text.
    public func hold(id: String, text: String, attachments: [ChatOutgoingAttachment], sessionID: UUID) throws {
        try locked {
            var existing = try load(sessionID: sessionID) ?? ChatDraft()
            let listed = try store(attachments, sessionID: sessionID)
            existing.held.removeAll { $0.id == id }
            existing.held.append(ChatDraft.Held(id: id, text: text, attachments: listed))
            try write(existing, sessionID: sessionID)
        }
    }

    /// Claude read these messages (or they never went out): they leave the held list. Nothing else changes.
    public func release(ids: [String], sessionID: UUID) throws {
        try locked {
            guard var existing = try load(sessionID: sessionID), existing.held.contains(where: { ids.contains($0.id) }) else { return }
            existing.held.removeAll { ids.contains($0.id) }
            try write(existing, sessionID: sessionID)
        }
    }

    /// A driver made after the run that wrote these is gone (a crash, a force quit): the messages it held unread were never
    /// confirmed read, so they come back to the user as text in front of what was typed. Returns whether there were any.
    @discardableResult
    public func recoverHeld(sessionID: UUID) throws -> Bool {
        try locked {
            guard var existing = try load(sessionID: sessionID), !existing.held.isEmpty else { return false }
            let front = existing.held.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            existing.text = front.isEmpty ? existing.text : existing.text.isEmpty ? front : front + "\n\n" + existing.text
            existing.attachments = existing.held.flatMap(\.attachments) + existing.attachments
            existing.held = []
            existing.updatedAt = Date()
            try write(existing, sessionID: sessionID)
            return true
        }
    }

    /// Takes a message out of the draft again: its text and its attachments (matched by their bytes), as `prepend` put them
    /// in. Used when a message the draft got back was sent again (Retry), so it is not in the draft twice.
    public func withdraw(text: String, attachments: [ChatOutgoingAttachment], sessionID: UUID) throws {
        try locked {
            guard var draft = try load(sessionID: sessionID) else { return }
            draft.text = ChatDraftText.removing(text, from: draft.text)
            for attachment in attachments {
                let bytes: Data?
                let kind: ChatDraft.Attachment.Kind
                switch attachment {
                case let .pastedText(pasted): (bytes, kind) = (Data(pasted.utf8), .pastedText)
                case let .image(_, base64): (bytes, kind) = (Data(base64Encoded: base64), .image)
                }
                guard let bytes, let index = draft.attachments.firstIndex(where: {
                    $0.kind == kind && attachmentData(id: $0.id, sessionID: sessionID) == bytes
                }) else { continue }
                draft.attachments.remove(at: index)
            }
            try write(draft, sessionID: sessionID)
        }
    }

    /// Keeps an attachment's bytes (the draft's file lists it).
    public func writeAttachment(_ data: Data, id: String, sessionID: UUID) throws {
        guard Self.isSafeName(id), data.count <= Self.maximumAttachmentBytes else { return }
        try locked {
            let folder = folder(for: sessionID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(id)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    public func attachmentData(id: String, sessionID: UUID) -> Data? {
        guard Self.isSafeName(id) else { return nil }
        return locked {
            let file = folder(for: sessionID).appendingPathComponent(id)
            // A file over the limit is never read whole (nothing here writes one, but the folder is just files).
            guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
                  size <= Self.maximumAttachmentBytes else { return nil }
            return try? Data(contentsOf: file)
        }
    }

    /// Removes the attachment files the draft no longer lists.
    func removeAttachments(except keep: Set<String>, sessionID: UUID) throws {
        try locked {
            let folder = folder(for: sessionID)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            for name in names where !keep.contains(name) {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            if keep.isEmpty { try? FileManager.default.removeItem(at: folder) }
        }
    }

    /// The draft moves with its run to another card (`/clear`). The driver does it when the run moves; a composer that
    /// learns of the move later asks again, so a draft the new card already has is merged, not replaced: the moved file's
    /// text and attachments win (they are the newer composer's), and the held messages of both stay.
    public func move(from old: UUID, to new: UUID) throws {
        guard old != new else { return }
        try locked {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fileManager.fileExists(atPath: url(for: old).path) {
                let moved: ChatDraft? = try? load(sessionID: old)
                var target: ChatDraft? = try? load(sessionID: new)
                if var moved = moved {
                    if let existing = target {
                        for held in existing.held where !moved.held.contains(where: { $0.id == held.id }) { moved.held.append(held) }
                    }
                    target = moved
                }
                try? fileManager.removeItem(at: url(for: old))
                if fileManager.fileExists(atPath: folder(for: old).path) {
                    try fileManager.createDirectory(at: folder(for: new), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
                    for name in (try? fileManager.contentsOfDirectory(atPath: folder(for: old).path)) ?? [] {
                        try? fileManager.removeItem(at: folder(for: new).appendingPathComponent(name))
                        try fileManager.moveItem(at: folder(for: old).appendingPathComponent(name),
                                                 to: folder(for: new).appendingPathComponent(name))
                    }
                    try? fileManager.removeItem(at: folder(for: old))
                }
                if let target { try write(target, sessionID: new) }
            } else if fileManager.fileExists(atPath: folder(for: old).path) {
                try? fileManager.removeItem(at: folder(for: new))
                try fileManager.moveItem(at: folder(for: old), to: folder(for: new))
            }
        }
    }

    /// The session was deleted, or the draft is empty: its file and attachments go. With `keepingUnreadable` the
    /// files set aside stay (they hold what the user wrote); a deleted session takes them too.
    public func forget(sessionID: UUID, keepingUnreadable: Bool = false) throws {
        try locked {
            let fileManager = FileManager.default
            for url in [url(for: sessionID), folder(for: sessionID)] where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            guard !keepingUnreadable else { return }
            let prefix = sessionID.uuidString.lowercased() + ".unreadable-"
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasPrefix(prefix) {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// The sessions that have a draft file here (or one set aside).
    public func sessionIDs() -> Set<UUID> {
        locked {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return Set(names.compactMap { UUID(uuidString: String($0.prefix(36))) })
        }
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

private extension JSONEncoder {
    static var chatDraft: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var chatDraft: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
