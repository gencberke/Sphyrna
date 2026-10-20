import SwiftUI

/// The open side chat: its stream, and under it the card of a request that waits (one at a time, as the main chat's pinned
/// card; "Allow for this session" is never offered here).
struct SideThread: View {
    let model: CatalogModel
    let parent: UUID
    let item: SideChatItem
    let feed: LiveChatFeed
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                SideStreamView(feed: feed, notes: model.sideNotes(for: item.id, in: parent),
                               onOpenChanges: { [model, parent] in model.openChanges(.branch, for: parent) })
                    .id(ObjectIdentifier(feed))
                if item.firstUUID == nil, model.side.existing(for: parent)?.hasAsked(item.id) != true {
                    // Nothing was asked yet: the thread is empty by construction (what the fork copied is not shown).
                    SideEmptyState().frame(maxHeight: .infinity, alignment: .top)
                }
            }
            // The slot between the stream and the composer: the stream gives way to the card, up to its share.
            PinnedCardsView(cards: feed.cards,
                            maxHeight: height > 0 ? height * LoomTheme.Pinned.stackMaxHeightFraction : nil)
                .layoutPriority(1)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
}

/// The stream of a side chat: the main chat's own rows (`LiveChatViewModel` over a `LiveChatFeed`) at the column's width. It
/// has no composer behind it, so its rows draw no "Read now", "Retry" or "Rewind files" (`ChatRowContext.rewind.source` stays
/// unset: the fork shares the parent's folder, and a rewind there would change files under the main session), and a finished
/// answer offers "Send to main as a note".
struct SideStreamView: View {
    let feed: LiveChatFeed
    let notes: SideAnswerNotes
    var onOpenChanges: (() -> Void)?
    @State private var model: LiveChatViewModel?

    var body: some View {
        ZStack {
            if let model {
                SideStreamContent(model: model, feed: feed)
            } else {
                Color.clear
            }
        }
        .task(id: ObjectIdentifier(feed)) {
            if model?.feed !== feed {
                model?.close()
                let made = Self.makeModel(feed: feed, notes: notes)
                made.onOpenChanges = { _ in onOpenChanges?() }
                model = made
            }
        }
    }

    /// The view model of a side chat's stream: no composer, the notes holder, and the column's own side padding.
    static func makeModel(feed: LiveChatFeed, notes: SideAnswerNotes) -> LiveChatViewModel {
        let made = LiveChatViewModel(feed: feed, composer: nil)
        made.controller.context.sideNotes = notes
        made.controller.context.columnPadding = LoomTheme.Side.threadInset
        return made
    }
}

private struct SideStreamContent: View {
    let model: LiveChatViewModel
    let feed: LiveChatFeed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if feed.phase == .ready {
                ZStack(alignment: .bottom) {
                    ChatStreamHost(controller: model.controller)
                    if model.showsJump {
                        ChatJumpPill { model.jumpToLatest() }
                            .padding(.bottom, LoomTheme.Side.headerInsetV)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Chat.fadeDuration), value: model.showsJump)
            }
            ChatWindowVisibility { model.setWindowVisible($0) }.frame(width: 0, height: 0)
        }
        .onAppear { model.setOnScreen(true) }
        .onDisappear { model.setOnScreen(false) }
    }
}
