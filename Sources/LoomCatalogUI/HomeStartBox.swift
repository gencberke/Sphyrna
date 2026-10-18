import LoomCore
import SwiftUI

/// The start box (V05): the new-session composer of the project that was used last, a strip with the project
/// and its branch, and the way to start. ↵ starts the session through the same path as the draft screen; the
/// slot is the project's own draft, so what is typed here is the draft the sidebar lists.
struct HomeStartBox: View {
    let model: CatalogModel

    var body: some View {
        let projectID = model.homeStartProjectID
        VStack(alignment: .leading, spacing: LoomTheme.Space.chipInset) {
            // One composer per project, as on the draft screen: another project starts from its own field.
            NewSessionComposer(model: model, projectID: projectID).id(projectID?.uuidString ?? "none")
            HomeStartStrip(model: model, projectID: projectID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-start")
    }
}

/// Under the composer: the project (a menu), its branch and where mode and model come from.
private struct HomeStartStrip: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        HStack(spacing: NewSessionLayout.chipSpacing) {
            projectMenu
            if case .named(let name)? = model.newSession.branch(for: projectID) {
                HStack(spacing: LoomTheme.Space.hintSpacing) {
                    Image(systemName: "arrow.triangle.branch").font(LoomTheme.Typography.small)
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
                .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .accessibilityLabel("Branch, \(name)")
            }
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            Text(hint).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.tertiary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, LoomTheme.Space.headerSpacing)
    }

    private var project: CatalogProject? { model.draftProject(projectID) }

    /// "↵ starts it", and where mode and model come from when that is the project's last start.
    private var hint: String {
        let resolved = model.resolvedStart(for: projectID)
        if resolved.mode.source == .lastUsed || resolved.model.source == .lastUsed {
            return "↵ starts it · mode and model as last used" + (project.map { " in \($0.name)" } ?? "")
        }
        return "↵ starts it"
    }

    @ViewBuilder private var projectMenu: some View {
        if model.projects.isEmpty {
            Text("No project").font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
        } else {
            let tone = model.projectTone(forProject: projectID)
            Menu {
                ForEach(model.projects) { entry in
                    Button { model.chooseHomeStartProject(entry.id) } label: {
                        if entry.id == projectID { Label(entry.name, systemImage: "checkmark") } else { Text(entry.name) }
                    }
                }
            } label: {
                HStack(spacing: NewSessionLayout.chipSpacing) {
                    if let tone {
                        RoundedRectangle(cornerRadius: LoomTheme.ProjectColor.stripeRadius)
                            .fill(LoomTheme.ProjectColor.stripe(tone))
                            .frame(width: LoomTheme.Home.toneStripe.width, height: LoomTheme.Home.toneStripe.height)
                            .accessibilityHidden(true)
                    }
                    Text(project?.name ?? "Project").lineLimit(1)
                    Image(systemName: "chevron.down").font(LoomTheme.Typography.chevron)
                        .foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
            }
            .menuStyle(.button).buttonStyle(ChipButtonStyle()).menuIndicator(.hidden).fixedSize()
            .help("The project the session starts in")
            .accessibilityLabel("Project, \(project?.name ?? "none")")
            .accessibilityIdentifier("home-start-project")
        }
    }
}
