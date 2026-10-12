import Foundation
import LoomCore

/// A session's project as the colour surfaces show it: the name, and the tone when the project has one
/// (None and an unknown tone are nil and stay neutral).
struct ProjectMark: Equatable {
    let name: String
    let tone: ProjectTone?
}

/// Project colours (D-48). Every function answers "nothing" while the setting is off, so a surface that
/// asks the model draws exactly what it drew before the feature; the stored tones stay in the catalog.
extension CatalogModel {
    /// The tone to draw for a project, or nil: colours off, no project, None, or an unknown tone.
    func projectTone(forProject id: UUID?) -> ProjectTone? {
        guard projectColorsEnabled, let id else { return nil }
        return projectTones[id]
    }

    /// The project of a session for the tab and the detail header; nil while colours are off or the session has none.
    func projectMark(of record: CatalogSession) -> ProjectMark? {
        guard projectColorsEnabled, let name = projectName(for: record) else { return nil }
        return ProjectMark(name: name, tone: record.projectID.flatMap { projectTones[$0] })
    }
}
