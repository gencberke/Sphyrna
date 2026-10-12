import LoomCore
import SwiftUI

/// The slim notice above a live terminal while the session's state carries an issue (for example the
/// hook watchdog's "Loom is not receiving events from Claude…"). Without it the person sees only the
/// "Problem" label on the card; the text otherwise shows only on the record view, which a live session
/// does not have. It looks like `EndedScreenNotice` and fades in with opacity only: a height animation
/// above the terminal would resize it. Its colour is the failure colour of the "Problem" state it
/// explains, as on the record view's notice. It is present exactly while the issue is, and does not
/// depend on anything else in the frame, so unrelated state changes neither redraw nor re-fade it.
struct SessionIssueNotice: View {
    let message: String

    /// The text to show for a live state, nil when it has no issue.
    nonisolated static func message(for live: SessionViewState?) -> String? {
        guard let issue = live?.issue, !issue.isEmpty else { return nil }
        return issue
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.detailSpacing) {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
            Text(message).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
        }
        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.failure)
        .padding(.horizontal, LoomTheme.Space.detailInset).padding(.bottom, LoomTheme.Space.bannerBottom)
        .fadesIn()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityIdentifier("session-issue-notice")
    }
}
