import Foundation
import Observation

/// Which sessions have their inspector open. Closed by default; the choice is remembered per session in
/// `UIPreferences.inspectorOpen` (written by `CatalogModel.setInspectorOpen`). The inspector's content
/// belongs to the Inspector and Agents slice.
@MainActor @Observable
public final class InspectorState {
    public private(set) var openSessions: [UUID]

    init(open: [UUID]) { openSessions = open }

    public func isOpen(for id: UUID?) -> Bool {
        id.map { openSessions.contains($0) } ?? false
    }

    /// Returns whether anything changed. The newest open session is last; the oldest fall away at the cap.
    func set(_ open: Bool, for id: UUID) -> Bool {
        guard open != openSessions.contains(id) else { return false }
        if open {
            openSessions = UIPreferences.normalizedInspectors(openSessions + [id])
        } else {
            openSessions.removeAll { $0 == id }
        }
        return true
    }
}

extension CatalogModel {
    /// "Toggle Inspector": opens or closes the selected session's inspector. Nothing without a selected session.
    public func toggleInspector() {
        guard let id = selectedSessionID else { return }
        setInspectorOpen(!inspector.isOpen(for: id), for: id)
    }
}
