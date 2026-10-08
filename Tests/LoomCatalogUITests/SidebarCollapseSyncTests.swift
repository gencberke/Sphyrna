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
    /// An animated move AppKit does not carry out (the state stays; the completion still runs).
    var ignoresAnimatedMoves = false
    /// An animated move whose state flips only when it ends, with no change notification.
    var changesSilentlyAtTheEnd = false
    var immediateMoves: [Bool] = []

    func setCollapsed(_ collapsed: Bool, completion: @escaping @MainActor () -> Void) {
        var finish = completion
        if ignoresAnimatedMoves {
        } else if changesSilentlyAtTheEnd {
            finish = { [weak self] in self?.change(to: collapsed, silently: true); completion() }
        } else {
            change(to: collapsed, silently: false)
        }
        if deferCompletion { pendingCompletion = finish } else { finish() }
    }

    func setCollapsedImmediately(_ collapsed: Bool) {
        immediateMoves.append(collapsed)
        change(to: collapsed, silently: false)
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
        sidebar.changesSilentlyAtTheEnd = true
        let sync = SidebarCollapseSync(model: model, source: sidebar)
        sync.activate()
        model.onToggleSidebar?()
        #expect(!model.sidebarCollapsed)
        // The state flipped at the end and its notification was lost: the completion tells the model.
        sidebar.pendingCompletion?()
        #expect(sidebar.isCollapsed && model.sidebarCollapsed)
        #expect(sidebar.immediateMoves.isEmpty, "a move that happened needs no fallback")
    }

    /// The user's report on 0.2.1: the Show button was visible and a click did nothing. If AppKit does
    /// not carry out the animated expand, the move is applied without animation.
    @Test func anExpandAppKitDidNotCarryOutIsAppliedWithoutAnimation() throws {
        let (model, root) = try makeModel(collapsed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FakeSidebar()
        sidebar.change(to: true, silently: true)
        let sync = SidebarCollapseSync(model: model, source: sidebar)
        sync.activate()
        #expect(model.sidebarCollapsed)
        sidebar.ignoresAnimatedMoves = true
        model.onToggleSidebar?()
        #expect(!sidebar.isCollapsed && !model.sidebarCollapsed)
        #expect(sidebar.immediateMoves == [false])
    }

    /// The user's case again: the expand did not happen yet, so the second Show click finishes it
    /// instead of reversing it.
    @Test func aSecondShowWhileTheFirstHasNotTakenEffectShowsTheSidebar() throws {
        let (model, root) = try makeModel(collapsed: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FakeSidebar()
        sidebar.change(to: true, silently: true)
        sidebar.deferCompletion = true
        sidebar.ignoresAnimatedMoves = true
        let sync = SidebarCollapseSync(model: model, source: sidebar)
        sync.activate()
        model.onToggleSidebar?()                     // Show: nothing happens yet
        #expect(sidebar.isCollapsed)
        model.onToggleSidebar?()                     // Show again
        #expect(!sidebar.isCollapsed && !model.sidebarCollapsed)
        #expect(sidebar.immediateMoves == [false])
    }

    /// A second click while the first move runs reverses it at once, and the first move's late
    /// completion does not undo the second.
    @Test func aToggleDuringAMoveReversesItAndTheLateCompletionKeepsIt() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FakeSidebar()
        sidebar.deferCompletion = true
        let sync = SidebarCollapseSync(model: model, source: sidebar)
        sync.activate()
        model.onToggleSidebar?()                     // hide, animating
        let firstCompletion = sidebar.pendingCompletion
        model.onToggleSidebar?()                     // show again before the hide finished
        #expect(!sidebar.isCollapsed && !model.sidebarCollapsed)
        #expect(sidebar.immediateMoves == [false])
        firstCompletion?()
        #expect(!sidebar.isCollapsed && !model.sidebarCollapsed, "the superseded hide does not come back")
        model.onToggleSidebar?()                     // the next toggle animates normally again
        sidebar.pendingCompletion?()
        #expect(sidebar.isCollapsed && model.sidebarCollapsed)
        #expect(sidebar.immediateMoves == [false])
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
