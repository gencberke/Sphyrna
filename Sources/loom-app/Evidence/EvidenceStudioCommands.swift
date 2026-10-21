#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// The Release A glue (V13 route, V07 drafts, the search switch), driven through the model calls the menus and buttons make.
///
/// - `face:<chat|terminal>`: the selected session's "Show Chat" / "Show Terminal" (the ⋯ menu and the View menu).
/// - `new-session:<project id|none>`: what the sidebar's "+", the project menus and ⌘N do (`beginNewSession`).
/// - `draft-text:<project id|none>:<text>`: the draft composer's text change.
/// - `draft-discard:<project id|none>`: the draft row's Discard.
/// - `draft-branch:<project id|none>:<stay|newBranch|newWorktree>[:name]` and `draft-send:<project id|none>`: the strip and Send.
/// - `draft-popover:<project id|none>:<model|mode|branch|off>`: the draft page's model, mode or branch-name popover, opened in the
///   window's host as a click on its chip or segment opens it (`off` closes it). The live composer's own are `composer-popover` and
///   `composer-ring`.
/// - `render-probe:<start|reset>`: counts body evaluations (the snapshot's `renderProbe`).
/// - `search-session-text:<on|off>`: Settings → General → Search session text.
/// - `hover:<key|none>`: holds the pill of the row named `key` at its hover fill (V25; keys are `sidebar-card:<id>`, `sidebar-home`,
///   `home-entry:<id>`, `project-row:<id>`, `palette-row:<id>`, `pick:<row id>`, `segment:<title>`, …).
/// The snapshot's `catalog` gains `route`, `readOnlyChat`, `faceChoices`, `searchesSessionText` and `drafts`.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not one of these commands.
    func handleStudioCommand(_ name: String, _ argument: String) -> Bool {
        guard let model = app?.model else { return false }
        /// The project at the head of `<project id|none>[:rest]`.
        func project(_ text: String) -> UUID?? {
            let head = text.prefix { $0 != ":" }
            if head == "none" { return .some(nil) }
            return UUID(uuidString: String(head)).map { .some($0) }
        }
        func rest(_ text: String) -> String { text.firstIndex(of: ":").map { String(text[text.index(after: $0)...]) } ?? "" }
        switch name {
        case "face":
            switch argument {
            case "chat": model.showFace(.chat)
            case "terminal": model.showFace(.terminal)
            default: return false
            }
        case "new-session":
            guard let id = project(argument) else { return false }
            model.beginNewSession(projectID: id)
        case "draft-text":
            guard let id = project(argument) else { return false }
            model.setDraftText(rest(argument), projectID: id)
        case "draft-discard":
            guard let id = project(argument) else { return false }
            model.discardDraft(projectID: id)
        case "draft-branch":
            // draft-branch:<project|none>:<stay|newBranch|newWorktree>[:name]
            guard let id = project(argument) else { return false }
            let tail = rest(argument)
            let kind = String(tail.prefix { $0 != ":" })
            model.setDraftBranchForEvidence(kind, name: tail.contains(":") ? rest(tail) : nil, projectID: id)
        case "draft-send":
            guard let id = project(argument) else { return false }
            model.sendDraft(projectID: id)
        case "draft-popover":
            guard let id = project(argument), InkEvidence.draftPopover(projectID: id, kind: rest(argument), model: model) else { return false }
        case "dismiss-error":
            model.dismissError()
        case "render-probe":
            switch argument {
            case "start": RenderEvidence.start(model: model)
            case "reset": RenderEvidence.reset()
            default: return false
            }
        case "search-session-text":
            model.setSearchesSessionText(argument == "on")
        case "hover":
            // V25: holds one row's hover on, as the pointer would, for a screenshot. `none` lets go.
            LookEvidence.setHover(argument == "none" ? nil : argument)
        default: return false
        }
        return true
    }
}
#endif
