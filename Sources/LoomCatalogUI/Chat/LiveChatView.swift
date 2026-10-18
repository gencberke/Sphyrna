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

    init(feed: LiveChatFeed) {
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
        controller.onNeedOlder = { [weak feed, weak controller] in feed?.loadOlder(controller) }
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
/// with the stream's folds, views (⌃O), "Show all", live row, jump pill and notices.
struct LiveChatView: View {
    let feed: LiveChatFeed
    let onOpenSubagent: ((String?, String) -> Void)?
    @State private var model: LiveChatViewModel?

    var body: some View {
        ZStack {
            if let model {
                LiveChatContent(model: model, feed: feed, onOpenSubagent: onOpenSubagent)
            } else {
                LoomTheme.Surface.canvas
            }
        }
        .task(id: ObjectIdentifier(feed)) {
            if model?.feed !== feed {
                model?.close()
                model = LiveChatViewModel(feed: feed)
            }
        }
    }
}

struct LiveChatContent: View {
    let model: LiveChatViewModel
    let feed: LiveChatFeed
    let onOpenSubagent: ((String?, String) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    var body: some View {
        let presentation = feed.presentation
        ZStack {
            LoomTheme.Surface.canvas
            if feed.phase == .ready {
                ZStack(alignment: .bottom) {
                    ChatStreamHost(controller: model.controller)
                    VStack(spacing: 8) {
                        if model.showsJump {
                            ChatJumpPill { model.jumpToLatest() }
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                        if feed.policySignal != nil, !feed.policyDismissed {
                            ChatNotice(message: "Claude says this account's plan may not allow the Chat face. The terminal still runs this session.",
                                       dismiss: { feed.policyDismissed = true })
                        }
                        if feed.wireDrift > 0, !feed.wireDriftDismissed {
                            ChatNotice(message: "Claude sent something this version of Loom does not expect. The session goes on; some of it may not show.",
                                       dismiss: { feed.wireDriftDismissed = true })
                        }
                        if presentation.unknownRecordCount > 0, !presentation.driftDismissed {
                            ChatDriftNotice(count: presentation.unknownRecordCount) { presentation.dismissDrift() }
                        }
                    }
                    .padding(.bottom, 12)
                    .animation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Chat.fadeDuration), value: model.showsJump)
                }
                .overlay(alignment: .topTrailing) {
                    ChatViewChip(mode: presentation.viewMode, compact: ChatViewChip.isCompact(width: width)) {
                        presentation.cycleViewMode()
                    }
                    .padding(.top, 10).padding(.trailing, 14)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
