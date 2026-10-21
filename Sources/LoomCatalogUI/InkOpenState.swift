import Foundation
import Observation
import SwiftUI

/// Which of the draft page's popovers and which project menu is open. The controls open and close them through bindings, and the
/// development evidence opens them by key (`InkEvidence`), since a private `@State` flag cannot be reached from outside the view.
/// There is one draft page and one project menu on screen at a time, so one shared instance holds both.
@MainActor @Observable
final class InkOpenState {
    static let shared = InkOpenState()

    /// A popover of the draft page.
    enum DraftPopover: Equatable, Sendable {
        case mode, model
        /// The branch or worktree name, from its segment.
        case branchName(BranchKind)
    }

    struct DraftOpen: Equatable, Sendable {
        var projectID: UUID?
        var popover: DraftPopover
    }

    /// Where a project menu hangs from.
    enum MenuOrigin: String, Equatable, Sendable {
        case sidebar, page
    }

    struct MenuOpen: Equatable, Sendable {
        var projectID: UUID
        var origin: MenuOrigin
    }

    var draft: DraftOpen?
    var projectMenu: MenuOpen?

    /// A flag for one draft popover: true while it is the open one.
    func draftBinding(_ popover: DraftPopover, projectID: UUID?) -> Binding<Bool> {
        let wanted = DraftOpen(projectID: projectID, popover: popover)
        return Binding(get: { self.draft == wanted }, set: { shown in
            if shown { self.draft = wanted } else if self.draft == wanted { self.draft = nil }
        })
    }

    /// A flag for one project menu: true while it is the open one.
    func menuBinding(projectID: UUID, origin: MenuOrigin) -> Binding<Bool> {
        let wanted = MenuOpen(projectID: projectID, origin: origin)
        return Binding(get: { self.projectMenu == wanted }, set: { shown in
            if shown { self.projectMenu = wanted } else if self.projectMenu == wanted { self.projectMenu = nil }
        })
    }
}

/// Opens the draft page's popovers and the project menu for the development evidence (DEVELOPMENT §5: `draft-popover` and
/// `project-menu`). It only sets the same flags a click sets.
public enum InkEvidence {
    /// `kind`: `model`, `mode`, `branch` (the name popover of the chosen new-branch or new-worktree segment, else New branch) or
    /// `off`. False when `kind` is none of those.
    @MainActor public static func draftPopover(projectID: UUID?, kind: String, model: CatalogModel) -> Bool {
        let state = InkOpenState.shared
        switch kind {
        case "model": state.draft = .init(projectID: projectID, popover: .model)
        case "mode": state.draft = .init(projectID: projectID, popover: .mode)
        case "branch":
            let chosen = (model.newSession.draft(for: projectID) ?? SessionDraft(projectID: projectID)).branchKind
            state.draft = .init(projectID: projectID, popover: .branchName(chosen == .stay ? .newBranch : chosen))
        case "off": state.draft = nil
        default: return false
        }
        return true
    }

    /// `origin`: `page` (the project page's ⋯), `sidebar` (the project head's ⋯) or `off`.
    @MainActor public static func projectMenu(projectID: UUID, origin: String) -> Bool {
        let state = InkOpenState.shared
        if origin == "off" {
            state.projectMenu = nil
            return true
        }
        guard let origin = InkOpenState.MenuOrigin(rawValue: origin) else { return false }
        state.projectMenu = .init(projectID: projectID, origin: origin)
        return true
    }
}
