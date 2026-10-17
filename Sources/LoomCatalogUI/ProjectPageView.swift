import Foundation
import SwiftUI

/// A project's page. A placeholder until the project-page slice (V08) fills it; `DetailContent` draws it for
/// `.projectPage`.
struct ProjectPageView: View {
    let model: CatalogModel
    let projectID: UUID

    var body: some View {
        Message(symbol: "folder", title: projectName, text: "The project's sessions and settings will appear here.")
            .accessibilityIdentifier("project-page")
    }

    private var projectName: String {
        model.projects.first { $0.id == projectID }?.name ?? "Project"
    }
}
