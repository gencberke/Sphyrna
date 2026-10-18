import LoomCore
import SwiftUI

// The pieces around the subagent transcript (FB4-5, V09): the title and state text of a subagent, and the
// notice for an approval that waits in the session's terminal. The transcript itself is in the inspector's
// Agents tab (`InspectorAgents.swift`).

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
/// Claude reports neither success nor failure for a subagent, so there is no failed state to show.
struct SubagentPillContent: Equatable {
    let indicator: SessionIndicator
    let label: String

    init(record: SubagentRecord, now: Date) {
        if let ended = record.endedAt {
            indicator = .idle
            label = "Finished \(SubagentTreeContent.duration(from: record.startedAt, to: ended))"
        } else {
            indicator = .working
            let elapsed = RelativeTime.string(from: record.startedAt, to: now)
            label = elapsed == "now" ? "Running" : "Running \(elapsed)"
        }
    }
}

/// A subagent's own permission prompt is answered in the session's terminal, which stays on screen beside the
/// inspector: this says where to look. Opacity only, like the other notices.
struct SubagentApprovalNotice: View {
    var body: some View {
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
            Text("Waiting for approval: answer it in the session's terminal")
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
        }
        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.attention)
        .fadesIn()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent-approval-notice")
    }
}
