import AppKit
import Foundation
import LoomChat
import UniformTypeIdentifiers

/// Attachments (CHAT-SPEC → Attachments): images from +, paste and drop; a large paste as a chip; files as `@path`.
extension ChatComposerModel {
    // MARK: Adding

    /// Files chosen with + or dropped: an image becomes a thumbnail above the text, anything else an `@path` in it.
    func attach(fileURLs urls: [URL]) {
        var mentions: [String] = []
        for url in urls {
            if ComposerImages.isImageFile(url) {
                guard let data = readImageFile(url) else { continue }
                attachImage(data, name: url.lastPathComponent)
            } else {
                mentions.append(ComposerPasteboard.mention(for: url, relativeTo: environment.workingDirectory()))
            }
        }
        if !mentions.isEmpty { insert(mentions.joined(separator: " ") + " ") }
    }

    /// Prepares an image off the main thread (decoded, scaled to 2000 px, a thumbnail) and attaches it. Sending waits for
    /// it.
    func attachImage(_ data: Data, name: String?) {
        beginPreparing()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ComposerImages.Prepared, ComposerImages.Failure> in
                do { return .success(try ComposerImages.prepare(data)) } catch let error as ComposerImages.Failure {
                    return .failure(error)
                } catch { return .failure(.unreadable) }
            }.value
            guard let self else { return }
            endPreparing()
            switch result {
            case let .success(prepared):
                let attachment = ComposerAttachment(
                    id: UUID().uuidString.lowercased(), name: name,
                    content: .image(mediaType: prepared.mediaType, base64: prepared.data.base64EncodedString(),
                                    pixelSize: prepared.pixelSize),
                    thumbnail: prepared.thumbnail)
                add(attachment)
            case .failure(.tooLarge):
                show("\(name ?? "That image") is too large to attach (over 40 MB).")
            case .failure(.unreadable):
                show("\(name ?? "That image") could not be read as an image.")
            }
        }
    }

    /// The bytes of an image file, mapped, after its size is checked (a file over the limit is not read at all). Says why on
    /// a refusal.
    func readImageFile(_ url: URL) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, size > ComposerImages.refuseAbove {
            show("\(url.lastPathComponent) is too large to attach (over 40 MB).")
            return nil
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            show("\(url.lastPathComponent) could not be read.")
            return nil
        }
        return data
    }

    /// A paste of 32 KiB or more is a chip that goes out as a text block of its own [T3]. One over 16 MB is refused, with a
    /// notice.
    func addPastedText(_ text: String) {
        guard text.utf8.count <= ComposerPaste.maximumChipBytes else {
            show("That paste is over 16 MB, too much to send as text. Save it as a file and attach the file instead.")
            return
        }
        add(ComposerAttachment(id: UUID().uuidString.lowercased(), name: nil, content: .pastedText(text), thumbnail: nil))
    }

    private func add(_ attachment: ComposerAttachment) {
        keepAttachmentFile(attachment)
        setAttachments(attachments + [attachment])
        scheduleSave()
    }

    func removeAttachment(_ id: String) {
        setAttachments(attachments.filter { $0.id != id })
        scheduleSave()
    }

    /// Text inserted at the caret (a file mention).
    func insert(_ text: String) {
        if let editor {
            editor.insertAtCaret(text)
            editor.focus()
        } else {
            setText(self.text + text)
        }
    }

    // MARK: Mentions (D-96)

    /// Whether `id` may be mentioned now: a session the catalog says this composer may mention (Claude, not a side chat), not
    /// this composer's own, and not one a pill already names.
    func canMention(_ id: UUID) -> Bool {
        id != card && !mentions.contains { $0.id == id } && environment.mentionTarget(id) != nil
    }

    /// Adds a pill for the session (a drop, the `@` list). A refused one changes nothing. Returns whether a pill was added.
    @discardableResult
    func addMention(_ id: UUID) -> Bool {
        guard id != card, !mentions.contains(where: { $0.id == id }), let target = environment.mentionTarget(id) else { return false }
        setMentions(mentions + [target])
        scheduleSave()
        return true
    }

    func removeMention(_ id: UUID) {
        setMentions(mentions.filter { $0.id != id })
        scheduleSave()
    }

    /// A session dragged onto the field or the chip row (`ComposerEditorHost`).
    @discardableResult
    func takesSession(_ id: UUID, perform: Bool) -> Bool {
        guard perform else { return canMention(id) }
        guard addMention(id) else { return false }
        editor?.focus()
        return true
    }

    // MARK: Paste and drop

    /// ⌘V (`plain` false) or ⌘⇧V (`plain` true). Returns false when the text view should paste as it does: plain text under
    /// the chip size. ⌘⇧V pastes the pasteboard's text inline, whatever its size, and never makes a chip.
    @discardableResult
    func paste(from pasteboard: NSPasteboard, plain: Bool) -> Bool {
        let items = ComposerPasteboard.items(from: pasteboard)
        if plain {
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }
            insert(text)
            return true
        }
        return handle(items, insertsSmallText: false)
    }

    /// A drop of files or an image onto the composer.
    @discardableResult
    func drop(from pasteboard: NSPasteboard) -> Bool {
        handle(ComposerPasteboard.items(from: pasteboard), insertsSmallText: true)
    }

    /// Files or folders dropped on the session's stream (`ComposerPaneDrop`): they land here as on the field, and the field
    /// takes the keyboard. Anything without a file is refused.
    @discardableResult
    func dropOnPane(_ pasteboard: NSPasteboard) -> Bool {
        guard ComposerPasteboard.items(from: pasteboard).contains(where: {
            if case .imageFile = $0 { true } else if case .otherFile = $0 { true } else { false }
        }), drop(from: pasteboard) else { return false }
        editor?.focus()
        return true
    }

    private func handle(_ items: [ComposerPasteItem], insertsSmallText: Bool) -> Bool {
        guard !items.isEmpty else { return false }
        var mentions: [String] = []
        var handled = false
        for item in items {
            switch item {
            case let .imageFile(url):
                if let data = readImageFile(url) {
                    attachImage(data, name: url.lastPathComponent)
                }
                handled = true
            case let .otherFile(url):
                mentions.append(ComposerPasteboard.mention(for: url, relativeTo: environment.workingDirectory()))
                handled = true
            case let .imageData(data):
                attachImage(data, name: nil)
                handled = true
            case let .text(text):
                if ComposerPaste.becomesChip(text) {
                    addPastedText(text)
                    handled = true
                } else if insertsSmallText {
                    insert(text)
                    handled = true
                }
            }
        }
        if !mentions.isEmpty { insert(mentions.joined(separator: " ") + " ") }
        return handled
    }

    // MARK: The file panel

    /// + → Add images and files: images become thumbnails, other files `@path` mentions.
    func pickFiles(in window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        if let folder = environment.workingDirectory() { panel.directoryURL = URL(fileURLWithPath: folder) }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.attach(fileURLs: urls) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }
}
