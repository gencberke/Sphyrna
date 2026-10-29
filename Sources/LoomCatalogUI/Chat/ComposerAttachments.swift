import AppKit
import ImageIO
import LoomChat
import LoomCore
import SwiftUI
import UniformTypeIdentifiers

/// One thing attached to the message being written (CHAT-SPEC → Attachments): an image, or a large paste that goes out
/// as a text block of its own. A file is not an attachment: it becomes an `@path` in the text.
struct ComposerAttachment: Identifiable, Equatable {
    enum Content: Equatable {
        case image(mediaType: String, base64: String, pixelSize: CGSize)
        case pastedText(String)
    }

    let id: String
    var name: String?
    var content: Content
    /// A small picture for an image (made when it was prepared).
    var thumbnail: NSImage?

    static func == (lhs: ComposerAttachment, rhs: ComposerAttachment) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.name == rhs.name
    }

    var outgoing: ChatOutgoingAttachment {
        switch content {
        case let .image(mediaType, base64, _): .image(mediaType: mediaType, base64: base64)
        case let .pastedText(text): .pastedText(text)
        }
    }

    /// "Pasted text · 48 KB", or the image's name.
    var label: String {
        switch content {
        case let .pastedText(text):
            "Pasted text \u{00B7} " + ComposerPaste.sizeLabel(bytes: text.utf8.count)
        case let .image(_, _, size):
            name ?? "Image \(Int(size.width)) \u{00D7} \(Int(size.height))"
        }
    }

    var isImage: Bool { if case .image = content { true } else { false } }

    /// The chip's name, and the size after it in mono ("Pasted text", "48 KB"); an image has no size.
    var title: String {
        switch content {
        case .pastedText: "Pasted text"
        case .image: label
        }
    }

    var detail: String? {
        switch content {
        case let .pastedText(text): ComposerPaste.sizeLabel(bytes: text.utf8.count)
        case .image: nil
        }
    }
}

/// A session the message mentions (D-96): a pill in the chip row, not text in the field. Only the session's id is kept with
/// the draft; the title and the harness are the catalog's, and the mention text (`CatalogModel.sessionMentionText(for:)`) is
/// built when the message goes out.
struct ComposerMention: Identifiable, Equatable {
    let id: UUID
    var title: String
    var provider: ManagedSession.Provider

    /// What VoiceOver reads for the pill.
    var accessibilityLabel: String { "Mentions session \(title)" }

    /// The pill of a session the catalog no longer knows (a draft restored after the session went): left out on send.
    static func unavailable(_ id: UUID) -> ComposerMention {
        ComposerMention(id: id, title: "Session not found", provider: .claude)
    }
}

/// How the mentions go into the message: each mention's text and a space, in pill order, before the user's text, as the `@`
/// list inserted them before it made pills.
enum ComposerMentionText {
    /// The message as sent: the mention texts, then the user's words. A message of mentions alone ends with the last one.
    static func message(mentions texts: [String], text: String) -> String {
        guard !texts.isEmpty else { return text }
        let joined = texts.map { $0 + " " }.joined() + text
        return text.contains(where: { !$0.isWhitespace }) ? joined : joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The notice for mentions left out of a message.
    static func skippedNotice(_ count: Int) -> String {
        count == 1
            ? "One mention was skipped: that session is gone or has no transcript."
            : "\(count) mentions were skipped: those sessions are gone or have no transcript."
    }
}

/// A mention's pill in the composer's chip row: the harness mark, the session's title and a remove button, in the file chips'
/// shape. VoiceOver reads "Mentions session <title>" and offers Remove.
struct ComposerMentionPill: View {
    let mention: ComposerMention
    let remove: () -> Void

