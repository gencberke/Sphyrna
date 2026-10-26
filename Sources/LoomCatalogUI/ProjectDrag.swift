import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The in-app drag of one project head in the sidebar's project view (W3-c): the project's id as UTF-8 text under its own type,
/// so a session drag is never taken as a project and a project is never dropped as a session. The id is the only thing offered,
/// under a type no other app reads: no name, no path.
enum ProjectDrag {
    static let typeIdentifier = "local.loom.desktop.project-reference"
    static let contentType = UTType(exportedAs: typeIdentifier)

    /// The project this app is dragging right now (`DragActivity`), so a block can show where the drop lands before the payload is
    /// read. Cleared when it is dropped or the mouse button is up.
    @MainActor static var current: UUID? { DragActivity.shared.project }

    /// What a head's drag offers; notes the project as the one being dragged. SwiftUI asks for it on the main thread.
    static func beginDrag(_ id: UUID) -> NSItemProvider {
        MainActor.assumeIsolated { DragActivity.shared.begin(.project, id) }
        return itemProvider(for: id)
    }

    static func itemProvider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { done in
            done(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// Whether a drop offers a project: the heads refuse everything else, sessions included.
    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.registeredTypeIdentifiers.contains(typeIdentifier) }
    }

    /// The project the first provider that carries one holds.
    @MainActor static func projectID(from providers: [NSItemProvider]) async -> UUID? {
        guard let provider = providers.first(where: { $0.registeredTypeIdentifiers.contains(typeIdentifier) }) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in continuation.resume(returning: data) }
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { UUID(uuidString: $0) }
    }

    /// The gap a drop on the block of project `index` lands in, or nil when nothing moves. A project dragged from another place
    /// takes that block's place: from above it lands after the block, from below before it (RESCUE C3; before this, a drop on the
    /// next expanded project landed in the gap the project already stood in and nothing moved). With the source unknown: before.
    static func gap(onBlock index: Int, from: Int?) -> Int? {
        guard let from else { return index }
        if from == index { return nil }
        return from < index ? index + 1 : index
    }

    /// Where a project dropped into gap `gap` ends: a project that moves down leaves its own place first.
    static func position(forGap gap: Int, from: Int) -> Int { gap > from ? gap - 1 : gap }
}
