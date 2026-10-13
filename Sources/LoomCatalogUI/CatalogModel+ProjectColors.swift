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

    /// The project of a session for the tab; nil while colours are off or the session has none.
    func projectMark(of record: CatalogSession) -> ProjectMark? {
        guard projectColorsEnabled, let name = projectName(for: record) else { return nil }
        return ProjectMark(name: name, tone: record.projectID.flatMap { projectTones[$0] })
    }

    /// The project of a session for the detail header's chip. The chip names the project whatever the
    /// setting says (D-53): with colours off, or a project set to None, it is neutral (no tone).
    func headerProjectMark(of record: CatalogSession) -> ProjectMark? {
        guard let name = projectName(for: record) else { return nil }
        return ProjectMark(name: name, tone: projectColorsEnabled ? record.projectID.flatMap { projectTones[$0] } : nil)
    }

    /// What the header chip shows for a session: its project and branch, or nil when there is neither.
    func headerChip(of record: CatalogSession) -> SessionHeaderChip? {
        SessionHeaderChip(project: headerProjectMark(of: record), branch: branches[record.session.workingDirectory])
    }
}
