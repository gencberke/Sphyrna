import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// The actual lazy sidebar host must give every project draft its own row and reorder measurement.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .renderProbe)
struct ProjectDraftLayoutTests {
    private struct Rig {
        let root: URL
        let model: CatalogModel
        let alpha: UUID
        let beta: UUID
        let betaSession: UUID
        let newest: UUID
        let oldest: UUID
    }

    private func rig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-project-draft-layout-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let alpha = root.appendingPathComponent("Alpha", isDirectory: true)
        let beta = root.appendingPathComponent("Beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        let alphaID = try await catalog.addProject(path: alpha.path).project.id
        let betaID = try await catalog.addProject(path: beta.path).project.id
        let betaSession = UUID()
        try await catalog.insertSession(ManagedSession(id: betaSession, provider: .claude, workingDirectory: beta.path),
                                        title: "Beta work", lifecycle: .idle, projectID: betaID)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        await model.start()
        await model.stopAndWait()
        model.setViewMode(.projects)
        await model.settle()
        var now = Date(timeIntervalSince1970: 1_000)
        model.newSession.clock = { now }
        model.beginNewSession(projectID: alphaID)
        model.setDraftText("The same draft title", projectID: alphaID)
        let oldest = try #require(model.newSession.currentID(for: alphaID))
        now += 60
        model.beginNewSession(projectID: alphaID)
        model.setDraftText("The same draft title", projectID: alphaID)
        let newest = try #require(model.newSession.currentID(for: alphaID))
        model.showHome()
        await model.settle()
        return Rig(root: root, model: model, alpha: alphaID, beta: betaID, betaSession: betaSession,
                   newest: newest, oldest: oldest)
    }

