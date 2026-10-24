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

    /// D-96: the sessions a draft mentions are kept as ids, in order; a draft of mentions alone is kept; a draft written before
    /// mentions loads with none.
    @Test func aDraftKeepsItsMentionsAndAnOlderDraftLoadsWithout() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let mentioned = [UUID(), UUID()]
        try store.save(ChatDraft(text: "", mentions: mentioned), sessionID: id)
        #expect(try store.load(sessionID: id)?.mentions == mentioned)
        // A held message written by the driver keeps the mentions, as it keeps the text.
        try store.hold(id: "m1", text: "sent", attachments: [], sessionID: id)
        #expect(try store.load(sessionID: id)?.mentions == mentioned)
        let moved = UUID()
        try store.move(from: id, to: moved)
        #expect(try store.load(sessionID: moved)?.mentions == mentioned, "a /clear moves them with the draft")

        let old = UUID()
        try Data(#"{"attachments":[],"text":"old","updatedAt":"2026-10-01T10:00:00Z"}"#.utf8).write(to: store.url(for: old))
        let loaded = try #require(try store.load(sessionID: old))
        #expect(loaded.text == "old" && loaded.mentions.isEmpty)
    }

    @Test func savingAnEmptyDraftRemovesItAndAnAttachmentTheDraftNoLongerListsGoes() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.writeAttachment(Data([9]), id: "a", sessionID: id)
        try store.writeAttachment(Data([8]), id: "b", sessionID: id)
        try store.save(ChatDraft(text: "x", attachments: [ChatDraft.Attachment(id: "a", kind: .image, mediaType: "image/png"),
                                                          ChatDraft.Attachment(id: "b", kind: .image, mediaType: "image/png")]),
                       sessionID: id)
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

// MARK: Fix round 2: messages held unread, and one lock for every operation on a draft

extension ChatDraftStoreTests {
    private func makeStore() throws -> (ChatDraftStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-drafts-\(UUID())", isDirectory: true)
        return (ChatDraftStore(directory: root.appendingPathComponent("chat-drafts", isDirectory: true)), root)
    }

    /// D5: the composer's save and the driver's held messages share one file and never drop each other's part.
    @Test func aHeldMessageSurvivesTheComposersSavesAndLeavesWhenReleased() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.hold(id: "row-1", text: "sent while working", attachments: [.pastedText("long paste")], sessionID: id)
        #expect(try store.load(sessionID: id)?.held.map(\.text) == ["sent while working"])
        // The composer saves its own text: the held message stays; an empty composer does not delete the file.
        try store.save(ChatDraft(text: "typed since"), sessionID: id)
        var draft = try #require(try store.load(sessionID: id))
        #expect(draft.text == "typed since" && draft.held.map(\.id) == ["row-1"])
        try store.save(ChatDraft(), sessionID: id)
        draft = try #require(try store.load(sessionID: id))
        #expect(draft.text.isEmpty && draft.held.count == 1)
        let file = try #require(draft.held.first?.attachments.first)
        #expect(store.attachmentData(id: file.id, sessionID: id) == Data("long paste".utf8), "a save keeps the held message's file")
        // Claude read it: the file goes with the last thing in it.
        try store.release(ids: ["row-1"], sessionID: id)
        #expect(try store.load(sessionID: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: id).path))
    }

    /// D5: held messages settle into the text in front of what was typed (a run that ended), or after a crash (`recoverHeld`).
    @Test func heldMessagesSettleIntoTheTextOnAnEndOrACrash() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.hold(id: "a", text: "first", attachments: [], sessionID: id)
        try store.hold(id: "b", text: "second", attachments: [.pastedText("p")], sessionID: id)
        try store.save(ChatDraft(text: "typed"), sessionID: id)
        // The run ended with "a" unread: it comes back as text; "b" stays held.
        try store.prepend(texts: ["first"], attachments: [], sessionID: id, settling: ["a"])
        var draft = try #require(try store.load(sessionID: id))
        #expect(draft.text == "first\n\ntyped" && draft.held.map(\.id) == ["b"])
        // A crash: what is still held becomes text, in front, once.
        #expect(try store.recoverHeld(sessionID: id))
        draft = try #require(try store.load(sessionID: id))
        #expect(draft.text == "second\n\nfirst\n\ntyped" && draft.held.isEmpty && draft.attachments.count == 1)
        #expect(try store.recoverHeld(sessionID: id) == false, "nothing is recovered twice")
        #expect(try store.load(sessionID: id)?.text == "second\n\nfirst\n\ntyped")
        // A file from before this change (no held list) still reads.
        let old = #"{"text":"old","attachments":[],"updatedAt":"2026-10-01T00:00:00Z"}"#
        try Data(old.utf8).write(to: store.url(for: id))
        #expect(try store.load(sessionID: id)?.text == "old" && store.load(sessionID: id)?.held.isEmpty == true)
    }

    /// D5: concurrent writers keep each other's text: many holds and many prepends from several threads while the composer saves.
    @Test func concurrentWritersKeepBothTexts() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let count = 60
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<count { try? store.hold(id: "row-\(index)", text: "held \(index)", attachments: [], sessionID: id) }
            }
            group.addTask {
                for index in 0..<count { try? store.prepend(texts: ["returned \(index)"], attachments: [], sessionID: id) }
            }
            group.addTask {
                // The composer saves a text that holds what it has taken; it never writes the other two's parts.
                for _ in 0..<count { try? store.save(ChatDraft(text: "composer"), sessionID: id) }
            }
        }
        let draft = try #require(try store.load(sessionID: id))
        #expect(draft.held.count == count, "no held message was lost: \(draft.held.count)")
        #expect(draft.held.map(\.id).sorted() == (0..<count).map { "row-\($0)" }.sorted())
        // Prepends and saves race on the text: the composer's saves replace it, but a prepend made after the last save stays,
        // and the file is always whole (a draft that reads).
        #expect(!draft.text.isEmpty)
    }

    /// D5: the same race on `prepend` alone loses nothing: each one reads and writes under the lock.
    @Test func concurrentPrependsAllLand() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let count = 80
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask { try? store.prepend(texts: ["message \(index)"], attachments: [], sessionID: id) }
            }
        }
        let pieces = Set(try #require(try store.load(sessionID: id)).text.components(separatedBy: "\n\n"))
        #expect(pieces == Set((0..<count).map { "message \($0)" }), "\(pieces.count) of \(count) landed")
    }

    /// A move that finds a draft already under the new card keeps the held messages of both, and the moved text.
    @Test func aMoveOntoAnExistingDraftMergesTheHeldMessages() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let (old, new) = (UUID(), UUID())
        try store.hold(id: "a", text: "held on old", attachments: [], sessionID: old)
        try store.save(ChatDraft(text: "composer text"), sessionID: old)
        try store.hold(id: "b", text: "held on new", attachments: [], sessionID: new)
        try store.move(from: old, to: new)
        let moved = try #require(try store.load(sessionID: new))
        #expect(moved.text == "composer text" && Set(moved.held.map(\.id)) == ["a", "b"])
        #expect(try store.load(sessionID: old) == nil)
    }
}

