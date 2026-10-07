import AppKit
import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// A stand-in for the split view's sidebar item. `deferCompletion` mimics AppKit finishing an animated
/// move later than it starts it; `change(to:silently:)` a collapse the model was never told about.
@MainActor
private final class FakeSidebar: SidebarCollapsing {
    var isCollapsed = false
    var onChange: (@MainActor () -> Void)?
    var pendingCompletion: (@MainActor () -> Void)?
    var deferCompletion = false

    func setCollapsed(_ collapsed: Bool, completion: @escaping @MainActor () -> Void) {
        change(to: collapsed, silently: false)
        if deferCompletion { pendingCompletion = completion } else { completion() }
    }

    /// A change of the real state; `silently` is the case where no notification named it.
    func change(to collapsed: Bool, silently: Bool) {
        isCollapsed = collapsed
        if !silently { onChange?() }
    }
}

/// FB-C item 5: the split view's sidebar item is the single source of truth for hidden or shown.
/// The real `MainSplitViewController` lives in the executable target and needs a window; what stays
/// unverified here is the whole path through a real window (a real click, the animation, the layout).
@MainActor
struct SidebarCollapseSyncTests {
    private func makeModel(collapsed: Bool = false) throws -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-collapse-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("p.json"))
        try preferences.update { $0.sidebarCollapsed = collapsed }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: preferences)
        return (model, root)
    }

    @Test func theModelFollowsTheRealStateWithoutAnyResizeCallback() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FakeSidebar()
        let sync = SidebarCollapseSync(model: model, source: sidebar)
        sync.activate()
        #expect(!model.sidebarCollapsed)
        sidebar.change(to: true, silently: false) // KVO fired; no resize notification involved
        #expect(model.sidebarCollapsed)
        sidebar.change(to: false, silently: false)
        #expect(!model.sidebarCollapsed)
    }

    @Test func aToggleActsOnTheRealStateEvenWhenTheModelDisagrees() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FakeSidebar()
        let sync = SidebarCollapseSync(model: model, source: sidebar)
        sync.activate()
        // The reported failure shape: AppKit collapsed the sidebar and the model never heard about it,
        // so the Show button was not drawn.
        sidebar.change(to: true, silently: true)
        #expect(!model.sidebarCollapsed)
        model.onToggleSidebar?()
        #expect(!sidebar.isCollapsed, "a toggle shows what is really hidden")
        #expect(!model.sidebarCollapsed)
        model.onToggleSidebar?()
        #expect(sidebar.isCollapsed && model.sidebarCollapsed)
    }

    @Test func theModelCatchesUpWhenAnAnimatedToggleFinishes() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FakeSidebar()
        sidebar.deferCompletion = true
        let sync = SidebarCollapseSync(model: model, source: sidebar)
        sync.activate()
        model.onToggleSidebar?()
        #expect(sidebar.isCollapsed && model.sidebarCollapsed)
        // A notification that was lost during the move: only the completion tells the model the end state.
        sidebar.change(to: false, silently: true)
        #expect(model.sidebarCollapsed)
        sidebar.pendingCompletion?()
        #expect(!model.sidebarCollapsed)
    }

    @Test func theSavedStateIsNotOverwrittenWhileItIsBeingRestored() throws {
        let (model, root) = try makeModel(collapsed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.sidebarCollapsed)
        let sidebar = FakeSidebar() // a fresh split view starts expanded, before the restore ran
        let sync = SidebarCollapseSync(model: model, source: sidebar)
        sidebar.onChange?()
        sync.reconcile()
        #expect(model.sidebarCollapsed, "before activate() the persisted collapsed state survives")
        sidebar.change(to: true, silently: false) // the restore collapses the item
        sync.activate()
        #expect(model.sidebarCollapsed)
    }

    @Test func aRealSplitViewItemReportsItsCollapseThroughKVO() {
        let item = NSSplitViewItem(sidebarWithViewController: NSViewController())
        let source = SplitViewItemCollapse(item: item)
        var seen: [Bool] = []
        source.onChange = { seen.append(source.isCollapsed) }
        item.isCollapsed = true
        item.isCollapsed = false
        #expect(seen == [true, false])
    }
}
