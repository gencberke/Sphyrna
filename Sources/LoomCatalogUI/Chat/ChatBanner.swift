import SwiftUI

/// How much a banner weighs (DESIGN §19 Banners): what did not happen first, in the failure tone with the triangle; then what
/// limits Sphyrna, in the attention tone; then notes, quiet. Only the edge and the symbol take the tone, and each tone has its
/// own symbol, so colour is never alone.
enum ChatBannerTone: Int, Comparable, CaseIterable {
    case failure
    case attention
    case note

    static func < (lhs: ChatBannerTone, rhs: ChatBannerTone) -> Bool { lhs.rawValue < rhs.rawValue }

    var symbol: String {
        switch self {
        case .failure: "exclamationmark.triangle"
        case .attention: "exclamationmark.circle"
        case .note: "info.circle"
        }
    }

    /// The box's 1 pt edge: the tone at 34 %, or the strong hairline for a note.
    var edge: AnyShapeStyle {
        switch self {
        case .failure: AnyShapeStyle(LoomTheme.Status.failure.opacity(LoomTheme.Pinned.edgeOpacity))
        case .attention: AnyShapeStyle(LoomTheme.Status.attention.opacity(LoomTheme.Pinned.edgeOpacity))
        case .note: AnyShapeStyle(LoomTheme.Surface.strongHairline)
        }
    }

    var symbolStyle: AnyShapeStyle {
        switch self {
        case .failure: AnyShapeStyle(LoomTheme.Status.failure)
        case .attention: AnyShapeStyle(LoomTheme.Status.attention)
        case .note: AnyShapeStyle(LoomTheme.Text.tertiaryStyle)
        }
    }
}

/// What the live chat's banner can say (CHAT-SPEC → Markers and banners, V19). One banner shows between the stream and the
/// cards; the others wait behind a "+N" peek. The order is DESIGN §19's: by tone, then as they came (a policy signal with
/// Switch to Terminal limits Sphyrna; drift Sphyrna does not understand is a note). A dismissed banner stays dismissed for the
/// session.
struct ChatBannerItem: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Claude says the account's plan may not allow the Chat face.
        case policy
        /// A wire shape or capability this version of Loom does not expect.
        case wireDrift
        /// Records in the transcript with a shape Loom does not know.
        case unknownRecords
    }

    let kind: Kind
    let message: String
    /// The button's title; nil for a banner that only informs.
    let actionTitle: String?
    /// How much it weighs; a kind has its own unless the caller says otherwise.
    let tone: ChatBannerTone

    var id: Kind { kind }

    init(kind: Kind, message: String, actionTitle: String?, tone: ChatBannerTone? = nil) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.tone = tone ?? Self.defaultTone(kind)
    }

    static func defaultTone(_ kind: Kind) -> ChatBannerTone {
        switch kind {
        case .policy: .attention
        case .wireDrift, .unknownRecords: .note
        }
    }
}

enum ChatBanners {
    /// The banners that apply now, heaviest first.
    /// `owner` is the face that owns the session: the fallback text without a button names the terminal only where the
    /// terminal really runs the session (the live chat is the Chat face's, so it never does there).
    static func items(policySignal: Bool, policyDismissed: Bool, canContinueInTerminal: Bool, owner: SessionFace = .chat,
                      wireDrift: Int, wireDriftDismissed: Bool,
                      unknownRecords: Int, recordsDismissed: Bool) -> [ChatBannerItem] {
        var items: [ChatBannerItem] = []
        if policySignal, !policyDismissed {
            items.append(ChatBannerItem(
                kind: .policy,
                message: canContinueInTerminal || owner == .chat
                    ? "Claude says this account's plan may not allow the Chat face."
                    : "Claude says this account's plan may not allow the Chat face. The terminal still runs this session.",
                actionTitle: canContinueInTerminal ? "Switch to Terminal" : nil))
        }
        if wireDrift > 0, !wireDriftDismissed {
            items.append(ChatBannerItem(
                kind: .wireDrift,
                message: "Claude sent something this version of Loom does not expect. The session goes on; some of it may not show.",
                actionTitle: nil))
        }
        if unknownRecords > 0, !recordsDismissed {
            items.append(ChatBannerItem(
                kind: .unknownRecords,
                message: "\(unknownRecords) record\(unknownRecords == 1 ? "" : "s") in this session \(unknownRecords == 1 ? "has" : "have") a shape Loom does not know. They show as raw rows.",
                actionTitle: nil))
        }
        return ordered(items)
    }

    /// By weight (failure, attention, note), and as they came within a tone (DESIGN §19 Banners).
    static func ordered(_ items: [ChatBannerItem]) -> [ChatBannerItem] {
        items.enumerated().sorted { ($0.element.tone, $0.offset) < ($1.element.tone, $1.offset) }.map(\.element)
    }
}

/// The banner between the stream and the cards: the first item in the family's box (raised 2, radius 12, the tone's edge and
/// symbol), its action and a dismiss button; "+N" opens the others under it in place and closes them again.
struct ChatBannerView: View {
    let items: [ChatBannerItem]
    let dismiss: (ChatBannerItem.Kind) -> Void
    let perform: (ChatBannerItem.Kind) -> Void
    @State private var open = false

    var body: some View {
        if let first = items.first {
            let shown = open && items.count > 1 ? items : [first]
            VStack(spacing: LoomTheme.ChatBanner.stackGap) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    row(item, peek: index == 0 && items.count > 1)
                }
            }
            .frame(maxWidth: LoomTheme.Chat.column)
            .padding(.horizontal, LoomTheme.Pinned.stackPaddingH).padding(.bottom, LoomTheme.Pinned.stackPaddingBottom)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-banner")
        }
    }

    private func row(_ item: ChatBannerItem, peek: Bool) -> some View {
        HStack(spacing: LoomTheme.ChatBanner.gap) {
            Image(systemName: item.tone.symbol).font(LoomTheme.ChatBanner.symbol).foregroundStyle(item.tone.symbolStyle)
                .frame(width: LoomTheme.ChatBanner.symbolSlot).accessibilityHidden(true)
            Text(item.message).font(LoomTheme.ChatBanner.text).foregroundStyle(LoomTheme.Text.primary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let title = item.actionTitle {
                Button(title) { perform(item.kind) }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                    .accessibilityIdentifier("chat-banner-action")
            }
            if peek {
                Button { open.toggle() } label: {
                    Text(open ? "\u{2212}\(items.count - 1)" : "+\(items.count - 1)").font(LoomTheme.ChatBanner.peek)
                        .foregroundStyle(LoomTheme.Text.tertiaryStyle).padding(.horizontal, LoomTheme.ChatBanner.peekPadding)
                        .frame(minHeight: LoomTheme.ChatBanner.peekHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Show fewer notices" : "Show \(items.count - 1) more notices")
                .accessibilityIdentifier("chat-banner-peek")
            }
            ChatIconButton(symbol: "xmark", label: "Dismiss") { dismiss(item.kind) }
        }
        .padding(.leading, LoomTheme.ChatBanner.paddingLeading).padding(.trailing, LoomTheme.ChatBanner.paddingTrailing)
        .frame(minHeight: LoomTheme.ChatBanner.minHeight)
        .pinnedSurface(radius: LoomTheme.ChatBanner.radius, fill: LoomTheme.Pinned.cardFill, edge: item.tone.edge)
    }
}
