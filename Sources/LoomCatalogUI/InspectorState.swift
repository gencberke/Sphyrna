import Foundation
import LoomCore
import Observation

/// The inspector's tabs (V09, V20). The rest of the concept's tabs (Tasks, Side) come with the slices that fill them.
public enum InspectorTab: String, CaseIterable, Sendable {
    case overview
    case changes
    case agents

    /// The column's width while this tab is open: review needs the wide column, the others keep the narrow one.
    var width: CGFloat {
        self == .changes ? LoomTheme.Rhythm.inspectorWidthReview : LoomTheme.Rhythm.inspectorWidth
    }
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

    /// The sessions whose context is shown right now: the selected Claude session while its inspector is open on
    /// Overview, while the ring of its live Chat composer is on screen (V17), and while the header's model segment is
    /// (every face without the bar, fix round 3 F). These are the "visible sessions" of `UsageModel.trackContext`.
    var inspectorContextSessions: [String] {
        guard let row = selectedRow, row.record.session.provider == .claude,
              let conversationID = row.record.session.providerConversationID else { return [] }
        let inspectorShows = inspector.isOpen(for: row.id) && inspector.tab == .overview
        let headerShows = detailRoute.showsSessionHeader && headerShowsModelSegment(row)
        return inspectorShows || runEndpoint(of: row) == .pipe || headerShows ? [conversationID] : []
    }

    /// Hands `inspectorContextSessions` to the usage model: one indexed lookup per named session, and none
    /// when the inspector is closed or shows another tab.
    func trackInspectorContext() {
        usage?.trackContext(sessions: inspectorContextSessions)
    }
}
