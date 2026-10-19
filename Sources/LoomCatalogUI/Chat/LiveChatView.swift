import AppKit
import LoomChat
import Observation
import SwiftUI

/// One view of a live chat (V16): its own stream (`ChatStreamController`: the scroll view, the table, the latch) over the
/// session's `LiveChatFeed`. The stream is attached to the feed's presentation only while the view is on screen and its
/// window can be seen; otherwise the presentation goes on taking the driver's changes without drawing, and the next
/// attach draws them where the reader was.
@MainActor
@Observable
final class LiveChatViewModel {
    private(set) var isFollowing = true
    private(set) var showsJump = false

    @ObservationIgnored let feed: LiveChatFeed
    @ObservationIgnored let controller: ChatStreamController
    @ObservationIgnored var onOpenSubagent: ((_ agentID: String?, _ toolUseID: String) -> Void)?
    @ObservationIgnored private var onScreen = false
    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var closed = false

    init(feed: LiveChatFeed, composer: ChatComposerModel? = nil) {
        self.feed = feed
        let context = ChatRowContext()
        context.workingDirectory = feed.workingDirectory
        controller = ChatStreamController(context: context)
        context.toggle = { [weak feed] id in feed?.presentation.toggle(id) }
        context.toggleFlag = { [weak feed] id, flag in feed?.presentation.toggleFlag(id, flag) }
        context.showAll = { [weak feed] entry in feed?.showAll(entry) }
        // A live row has no line of its own: the feed finds its result in the transcript, when it knows the folder.
        context.canShowAll = { [weak feed] entry in feed?.canShowAll(entry) ?? false }
        context.openSubagent = { [weak self] run in self?.onOpenSubagent?(run.agentID, run.toolUseID) }
        context.openImage = { image in ChatQuickLook.show(image) }
        // Delivery actions on the user's own rows (V17): Read now on a message Claude has not read, Retry on one that was not
        // delivered.
        if let composer {
            context.canReadNow = true
            context.readNow = { [weak composer] rowID in composer?.readNow(rowID: rowID) }
            context.retry = { [weak composer] rowID in composer?.retry(rowID: rowID) }
        }
        controller.onNeedOlder = { [weak feed, weak controller] in feed?.loadOlder(controller) }
        controller.onTypeToFocus = composer.map { composer in { [weak composer] event in composer?.typeToFocus(event) } }
        controller.onCycleView = { [weak feed] in feed?.presentation.cycleViewMode() }
        controller.onLatchChange = { [weak self] following, jump in
            guard let self else { return }
            if isFollowing != following { isFollowing = following }
            if showsJump != jump { showsJump = jump }
        }
        feed.viewAppeared()
    }

    isolated deinit {
        if !closed { feed.viewWentAway(controller) }
        controller.stop()
    }

    func setOnScreen(_ value: Bool) {
        onScreen = value
        if value { feed.start() }
        reconcile()
    }

    func setWindowVisible(_ value: Bool) {
        windowVisible = value
        reconcile()
    }

    private func reconcile() {
        let shows = onScreen && windowVisible && !closed
        controller.setAnimates(shows)
        if shows { feed.attach(controller) } else { feed.detach(controller) }
    }

    func jumpToLatest() { controller.jumpToLatest() }

    func close() {
        guard !closed else { return }
        closed = true
        feed.viewWentAway(controller)
        controller.stop()
    }
}

/// The stream of a Chat-face session while its driver lives: the transcript's history above the driver's live turns,
/// with the stream's folds, views (⌃O), "Show all", live row, jump pill and notices; under it `pinned` (the cards that wait
/// for the user, V18) and the session's composer (V17).
struct LiveChatView<Pinned: View>: View {
    let feed: LiveChatFeed
    let composer: ChatComposerModel?
    let onOpenSubagent: ((String?, String) -> Void)?
    /// "Switch to Terminal" on the policy banner (the switch in Settings goes to Terminal and this session moves); nil where the session cannot be moved.
    var onContinueInTerminal: (() -> Void)?
    @ViewBuilder let pinned: (_ maxHeight: CGFloat?) -> Pinned
    @State private var model: LiveChatViewModel?

