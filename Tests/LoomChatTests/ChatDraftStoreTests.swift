import Foundation
import Testing
@testable import LoomChat

// The Chat composer's drafts on disk (V17): kept per session, owner-only, never overwritten when unreadable, moved with a
// `/clear`, gone with the session. No process.

struct ChatDraftStoreTests {
    private func store() throws -> (ChatDraftStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-drafts-\(UUID())", isDirectory: true)
        return (ChatDraftStore(directory: root.appendingPathComponent("chat-drafts", isDirectory: true)), root)
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
    }

    @Test func aDraftRoundTripsWithItsAttachmentsAndIsOwnerOnly() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        #expect(try store.load(sessionID: id) == nil)
        let draft = ChatDraft(text: "Half a thought", attachments: [
            ChatDraft.Attachment(id: "img-1", kind: .image, mediaType: "image/png", name: "shot.png"),
            ChatDraft.Attachment(id: "paste-1", kind: .pastedText),
        ])
        try store.writeAttachment(Data([1, 2, 3]), id: "img-1", sessionID: id)
        try store.writeAttachment(Data("long paste".utf8), id: "paste-1", sessionID: id)
        try store.save(draft, sessionID: id)
        let loaded = try #require(try store.load(sessionID: id))
        #expect(loaded.text == "Half a thought")
        #expect(loaded.attachments == draft.attachments)
        #expect(store.attachmentData(id: "img-1", sessionID: id) == Data([1, 2, 3]))
        #expect(store.attachmentData(id: "paste-1", sessionID: id) == Data("long paste".utf8))
        #expect(try permissions(store.url(for: id)) == 0o600)
        #expect(try permissions(store.folder(for: id)) == 0o700)
        #expect(try permissions(store.folder(for: id).appendingPathComponent("img-1")) == 0o600)
        #expect(try permissions(store.directory) == 0o700)
    }

    @Test func savingAnEmptyDraftRemovesItAndAnAttachmentTheDraftNoLongerListsGoes() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.writeAttachment(Data([9]), id: "a", sessionID: id)
        try store.writeAttachment(Data([8]), id: "b", sessionID: id)
        try store.save(ChatDraft(text: "x", attachments: [ChatDraft.Attachment(id: "a", kind: .image, mediaType: "image/png")]),
                       sessionID: id)
        #expect(store.attachmentData(id: "a", sessionID: id) != nil)
        #expect(store.attachmentData(id: "b", sessionID: id) == nil)
        try store.save(ChatDraft(), sessionID: id)
        #expect(try store.load(sessionID: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: id).path))
        #expect(store.sessionIDs().isEmpty)
    }

    @Test func anUnreadableDraftIsSetAsideNeverOverwrittenAndKeptWhenTheComposerEmpties() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.url(for: id))
        var keptAs: String?
        do { _ = try store.load(sessionID: id) } catch let ChatDraftStoreError.unreadable(name) { keptAs = name }
        let name = try #require(keptAs)
        #expect(name.contains("unreadable"))
        #expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(name).path))
        // The next load finds no draft, and an empty save keeps the set-aside file.
        #expect(try store.load(sessionID: id) == nil)
        try store.save(ChatDraft(), sessionID: id)
        #expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(name).path))
        // A deleted session takes it too.
        try store.forget(sessionID: id)
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(name).path))
    }

    @Test func aDraftMovesWithItsRunToTheNewCardAndForgetRemovesEverything() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = UUID(), new = UUID()
        try store.writeAttachment(Data([7]), id: "a", sessionID: old)
        try store.save(ChatDraft(text: "carry me", attachments: [ChatDraft.Attachment(id: "a", kind: .image, mediaType: "image/png")]),
                       sessionID: old)
        try store.move(from: old, to: new)
        #expect(try store.load(sessionID: old) == nil)
        #expect(try store.load(sessionID: new)?.text == "carry me")
        #expect(store.attachmentData(id: "a", sessionID: new) == Data([7]))
        try store.forget(sessionID: new)
        #expect(store.sessionIDs().isEmpty)
    }

    @Test func anUnsafeAttachmentNameIsNeverWrittenOrRead() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.writeAttachment(Data([1]), id: "../escape", sessionID: id)
        #expect(store.attachmentData(id: "../escape", sessionID: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("escape").path))
    }

    /// Fix 10 (V17): a draft file past the cap is not read into memory; it is set aside like an unreadable one.
    @Test func aDraftFilePastTheCapIsSetAsideUnread() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(count: ChatDraftStore.maximumDraftBytes + 1).write(to: store.url(for: id))
        var keptAs: String?
        do { _ = try store.load(sessionID: id) } catch let ChatDraftStoreError.unreadable(name) { keptAs = name }
        #expect(keptAs?.contains("unreadable") == true)
        #expect(try store.load(sessionID: id) == nil)
    }
}
