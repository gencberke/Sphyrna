import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The in-app drag of one project head in the sidebar's project view (W3-c): the project's id as UTF-8 text under its own type,
/// so a session drag is never taken as a project and a project is never dropped as a session. Nothing is offered outside the app.
enum ProjectDrag {
    static let typeIdentifier = "local.loom.desktop.project-reference"
    static let contentType = UTType(exportedAs: typeIdentifier)

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

    /// The gap a drop on head `index` lands in: before the head in its upper half; after it in its lower half only where nothing
    /// of the project follows the head (a collapsed project, or the last one, so a project can reach the end).
    static func gap(onHead index: Int, y: CGFloat, height: CGFloat, canDropAfter: Bool) -> Int {
        canDropAfter && y > height / 2 ? index + 1 : index
    }

    /// Where a project dropped into gap `gap` ends: a project that moves down leaves its own place first.
    static func position(forGap gap: Int, from: Int) -> Int { gap > from ? gap - 1 : gap }
}
