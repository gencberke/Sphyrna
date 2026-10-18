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

    public var text: String
    public var attachments: [Attachment]
    public var updatedAt: Date

    public init(text: String = "", attachments: [Attachment] = [], updatedAt: Date = Date()) {
        self.text = text
        self.attachments = attachments
        self.updatedAt = updatedAt
    }

    /// Nothing worth keeping: a blank text and no attachment.
    public var isEmpty: Bool {
        attachments.isEmpty && text.allSatisfy(\.isWhitespace)
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
public struct ChatDraftStore: Sendable {
    public let directory: URL

    /// The most an attachment file may hold; a draft never keeps more than this per file.
    public static let maximumAttachmentBytes = 64 << 20
    /// The most a draft's own file may hold (text and the list of attachments; their bytes are files of their own). A
    /// bigger one is not read: it is set aside like an unreadable one.
    public static let maximumDraftBytes = 8 << 20

    public init(directory: URL) {
        self.directory = directory
    }

    func url(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString.lowercased() + ".json")
    }

    func folder(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
    }

    /// The saved draft, or nil when there is none.
    public func load(sessionID: UUID) throws -> ChatDraft? {
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

    /// Writes the draft's small file. An empty draft removes its file and its attachments.
    public func save(_ draft: ChatDraft, sessionID: UUID) throws {
        guard !draft.isEmpty else {
            try forget(sessionID: sessionID, keepingUnreadable: true)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = url(for: sessionID)
        try JSONEncoder.chatDraft.encode(draft).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try removeAttachments(except: Set(draft.attachments.map(\.id)), sessionID: sessionID)
    }

    /// Puts messages in front of what the draft holds (they were written first): their text, then a blank line, then the
    /// draft's; their images and pasted texts go in front of its attachments, each with its file. What the user typed
    /// stays. Used by the driver when a run ends or is interrupted with messages Claude never read, so they are on disk
    /// even when no composer exists.
    public func prepend(texts: [String], attachments: [ChatOutgoingAttachment], sessionID: UUID) throws {
        let existing = try load(sessionID: sessionID) ?? ChatDraft()
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
        let front = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let joined = front.isEmpty ? existing.text : existing.text.isEmpty ? front : front + "\n\n" + existing.text
        try save(ChatDraft(text: joined, attachments: listed + existing.attachments), sessionID: sessionID)
    }

    /// Keeps an attachment's bytes (the draft's file lists it).
    public func writeAttachment(_ data: Data, id: String, sessionID: UUID) throws {
        guard Self.isSafeName(id), data.count <= Self.maximumAttachmentBytes else { return }
        let folder = folder(for: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(id)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func attachmentData(id: String, sessionID: UUID) -> Data? {
        guard Self.isSafeName(id) else { return nil }
        let file = folder(for: sessionID).appendingPathComponent(id)
        // A file over the limit is never read whole (nothing here writes one, but the folder is just files).
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
              size <= Self.maximumAttachmentBytes else { return nil }
        return try? Data(contentsOf: file)
    }

    /// Removes the attachment files the draft no longer lists.
    func removeAttachments(except keep: Set<String>, sessionID: UUID) throws {
        let folder = folder(for: sessionID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where !keep.contains(name) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        if keep.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }

    /// The draft moves with its run to another card (`/clear`).
    public func move(from old: UUID, to new: UUID) throws {
        guard old != new else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fileManager.fileExists(atPath: url(for: old).path) {
            try? fileManager.removeItem(at: url(for: new))
            try fileManager.moveItem(at: url(for: old), to: url(for: new))
        }
        if fileManager.fileExists(atPath: folder(for: old).path) {
            try? fileManager.removeItem(at: folder(for: new))
            try fileManager.moveItem(at: folder(for: old), to: folder(for: new))
        }
    }

    /// The session was deleted, or the draft is empty: its file and attachments go. With `keepingUnreadable` the
    /// files set aside stay (they hold what the user wrote); a deleted session takes them too.
    public func forget(sessionID: UUID, keepingUnreadable: Bool = false) throws {
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

    /// The sessions that have a draft file here (or one set aside).
    public func sessionIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { UUID(uuidString: String($0.prefix(36))) })
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
