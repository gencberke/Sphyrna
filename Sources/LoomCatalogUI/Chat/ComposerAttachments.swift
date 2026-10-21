import AppKit
import ImageIO
import LoomChat
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
