import LoomCore
import SwiftUI

// The pieces around the subagent transcript (FB4-5, V09, V23): the title and state text of a subagent, and the
// notice for a request that waits (in the chat or in the session's terminal). The transcript itself is in the
// inspector's Agents tab (`InspectorAgents.swift`).

/// How a subagent is named: its type and description.
enum SubagentTitle {
    /// "agent type · description", or the type alone, or "Subagent" while the record has neither yet.
    static func text(_ record: SubagentRecord?) -> String {
        guard let record else { return "Subagent" }
        let type = record.agentType.isEmpty ? "Subagent" : record.agentType
        return record.description.map { "\(type) · \($0)" } ?? type
    }
}

/// How the subagent's state pill reads: the chase and "Running 4m", or "Finished 7m" without a mark.
/// Claude reports neither success nor failure for a subagent, so there is no failed state to show; a stopped
/// session's subagent whose Agent call has no result reads "Interrupted".
struct SubagentPillContent: Equatable {
    static let interruptedLabel = "Interrupted"

    let indicator: SessionIndicator
    let label: String

    init(record: SubagentRecord, now: Date) {
        if record.wasInterrupted {
            indicator = .idle
            label = Self.interruptedLabel
        } else if let ended = record.endedAt {
            indicator = .idle
            label = "Finished \(SubagentTreeContent.duration(from: record.startedAt, to: ended))"
        } else {
            indicator = .working
            let elapsed = RelativeTime.string(from: record.startedAt, to: now)
            label = elapsed == "now" ? "Running" : "Running \(elapsed)"
        }
    }
}

/// The open subagent's request waits for the user (V23). On the Chat face it says where the card is and offers "Show the
/// request", which brings the pinned card into view in the main chat; on the terminal face it points at the session's
/// terminal, which stays on screen beside the inspector. Opacity only, like the other notices; the text is the attention
/// text tone (AA on the inspector surface).
struct SubagentWaitingNotice: View {
    let notice: SubagentWaiting.Notice
    let show: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.detailSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.detailSpacing) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(LoomTheme.Status.attention).accessibilityHidden(true)
                Text(notice.text).foregroundStyle(LoomTheme.Status.attentionLight).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            }
            if notice == .chat {
                Button("Show the request", action: show)
                    .buttonStyle(.plain).foregroundStyle(LoomTheme.Accent.high)
                    .accessibilityIdentifier("subagent-show-request")
            }
        }
        .font(LoomTheme.Typography.small)
        .fadesIn()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent-approval-notice")
    }
}
