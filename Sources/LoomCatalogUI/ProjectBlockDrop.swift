import LoomCore
import SwiftUI

extension View {
    /// Makes the view a part of the project's block as a drop target for another project (FB6-4): the head, its drafts, its session
    /// cards and its "No sessions" note all take the drop, so a project can be dropped anywhere on another's block. The insertion
    /// line stands above the block's head or under its last part (`isTail`), by where the dragged project comes from.
    func projectBlockDrop(model: CatalogModel, projectID: UUID, isHead: Bool = false, isTail: Bool = false) -> some View {
        modifier(ProjectBlockDrop(model: model, projectID: projectID, isHead: isHead, isTail: isTail))
    }
}

private struct ProjectBlockDrop: ViewModifier {
    let model: CatalogModel
    let projectID: UUID
    let isHead: Bool
    let isTail: Bool

    func body(content: Content) -> some View {
        let mark = DragActivity.shared.projectMark
        content
            .overlay(alignment: .top) {
                if isHead, mark == .init(projectID: projectID, after: false) { ProjectInsertionMark() }
            }
            .overlay(alignment: .bottom) {
                if isTail, mark == .init(projectID: projectID, after: true) { ProjectInsertionMark() }
            }
            .onDrop(of: [ProjectDrag.contentType], delegate: ProjectBlockDropDelegate(model: model, projectID: projectID))
    }
}

/// Where a dragged project will land: the accent line across the block's edge, as the tab strip's mark.
private struct ProjectInsertionMark: View {
    var body: some View {
        Rectangle().fill(LoomTheme.Accent.base).frame(height: LoomTheme.Drag.lineWidth)
            .padding(.leading, LoomTheme.Sidebar.headLeading).padding(.trailing, LoomTheme.Sidebar.headTrailing)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A part of a project's block as a drop target for another project: it takes that block's place, the line on the edge it lands at
/// (`CatalogModel.projectDropGap`). Anything that is not a project (a session too) is refused. Each part logs what it is asked,
/// ids only (the first 8 digits), so a drag that does nothing can be told from one that never arrived.
struct ProjectBlockDropDelegate: DropDelegate {
    let model: CatalogModel
    let projectID: UUID

    private var activity: DragActivity { .shared }
    private var key: String { DragActivity.projectBlock(projectID) }

    private func accepts(_ info: DropInfo) -> Bool { ProjectDrag.accepts(info.itemProviders(for: [ProjectDrag.contentType])) }

    private func settle() {
        activity.enter(key)
        guard let index = model.projects.firstIndex(where: { $0.id == projectID }),
              let gap = model.projectDropGap(onBlock: projectID, dragged: activity.project)
        else { return activity.mark(nil) }
        activity.mark(.init(projectID: projectID, after: gap > index))
    }

    func validateDrop(info: DropInfo) -> Bool {
        let takes = accepts(info)
        LoomLog.debug(.sidebar, "validateDrop project \(DragActivity.short(projectID)) accepts=\(takes)")
        return takes
    }

    func dropEntered(info: DropInfo) { if accepts(info) { settle() } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard accepts(info) else { return DropProposal(operation: .forbidden) }
        settle()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        activity.leave(key)
        activity.clearMark(of: projectID)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [ProjectDrag.contentType])
        let takes = ProjectDrag.accepts(providers)
        LoomLog.debug(.sidebar, "performDrop project \(DragActivity.short(projectID)) accepts=\(takes)")
        activity.end(why: takes ? "dropped" : "refused")
        guard takes else { return false }
        let model = model, target = projectID
        Task { @MainActor in
            guard let id = await ProjectDrag.projectID(from: providers) else { return }
            await model.dropProject(id, onBlock: target)
        }
        return true
    }
}
