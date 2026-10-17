import Foundation
import SwiftUI

/// A project's new-session draft. A placeholder until the new-session slice (V07) fills it; `DetailContent`
/// draws it for `.draft`.
struct DraftSessionView: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        Message(symbol: "square.and.pencil", title: "New session",
                text: "What should we work on in \(projectName)?")
            .accessibilityIdentifier("draft-session")
    }

    private var projectName: String {
        projectID.flatMap { id in model.projects.first { $0.id == id }?.name } ?? "this folder"
    }
}
