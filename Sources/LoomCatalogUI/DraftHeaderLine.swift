import SwiftUI

/// The draft a header row draws its line for; `nil` project is a draft with no project.
struct DraftHeaderTarget: Equatable {
    let projectID: UUID?
}

/// The new-session page's header line (DESIGN §8 Header): no hairline, the crumb "<project> / new session" in mono 12 tertiary
/// with the project's name in secondary, and at the trailing end a small ghost button with the clock glyph, "N sessions in
/// <project>", that opens the project's page. The button is left out while the project has no sessions, and a draft with no
/// project says only "new session". It is the content of `DetailHeader`'s 52 pt row, after the window-button clearance.
struct DraftHeaderLine: View {
    let model: CatalogModel
    let projectID: UUID?

    /// The crumb's words after the project's name.
    static let crumbTail = " / new session"
    static let tooltip = "Opens the project's page"

    /// The crumb's words: "loom / new session", or "new session" for a draft with no project.
    static func crumbWords(projectName: String?) -> String {
        projectName.map { $0 + Self.crumbTail } ?? "new session"
    }

    /// The button's words, or nil while the project has no sessions: "1 session in loom", "9 sessions in loom".
    static func sessionsWords(count: Int, projectName: String) -> String? {
        count > 0 ? "\(count) \(count == 1 ? "session" : "sessions") in \(projectName)" : nil
    }

    /// What the line says for a draft of `projectID`: the crumb, and the button's words (nil: no button).
    struct Words: Equatable {
        let crumb: String
        let sessions: String?
    }

    static func words(model: CatalogModel, projectID: UUID?) -> Words {
        guard let project = model.draftProject(projectID) else { return Words(crumb: crumbWords(projectName: nil), sessions: nil) }
        return Words(crumb: crumbWords(projectName: project.name),
                     sessions: sessionsWords(count: model.sessionCounts[project.id] ?? 0, projectName: project.name))
    }

    var body: some View {
        let project = model.draftProject(projectID)
        let words = Self.words(model: model, projectID: projectID)
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            crumb(projectName: project?.name, words: words.crumb)
            if let notice = model.preparingNotice { PreparingNotice(text: notice) }
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            if let project, let sessions = words.sessions {
                Button { model.showProjectPage(project.id) } label: {
                    HStack(spacing: LoomTheme.DraftHeader.glyphGap) {
                        Image(systemName: "clock").font(LoomTheme.DraftHeader.glyph)
                        Text(sessions).lineLimit(1)
                    }
                }
                .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                .help(Self.tooltip)
                .accessibilityLabel(sessions)
                .accessibilityIdentifier("draft-project-sessions")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func crumb(projectName: String?, words: String) -> some View {
        HStack(spacing: 0) {
            if let projectName {
                Text(projectName).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1).truncationMode(.tail)
                Text(Self.crumbTail).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1).fixedSize()
            } else {
                Text(words).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
            }
        }
        .font(LoomTheme.DraftHeader.crumbFont)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
        .accessibilityIdentifier("draft-crumb")
    }
}
