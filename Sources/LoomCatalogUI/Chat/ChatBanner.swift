import SwiftUI

/// What the live chat's banner can say (CHAT-SPEC → Markers and banners, V19). One banner shows above the composer; the
/// others wait behind a "+N" peek. The order is the spec's: a blocker first (a policy signal, with Continue in Terminal),
/// then notices (drift Loom does not understand). A dismissed banner stays dismissed for the session.
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

    var id: Kind { kind }
}

enum ChatBanners {
    /// The banners that apply now, blockers first.
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
                actionTitle: canContinueInTerminal ? "Continue in Terminal" : nil))
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
        return items
    }
}

/// The one banner above the composer: the first item, its action and a dismiss button, and "+N" for the others. The "+N"
/// peeks at the next one; dismissing shows what waited.
struct ChatBannerView: View {
    let items: [ChatBannerItem]
    let dismiss: (ChatBannerItem.Kind) -> Void
    let perform: (ChatBannerItem.Kind) -> Void
    @State private var peek = 0

    var body: some View {
        if let item = items.isEmpty ? nil : items[min(peek, items.count - 1)] {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").font(LoomTheme.Chat.rowIcon)
                    .foregroundStyle(LoomTheme.Status.attentionLight).accessibilityHidden(true)
                Text(item.message)
                    .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.primary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let title = item.actionTitle {
                    Button(title) { perform(item.kind) }
                        .buttonStyle(.plain).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Accent.base)
                        .accessibilityIdentifier("chat-banner-action")
                }
                if items.count > 1 {
                    Button { peek = (min(peek, items.count - 1) + 1) % items.count } label: {
                        Text("+\(items.count - 1)").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Show the next of \(items.count - 1) more notices")
                }
                Button { dismiss(item.kind) } label: {
                    Image(systemName: "xmark").font(LoomTheme.Chat.chevron).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).fill(LoomTheme.Surface.card))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).strokeBorder(LoomTheme.Surface.hairlineStyle))
            .frame(maxWidth: LoomTheme.Chat.column - 2 * LoomTheme.Chat.columnPadding)
            .padding(.horizontal, LoomTheme.Chat.columnPadding).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-banner")
        }
    }
}
