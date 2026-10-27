import LoomChat
import SwiftUI
import UniformTypeIdentifiers

/// The words of the queue strip (CHAT-SPEC → Queue).
enum ComposerQueueText {
    static func title(count: Int) -> String { "Queued \u{00B7} \(count)" }

    /// Why the queue waits, or nil when it does not.
    static func pause(_ reason: ChatQueue.PauseReason?) -> String? {
        switch reason {
        case nil: nil
        case .interrupted?: "Queue paused because you interrupted"
        case .failedTurn?: "Queue paused because the turn failed"
        case .processEnded?: "Queue paused because Claude ended"
        case .relaunch?: "Queue paused since Sphyrna started again"
        case .handover?: "Queue paused because the session moved to the terminal"
        }
    }

    /// The queue's issue line (`ChatQueueIssue`): not saved, unreadable, not sent.
    static func issue(_ issue: ChatQueueIssue?) -> String? {
        switch issue {
        case nil: nil
        case let .notSaved(category)?:
            "The queue could not be saved (\(category)). It stays here until Sphyrna can save it."
        case let .unreadable(keptAs)?:
            "The saved queue could not be read." + (keptAs.map { " It was kept as \($0)." } ?? "")
        case let .notSent(category)?:
            "The next message could not be sent (\(category)). It is back at the front of the queue."
        }
    }
}

/// The strip tucked behind the card's top edge: "Queued · 2", one row per message with Edit, Send Now and Remove on hover, and
/// what a pause or a problem needs. It is raised 1 with a hairline and radius 12 at its top, 14 in from the card's sides, and
/// its foot is behind the card. Rows reorder by dragging, or with ⌥↑ and ⌥↓ while a row has focus [T3].
struct ComposerQueueStrip: View {
    let model: ChatComposerModel
    @State private var collapsed = false
    @FocusState private var focusedRow: String?

    var body: some View {
        let queue = model.state.queue
        let pause = ComposerQueueText.pause(queue.paused)
        let issue = ComposerQueueText.issue(model.state.queueIssue)
        if !queue.isEmpty || issue != nil {
            VStack(alignment: .leading, spacing: LoomTheme.Composer.queueRowSpacing) {
                if !queue.isEmpty { header(queue, pause: pause) }
                if !collapsed || queue.isEmpty {
                    ForEach(queue.items) { item in row(item, paused: pause != nil) }
                }
                if let issue {
                    Text(issue).font(LoomTheme.Composer.noticeFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, LoomTheme.Space.cardH)
                        .accessibilityIdentifier("composer-queue-issue")
                }
            }
            .padding(.horizontal, LoomTheme.Composer.queuePaddingH)
            .padding(.top, LoomTheme.Composer.queuePaddingTop).padding(.bottom, LoomTheme.Composer.queuePaddingBottom)
            .background(Self.shape.fill(LoomTheme.Composer.queueFill))
            .overlay(Self.shape.strokeBorder(LoomTheme.Surface.hairline, lineWidth: LoomTheme.Line.hairline))
            .padding(.horizontal, LoomTheme.Composer.queueInsetH)
            // The foot goes behind the card, which draws after the strip.
            .padding(.bottom, -LoomTheme.Composer.queueOverlap)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer-queue")
        }
    }

