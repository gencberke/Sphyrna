import Foundation

public enum TabDirection: Sendable {
    case next, previous
}

/// What the menu items and shortcuts do with the tab strip (U4). They act only
/// while the strip is on screen, so a hidden strip never changes the selection.
extension CatalogModel {
    /// The strip is drawn for two or more visible tabs, and not over the development terminal.
    public var tabStripIsVisible: Bool {
        !showsDevTerminal && TabStripLayout.isVisible(tabCount: visibleTabIDs.count)
    }

    public var canSelectAdjacentTab: Bool { tabStripIsVisible }
    public var canCloseSelectedTab: Bool { tabStripIsVisible && selectedSessionID != nil }

    /// Shows the next or previous visible tab, wrapping at the ends. With no
    /// selection `.next` picks the first tab and `.previous` the last.
    @discardableResult
    public func selectAdjacentTab(_ direction: TabDirection) -> Bool {
        guard canSelectAdjacentTab else { return false }
        let ids = visibleTabIDs
        let target: UUID
        if let selectedSessionID, let index = ids.firstIndex(of: selectedSessionID) {
            let step = direction == .next ? 1 : ids.count - 1
            target = ids[(index + step) % ids.count]
        } else {
            target = direction == .next ? ids[0] : ids[ids.count - 1]
        }
        selectTab(target)
        return true
    }

    /// Closes the selected tab (Close Tab): only unpins, never stops a run.
    public func closeSelectedTab() {
        guard canCloseSelectedTab, let id = selectedSessionID else { return }
        closeTab(id)
    }
}
