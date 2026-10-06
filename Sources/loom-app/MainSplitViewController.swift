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
    private var widthTask: Task<Void, Never>?

    init(model: CatalogModel) {
        self.model = model
        let sidebar = NSHostingController(rootView: SidebarView(model: model))
        let detail = NSHostingController(rootView: DetailView(model: model))
        sidebar.sizingOptions = []
        detail.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        let contentItem = NSSplitViewItem(viewController: detail)
        super.init(nibName: nil, bundle: nil)
        sidebarItem.minimumThickness = UIPreferences.sidebarWidthRange.lowerBound
        sidebarItem.maximumThickness = UIPreferences.sidebarWidthRange.upperBound
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = 0.25
        contentItem.minimumThickness = 480
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        splitView.dividerStyle = .thin
        model.onToggleSidebar = { [weak self] in self?.toggleSidebar(nil) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var sidebarWidth: Double { sidebarItem.isCollapsed ? 0 : Double(sidebarItem.viewController.view.frame.width) }
    var sidebarIsCollapsed: Bool { sidebarItem.isCollapsed }

    /// Moves the divider as a user drag would; the persistence path is the same.
    func setSidebarWidth(_ width: Double) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        splitView.setPosition(CGFloat(width), ofDividerAt: 0)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !restored, view.bounds.width > 0 else { return }
        restored = true
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
        model.setSidebarCollapsed(sidebarItem.isCollapsed)
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
