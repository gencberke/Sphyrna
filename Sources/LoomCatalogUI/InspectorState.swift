import Foundation
import LoomCore
import Observation

/// The inspector's tabs (V09). The rest of the concept's tabs (Changes, Tasks, Side) come with the slices
/// that fill them.
public enum InspectorTab: String, CaseIterable, Sendable {
    case overview
    case agents
}

/// Which sessions have their inspector open, and which tab it shows. Closed by default; the open choice is
/// remembered per session in `UIPreferences.inspectorOpen` (written by `CatalogModel.setInspectorOpen`).
/// The tab is not remembered: a relaunch opens on Overview.
@MainActor @Observable
public final class InspectorState {
    public private(set) var openSessions: [UUID]
    public private(set) var tab: InspectorTab = .overview

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

    /// Returns whether the tab changed.
    func select(_ tab: InspectorTab) -> Bool {
        guard tab != self.tab else { return false }
        self.tab = tab
        return true
    }
}

extension CatalogModel {
    /// "Toggle Inspector": opens or closes the selected session's inspector. Nothing without a selected session.
    public func toggleInspector() {
        guard let id = selectedSessionID else { return }
        setInspector(open: !inspector.isOpen(for: id), for: id)
    }

    /// Every way the user opens or closes an inspector (the menu item, the header button, the column's own
    /// presentation binding) comes through here. Closing it ends the subagent transcript it was reading.
    public func setInspector(open: Bool, for id: UUID) {
        setInspectorOpen(open, for: id)
        if !open, viewedSubagent?.sessionID == id { closeSubagent() }
    }

    /// Shows a tab. Leaving Agents ends the transcript it was reading.
    public func selectInspectorTab(_ tab: InspectorTab) {
        guard inspector.select(tab) else { return }
        if tab != .agents { closeSubagent() }
    }

    /// The sessions whose context the inspector shows right now: the selected Claude session while its
    /// inspector is open on Overview. These are the "visible sessions" of `UsageModel.trackContext`.
    var inspectorContextSessions: [String] {
        guard let row = selectedRow, row.record.session.provider == .claude,
              inspector.isOpen(for: row.id), inspector.tab == .overview,
              let conversationID = row.record.session.providerConversationID else { return [] }
        return [conversationID]
    }

    /// Hands `inspectorContextSessions` to the usage model: one indexed lookup per named session, and none
    /// when the inspector is closed or shows another tab.
    func trackInspectorContext() {
        usage?.trackContext(sessions: inspectorContextSessions)
    }
}
