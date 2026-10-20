import LoomCore
import SwiftUI

/// What the Agents tab lists for a session (V09), as a plain value: the running subagents first, then the
/// finished ones of the current turn (a stopped session's, from its folder), each oldest first. A subagent a subagent
/// started (`depth` > 1) is indented one step per level, up to `LoomTheme.Inspector.agentMaxIndent`. A subagent whose
/// request waits for the user says so (V23).
struct InspectorAgentsContent: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String?
        let isRunning: Bool
        /// Its request waits for the user: "Waiting for you" on the row, in the attention tone.
        let isWaiting: Bool
        /// "Interrupted": a stopped session's subagent whose run ended with it still going.
        let note: String?
        let depth: Int
        /// "now" or "4m" for a running subagent, "41s" for a finished one.
        let time: String
        let accessibilityLabel: String
    }

    let running: [Row]
    let finished: [Row]

    var isEmpty: Bool { running.isEmpty && finished.isEmpty }
    var count: Int { running.count + finished.count }

    static let waitingText = "Waiting for you"

    init(records: [SubagentRecord], now: Date, waiting: Set<String> = []) {
        func row(_ record: SubagentRecord) -> Row {
            let type = record.agentType.isEmpty ? "Subagent" : record.agentType
            let time = record.endedAt.map { SubagentTreeContent.duration(from: record.startedAt, to: $0) }
                ?? RelativeTime.string(from: record.startedAt, to: now)
            let state = SubagentPillContent(record: record, now: now).label
            let isWaiting = record.isRunning && waiting.contains(record.id)
            let note = record.wasInterrupted ? SubagentPillContent.interruptedLabel : nil
            return Row(id: record.id, title: type, detail: record.description, isRunning: record.isRunning,
                       isWaiting: isWaiting, note: note, depth: record.depth, time: time,
                       accessibilityLabel: [type, record.description, state, isWaiting ? Self.waitingText.lowercased() : nil]
                           .compactMap { $0 }.joined(separator: ", "))
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

    /// What the empty list says: a live run lists the subagents it runs; a stopped Claude session lists those in its
    /// folder (V23), so an empty list there means it ran none; anything else cannot list a past run's.
    nonisolated static func emptyText(isRunning: Bool, readsFolder: Bool = false) -> String {
        if isRunning { return "No subagents. They appear here while the session runs them." }
        return readsFolder ? "No subagents in this session." : "Agents show while the session runs."
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
        // A stopped Claude session lists its folder, once read (nil before that: no empty text for a list not read yet).
        let records = model.agentRecords(for: row)
        let content = InspectorAgentsContent(records: records ?? [], now: model.now, waiting: SubagentWaiting.ids(in: row.live))
        let readsFolder = model.agentsFolderIsReadable(row)
        return ScrollView {
            VStack(alignment: .leading, spacing: LoomTheme.Inspector.sectionGap) {
                if content.isEmpty, records != nil {
                    Text(Self.emptyText(isRunning: model.isRunning(row), readsFolder: readsFolder))
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
        let record = model.viewedSubagentRecord()
        let notice = SubagentWaiting.notice(
            agentID: viewed.agentID, record: record, state: row.live, indicator: row.indicator, endpoint: model.runEndpoint(of: row))
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
                if let notice {
                    SubagentWaitingNotice(notice: notice) { model.showAgentRequest(agentID: viewed.agentID, in: row.id) }
                }
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
                    if agent.isWaiting {
                        // The attention text tone, AA on every surface of the inspector (`ThemeAppearanceTests`).
                        Text(InspectorAgentsContent.waitingText).font(LoomTheme.Typography.caption)
                            .foregroundStyle(LoomTheme.Status.attentionLight)
                            .accessibilityIdentifier("agent-waiting:\(agent.id)")
                    } else if let note = agent.note {
                        Text(note).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: LoomTheme.Space.subagentTextGap) {
                    if agent.isWaiting {
                        IndicatorView(indicator: .waitingForApproval)
                    } else if agent.isRunning {
                        IndicatorView(indicator: .working)
                    }
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