    var body: some View {
        HStack(spacing: LoomTheme.Composer.mentionPartGap) {
            ProviderIcon(provider: mention.provider, size: LoomTheme.Composer.mentionMark)
            Text(mention.title).font(LoomTheme.Composer.attachmentFont).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: LoomTheme.Composer.attachmentMaxLabelWidth, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            Button(action: remove) {
                InkIcon(.close, size: LoomTheme.Icon.tiny).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: LoomTheme.Composer.queueIcon, height: LoomTheme.Composer.queueIcon).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Remove mention of \(mention.title)")
        }
        .foregroundStyle(LoomTheme.Text.primary)
        .padding(.leading, LoomTheme.Composer.attachmentPaddingLeading).padding(.trailing, LoomTheme.Composer.mentionPaddingTrailing)
        .frame(height: LoomTheme.Composer.mentionHeight)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Composer.attachmentRadius).fill(LoomTheme.Composer.mentionFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Composer.attachmentRadius)
            .strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
        .help(mention.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mention.accessibilityLabel)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityAction(named: "Remove", remove)
        .accessibilityIdentifier("composer-mention")
    }
}

/// Large pastes and what they are called.
enum ComposerPaste {
    /// A paste of this many UTF-16 units or UTF-8 bytes, whichever is reached first, becomes a chip [T3].
    static let chipThreshold = 32 * 1024
    /// The most a chip may hold (UTF-8 bytes). A bigger paste is refused with a notice: the draft store keeps no file over
    /// 64 MB, and a chip this size is no message for Claude anyway.
    static let maximumChipBytes = 16 << 20

    static func becomesChip(_ text: String) -> Bool {
        // `utf16.count` is a scan for a bridged string; check the cheaper bound first.
        text.utf8.count >= chipThreshold || text.utf16.count >= chipThreshold
    }

    static func sizeLabel(bytes: Int) -> String {
        "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
    }
}

/// Images for the composer: scaled to at most 2000 px on the long side [T3], in a type the API takes. The CLI shrinks big
/// images itself (S1 §D15: a 7.2 MB PNG went out as a 0.5 MB JPEG), so Loom's own check only names an image that is far
/// too large.
enum ComposerImages {
    static let maximumLongSide = 2000
    static let thumbnailSide = 160
    /// A file above this is not read at all.
    static let refuseAbove = 40 << 20
    /// An image of more pixels than this is never decoded (its file can be small and its bitmap gigabytes).
    static let maximumPixels = 120_000_000
    static let apiTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    enum Failure: Error, Equatable {
        case tooLarge
        case unreadable
    }

    struct Prepared {
        var mediaType: String
        var data: Data
        var pixelSize: CGSize
        var thumbnail: NSImage?
    }

    /// Decodes `data`, scales it when its long side is over the limit (or re-encodes a type the API does not take), and
    /// makes the thumbnail. Pure work on the bytes: call it off the main thread.
    static func prepare(_ data: Data) throws -> Prepared {
        guard data.count <= refuseAbove else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Failure.unreadable }
        // Checked from the file's own properties, before any pixel is decoded.
        guard width * height <= maximumPixels else { throw Failure.tooLarge }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let mime = type?.preferredMIMEType
        let longSide = max(width, height)
        var outData = data
        var outType = mime ?? ""
        var size = CGSize(width: width, height: height)
        if longSide > maximumLongSide || !apiTypes.contains(outType) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(longSide, maximumLongSide),
            ]
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }
            let hasAlpha = scaled.alphaInfo != .none && scaled.alphaInfo != .noneSkipFirst && scaled.alphaInfo != .noneSkipLast
            let keepsPNG = hasAlpha || type == .png
            guard let encoded = encode(scaled, as: keepsPNG ? UTType.png : UTType.jpeg) else { throw Failure.unreadable }
            outData = encoded
            outType = keepsPNG ? "image/png" : "image/jpeg"
            size = CGSize(width: scaled.width, height: scaled.height)
        }
        return Prepared(mediaType: outType, data: outData, pixelSize: size, thumbnail: thumbnail(of: source))
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.88] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func thumbnail(of source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Whether the file at `url` is an image the composer attaches (anything else becomes an `@path`).
    static func isImageFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true
    }
}

/// What a paste or a drop carries, in the order the composer treats it.
enum ComposerPasteItem: Equatable {
    case imageFile(URL)
    case otherFile(URL)
    case imageData(Data)
    case text(String)
}

