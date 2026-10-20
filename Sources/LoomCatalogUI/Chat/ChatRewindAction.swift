import Foundation
import LoomChat
import SwiftUI

/// What the stream's rows ask of the session about "Rewind files" (V21): whether the action is there and on. It reads the
/// composer's state through a closure, so a row's hover footer follows the driver (a turn begins, the process stops) without
/// the row being rebuilt.
@MainActor
final class ChatRewindAccess {
    /// The session's availability; nil where no live chat stands behind the stream (a transcript has no rewind).
    var source: () -> RewindAvailability? = { nil }

    var availability: RewindAvailability? { source() }
}

/// How the action reads on one user message.
enum RewindActionState: Equatable {
    /// Not offered on this row.
    case hidden
    case enabled
    /// Offered and off, with the reason.
    case disabled(String)
}

enum ChatRewindAction {
    static let title = "Rewind files to before this message"

    /// A row offers the action when it is a user prompt Claude read that carries a message uuid: typed, or sent by Loom.
    /// Task notifications, meta records and Loom's own marker rows are not user entries; a subagent's brief is not a prompt of
    /// the session; a prompt that is not delivered, or was withdrawn, has no checkpoint to go back to.
    static func offers(_ entry: ChatEntry) -> Bool {
        guard case let .user(prompt) = entry.body, !prompt.isBrief, prompt.delivery == .read else { return false }
        return UUID(uuidString: entry.id) != nil
    }

    static func state(for entry: ChatEntry, availability: RewindAvailability?) -> RewindActionState {
        guard let availability, offers(entry) else { return .hidden }
        return availability == .available ? .enabled : .disabled(availability.reason ?? "")
    }
}

/// The action in the hover footer, beside Copy.
struct ChatRewindButton: View {
    let state: RewindActionState
    let action: () -> Void

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .enabled:
            button(reason: nil)
        case let .disabled(reason):
            button(reason: reason)
        }
    }

    private func button(reason: String?) -> some View {
        Button(action: action) {
            HStack(spacing: LoomTheme.Rewind.actionGap) {
                Image(systemName: "arrow.uturn.backward").font(LoomTheme.Rewind.actionGlyph)
                Text(ChatRewindAction.title)
            }
        }
        .buttonStyle(.plain)
        .font(LoomTheme.Chat.meta)
        .foregroundStyle(LoomTheme.Text.secondaryStyle)
        .frame(minHeight: 18)
        .disabled(reason != nil)
        .opacity(reason == nil ? 1 : LoomTheme.Opacity.disabled)
        .help(reason ?? ChatRewindAction.title)
        .accessibilityLabel(ChatRewindAction.title)
        .accessibilityHint(reason ?? "")
        .accessibilityIdentifier("chat-row-rewind-files")
    }
}

/// The marker after a rewind: "Files rewound to before …", with Undo while it is offered.
struct ChatRewoundMarkerView: View {
    let marker: RewindMarker
    let date: Date?
    let context: ChatRowContext

    var body: some View {
        HStack(spacing: LoomTheme.Rewind.markerGap) {
            line
            Text(Self.text(marker, date: date)).font(LoomTheme.Chat.markerText)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1).layoutPriority(1)
            if marker.undo == .available {
                ChatLinkButton(title: "Undo") { context.undoRewind(marker.rewindID) }.layoutPriority(2)
            }
            line
        }
        .frame(height: LoomTheme.Chat.markerHeight)
    }

    private var line: some View { Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline) }

    /// "Files rewound to before “fix the login…” · 14:02", or "Rewind undone" once Undo ran.
    static func text(_ marker: RewindMarker, date: Date?) -> String {
        if marker.undo == .undone { return "Rewind undone" }
        let base = marker.title.isEmpty ? "Files rewound" : "Files rewound to before \u{201C}\(marker.title)\u{201D}"
        guard let date else { return base }
        return base + " \u{00B7} " + ChatTime.label(for: date)
    }
}
