import Foundation
import LoomChat

/// Drafts (CHAT-SPEC → Delivery and drafts): kept per session, written 300 ms after the last change, on blur, on send and
/// on Quit [T3]. What an interrupt gives back goes into the composer and into the draft at once.
extension ChatComposerModel {
    /// Takes the saved draft, if there is one (when the model is made).
    func restoreDraft() {
        guard let drafts else { return }
        let draft: ChatDraft?
        do {
            draft = try drafts.load(sessionID: card)
        } catch let ChatDraftStoreError.unreadable(keptAs) {
            show("A saved draft could not be read" + (keptAs.map { ". It was kept as \($0)." } ?? "."))
            return
        } catch {
            show("A saved draft could not be read.")
            return
        }
        guard let draft else { return }
        restoredAt = Date()
        setText(draft.text)
        lastSavedDraft = draft
        guard !draft.attachments.isEmpty else { return }
        // The files are read and the thumbnails made off the main thread; until they are back, the draft keeps listing them
        // (`pendingRestore`), so a save in between does not delete their files.
        pendingRestore = draft.attachments
        let listed = draft.attachments
        let id = card
        restoreTask = Task { [weak self] in
            let restored = await Task.detached(priority: .userInitiated) { () -> [ComposerAttachment] in
                var out: [ComposerAttachment] = []
                for item in listed {
                    guard let data = drafts.attachmentData(id: item.id, sessionID: id) else { continue }
                    switch item.kind {
                    case .pastedText:
                        if let text = String(data: data, encoding: .utf8) {
                            out.append(ComposerAttachment(id: item.id, name: nil, content: .pastedText(text), thumbnail: nil))
                        }
                    case .image:
                        out.append(ComposerAttachment(restoring: .image(mediaType: item.mediaType ?? "image/png",
                                                                         base64: data.base64EncodedString()),
                                                      id: item.id, name: item.name))
                    }
                }
                return out
            }.value
            guard let self, !forgotten else { return }
            pendingRestore = []
            setAttachments(restored + attachments)
        }
    }

    /// Resolves once the attachments of the restored draft are back in the composer (tests).
    func attachmentsRestored() async {
        await restoreTask?.value
    }

    /// What the draft file holds now: messages not accepted yet first (they were typed first), then the composer. While a
    /// queued message is edited, the composer's own text is the saved one, never the item's.
    func draftForSave() -> ChatDraft {
        var pieces = inFlight.map(\.text)
        var kept = inFlight.flatMap(\.attachments)
        pieces.append(editing?.savedText ?? text)
        kept += editing?.savedAttachments ?? attachments
        let joined = pieces.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let listed = kept.map { attachment -> ChatDraft.Attachment in
            switch attachment.content {
            case let .image(mediaType, _, _):
                ChatDraft.Attachment(id: attachment.id, kind: .image, mediaType: mediaType, name: attachment.name)
            case .pastedText:
                ChatDraft.Attachment(id: attachment.id, kind: .pastedText)
            }
        }
        return ChatDraft(text: joined, attachments: listed + pendingRestore)
    }

    func scheduleSave() {
        guard !forgotten else { return }
        saveTask?.cancel()
        let delay = environment.draftDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    /// Writes the draft now (blur, send, Quit).
    func flushDraft() {
        saveTask?.cancel()
        saveTask = nil
        writePendingFiles()
        saveDraftNow()
    }

    func saveDraftNow() {
        saveTask = nil
        // A session deleted through Loom never gets its draft file back from a late timer or a blur.
        guard let drafts, !forgotten else { return }
        let draft = draftForSave()
        if let last = lastSavedDraft, last.text == draft.text, last.attachments == draft.attachments { return }
        do {
            try drafts.save(draft, sessionID: card)
            lastSavedDraft = draft
        } catch {
            show("This draft could not be saved. What you typed is still here, but it may be gone after a restart.")
        }
    }

    /// Keeps an attachment's bytes beside the draft, so the draft file stays small while the text changes.
    /// The file is written off the main thread, after the files written before it.
    func keepAttachmentFile(_ attachment: ComposerAttachment) {
        guard let drafts, !forgotten else { return }
        let content = attachment.content
        let id = attachment.id
        let card = card
        let previous = fileWrites
        unwrittenFiles[id] = content
        fileWrites = Task { [weak self] in
            await previous?.value
            // A flush may have written it already.
            guard await self?.unwrittenFiles[id] != nil else { return }
            let failed = await Task.detached(priority: .utility) { () -> Bool in
                guard let data = ComposerAttachment.storedData(of: content) else { return true }
                do { try drafts.writeAttachment(data, id: id, sessionID: card) } catch { return true }
                return false
            }.value
            self?.unwrittenFiles[id] = nil
            if failed { self?.show("An attachment could not be saved with the draft.") }
        }
    }

    /// Quit and blur must not leave a draft that lists a file which is not there yet.
    func writePendingFiles() {
        guard let drafts, !unwrittenFiles.isEmpty else { return }
        let pending = unwrittenFiles
        unwrittenFiles = [:]
        for (id, content) in pending {
            guard let data = ComposerAttachment.storedData(of: content) else { continue }
            try? drafts.writeAttachment(data, id: id, sessionID: card)
        }
    }

    /// Resolves once the attachment files asked for so far are written (tests).
    func attachmentFilesWritten() async {
        await fileWrites?.value
    }

    /// Whether `returned` was in the draft file this composer restored (the driver wrote it before the composer was made).
    func restoredAlready(_ returned: ChatReturnedDraft) -> Bool {
        guard let at = returned.persistedAt, let restoredAt else { return false }
        return at <= restoredAt
    }

    /// The run moved to another card (`/clear`): the draft goes with it.
    func moveDraft(to newCard: UUID) {
        guard newCard != card else { return }
        flushDraft()
        try? drafts?.move(from: card, to: newCard)
        card = newCard
    }

    /// Messages an interrupt (or a Stop) gave back come into the composer (CHAT-SPEC → Queue → Pause): in front of what is
    /// typed now, because they were written first.
    func takeReturnedDrafts(_ all: [ChatReturnedDraft]) {
        // One the driver wrote into the draft file before this composer was made came back with the draft.
        let returned = all.filter { !restoredAlready($0) }
        guard !returned.isEmpty else { return }
        let back = returned.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let restored = returned.flatMap(\.attachments).map { ComposerAttachment(restoring: $0) }
        for attachment in restored { keepAttachmentFile(attachment) }
        if var edit = editing {
            // The composer holds a queued message: the returned ones wait with the user's own draft.
            edit.savedText = Self.join(back, edit.savedText)
            edit.savedAttachments = restored + edit.savedAttachments
            setEditing(edit)
        } else {
            setAttachments(restored + attachments)
            setText(Self.join(back, text))
        }
        flushDraft()
    }

    /// `first`, a blank line, `second`; either may be empty.
    static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + "\n\n" + second
    }
}