enum ComposerPasteboard {
    /// Files first (an image file is an image, any other file a mention), then raw image data, then text. A pasteboard with
    /// text and an image (a copy from a page) pastes the text: the image is a rendering of it.
    static func items(from pasteboard: NSPasteboard) -> [ComposerPasteItem] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { ComposerImages.isImageFile($0) ? .imageFile($0) : .otherFile($0) }
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return [.text(text)] }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = pasteboard.data(forType: type) { return [.imageData(data)] }
        }
        return []
    }

    /// `@path` for a file: relative to the session's folder when it lies inside it, else absolute; quoted when it has a space.
    static func mention(for url: URL, relativeTo folder: String?) -> String {
        var path = url.standardizedFileURL.path
        if let folder {
            let root = URL(fileURLWithPath: folder).standardizedFileURL.path
            if path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
        }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return ComposerFileIndex.insertion(for: path, isDirectory: isFolder).trimmingCharacters(in: .whitespaces)
    }
}

extension ComposerPasteboard {
    /// What a drop puts into a composer that sends text only (the draft page, Side, Quick Question): every file as `@path`, an
    /// image file too, and every folder as `@folder/`, relative to `folder` when inside it, joined by spaces with one after.
    /// Nil when the pasteboard carries no file (text, raw image data, a session). Only each item's kind is read.
    static func textOnlyMentions(from pasteboard: NSPasteboard, relativeTo folder: String?) -> String? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls.map { mention(for: $0, relativeTo: folder) }.joined(separator: " ") + " "
    }

    /// Drops files and folders into a text-only composer: at the caret of its field when the field is there (which then takes
    /// the keyboard), else after the text it keeps. False when the drop carries no file; it never sends.
    @MainActor
    static func dropMentions(from pasteboard: NSPasteboard, relativeTo folder: String?, into bridge: (any ComposerEditorBridge)?,
                             text: String, setText: (String) -> Void) -> Bool {
        guard let mentions = textOnlyMentions(from: pasteboard, relativeTo: folder) else { return false }
        if let bridge {
            bridge.insertAtCaret(mentions)
            bridge.focus()
        } else {
            setText(appending(mentions, to: text))
        }
        return true
    }

    /// `mentions` after `text`, a space between them when the text does not end in one.
    static func appending(_ mentions: String, to text: String) -> String {
        text.isEmpty || text.last?.isWhitespace == true ? text + mentions : text + " " + mentions
    }
}

/// A drop of files or folders anywhere on a pane (the live stream, the draft page) lands in its composer, as on its field
/// (W3-d). The drag pasteboard is read as the drop lands. Only files are taken: text and sessions are not this target's.
struct ComposerPaneDrop: DropDelegate {
    /// Whether the composer takes a drop now (the draft page's is locked while its draft is being sent).
    var accepts: @MainActor () -> Bool = { true }
    let land: @MainActor (NSPasteboard) -> Bool

    func validateDrop(info: DropInfo) -> Bool { accepts() && info.hasItemsConforming(to: [.fileURL]) }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: accepts() ? .copy : .forbidden) }

    func performDrop(info: DropInfo) -> Bool { land(NSPasteboard(name: .drag)) }
}

extension ComposerAttachment {
    /// An attachment an interrupt gave back, or a draft kept: the bytes are decoded again for the thumbnail.
    init(restoring outgoing: ChatOutgoingAttachment, id: String = UUID().uuidString.lowercased(), name: String? = nil) {
        switch outgoing {
        case let .pastedText(text):
            self.init(id: id, name: nil, content: .pastedText(text), thumbnail: nil)
        case let .image(mediaType, base64):
            let data = Data(base64Encoded: base64) ?? Data()
            let prepared = try? ComposerImages.prepare(data)
            self.init(id: id, name: name,
                      content: .image(mediaType: mediaType, base64: base64, pixelSize: prepared?.pixelSize ?? .zero),
                      thumbnail: prepared?.thumbnail)
        }
    }

    /// The bytes a draft keeps for this attachment.
    var storedData: Data? { Self.storedData(of: content) }

    static func storedData(of content: Content) -> Data? {
        switch content {
        case let .pastedText(text): Data(text.utf8)
        case let .image(_, base64, _): Data(base64Encoded: base64)
        }
    }
}
