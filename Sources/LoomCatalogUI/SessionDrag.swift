import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The in-app drag of one session (U4 tabs; the Chat composer's mention reads it too). The payload is the session's id as
/// UTF-8 text under `typeIdentifier`, plus the title as plain text for anything outside the app: no path, no file, nothing
/// another app could use to reach the user's sessions. The type is not declared in Info.plist and needs no declaration: within
/// the app it is matched by identifier, on the drag pasteboard as on an item provider.
public enum SessionDrag {
    public static let typeIdentifier = "local.loom.desktop.session-reference"
    /// The type on a drag pasteboard (`NSDraggingInfo.draggingPasteboard`), for an AppKit drop target.
    public static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)
    /// The type a SwiftUI drop destination asks for.
    public static let contentType = UTType(exportedAs: typeIdentifier)

    /// The session a pasteboard carries, or nil for anything else (plain text that looks like an id included).
    public static func sessionID(from pasteboard: NSPasteboard) -> UUID? {
        pasteboard.data(forType: pasteboardType).flatMap(sessionID(from:))
    }

    /// Writes the payload to a pasteboard, as a drag of the session does.
    public static func write(_ id: UUID, title: String?, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setData(data(for: id), forType: pasteboardType)
        if let title { item.setString(title, forType: .string) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// What a drag of the session offers (SwiftUI's `onDrag`).
    static func itemProvider(for id: UUID, title: String?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { done in
            done(data(for: id), nil)
            return nil
        }
        if let title {
            provider.registerObject(title as NSString, visibility: .all)
            provider.suggestedName = title
        }
        return provider
    }

    /// Whether a drop offers a session: the strip refuses everything else.
    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.registeredTypeIdentifiers.contains(typeIdentifier) }
    }

    /// The session the first provider that carries one holds.
    @MainActor static func sessionID(from providers: [NSItemProvider]) async -> UUID? {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in continuation.resume(returning: data) }
        }
        return data.flatMap(sessionID(from:))
    }

    static func data(for id: UUID) -> Data { Data(id.uuidString.utf8) }

    static func sessionID(from data: Data) -> UUID? {
        String(data: data, encoding: .utf8).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

extension View {
    /// Makes the view a drag source for the session. The drag starts only past the system's drag threshold, so a click, a
    /// double click, a context menu, hover and the view's accessibility stay as they were.
    func sessionDragSource(_ id: UUID, title: String) -> some View {
        modifier(SessionDragSource(id: id, title: title))
    }
}

private struct SessionDragSource: ViewModifier {
    let id: UUID
    let title: String

    func body(content: Content) -> some View {
        let _ = SessionDragProbe.source(id)
        let id = id
        content
            .onDrag {
                MainActor.assumeIsolated { DragActivity.shared.begin(.session, id) }
                return SessionDrag.itemProvider(for: id, title: title)
            }
            .dragSourceDimming(id)
    }
}

/// Tests: which sessions' views carry a drag source. Off (an emptiness check) unless a test watches.
@MainActor
enum SessionDragProbe {
    static var watching = false
    private(set) static var sources: Set<UUID> = []

    static func source(_ id: UUID) {
        guard watching else { return }
        sources.insert(id)
    }

    static func watch() { watching = true; sources = [] }
    static func stop() { watching = false; sources = [] }
}
