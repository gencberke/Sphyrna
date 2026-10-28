import AppKit
import LoomCatalogUI
import SwiftUI

/// The one main window's content: a native sidebar (SwiftUI catalog) beside the
/// detail pane (CHECKPOINT-5-HISTORY §4.1: sidebar 300 pt in 220–520 pt, detail at least 480 pt).
/// Width and collapse state are persisted through the model's preferences.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let model: CatalogModel
    private let sidebarItem: NSSplitViewItem
    private var restored = false
    /// AppKit's sidebar item is the one truth for collapsed or not; this mirrors it into the model.
    private let collapseSync: SidebarCollapseSync
    private var widthTask: Task<Void, Never>?
    /// The window's popover and menu host: the composer's pickers, the draft's, and the project menu open in it.
    private let inkHost: InkHost

    /// `settingsNavigation` is Home's way to Remora's memory sheet (⋯ → Memory… and the footer's Memory…): read each time a
    /// door is used, so a Settings window made later is found.
    init(model: CatalogModel, settingsNavigation: @escaping @MainActor () -> SettingsNavigation?) {
        self.model = model
        let host = InkHost()
        inkHost = host
        let sidebar = NSHostingController(rootView: SidebarView(model: model).inkHost(host))
        let detail = NSHostingController(rootView: DetailView(model: model)
            .remoraMemoryDoor(model: model, navigation: settingsNavigation).inkHost(host))
        sidebar.sizingOptions = []
        detail.sizingOptions = []
        // A plain item, not `sidebarWithViewController`: a sidebar item puts AppKit's own blurred sidebar material behind the
        // view, and Transparent is the canvas straight over what is behind the window (RESCUE C3). The holding priority is the one a
        // sidebar item has, so a window resize goes to the detail pane.
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        collapseSync = SidebarCollapseSync(model: model, source: SplitViewItemCollapse(item: sidebarItem))
        let contentItem = NSSplitViewItem(viewController: detail)
        super.init(nibName: nil, bundle: nil)
        splitView = CanvasSplitView()
        sidebarItem.minimumThickness = UIPreferences.sidebarWidthRange.lowerBound
        sidebarItem.maximumThickness = UIPreferences.sidebarWidthRange.upperBound
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = 0.25
        contentItem.minimumThickness = 480
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        splitView.dividerStyle = .thin
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var sidebarWidth: Double { sidebarItem.isCollapsed ? 0 : Double(sidebarItem.viewController.view.frame.width) }
    var sidebarIsCollapsed: Bool { sidebarItem.isCollapsed }

    /// Redraws the AppKit chrome that SwiftUI does not reach: the split view's divider, whose colour follows Appearance and
    /// Increase Contrast (FB6-1). Called from `AppDelegate.applyTheme`.
    func refreshChrome() {
        splitView.needsDisplay = true
    }

    /// Moves the divider as a user drag would; the persistence path is the same.
    func setSidebarWidth(_ width: Double) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        splitView.setPosition(CGFloat(width), ofDividerAt: 0)
    }

    /// One root for both panes, the bar, and the existing window-wide overlays.
    func makeWindowContentController() -> NSViewController {
        let status = NSHostingController(rootView: StatusBarView(model: model).inkHost(inkHost))
        status.sizingOptions = []
        return StatusBarWindowLayout(split: self, bar: status, overlays: [
            makePaletteOverlayView(model: model), inkHost.view, makeMainSheetOverlayView(model: model),
        ], popoverHost: inkHost)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !restored, view.bounds.width > 0 else { return }
        restored = true
        defer { collapseSync.activate() }
        let preferences = model.preferencesSnapshot
        if preferences.sidebarCollapsed {
            sidebarItem.isCollapsed = true
        } else {
            splitView.setPosition(CGFloat(preferences.sidebarWidth), ofDividerAt: 0)
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard restored else { return }
        collapseSync.reconcile()
        // Only a divider drag is the user's width choice; a smaller window that
        // squeezes the sidebar must not overwrite it.
        guard !sidebarItem.isCollapsed, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        // Written once after a drag settles, not on every intermediate width.
        widthTask?.cancel()
        widthTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, !self.sidebarItem.isCollapsed else { return }
            self.model.setSidebarWidth(Double(self.sidebarItem.viewController.view.frame.width))
        }
    }
}
