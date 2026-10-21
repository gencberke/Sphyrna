#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// The project page (V08), driven through the model calls a click makes.
///
/// - `project-page:<project id>`: a click on a project's name in the sidebar (`showProjectPage`).
/// - `project-tab:<sessions|branches|instructions>`: a click on one of the page's tabs.
/// - `project-preset:<project id>:<index>`: a click on the page's preset with that index.
/// - `project-menu:<project id>:<page|sidebar|off>`: the project menu from the page's ⋯ or the sidebar head's ⋯, opened in the
///   window's host as a click opens it (`off` closes it). The sidebar head's ⋯ is there while its project is listed.
/// - `project-page-state:<label>`: only writes the acknowledgement.
///
/// Every command waits (at most four seconds) for the page's reads to end, then writes `ack-<command name>.json`
/// (`ack-project-page.json`, `ack-project-tab.json`, `ack-project-preset.json`, `ack-project-menu.json`); `project-page-state` adds its label
/// like `palette-state` does (`ack-project-page-state-<label>.json`, letters, digits and `-` of the label; just
/// `ack-project-page-state.json` without one). The file holds what the page holds as numbers and flags, and how many
/// reads of each kind it made. No title, path, branch name or line of text is in it.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not a project page command.
    func handleProjectPageCommand(_ name: String, _ argument: String) -> Bool {
        guard name.hasPrefix("project-"), let app, let model = app.model else { return false }
        var clicked = true
        switch name {
        case "project-page":
            guard let id = UUID(uuidString: argument) else { return false }
            model.showProjectPage(id)
        case "project-tab":
            guard let tab = ProjectPageTab.allCases.first(where: { $0.rawValue.lowercased() == argument }) else { return false }
            model.showProjectPageTab(tab)
        case "project-preset":
            let parts = argument.split(separator: ":")
            guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let index = Int(parts[1]) else { return false }
            clicked = model.usePresetForEvidence(index: index, projectID: id)
        case "project-menu":
            let parts = argument.split(separator: ":")
            guard parts.count == 2, let id = UUID(uuidString: String(parts[0])) else { return false }
            clicked = InkEvidence.projectMenu(projectID: id, origin: String(parts[1]))
        case "project-page-state": break
        default: return false
        }
        let label = name == "project-page-state" ? argument.filter { $0.isLetter || $0.isNumber || $0 == "-" } : ""
        let tag = label.isEmpty ? name : name + "-" + label
        Task { @MainActor in
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            let page = model.projectPage
            while ProcessInfo.processInfo.systemUptime < deadline,
                  page.projectID != nil, [page.sessionsLoad, page.usageLoad, page.branchesLoad, page.instructionsLoad].contains(.loading) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(400))
            var state = model.projectPageEvidence()
            state["clicked"] = clicked
            state["route"] = model.detailRouteKind
            write("ack-" + tag, state)
        }
        return true
    }
}
#endif
