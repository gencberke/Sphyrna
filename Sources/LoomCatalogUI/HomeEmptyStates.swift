import AppKit
import SwiftUI

/// What Home says in each first-run case. Plain values so a test reads the words without a view.
struct HomeEmptyCopy: Equatable {
    let title: String
    let text: String

    /// A catalog with nothing in it: the way on is to add a project.
    static let noProjects = HomeEmptyCopy(
        title: "No projects yet",
        text: "Add the folder you work in. Its Claude sessions then appear in the sidebar and here, and new sessions start inside it.")

    /// A connected agent needs setting up (D-98): the cards stand under these words.
    static let connect = HomeEmptyCopy(title: HomeConnect.title, text: HomeConnect.firstRunText)
}

/// The words of Check Again while it asks (DESIGN §9 Empty states).
enum HomeCheckAgain {
    static func title(checking: Bool) -> String { checking ? "Checking…" : "Check Again" }
}

/// Check Again: asks the harness health again (every connected harness, whatever the 5-minute floor says). While that asks it
/// says "Checking…" with the spinner and is off.
struct HomeCheckAgainButton: View {
    let model: CatalogModel
    var size: LoomTheme.Control.Size = .regular
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate

    var body: some View {
        let checking = !(model.harnessHealth?.checking.isEmpty ?? true)
        Button { model.recheckHarnesses() } label: {
            HStack(spacing: LoomTheme.Home.projectGap) {
                if checking {
                    BrailleSpinner(animating: indicatorsAnimate).frame(width: LoomTheme.Layout.indicatorSlot.width).accessibilityHidden(true)
                }
                Text(HomeCheckAgain.title(checking: checking))
            }
        }
        .buttonStyle(ControlButtonStyle(kind: .outline, size: size))
        .disabled(checking)
        .accessibilityIdentifier("home-check-again")
    }
}

/// Home over an empty catalog: no project and no session. The Home route comes before "Add a project", so Home carries this
/// state itself, with the add-project action; while a connected harness needs setting up it says "Connect your agents" first,
/// with a card for each harness (`HomeConnect`). It is its own view, not `Message`: the first run carries the app icon at 84
/// over the faint grid; the cards take its place, without the school.
struct HomeEmptyCatalog: View {
    let model: CatalogModel

    /// The first run carries the app icon; "Connect your agents" stands in its place.
    static func showsMark(connectCards: Bool) -> Bool { !connectCards }

    var body: some View {
        let connect = model.homeConnect.showsCards
        let copy = connect ? HomeEmptyCopy.connect : HomeEmptyCopy.noProjects
        VStack(spacing: 0) {
            if Self.showsMark(connectCards: connect) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: LoomTheme.Home.iconSide, height: LoomTheme.Home.iconSide)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("home-app-icon")
            }
            Text(copy.title).homeType(LoomTheme.InkType.title).foregroundStyle(LoomTheme.Text.primary)
                .padding(.top, connect ? 0 : LoomTheme.Home.titleTop)
                .accessibilityAddTraits(.isHeader)
            Text(copy.text).homeType(LoomTheme.Home.firstText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineSpacing(LoomTheme.Home.textLineSpacing)
                .multilineTextAlignment(.center).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: LoomTheme.Home.textWidth)
                .padding(.top, LoomTheme.Home.textTop)
            if connect {
                HomeConnectCards(model: model).padding(.top, LoomTheme.Home.connectCardsTop)
            }
            HStack(alignment: .top, spacing: LoomTheme.Home.firstActionsGap) {
                Button("Add Project…") { model.presentAddProject() }
                    .keyboardShortcut("o", modifiers: .command)
                    .buttonStyle(ControlButtonStyle(kind: .default))
                    .accessibilityIdentifier("home-add-project")
                if connect {
                    HomeCheckAgainButton(model: model)
                } else {
                    Button("New Claude Session") { model.beginNewSession(projectID: nil) }
                        .buttonStyle(ControlButtonStyle(kind: .secondary))
                        .disabled(!model.canStart(.claude, projectID: nil))
                        .accessibilityIdentifier("home-new-session")
                }
                // Codex is listed in every build (D-69); a build that cannot start it shows the entry disabled, with
                // the reason (`startableProviders` is the build's decision). Over the cards, Codex's card says it.
                if !connect {
                    VStack(spacing: LoomTheme.Home.codexNoteGap) {
                        Button("New Codex Session") { model.startConversation(.codex, projectID: nil) }
                            .buttonStyle(ControlButtonStyle(kind: .secondary))
                            .disabled(!model.canStart(.codex, projectID: nil))
                            .accessibilityIdentifier("home-new-codex-session")
                        if let reason = model.newSessionUnavailableReason(.codex) {
                            Text(reason).homeType(LoomTheme.Home.codexNote).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                                .accessibilityIdentifier("home-new-codex-reason")
                        }
                    }
                }
            }
            .padding(.top, LoomTheme.Home.actionsTop)
        }
        .padding(.bottom, LoomTheme.Home.lift)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(connect ? "home-connect" : "home-empty-catalog")
    }
}