    var body: some View {
        ZStack {
            if let model {
                LiveChatContent(model: model, feed: feed, composer: composer, onOpenSubagent: onOpenSubagent,
                                onContinueInTerminal: onContinueInTerminal, pinned: pinned)
            } else {
                LoomTheme.Surface.canvas
            }
        }
        .task(id: ObjectIdentifier(feed)) {
            if model?.feed !== feed {
                model?.close()
                model = LiveChatViewModel(feed: feed, composer: composer)
            }
        }
    }
}

extension LiveChatView where Pinned == EmptyView {
    init(feed: LiveChatFeed, composer: ChatComposerModel? = nil, onOpenSubagent: ((String?, String) -> Void)?) {
        self.init(feed: feed, composer: composer, onOpenSubagent: onOpenSubagent, pinned: { _ in EmptyView() })
    }
}

struct LiveChatContent<Pinned: View>: View {
    let model: LiveChatViewModel
    let feed: LiveChatFeed
    let composer: ChatComposerModel?
    let onOpenSubagent: ((String?, String) -> Void)?
    var onContinueInTerminal: (() -> Void)?
    /// The cards that wait for the user, between the stream and the composer. They get the most they may take.
    @ViewBuilder let pinned: (_ maxHeight: CGFloat?) -> Pinned
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0
    /// The stream's own height: with a card, the banner and the composer under it, a short window leaves it a sliver.
    @State private var streamHeight: CGFloat = .infinity

    var body: some View {
        VStack(spacing: 0) {
            stream
            banner
            // The slot between the stream and the composer: V18's card stack. The stream gives way to it and to the composer.
            pinned(height > 0 ? height * (composer?.cardShown == true ? LoomTheme.Pinned.compactStackMaxHeightFraction
                                          : LoomTheme.Pinned.stackMaxHeightFraction) : nil)
                // Laid out before the stream: the stream gives way to the card (up to its share), not the card to the stream.
                .layoutPriority(1)
            if let composer { ChatComposerDock(model: composer) }
        }
        .background(LoomTheme.Surface.canvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }

    /// The one banner above the composer (CHAT-SPEC → Markers and banners): the policy signal with Switch to Terminal,
    /// then wire drift and unknown records behind a "+N".
    private var banner: some View {
        let presentation = feed.presentation
        let items = feed.phase == .ready ? ChatBanners.items(
            policySignal: feed.policySignal != nil, policyDismissed: feed.policyDismissed,
            canContinueInTerminal: onContinueInTerminal != nil, owner: .chat,
            wireDrift: feed.wireDrift, wireDriftDismissed: feed.wireDriftDismissed,
            unknownRecords: presentation.unknownRecordCount, recordsDismissed: presentation.driftDismissed) : []
        return ChatBannerView(items: items, dismiss: { kind in
            switch kind {
            case .policy: feed.policyDismissed = true
            case .wireDrift: feed.wireDriftDismissed = true
            case .unknownRecords: presentation.dismissDrift()
            }
        }, perform: { kind in
            if kind == .policy { onContinueInTerminal?() }
        })
    }

    private var stream: some View {
        let presentation = feed.presentation
        return ZStack {
            LoomTheme.Surface.canvas
            if feed.phase == .ready {
                ZStack(alignment: .bottom) {
                    ChatStreamHost(controller: model.controller)
                    VStack(spacing: 8) {
                        if model.showsJump {
                            ChatJumpPill { model.jumpToLatest() }
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                    }
                    .padding(.bottom, 12)
                    .animation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Chat.fadeDuration), value: model.showsJump)
                }
                .overlay(alignment: .topTrailing) {
                    // Not in a sliver of a stream: it would stick out from under the banner.
                    if streamHeight >= LoomTheme.Chat.viewChipMinimumStreamHeight {
                        ChatViewChip(mode: presentation.viewMode, compact: ChatViewChip.isCompact(width: width)) {
                            presentation.cycleViewMode()
                        }
                        .padding(.top, 10).padding(.trailing, 14)
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { width = $0.width; streamHeight = $0.height }
            }
            ChatWindowVisibility { model.setWindowVisible($0) }.frame(width: 0, height: 0)
        }
        .onAppear {
            model.onOpenSubagent = onOpenSubagent
            model.setOnScreen(true)
        }
        .onDisappear { model.setOnScreen(false) }
    }
}
