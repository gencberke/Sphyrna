import AppKit

/// The thing that really collapses the sidebar (the split view's sidebar item). It owns the truth; the
/// catalog model only mirrors it.
@MainActor
public protocol SidebarCollapsing: AnyObject {
    /// The real state, as AppKit holds it (an animated change reports its target at once).
    var isCollapsed: Bool { get }
    /// Called after every change of `isCollapsed`, from whatever caused it (a button, the menu, a drag).
    var onChange: (@MainActor () -> Void)? { get set }
    /// Moves to `collapsed` (animated); `completion` runs when the move has finished.
    func setCollapsed(_ collapsed: Bool, completion: @escaping @MainActor () -> Void)
}

/// `NSSplitViewItem.isCollapsed` observed with KVO, so a collapse is seen however it happens and not
/// only when the split view happens to report a resize.
@MainActor
public final class SplitViewItemCollapse: SidebarCollapsing {
    private let item: NSSplitViewItem
    private var observation: NSKeyValueObservation?
    public var onChange: (@MainActor () -> Void)?

    public init(item: NSSplitViewItem) {
        self.item = item
        observation = item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    public var isCollapsed: Bool { item.isCollapsed }

    public func setCollapsed(_ collapsed: Bool, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ _ in
            MainActor.assumeIsolated { item.animator().isCollapsed = collapsed }
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }
}

/// Keeps `CatalogModel.sidebarCollapsed` (and with it the Show button and the window-button gap) equal to
/// the real collapse state, and makes every toggle act on that real state. Before `activate()` (the saved
/// state is still being restored) nothing is written back to the preferences.
@MainActor
public final class SidebarCollapseSync {
    private let model: CatalogModel
    private let source: any SidebarCollapsing
    private var active = false

    public init(model: CatalogModel, source: any SidebarCollapsing) {
        self.model = model
        self.source = source
        source.onChange = { [weak self] in self?.reconcile() }
        model.onToggleSidebar = { [weak self] in self?.toggle() }
    }

    /// The saved state has been restored: from now on the real state is mirrored (and persisted).
    public func activate() {
        active = true
        reconcile()
    }

    /// Copies the real state into the model. Safe to call from any signal (KVO, resize, layout).
    public func reconcile() {
        guard active else { return }
        model.setSidebarCollapsed(source.isCollapsed)
    }

    /// Hide or Show: the opposite of what the sidebar really is now, whatever the model believes.
    public func toggle() {
        source.setCollapsed(!source.isCollapsed) { [weak self] in self?.reconcile() }
        reconcile()
    }
}
