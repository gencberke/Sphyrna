import AppKit
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

/// The words of Check Again while it asks (DESIGN §9 Empty states).
enum HomeCheckAgain {
    static func title(checking: Bool) -> String { checking ? "Checking…" : "Check Again" }
}

/// Check Again: asks for the plan limits again, which resolves the Claude CLI again. While that asks it says "Checking…" with
/// the spinner and is off.
private struct HomeCheckAgainButton: View {
    let model: CatalogModel
    var size: LoomTheme.Control.Size = .regular
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate

    var body: some View {
        let checking = model.usage?.isRefreshing ?? false
        Button { model.recheckClaude() } label: {
            HStack(spacing: LoomTheme.Home.projectGap) {
                if checking {
                    BrailleSpinner(animating: indicatorsAnimate).frame(width: LoomTheme.Layout.indicatorSlot.width).accessibilityHidden(true)
                }
                Text(HomeCheckAgain.title(checking: checking))
            }
        }
        .buttonStyle(ControlButtonStyle(kind: .secondary, size: size))
        .disabled(checking)
        .accessibilityIdentifier("home-check-again")
    }
}

/// Home over an empty catalog: no project and no session. The Home route comes before "Add a project", so Home carries this
/// state itself, with the add-project action; with no Claude CLI it says that first. It is its own view, not `Message`:
/// the first run carries the app icon at 84 over the faint grid, and a missing Claude the attention triangle at 40.
struct HomeEmptyCatalog: View {
    let model: CatalogModel

    /// The first run carries the app icon; the missing-Claude state keeps its warning symbol.
    static func showsMark(claudeMissing: Bool) -> Bool { !claudeMissing }

    var body: some View {
        let missing = model.homeClaudeCLIMissing
        let copy = missing ? HomeEmptyCopy.noClaude : HomeEmptyCopy.noProjects
        VStack(spacing: 0) {
            if Self.showsMark(claudeMissing: missing) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: LoomTheme.Home.iconSide, height: LoomTheme.Home.iconSide)
                    .depth(LoomTheme.Home.iconDepth)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("home-app-icon")
            } else {
                Image(systemName: copy.symbol).homeType(LoomTheme.Home.symbol).foregroundStyle(LoomTheme.Status.attention)
                    .frame(width: LoomTheme.Home.symbolBox, height: LoomTheme.Home.symbolBox)
                    .accessibilityHidden(true)
            }
            Text(copy.title).homeType(LoomTheme.InkType.title).foregroundStyle(LoomTheme.Text.primary)
                .padding(.top, LoomTheme.Home.titleTop)
                .accessibilityAddTraits(.isHeader)
            Text(copy.text).homeType(LoomTheme.Home.firstText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineSpacing(LoomTheme.Home.textLineSpacing)
                .multilineTextAlignment(.center).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: LoomTheme.Home.textWidth)
                .padding(.top, LoomTheme.Home.textTop)
            HStack(alignment: .top, spacing: LoomTheme.Home.firstActionsGap) {
                Button("Add Project…") { model.presentAddProject() }
                    .keyboardShortcut("o", modifiers: .command)
                    .buttonStyle(ControlButtonStyle(kind: .primary))
                    .accessibilityIdentifier("home-add-project")
                if missing {
                    HomeCheckAgainButton(model: model)
                } else {
                    Button("New Claude Session") { model.beginNewSession(projectID: nil) }
                        .buttonStyle(ControlButtonStyle(kind: .secondary))
                        .disabled(!model.canStart(.claude, projectID: nil))
                        .accessibilityIdentifier("home-new-session")
                }
                // Codex is listed in every build (D-69); a build that cannot start it shows the entry disabled, with
                // the reason (`startableProviders` is the build's decision).
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
            .padding(.top, LoomTheme.Home.actionsTop)
        }
        .padding(.bottom, LoomTheme.Home.lift)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if Self.showsMark(claudeMissing: missing) { CanvasGrid() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(missing ? "home-no-claude" : "home-empty-catalog")
    }
}

/// Above a catalog that has sessions: a card under the band while no Claude CLI works (DESIGN §9 Empty states). Plan limits is
/// left out, and so is the sidebar's New session row.
struct HomeNoClaudeNotice: View {
    let model: CatalogModel

    var body: some View {
        let copy = HomeEmptyCopy.noClaudeWithSessions
        HomeCard(identifier: "home-no-claude") {
            HStack(alignment: .center, spacing: LoomTheme.Home.noticeGap) {
                HStack(alignment: .top, spacing: LoomTheme.Home.noticeGap) {
                    Image(systemName: copy.symbol).homeType(LoomTheme.Home.noticeSymbol)
                        .foregroundStyle(LoomTheme.Status.attention)
                        .frame(width: LoomTheme.Home.noticeColumn, alignment: .leading).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LoomTheme.Home.noticeTextGap) {
                        Text(copy.title).homeType(LoomTheme.Home.noticeTitle).foregroundStyle(LoomTheme.Text.primary)
                        Text(copy.text).homeType(LoomTheme.Home.noticeText).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: LoomTheme.Home.noticeGap)
                HomeCheckAgainButton(model: model, size: .small)
            }
            .padding(.vertical, LoomTheme.Home.noticePaddingV).padding(.horizontal, LoomTheme.Home.noticePaddingH)
        }
    }
}
