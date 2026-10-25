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

    /// Moves the divider as a user drag would; the persistence path is the same.
    func setSidebarWidth(_ width: Double) {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        splitView.setPosition(CGFloat(width), ofDividerAt: 0)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The command palette (⌘K) is one window-level overlay over both panes; it draws and takes clicks only while open.
        let palette = makePaletteOverlayView(model: model)
        palette.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(palette)
        NSLayoutConstraint.activate([
            palette.leadingAnchor.constraint(equalTo: view.leadingAnchor), palette.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            palette.topAnchor.constraint(equalTo: view.topAnchor), palette.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // The popovers and menus (the composer's pickers, the draft's, the project menu) are one more window-level layer, over the
        // palette's so that a popover is never under it; it takes clicks and keys only while one is open.
        let hosts = inkHost.view
        hosts.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosts)
        NSLayoutConstraint.activate([
            hosts.leadingAnchor.constraint(equalTo: view.leadingAnchor), hosts.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosts.topAnchor.constraint(equalTo: view.topAnchor), hosts.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // The window's questions (rename, delete, rewind, discard) are one more window-level layer, over the panes and the
        // popovers alike: a question hides the whole window and takes every click while it is open.
        let sheets = makeMainSheetOverlayView(model: model)
        sheets.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheets)
        NSLayoutConstraint.activate([
            sheets.leadingAnchor.constraint(equalTo: view.leadingAnchor), sheets.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheets.topAnchor.constraint(equalTo: view.topAnchor), sheets.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
