import Foundation
import LoomChat

/// Drafts (CHAT-SPEC → Delivery and drafts): kept per session, written 300 ms after the last change, on blur, on send and
/// on Quit [T3]. What an interrupt gives back goes into the composer and into the draft at once.
extension ChatComposerModel {
    /// Takes the saved draft, if there is one (when the model is made). The file and the attachments' bytes are read, and the
    /// thumbnails made, off the main thread; the draft comes into the composer when they are back. Until then nothing is
    /// written (a save would replace the file with the text typed meanwhile) and `refresh` waits before it takes what
    /// the driver gave back. Text typed in the meantime stays, after the draft's.
    func restoreDraft() {
        guard let drafts else {
            draftLoaded = true
            return
        }
        let id = card
        restoreTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> RestoredDraft in
                let readAt = Date()
                let draft: ChatDraft?
                do { draft = try drafts.load(sessionID: id) } catch ChatDraftStoreError.unreadable(let keptAs) {
                    return RestoredDraft(draft: nil, attachments: [], readAt: readAt,
                                         problem: "A saved draft could not be read" + (keptAs.map { ". It was kept as \($0)." } ?? "."))
                } catch {
                    return RestoredDraft(draft: nil, attachments: [], readAt: readAt, problem: "A saved draft could not be read.")
                }
                var out: [ComposerAttachment] = []
                for item in draft?.attachments ?? [] {
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
                return RestoredDraft(draft: draft, attachments: out, readAt: readAt, problem: nil)
            }.value
            guard let self, !forgotten else { return }
            applyRestored(loaded)
        }
    }

    private func applyRestored(_ loaded: RestoredDraft) {
        draftLoaded = true
        // What was typed while the file was read is saved once it is known (saves waited for the file).
        defer { if !text.isEmpty || !attachments.isEmpty { scheduleSave() } }
        if let problem = loaded.problem {
            show(problem)
            return
        }
        guard let draft = loaded.draft else { return }
        restoredAt = loaded.readAt
        lastSavedDraft = draft
        // What was typed while the file was read goes after the draft's text.
        let typed = text
        setAttachments(loaded.attachments + attachments)
        setText(Self.join(draft.text, typed))
    }

    /// The draft file as read off the main thread.
    struct RestoredDraft {
        var draft: ChatDraft?
        var attachments: [ComposerAttachment]
        var readAt: Date
        var problem: String?
    }

    /// Resolves once the saved draft, with its attachments, is in the composer (tests).
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
        return ChatDraft(text: joined, attachments: listed)
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
        guard let drafts, !forgotten, draftLoaded else { return }
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
    func takeReturnedDrafts(_ all: [ChatReturnedDraft]) async {
        // One the driver wrote into the draft file before this composer was made came back with the draft.
        let returned = all.filter { !restoredAlready($0) }
        guard !returned.isEmpty else { return }
        let back = returned.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        // The images are decoded again, for their thumbnails, off the main thread.
        let outgoing = returned.flatMap(\.attachments)
        let restored = await Task.detached(priority: .userInitiated) { outgoing.map { ComposerAttachment(restoring: $0) } }.value
        guard !forgotten else { return }
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

    /// Messages that came back and were sent again (a successful Retry) leave the composer's text and attachments, so the
    /// same message is not in the field twice.
    func takeWithdrawnDrafts(_ withdrawn: [ChatReturnedDraft]) {
        guard !withdrawn.isEmpty else { return }
        for draft in withdrawn {
            var gone = draft.attachments
            func without(_ attachments: [ComposerAttachment]) -> [ComposerAttachment] {
                var kept: [ComposerAttachment] = []
                for attachment in attachments {
                    if let index = gone.firstIndex(of: attachment.outgoing) { gone.remove(at: index) } else { kept.append(attachment) }
                }
                return kept
            }
            if var edit = editing {
                edit.savedText = ChatDraftText.removing(draft.text, from: edit.savedText)
                edit.savedAttachments = without(edit.savedAttachments)
                setEditing(edit)
            } else {
                setAttachments(without(attachments))
                let trimmed = ChatDraftText.removing(draft.text, from: text)
                if trimmed != text { setText(trimmed) }
            }
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
