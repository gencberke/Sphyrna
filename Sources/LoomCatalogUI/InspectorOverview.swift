import Foundation
import LoomCore
import SwiftUI

/// What the Overview tab says about a session, as a plain value so the words can be tested without a view.
/// It holds the session's status, why it has that status (the reason the hooks gave), where it works, and
/// what it has under it. The context is drawn separately from `UsageModel.contexts`.
struct InspectorOverviewContent: Equatable {
    let status: String
    let reason: String?
    let project: String?
    let branch: String?
    let folder: String
    let lastActivity: Date
    /// "2 running · 1 finished"; nil without subagents.
    let agents: String?

    @MainActor init(row: SessionRowModel, project: String?, branch: String?) {
        let record = row.record
        status = row.indicator.label ?? (record.lifecycle == .active ? "Not running" : "—")
        reason = row.live?.displayReason.flatMap(InspectorReasonText.line)
        self.project = project
        self.branch = branch
        folder = (record.session.workingDirectory as NSString).abbreviatingWithTildeInPath
        lastActivity = record.lastActivityAt
        agents = Self.agents(row.live?.subagents ?? [])
    }

    static func agents(_ records: [SubagentRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let running = records.filter(\.isRunning).count
        let finished = records.count - running
        return [running > 0 ? "\(running) running" : nil, finished > 0 ? "\(finished) finished" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The reason line in words (the concept's "Allow: git push origin fix/webhook-sig"). Built from content, so
/// it is shown here and never logged.
enum InspectorReasonText {
    static func line(_ reason: StatusReason) -> String? {
        switch reason.kind {
        case let .approval(tool):
            return SessionReasonLine.approvalText(tool: tool, detail: reason.detail)
        case .question:
            return reason.detail.map { "Question: \($0)" } ?? "Has a question"
        case .planReady:
            return "Plan ready for review"
        case .input:
            return "Waiting for your input"
        case .turnDone:
            let work = reason.work.isEmpty ? nil : "\(reason.work.total) running in the background"
            return [reason.detail, work].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case let .failure(category):
            return reason.detail ?? category ?? "The turn failed"
        case .automaticTurn:
            return reason.detail ?? "Working on a background task's report"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The Overview tab: facts about the session, its context, and what runs under it.
struct InspectorOverview: View {
    let model: CatalogModel
    let row: SessionRowModel

    var body: some View {
        let chip = model.headerChip(of: row.record)
        let content = InspectorOverviewContent(
            row: row, project: model.projectName(for: row.record), branch: chip?.branch)
        ScrollView {
            VStack(alignment: .leading, spacing: LoomTheme.Inspector.sectionGap) {
                InspectorSection(title: "Session") {
                    VStack(alignment: .leading, spacing: LoomTheme.Inspector.factRowGap) {
                        InspectorFact("Status", content.status)
                        if let reason = content.reason { InspectorFact("Why", reason) }
                        InspectorFact("Project", content.project ?? "No project")
                        if let branch = content.branch { InspectorFact("Branch", branch, mono: true) }
                        InspectorFact("Folder", content.folder, mono: true)
                        InspectorFact("Last activity",
                                      LoomDateFormat.dateTime(content.lastActivity))
                    }
                }
                InspectorSection(title: "Context") { context }
                if let agents = content.agents {
                    InspectorSection(title: "Agents") {
                        HStack {
                            Text(agents).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary)
                            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                            Button("Show Agents") { model.selectInspectorTab(.agents) }
                                .buttonStyle(.link).font(LoomTheme.Typography.small)
                        }
                    }
                }
            }
            .padding(LoomTheme.Inspector.bodyInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("inspector-overview")
    }

    @ViewBuilder private var context: some View {
        if row.record.session.provider != .claude {
            note("The context is read for Claude sessions.")
        } else if let id = row.record.session.providerConversationID, let usage = model.usage?.contexts[id] {
            VStack(alignment: .leading, spacing: LoomTheme.Inspector.factRowGap) {
                ContextRing(usage: usage, showsLabel: true)
                Text(ContextRingText.caption(usage)).font(LoomTheme.Typography.caption)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle).textSelection(.enabled)
            }
        } else {
            note("No reading yet. It appears after the session's first reply.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
    }
}
