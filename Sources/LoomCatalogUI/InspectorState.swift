import Foundation
import LoomCore
import Observation

/// The inspector's tabs (V09, V20, V22). The concept's Tasks tab comes with its own slice.
public enum InspectorTab: String, CaseIterable, Sendable {
    case overview
    case changes
    case agents
    /// A session's side chats (V22). Only on a Claude session that has a provider conversation id (`CatalogModel.inspectorTabs`).
    case side

    /// The column's default width while this tab is open: review needs the wide column, a side chat a medium one, the others
    /// keep the narrow one. The width it is drawn at is its class's remembered one (`InspectorWidthClass`).
    var width: CGFloat { InspectorWidthClass(tab: self, showsTranscript: false).defaultWidth }
}

/// Which sessions have their inspector open, and which tab it shows. Closed by default; the open choice is
/// remembered per session in `UIPreferences.inspectorOpen` (written by `CatalogModel.setInspectorOpen`).
/// The tab is not remembered: a relaunch opens on Overview. Each width class's width is remembered too, in
/// `UIPreferences.inspectorWidths` (written by `CatalogModel.setInspectorWidth`).
@MainActor @Observable
public final class InspectorState {
    public private(set) var openSessions: [UUID]
    public private(set) var tab: InspectorTab = .overview
    public private(set) var widths: InspectorWidths
    /// The drag on the resize handle, while there is one. Only the handle and its guide read it, so a drag step redraws them
    /// and nothing else; the widths change once, on release (`CatalogModel+InspectorWidth`).
    private(set) var resize: InspectorResize?

    init(open: [UUID], widths: InspectorWidths = InspectorWidths()) {
        openSessions = open
        self.widths = widths
    }

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

    /// Returns whether the class's width changed.
    func setWidth(_ width: CGFloat, for widthClass: InspectorWidthClass) -> Bool {
        var updated = widths
        updated[widthClass] = width
        guard updated != widths else { return false }
        widths = updated
        return true
    }

    func beginResize(_ resize: InspectorResize) { self.resize = resize }

    /// Moves the drag's edge; a step that lands on the same whole point changes nothing.
    func moveResize(to width: CGFloat) {
        guard var resize, resize.live != width else { return }
        resize.live = width
        self.resize = resize
    }

    /// Ends the drag and returns it.
    func endResize() -> InspectorResize? {
        defer { resize = nil }
        return resize
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

    /// The tabs the selected session's inspector offers: Side only for a Claude session that has a provider conversation id
    /// (a fork needs one), on either face. A side chat is never selected, so it never gets the tab; Codex never does.
    var inspectorTabs: [InspectorTab] {
        InspectorTab.allCases.filter { $0 != .side || sideTabIsOffered(for: selectedRow) }
    }

    /// The tab the open inspector shows: the chosen one, or Overview where the chosen one is not offered (Side was open, and
    /// the selection moved to a Codex session). Its width is this tab's.
    var shownInspectorTab: InspectorTab {
        inspectorTabs.contains(inspector.tab) ? inspector.tab : .overview
    }

    /// The sessions whose context is shown right now: the selected Claude session while its inspector is open on
    /// Overview, while the ring of its live Chat composer is on screen (V17), and while the header's model segment is
    /// (every face without the bar, fix round 3 F). These are the "visible sessions" of `UsageModel.trackContext`.
    var inspectorContextSessions: [String] {
        guard let row = selectedRow, capabilities(of: row.record.session.provider).readsContext,
              let conversationID = row.record.session.providerConversationID else { return [] }
        let inspectorShows = inspector.isOpen(for: row.id) && shownInspectorTab == .overview
        let headerShows = detailRoute.showsSessionHeader && headerShowsModelSegment(row)
        return inspectorShows || runEndpoint(of: row) == .pipe || headerShows ? [conversationID] : []
    }

    /// Hands `inspectorContextSessions` to the usage model: one indexed lookup per named session, and none
    /// when the inspector is closed or shows another tab.
    func trackInspectorContext() {
        usage?.trackContext(sessions: inspectorContextSessions)
    }
}
