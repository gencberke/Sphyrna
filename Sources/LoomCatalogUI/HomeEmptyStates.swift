import SwiftUI

/// What Home says in each first-run case. Plain values so a test reads the words without a view.
struct HomeEmptyCopy: Equatable {
    let symbol: String
    let title: String
    let text: String

    /// A catalog with nothing in it: the way on is to add a project.
    static let noProjects = HomeEmptyCopy(
        symbol: "folder.badge.plus", title: "No projects yet",
        text: "Add the folder you work in. Its Claude sessions then appear in the sidebar and here, and new sessions start inside it.")

    /// Loom could not use a Claude CLI (the plan-limits ask found none): nothing can start until it can.
    static let noClaude = HomeEmptyCopy(
        symbol: "exclamationmark.triangle", title: "Loom could not find Claude",
        text: "Loom starts sessions with the claude command and could not use the one on your terminal's PATH. "
            + "Install Claude Code or fix the PATH, then choose Check Again. You can add a project now.")

    /// The same fact above a catalog that has sessions in it: they stay readable.
    static let noClaudeWithSessions = HomeEmptyCopy(
        symbol: "exclamationmark.triangle", title: "Loom could not find Claude",
        text: "New sessions cannot start until the claude command works from your terminal's PATH. "
            + "Sessions already listed stay readable.")
}

/// Home over an empty catalog: no project and no session. The Home route comes before "Add a project", so
/// Home carries this state itself, with the add-project action; with no Claude CLI it says that first.
struct HomeEmptyCatalog: View {
    let model: CatalogModel

    var body: some View {
        let missing = model.homeClaudeCLIMissing
        let copy = missing ? HomeEmptyCopy.noClaude : HomeEmptyCopy.noProjects
        VStack(spacing: LoomTheme.Space.emptyStateSpacing) {
            Message(symbol: copy.symbol, title: copy.title, text: copy.text)
            HStack {
                Button("Add Project…") { model.presentAddProject() }
                    .keyboardShortcut("o", modifiers: .command)
                    .buttonStyle(AccentButtonStyle(kind: .filled))
                    .accessibilityIdentifier("home-add-project")
                if missing {
                    Button("Check Again") { model.recheckClaude() }
                        .accessibilityIdentifier("home-check-again")
                } else {
                    Button("New Claude Session") { model.beginNewSession(projectID: nil) }
                        .disabled(!model.canStart(.claude, projectID: nil))
                        .accessibilityIdentifier("home-new-session")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(missing ? "home-no-claude" : "home-empty-catalog")
    }
}

/// Above a catalog that has sessions: the start box gives way to this notice while no Claude CLI works.
struct HomeNoClaudeNotice: View {
    let model: CatalogModel

    var body: some View {
        let copy = HomeEmptyCopy.noClaudeWithSessions
        HomeCard(identifier: "home-no-claude") {
            HStack(alignment: .top, spacing: LoomTheme.Space.noticeSpacing) {
                Image(systemName: copy.symbol).font(LoomTheme.Typography.body)
                    .foregroundStyle(LoomTheme.Status.attention).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LoomTheme.Space.noticeLineSpacing) {
                    Text(copy.title).font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                    Text(copy.text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Check Again") { model.recheckClaude() }
                        .buttonStyle(ChipButtonStyle())
                        .padding(.top, LoomTheme.Space.headerSpacing)
                        .accessibilityIdentifier("home-check-again")
                }
                Spacer(minLength: 0)
            }
            .padding(LoomTheme.Space.noticePadding)
        }
    }
}