    /// Radius 12 at the top corners; the bottom is under the card.
    static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: LoomTheme.Composer.queueRadius, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                               topTrailingRadius: LoomTheme.Composer.queueRadius)
    }

    private func header(_ queue: ChatQueue, pause: String?) -> some View {
        HStack(spacing: LoomTheme.Composer.chipPartGap + 2) {
            if let pause {
                // A paused queue says why where the head would be, with Resume and Clear.
                Image(systemName: "pause").font(LoomTheme.Composer.queueWaitIcon).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                Text(pause).font(LoomTheme.Composer.queueFont).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                    .accessibilityIdentifier("composer-queue-pause")
                Spacer(minLength: 0)
                Button("Resume") { model.resumeQueue() }.buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                    .accessibilityIdentifier("composer-queue-resume")
                Button("Clear") { model.clearQueue() }.buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                    .accessibilityIdentifier("composer-queue-clear")
            } else {
                Button { collapsed.toggle() } label: {
                    HStack(spacing: LoomTheme.Composer.chipPartGap + 2) {
                        Text(ComposerQueueText.title(count: queue.items.count)).font(LoomTheme.InkType.label.font).tracking(LoomTheme.InkType.label.trackingPoints)
                            .textCase(.uppercase).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(LoomTheme.Typography.chevron)
                            .rotationEffect(.degrees(collapsed ? -90 : 0)).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(collapsed ? "Show the queue" : "Hide the queue")
            }
        }
        .padding(.leading, LoomTheme.Composer.queueRowPaddingLeading).padding(.trailing, LoomTheme.Composer.queueRowPaddingTrailing)
        .frame(height: LoomTheme.Composer.queueHeadHeight)
    }

    private func row(_ item: ChatQueue.Item, paused: Bool) -> some View {
        QueueRow(model: model, item: item, paused: paused, focusedRow: $focusedRow)
        .draggable(Self.dragPrefix + item.id)
        .dropDestination(for: String.self) { ids, _ in
            // Only the strip's own drag: a string from anywhere else, or an id that is no item, moves nothing.
            guard let dragged = ids.first.flatMap(Self.draggedID(from:)), dragged != item.id,
                  model.state.queue.items.contains(where: { $0.id == dragged }),
                  let target = model.state.queue.items.firstIndex(where: { $0.id == item.id }) else { return false }
            model.moveQueued(dragged, to: target)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued message: \(Self.oneLine(item.text))")
        .accessibilityIdentifier("composer-queue-row")
    }

    /// What marks a drag as one of this strip's rows.
    static let dragPrefix = "loom-queued-message:"

    /// The queued message a drag carries, or nil for any other string (text dragged in from elsewhere moves nothing).
    static func draggedID(from payload: String) -> String? {
        guard payload.hasPrefix(dragPrefix), payload.count > dragPrefix.count else { return nil }
        return String(payload.dropFirst(dragPrefix.count))
    }

    /// The first line, for a row.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// One queued message: the "after" icon, its first line, and Edit, Send Now and Remove, which show under the pointer or the
/// keyboard focus. A row being edited takes the accent wash and an edge.
private struct QueueRow: View {
    let model: ChatComposerModel
    let item: ChatQueue.Item
    let paused: Bool
    @FocusState.Binding var focusedRow: String?
    @State private var hovering = false

    var body: some View {
        let isEditing = model.editing?.itemID == item.id
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Composer.queueRowRadius)
        let showsActions = (hovering || focusedRow == item.id || LookEvidence.forcesHover("queue:\(item.id)")) && !isEditing
        HStack(spacing: LoomTheme.Composer.chipGap) {
            Image(systemName: "clock").font(LoomTheme.Composer.queueWaitIcon).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            Text(ComposerQueueStrip.oneLine(item.text)).font(LoomTheme.Composer.queueFont).foregroundStyle(LoomTheme.Text.primary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: LoomTheme.Composer.queueRowSpacing) {
                Button("Edit") { model.beginEdit(item.id) }
                    .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small)).accessibilityIdentifier("composer-queue-edit")
                Button("Send Now") { model.sendQueuedNow(item.id) }
                    .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small)).accessibilityIdentifier("composer-queue-send-now")
                Button { model.removeQueued(item.id) } label: {
                    Image(systemName: "xmark").font(LoomTheme.Typography.small).frame(width: LoomTheme.Chat.iconSlot + 2, height: LoomTheme.Chat.iconSlot + 2)
                }
                .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small)).help("Remove").accessibilityLabel("Remove")
                .accessibilityIdentifier("composer-queue-remove")
            }
            .opacity(showsActions ? 1 : 0).allowsHitTesting(showsActions)
        }
        .padding(.leading, LoomTheme.Composer.queueRowPaddingLeading).padding(.trailing, LoomTheme.Composer.queueRowPaddingTrailing)
        .frame(minHeight: LoomTheme.Composer.queueRowHeight)
        .background(shape.fill(isEditing ? LoomTheme.Composer.queueEditFill : (hovering ? LoomTheme.Surface.hover : Color.clear)))
        .overlay(shape.strokeBorder(isEditing ? LoomTheme.Composer.queueEditEdge : Color.clear, lineWidth: LoomTheme.Line.hairline))
        .opacity(paused ? LoomTheme.Composer.queuePausedOpacity : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .focusable().focused($focusedRow, equals: item.id)
        .onKeyPress(keys: [.upArrow], phases: [.down, .repeat]) { press in
            guard press.modifiers == .option else { return .ignored }
            model.moveQueued(item.id, by: -1)
            return .handled
        }
        .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { press in
            guard press.modifiers == .option else { return .ignored }
            model.moveQueued(item.id, by: 1)
            return .handled
        }
    }
}