    private func settle(_ window: NSWindow, until ready: () -> Bool = { true }) async throws {
        var stable = 0
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            stable = ready() ? stable + 1 : 0
            if stable >= 3 { return }
        }
    }

    private func buttons(_ label: String, in view: NSView) -> [AnyObject] {
        accessibilityElements(in: view).filter { $0.accessibilityRole?() == .button && InkAX.label($0) == label }
    }

    @Test func sameTitledDraftsHaveSeparateRowsMeasuredBlocksAndIndependentActions() async throws {
        enableAccessibilityTree()
        let rig = try await rig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        #expect(rig.newest != rig.oldest)
        let rows = DraftRows.drafts(in: .project(rig.alpha), of: rig.model)
        #expect(rows.map(\.id) == [rig.newest, rig.oldest])
        #expect(RenderProbeExclusive.isHeld)
        SidebarRenderProbe.watch([rig.newest, rig.oldest, rig.betaSession], model: rig.model)
        defer { SidebarRenderProbe.watch([]) }
        let reorder = ProjectReorderModel()
        let hosting = NSHostingView(rootView: SidebarList(model: rig.model, reorder: reorder).frame(width: 320, height: 520))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        let label = "Draft, The same draft title, Alpha"
        try await settle(window) {
            buttons(label, in: hosting).count == 2 && reorder.blocks[rig.beta] != nil
                && SidebarRenderProbe.cardBodies[rig.betaSession] != nil
        }
        #expect(SidebarRenderProbe.cardBodies[rig.betaSession] != nil, "the other project's session card is actually visible")
        #expect(!window.isVisible && !window.isKeyWindow)
        let same = buttons(label, in: hosting).sorted { InkAX.frame($0).midY > InkAX.frame($1).midY }
        try #require(same.count == 2, "the actual sidebar draws both draft buttons")
        let top = InkAX.frame(same[0]), bottom = InkAX.frame(same[1])
        #expect(top.width > 0 && bottom.width > 0)
        #expect(abs(top.height - LoomTheme.Sidebar.lineRowHeight) < 1 && abs(bottom.height - LoomTheme.Sidebar.lineRowHeight) < 1,
                "each accessible draft is the full 28 pt row")
        #expect(!top.intersects(bottom), "independent draft buttons must not paint on top of one another: \(top), \(bottom)")
        #expect(abs(top.midY - bottom.midY - LoomTheme.Sidebar.lineRowHeight) < 1,
                "the two 28 pt rows occupy consecutive list positions: \(top), \(bottom)")
        let order = rig.model.projects.map(\.id)
        let index = try #require(order.firstIndex(of: rig.alpha))
        let block = try #require(reorder.blocks[rig.alpha])
        let expectedHeight = ProjectHeader.topGap(isFirst: index == 0) + LoomTheme.InkHeight.sidebarRow
            + 2 * LoomTheme.Sidebar.lineRowHeight
        #expect(abs(block.height - expectedHeight) < 1, "the reorder block includes both draft rows: \(block.height)")
        let otherIndex = try #require(order.firstIndex(of: rig.beta))
        let otherBlock = try #require(reorder.blocks[rig.beta])
        #expect(reorder.begin(rig.alpha, pointer: CGPoint(x: 20, y: block.headTop + 4), order: order))
        #expect(reorder.draggedHeight == block.height)
        let down = index < otherIndex
        reorder.move(pointer: CGPoint(x: 20, y: otherBlock.midY + (down ? 1 : -1) - reorder.contentOffset))
        let destinationGap = down ? otherIndex + 1 : otherIndex
        #expect(reorder.gap == destinationGap)
        #expect(reorder.offsetY(blockAt: otherIndex) == (down ? -expectedHeight : expectedHeight),
                "the other project slides by the complete block including both drafts")
        var releases: [(UUID, Int?)] = []
        reorder.end { releases.append(($0, $1)) }
        #expect(releases.count == 1 && releases.first?.0 == rig.alpha && releases.first?.1 == destinationGap)
        #expect(reorder.isMoving(rig.alpha, order: order), "the gap holds until the new order lands")
        let destination = try #require(ProjectReorder.position(forGap: destinationGap, from: index))
        var landed = order
        landed.remove(at: index)
        landed.insert(rig.alpha, at: destination)
        #expect(reorder.hasLanded(landed) && !reorder.isMoving(rig.alpha, order: landed))
        reorder.settle(rig.alpha)
        #expect(reorder.begin(rig.alpha, pointer: CGPoint(x: 20, y: block.headTop + 4), order: order))
        reorder.cancel()
        reorder.end { releases.append(($0, $1)) }
        #expect(releases.count == 1 && reorder.offsetY(blockAt: otherIndex) == 0, "Escape leaves the next drag unmoved")
        try await settle(window)

        let afterCancel = buttons(label, in: hosting).sorted { InkAX.frame($0).midY > InkAX.frame($1).midY }
        try #require(afterCancel.count == 2)
        #expect(afterCancel[0].accessibilityPerformPress?() == true)
        #expect(rig.model.newSession.currentID(for: rig.alpha) == rig.newest)
        try await settle(window)
        SidebarRenderProbe.reset()
        rig.model.setDraftText("A distinct newer title", projectID: rig.alpha)
        try await settle(window) { buttons("Draft, A distinct newer title, Alpha", in: hosting).count == 1 }
        #expect((SidebarRenderProbe.draftRowBodies[rig.newest.uuidString] ?? 0) > 0)
        #expect(SidebarRenderProbe.projectListBodies == 0, "typing in a project draft must not redraw the project list")
        #expect(SidebarRenderProbe.cardTotal == 0, "typing in a draft must not redraw session cards")
        let older = try #require(buttons(label, in: hosting).first)
        #expect(older.accessibilityPerformPress?() == true)
        #expect(rig.model.newSession.currentID(for: rig.alpha) == rig.oldest)
        let actions = (older.accessibilityCustomActions?() as? [NSAccessibilityCustomAction]) ?? []
        let discard = try #require(actions.first { $0.name == "Discard" })
        _ = discard.handler?()
        try await settle(window) {
            buttons(label, in: hosting).isEmpty
                && abs((reorder.blocks[rig.alpha]?.height ?? 0) - (expectedHeight - LoomTheme.Sidebar.lineRowHeight)) < 1
        }
        #expect(DraftRows.drafts(in: .project(rig.alpha), of: rig.model).map(\.id) == [rig.newest],
                "Discard removes only the selected row")
        #expect(abs((reorder.blocks[rig.alpha]?.height ?? 0) - (expectedHeight - LoomTheme.Sidebar.lineRowHeight)) < 1,
                "the removed draft no longer contributes to the project block")
        #expect(buttons("Draft, A distinct newer title, Alpha", in: hosting).count == 1)
    }

    @Test func activityAndUnassignedDraftsStillOccupySeparateRows() async throws {
        enableAccessibilityTree()
        let rig = try await rig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        rig.model.setViewMode(.activity)
        await rig.model.settle()
        let hosting = NSHostingView(rootView: SidebarList(model: rig.model).frame(width: 320, height: 520))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        let alphaLabel = "Draft, The same draft title, Alpha"
        try await settle(window) { buttons(alphaLabel, in: hosting).count == 2 }
        let activity = buttons(alphaLabel, in: hosting).map(InkAX.frame).sorted { $0.midY > $1.midY }
        try #require(activity.count == 2)
        #expect(!activity[0].intersects(activity[1]) && abs(activity[0].midY - activity[1].midY - LoomTheme.Sidebar.lineRowHeight) < 1)

        rig.model.beginNewSession(projectID: nil)
        rig.model.setDraftText("Loose idea", projectID: nil)
        let first = try #require(rig.model.newSession.currentID(for: nil))
        rig.model.beginNewSession(projectID: nil)
        rig.model.setDraftText("Loose idea", projectID: nil)
        let second = try #require(rig.model.newSession.currentID(for: nil))
        #expect(first != second)
        rig.model.setViewMode(.projects)
        rig.model.showHome()
        await rig.model.settle()
        let looseLabel = "Draft, Loose idea"
        try await settle(window) { buttons(looseLabel, in: hosting).count == 2 }
        let loose = buttons(looseLabel, in: hosting).map(InkAX.frame).sorted { $0.midY > $1.midY }
        try #require(loose.count == 2)
        #expect(!loose[0].intersects(loose[1]) && abs(loose[0].midY - loose[1].midY - LoomTheme.Sidebar.lineRowHeight) < 1)
        #expect(!window.isVisible && !window.isKeyWindow)
    }
}
