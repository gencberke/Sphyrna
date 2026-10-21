import SwiftUI

/// The family's box (DESIGN §19 Banners, §12): raised 2, radius 12, a 1 pt edge in the tone's colour, 36 high at least. The chat's
/// banner above the composer (`ChatBannerView`) and the top stack (`Banners`) both draw it, so the two cannot drift. Only the
/// edge and the symbol take the tone; the words are the caller's.

/// What the box shows in its symbol slot: the tone's own symbol, or the spinner for a row that reports progress.
enum BannerLeading: Equatable {
    case tone
    case spinner
}

/// A button in the box's trailing group.
struct BannerAction: Identifiable {
    enum Style: Equatable {
        /// The small secondary button (the chat's "Switch to Terminal").
        case secondary
        /// The accent tint: the safe way on.
        case accent
        /// The failure tint: the way out that removes something.
        case failure
    }

    /// Also the accessibility identifier.
    let id: String
    let title: String
    var style: Style = .secondary
    var enabled = true
    var help: String?
    let perform: () -> Void
}

/// "+N" on the first box while others wait; opens them under it in place and closes them again.
struct BannerPeek {
    /// How many boxes wait behind the first.
    let hidden: Int
    let open: Bool
    let identifier: String
    let toggle: () -> Void

    var text: String { open ? "\u{2212}\(hidden)" : "+\(hidden)" }
    var label: String { open ? "Show fewer notices" : "Show \(hidden) more notices" }
}

struct BannerDismiss {
    let label: String
    let perform: () -> Void
}

struct BannerBox: View {
    let tone: ChatBannerTone
    var leading: BannerLeading = .tone
    let text: String
    /// A second line in mono under the text (a deletion's session title). A box with one aligns to the top.
    var detail: String?
    /// The chat's text stops at two lines; the stack's wraps.
    var lineLimit: Int?
    var selectable = false
    /// Room above and below the text, for a box whose text wraps.
    var textInsetV: CGFloat = 0
    var actions: [BannerAction] = []
    var peek: BannerPeek?
    var dismiss: BannerDismiss?
    var identifier: String?

    @Environment(\.indicatorsAnimate) private var indicatorsAnimate

    private var tall: Bool { detail != nil }

    var body: some View {
        HStack(alignment: tall ? .top : .center, spacing: LoomTheme.ChatBanner.gap) {
            symbol.padding(.top, tall ? LoomTheme.Edges.tallSymbolTop : 0)
            VStack(alignment: .leading, spacing: LoomTheme.Edges.detailTop) {
                words.modifier(OptionalIdentifier(identifier: identifier))
                if let detail {
                    Text(detail).font(LoomTheme.Edges.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.vertical, textInsetV)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !actions.isEmpty {
                HStack(spacing: LoomTheme.Edges.actionGap) {
                    ForEach(actions) { action in button(action) }
                }
                .padding(.top, tall ? LoomTheme.Edges.tallActionsTop : 0)
            }
            if let peek { peekButton(peek) }
            if let dismiss { ChatIconButton(symbol: "xmark", label: dismiss.label, action: dismiss.perform) }
        }
        .padding(.leading, LoomTheme.ChatBanner.paddingLeading).padding(.trailing, LoomTheme.ChatBanner.paddingTrailing)
        .frame(minHeight: LoomTheme.ChatBanner.minHeight)
        .pinnedSurface(radius: LoomTheme.ChatBanner.radius, fill: LoomTheme.Pinned.cardFill, edge: tone.edge)
    }

    @ViewBuilder private var symbol: some View {
        switch leading {
        case .tone:
            Image(systemName: tone.symbol).font(LoomTheme.ChatBanner.symbol).foregroundStyle(tone.symbolStyle)
                .frame(width: LoomTheme.ChatBanner.symbolSlot).accessibilityHidden(true)
        case .spinner:
            BrailleSpinner(animating: indicatorsAnimate).frame(width: LoomTheme.ChatBanner.symbolSlot).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var words: some View {
        let label = Text(text).font(LoomTheme.ChatBanner.text).foregroundStyle(LoomTheme.Text.primary).lineLimit(lineLimit)
        if lineLimit == nil {
            if selectable {
                label.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                label.fixedSize(horizontal: false, vertical: true)
            }
        } else if selectable {
            label.textSelection(.enabled)
        } else {
            label
        }
    }

    @ViewBuilder private func button(_ action: BannerAction) -> some View {
        let base = Button(action.title, action: action.perform).disabled(!action.enabled)
        Group {
            switch action.style {
            case .secondary: base.buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
            case .accent: base.buttonStyle(AccentButtonStyle(kind: .tinted, size: .small))
            case .failure: base.buttonStyle(BannerFailureTintStyle())
            }
        }
        .modifier(OptionalHelp(text: action.help))
        .accessibilityIdentifier(action.id)
    }

    private func peekButton(_ peek: BannerPeek) -> some View {
        Button(action: peek.toggle) {
            Text(peek.text).font(LoomTheme.ChatBanner.peek)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle).padding(.horizontal, LoomTheme.ChatBanner.peekPadding)
                .frame(minHeight: LoomTheme.ChatBanner.peekHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(peek.label)
        .accessibilityIdentifier(peek.identifier)
    }
}

/// The failure tint of a banner's way out (D-78: "Remove from Sphyrna Only"): the failure text on the failure wash.
struct BannerFailureTintStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ControlButtonStyle(kind: .destructive, size: .small).makeBody(configuration: configuration)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Control.Size.small.radius).fill(LoomTheme.Status.failureWash))
    }
}

private struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}

private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}
