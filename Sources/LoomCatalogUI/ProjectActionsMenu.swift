import LoomCore
import SwiftUI

/// What the project menu lists and in which order (DESIGN §10 Project menu, §6 Project colour): the new sessions with their
/// harness's marks (Codex off with its reason in a build that cannot start it), Color, Move Up and Move Down, and Remove Empty
/// Project, which only an empty project allows. Pure, so a test reads the items, their order and whether each is enabled; the
/// sidebar head's ⋯, its context menu and the project page's ⋯ all draw it (`ProjectActionsMenu`).
struct ProjectMenuPlan: Equatable {
    enum Entry: Equatable {
        case start(provider: ManagedSession.Provider, title: String, enabled: Bool)
        /// A quiet line that follows an item and says why it is off.
        case note(String)
        /// The Color submenu (`ProjectColorMenu`); left out while Project colors are off.
        case color
        case moveUp(enabled: Bool)
        case moveDown(enabled: Bool)
        case removeEmpty(enabled: Bool)
        case divider
    }

    /// Said under Remove Empty Project while the project has sessions.
    static let removeNote = "Only a project with no sessions can be removed"

    let entries: [Entry]

    /// One new-session item as the menu lists it.
    struct Start: Equatable {
        let provider: ManagedSession.Provider
        let title: String
        let enabled: Bool
        /// Why the item is off for good in this build; nil where the build can start the provider.
        let reason: String?
    }

    /// The menu of a project that is `index` of `count` in the list and holds `sessions` sessions.
    static func make(starts: [Start], colorsEnabled: Bool, index: Int, count: Int, sessions: Int) -> ProjectMenuPlan {
        var sections: [[Entry]] = []
        sections.append(starts.flatMap { start -> [Entry] in
            var items: [Entry] = [.start(provider: start.provider, title: start.title, enabled: start.enabled)]
            if let reason = start.reason { items.append(.note(reason)) }
            return items
        })
        if colorsEnabled { sections.append([.color]) }
        sections.append([.moveUp(enabled: index > 0), .moveDown(enabled: index < count - 1)])
        let empty = sessions == 0
        sections.append([.removeEmpty(enabled: empty)] + (empty ? [] : [.note(removeNote)]))
        var entries: [Entry] = []
        for section in sections where !section.isEmpty {
            if !entries.isEmpty { entries.append(.divider) }
            entries += section
        }
        return ProjectMenuPlan(entries: entries)
    }

    @MainActor static func make(model: CatalogModel, project: CatalogProject) -> ProjectMenuPlan {
        let starts = NewConversationAction.listed(on: model).map {
            Start(provider: $0.provider, title: $0.title, enabled: $0.isEnabled(on: model, projectID: project.id),
                  reason: $0.unavailableReason(on: model))
        }
        return make(starts: starts, colorsEnabled: model.projectColorsEnabled,
                    index: model.projects.firstIndex { $0.id == project.id } ?? 0, count: model.projects.count,
                    sessions: model.sessionCounts[project.id] ?? 0)
    }
}

/// The items of a project's right-click menu, for a `.contextMenu` to hold (the sidebar head's). The ⋯ buttons open the same plan in
/// the window's host (`ProjectMenuView`), where Color is DESIGN's row of seven swatches; a native menu cannot hold that row, so the
/// right-click menu keeps `ProjectColorMenu`'s submenu.
struct ProjectActionsMenu: View {
    let model: CatalogModel
    let project: CatalogProject

    var body: some View {
        ForEach(Array(ProjectMenuPlan.make(model: model, project: project).entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .start(let provider, let title, let enabled):
                Button { start(provider) } label: { HarnessMenuLabel(provider: provider, title: title) }
                    .disabled(!enabled)
            case .note(let text):
                Text(text)
            case .color:
                ProjectColorMenu(model: model, project: project)
            case .moveUp(let enabled):
                Button("Move Up") { Task { await model.moveProject(project.id, by: -1) } }.disabled(!enabled)
            case .moveDown(let enabled):
                Button("Move Down") { Task { await model.moveProject(project.id, by: 1) } }.disabled(!enabled)
            case .removeEmpty(let enabled):
                Button("Remove Empty Project") { Task { await model.removeProject(project.id) } }.disabled(!enabled)
            case .divider:
                Divider()
            }
        }
    }

    /// Every new session goes through the model's one start path.
    private func start(_ provider: ManagedSession.Provider) {
        NewConversationAction.listed(on: model).first { $0.provider == provider }?.perform(on: model, projectID: project.id)
    }
}
