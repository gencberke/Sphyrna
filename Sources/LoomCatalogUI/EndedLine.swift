import LoomCore
import SwiftUI

/// The line above the kept screen of a run that ended (DESIGN §19 The ended line): 40 high, flush on the canvas, with a hairline
/// under it. "This session is not running." in secondary, then Show Details and Resume at the trailing edge, Resume last and
/// filled, because it is the pane's one action. Return does nothing here (no key equivalent on either button): the screen below
/// keeps the focus. "Show Details" lets go of the screen and shows the record. It fades in (opacity only): a height animation
/// above the terminal would resize it. After a banner stack it gets 8 above it and a hairline.
struct EndedScreenNotice: View {
    let model: CatalogModel
    let row: SessionRowModel
    /// The kept screen offers "Show Details"; the chat view above the same notice has no screen to let go of.
    var showsDetails = true
    @Environment(\.bannerStackShown) private var afterStack
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate

    enum Choice: Equatable { case showDetails, resume }

    /// The notice text; a resume under way says so.
    static func text(busy: ConversationBusy?) -> String {
        busy == .resuming ? "Resuming…" : "This session is not running."
    }

    /// The buttons from the leading side: Show Details (where there is a screen to let go of), then Resume.
    static func buttons(showsDetails: Bool) -> [Choice] { showsDetails ? [.showDetails, .resume] : [.resume] }

    static func resumeTitle(stale: Bool) -> String { stale ? "Reactivate and Resume" : "Resume" }

    var body: some View {
        let busy = model.busy[row.id]
        VStack(spacing: 0) {
            if afterStack {
                Color.clear.frame(height: LoomTheme.Edges.endedAfterStackTop)
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
            }
            HStack(spacing: LoomTheme.Edges.endedGap) {
                if busy == .resuming {
                    BrailleSpinner(animating: indicatorsAnimate).frame(width: LoomTheme.Edges.spinnerSlot).accessibilityHidden(true)
                }
                Text(Self.text(busy: busy))
                    .font(LoomTheme.Edges.endedText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .lineLimit(1)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                ForEach(Self.buttons(showsDetails: showsDetails), id: \.self) { button in
                    switch button {
                    case .showDetails:
                        Button("Show Details") { model.closeEndedScreen(row.id) }
                            .disabled(busy == .resuming)
                            .buttonStyle(ControlButtonStyle(kind: .secondary))
                            .help("Closes this screen and shows the session's details")
                    case .resume:
                        Button(Self.resumeTitle(stale: row.record.lifecycle == .stale)) {
                            model.resumeConversation(row.id)
                        }
                        .disabled(!model.canResume(row) || busy == .resuming)
                        .buttonStyle(AccentButtonStyle(kind: .filled))
                        .onAppear { SidebarRenderProbe.appeared("resume", session: row.id) }
                        .onDisappear { SidebarRenderProbe.disappeared("resume", session: row.id) }
                    }
                }
            }
            .padding(.leading, LoomTheme.Edges.endedPaddingLeading).padding(.trailing, LoomTheme.Edges.endedPaddingTrailing)
            .frame(height: LoomTheme.Edges.endedHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
            }
        }
        .fadesIn()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ended-screen-notice")
    }
}
