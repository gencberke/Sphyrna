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
        case .relaunch?: "Queue paused since Loom started again"
        case .handover?: "Queue paused since the session moved to the terminal"
        }
    }

    /// The queue's issue line (`ChatQueueIssue`): not saved, unreadable, not sent.
    static func issue(_ issue: ChatQueueIssue?) -> String? {
        switch issue {
        case nil: nil
        case let .notSaved(category)?:
            "The queue could not be saved (\(category)). It stays here until Loom can save it."
        case let .unreadable(keptAs)?:
            "The saved queue could not be read." + (keptAs.map { " It was kept as \($0)." } ?? "")
        case let .notSent(category)?:
            "The next message could not be sent (\(category)). It is back at the front of the queue."
        }
    }
}

/// The strip above the text: "Queued · 2", one row per message with Edit, Send now and Remove, and what a pause or a
/// problem needs. Rows reorder by dragging, or with ⌥↑ and ⌥↓ while a row has focus [T3].
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
                    ForEach(queue.items) { item in row(item) }
                }
                if let issue {
                    Text(issue).font(LoomTheme.Composer.noticeFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, LoomTheme.Space.cardH)
                        .accessibilityIdentifier("composer-queue-issue")
                }
            }
            .padding(LoomTheme.Space.headerSpacing * 2)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Composer.queueRadius).fill(LoomTheme.Composer.queueFill))
            .padding(.horizontal, LoomTheme.Composer.queueMargin).padding(.top, LoomTheme.Composer.queueMargin)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer-queue")
        }
    }

    private func header(_ queue: ChatQueue, pause: String?) -> some View {
        HStack(spacing: LoomTheme.Space.bannerRowSpacing) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: LoomTheme.Space.hintSpacing) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(LoomTheme.Typography.chevron)
                    Image(systemName: "clock").font(LoomTheme.Typography.small)
                    Text(ComposerQueueText.title(count: queue.items.count)).font(LoomTheme.Typography.smallMedium)
                }
                .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            .buttonStyle(.plain).accessibilityLabel(collapsed ? "Show the queue" : "Hide the queue")
            if let pause {
                Text(pause).font(LoomTheme.Composer.noticeFont).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                    .accessibilityIdentifier("composer-queue-pause")
                Button("Resume") { model.resumeQueue() }.buttonStyle(AccentButtonStyle(kind: .tinted))
                    .accessibilityIdentifier("composer-queue-resume")
                Button("Clear") { model.clearQueue() }.buttonStyle(ChipButtonStyle())
                    .accessibilityIdentifier("composer-queue-clear")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Space.headerSpacing)
    }

    private func row(_ item: ChatQueue.Item) -> some View {
        let isEditing = model.editing?.itemID == item.id
        return HStack(spacing: LoomTheme.Space.bannerRowSpacing) {
            Text(Self.oneLine(item.text)).font(LoomTheme.Composer.queueFont).foregroundStyle(LoomTheme.Text.primary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            rowButton("pencil", "Edit", id: "edit") { model.beginEdit(item.id) }
            rowButton("arrow.up.right", "Send now", id: "send-now") { model.sendQueuedNow(item.id) }
            rowButton("xmark", "Remove", id: "remove") { model.removeQueued(item.id) }
        }
        .padding(.horizontal, LoomTheme.Space.cardH).frame(minHeight: LoomTheme.Composer.queueRowHeight)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.md)
            .fill(isEditing ? LoomTheme.Composer.queueEditFill : Color.clear))
        .contentShape(Rectangle())
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

    private func rowButton(_ symbol: String, _ label: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(width: LoomTheme.Composer.queueIcon, height: LoomTheme.Composer.queueIcon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .accessibilityIdentifier("composer-queue-\(id)")
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