// MARK: Release B close, ST-1: a driver write never deletes a file the composer has not listed yet

extension ChatDraftStoreTests {
    /// The composer writes an attachment's file first and lists it at its next save (up to 300 ms later). A `hold` and a
    /// `release` of the driver in between must not delete it.
    @Test func anAttachmentNotListedYetSurvivesAHoldAndARelease() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.save(ChatDraft(text: "typed"), sessionID: id)
        try store.writeAttachment(Data([4, 2]), id: "pasted", sessionID: id)
        try store.hold(id: "m", text: "sent", attachments: [], sessionID: id)
        try store.release(ids: ["m"], sessionID: id)
        #expect(store.attachmentData(id: "pasted", sessionID: id) == Data([4, 2]))
        // The composer lists it at its next save.
        try store.save(ChatDraft(text: "typed", attachments: [ChatDraft.Attachment(id: "pasted", kind: .image, mediaType: "image/png")]),
                       sessionID: id)
        #expect(store.attachmentData(id: "pasted", sessionID: id) == Data([4, 2]))
    }

    /// The same when the draft has nothing else: the last release empties the draft, and the unlisted file stays.
    @Test func anAttachmentNotListedYetSurvivesTheDraftGoingEmpty() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.writeAttachment(Data([7]), id: "pasted", sessionID: id)
        try store.hold(id: "m", text: "sent", attachments: [.pastedText("held paste")], sessionID: id)
        let held = try #require(try store.load(sessionID: id)?.held.first?.attachments.first)
        try store.release(ids: ["m"], sessionID: id)
        #expect(try store.load(sessionID: id) == nil)
        #expect(store.attachmentData(id: "pasted", sessionID: id) == Data([7]))
        #expect(store.attachmentData(id: held.id, sessionID: id) == nil, "what the released message listed goes")
    }

    /// A driver made after a crash sweeps the files nobody lists and keeps the listed ones; with no draft file, the whole
    /// folder goes.
    @Test func theSweepAtADriversInitRemovesAnOrphanAndKeepsAListedFile() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.writeAttachment(Data([1]), id: "listed", sessionID: id)
        try store.writeAttachment(Data([2]), id: "orphan", sessionID: id)
        try store.save(ChatDraft(text: "x", attachments: [ChatDraft.Attachment(id: "listed", kind: .image, mediaType: "image/png")]),
                       sessionID: id)
        #expect(try store.recoverHeld(sessionID: id) == false)
        #expect(store.attachmentData(id: "listed", sessionID: id) == Data([1]))
        #expect(store.attachmentData(id: "orphan", sessionID: id) == nil)
        // No draft file at all: the folder is all orphans.
        let other = UUID()
        try store.writeAttachment(Data([3]), id: "orphan", sessionID: other)
        #expect(try store.recoverHeld(sessionID: other) == false)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: other).path))
    }
}
