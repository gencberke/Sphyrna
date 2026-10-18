import LoomCore
import SwiftUI

/// What the Agents tab lists for a session (V09), as a plain value: the running subagents first, then the
/// finished ones of the current turn, each oldest first. A subagent a subagent started (`depth` > 1) is
/// indented one step per level, up to `LoomTheme.Inspector.agentMaxIndent`.
struct InspectorAgentsContent: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String?
        let isRunning: Bool
        let depth: Int
        /// "now" or "4m" for a running subagent, "41s" for a finished one.
        let time: String
        let accessibilityLabel: String
    }

    let running: [Row]
    let finished: [Row]

    var isEmpty: Bool { running.isEmpty && finished.isEmpty }
    var count: Int { running.count + finished.count }

    init(records: [SubagentRecord], now: Date) {
        func row(_ record: SubagentRecord) -> Row {
            let type = record.agentType.isEmpty ? "Subagent" : record.agentType
            let time = record.endedAt.map { SubagentTreeContent.duration(from: record.startedAt, to: $0) }
                ?? RelativeTime.string(from: record.startedAt, to: now)
            let state = SubagentPillContent(record: record, now: now).label
            return Row(id: record.id, title: type, detail: record.description, isRunning: record.isRunning,
                       depth: record.depth, time: time,
                       accessibilityLabel: [type, record.description, state].compactMap { $0 }.joined(separator: ", "))
        }
        let ordered = records.sorted { $0.startedAt < $1.startedAt }
        running = ordered.filter(\.isRunning).map(row)
        finished = ordered.filter { !$0.isRunning }.map(row)
    }
}

/// The Agents tab: the session's subagents; a click on one reads its transcript below a back control.
/// The terminal stays on screen beside it.
struct InspectorAgents: View {
    let model: CatalogModel
    let row: SessionRowModel

    /// What the empty list says: Loom learns of subagents from the run, so a session with no run now cannot list
    /// the ones an earlier run had.
    nonisolated static func emptyText(isRunning: Bool) -> String {
        isRunning ? "No subagents. They appear here while the session runs them."
            : "Agents show while the session runs."
    }

    var body: some View {
        Group {
            if let viewed = model.viewedSubagent, viewed.sessionID == row.id, let panel = model.subagentPanel {
                detail(viewed: viewed, panel: panel)
            } else {
                list
            }
        }
        .accessibilityIdentifier("inspector-agents")
    }

    private var list: some View {
        let content = InspectorAgentsContent(records: row.live?.subagents ?? [], now: model.now)
        return ScrollView {
            VStack(alignment: .leading, spacing: LoomTheme.Inspector.sectionGap) {
                if content.isEmpty {
                    Text(Self.emptyText(isRunning: row.live?.runID != nil))
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                if !content.running.isEmpty {
                    InspectorSection(title: "Running", note: "\(content.running.count)") {
                        rows(content.running)
                    }
                }
                if !content.finished.isEmpty {
                    InspectorSection(title: "Finished", note: "\(content.finished.count)") {
                        rows(content.finished)
                    }
                }
            }
            .padding(LoomTheme.Inspector.bodyInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rows(_ rows: [InspectorAgentsContent.Row]) -> some View {
        VStack(spacing: LoomTheme.Inspector.rowGap) {
            ForEach(rows) { agent in
                InspectorAgentRow(agent: agent) { model.openSubagent(agent.id, in: row.id) }
                    .padding(.leading, CGFloat(min(agent.depth - 1, LoomTheme.Inspector.agentMaxIndent))
                             * LoomTheme.Inspector.agentIndent)
            }
        }
    }

    /// A subagent open: a back control and its state, its name, then the transcript.
    private func detail(viewed: ViewedSubagent, panel: SubagentTranscriptModel) -> some View {
        let record = row.live?.subagents.first { $0.id == viewed.agentID }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: LoomTheme.Inspector.detailHeaderGap) {
                HStack {
                    Button { model.closeSubagent() } label: {
                        HStack(spacing: LoomTheme.Inspector.backGap) {
                            Image(systemName: "chevron.left").font(LoomTheme.Inspector.backGlyph)
                                .accessibilityHidden(true)
                            Text("Agents").font(LoomTheme.Typography.small)
                        }
                        .padding(.horizontal, LoomTheme.Header.backLeading)
                        .frame(height: LoomTheme.Header.groupHeight)
                    }
                    .buttonStyle(HeaderSegmentStyle()).focusEffectDisabled()
                    .background(LoomTheme.Header.group)
                    .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
                    .help("Back to the list of agents")
                    .accessibilityLabel("Back to the list of agents")
                    Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                    if let record {
                        let pill = SubagentPillContent(record: record, now: model.now)
                        if let style = StatePillStyle(pill.indicator, label: pill.label) {
                            StatePill(indicator: pill.indicator, style: style)
                        }
                    }
                }
                Text(SubagentTitle.text(record)).font(LoomTheme.Typography.bodyStrong)
                    .foregroundStyle(LoomTheme.Text.primary).lineLimit(2).textSelection(.enabled)
                if row.indicator == .waitingForApproval { SubagentApprovalNotice() }
            }
            .padding(.horizontal, LoomTheme.Inspector.bodyInset).padding(.top, LoomTheme.Inspector.bodyInset)
            .padding(.bottom, LoomTheme.Inspector.detailHeaderGap)
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                .accessibilityHidden(true)
            // One view per panel model: a new model (the same subagent opened again) is put on screen too.
            SubagentTranscriptView(panel: panel).id(ObjectIdentifier(panel))
        }
    }
}

/// One subagent as a card in the list: a mark, the type over the description, and the time on the right.
struct InspectorAgentRow: View {
    let agent: InspectorAgentsContent.Row
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: LoomTheme.Inspector.agentColumnGap) {
                Image(systemName: "person.crop.circle").font(LoomTheme.Inspector.agentMarkGlyph)
                    .foregroundStyle(LoomTheme.Accent.high)
                    .frame(width: LoomTheme.Inspector.agentMark, height: LoomTheme.Inspector.agentMark)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Inspector.agentMarkRadius)
                        .fill(LoomTheme.Accent.base.opacity(LoomTheme.Inspector.agentMarkWash)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LoomTheme.Inspector.agentLineGap) {
                    Text(agent.title).font(LoomTheme.Typography.smallMedium).foregroundStyle(LoomTheme.Accent.high)
                        .lineLimit(1)
                    if let detail = agent.detail {
                        Text(detail).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: LoomTheme.Space.subagentTextGap) {
                    if agent.isRunning { IndicatorView(indicator: .working) }
                    Text(agent.time).font(LoomTheme.Typography.subagentTime)
                        .foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
            }
            .padding(.horizontal, LoomTheme.Inspector.agentPaddingH).padding(.vertical, LoomTheme.Inspector.agentPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.card).fill(LoomTheme.Surface.card))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.card)
                .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.card))
        }
        // The card keeps its own fill; the shared pill's hover and press tones lie over it.
        .buttonStyle(RowButtonStyle(radius: LoomTheme.Radius.card, key: "agent-row:\(agent.id)")).focusEffectDisabled()
        .accessibilityLabel(agent.accessibilityLabel)
        .accessibilityHint("Shows the transcript")
    }
}
