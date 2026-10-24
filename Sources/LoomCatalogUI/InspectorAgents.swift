import LoomCore
import SwiftUI

/// What the Agents tab lists for a session (V09), as a plain value: the running subagents first, then the
/// finished ones of the current turn (a stopped session's, from its folder), each oldest first. A subagent a subagent
/// started (`depth` > 1) is indented one step per level, up to `LoomTheme.Inspector.agentMaxIndent`. A subagent whose
/// request waits for the user says so (V23).
struct InspectorAgentsContent: Equatable {
    struct Row: Equatable, Identifiable {
        /// The tree's status column: the working spinner, the attention dot, or nothing once finished (DESIGN §4).
        enum Status: Equatable {
            case working
            case waiting
            case none
        }

        /// The small line under the description: "Waiting for you" in the attention text, or "Interrupted" in secondary.
        struct Note: Equatable {
            let text: String
            let isAttention: Bool
        }

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

        var status: Status { isWaiting ? .waiting : isRunning ? .working : .none }

        var underLine: Note? {
            if isWaiting { return Note(text: InspectorAgentsContent.waitingText, isAttention: true) }
            return note.map { Note(text: $0, isAttention: false) }
        }
    }

    let running: [Row]
    let finished: [Row]

    var isEmpty: Bool { running.isEmpty && finished.isEmpty }
    var count: Int { running.count + finished.count }

    static let waitingText = "Waiting for you"
    static let runningTitle = "Running"
    static let finishedTitle = "Finished"

    init(records: [SubagentRecord], now: Date, waiting: Set<String> = []) {
        func row(_ record: SubagentRecord) -> Row {
            let type = record.agentType.isEmpty ? "Subagent" : record.agentType
            let time = record.endedAt.map { SubagentPillContent.duration(from: record.startedAt, to: $0) }
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

/// The keys of an open transcript: Esc goes back to the list, as "‹ Agents" does. Other keys are not the tab's.
enum AgentsTranscriptKeys {
    enum Reaction: Equatable {
        case back
        case ignore
    }

    static func reaction(to key: KeyEquivalent) -> Reaction { key == .escape ? .back : .ignore }
}

extension InspectorAgents {
    /// The inspector's default width for a tab: an open transcript takes the review width, 556, as Changes does; the list keeps the
    /// tab's own (328). The width follows the click that opens or closes the transcript, and never animates (a width change is a PTY
    /// resize).
    nonisolated static func width(tab: InspectorTab, showsTranscript: Bool) -> CGFloat {
        InspectorWidthClass(tab: tab, showsTranscript: showsTranscript).defaultWidth
    }
}

extension CatalogModel {
    /// The open inspector's width class: the shown tab's, or review while the Agents tab shows the selected session's subagent
    /// transcript.
    var inspectorWidthClass: InspectorWidthClass {
        let showsTranscript = viewedSubagent != nil && viewedSubagent?.sessionID == selectedSessionID && subagentPanel != nil
        return InspectorWidthClass(tab: shownInspectorTab, showsTranscript: showsTranscript)
    }

    /// The open inspector's width: its class's remembered one (the default until the user drags the edge). The pane may draw it
    /// narrower (`InspectorLayout`).
    var shownInspectorWidth: CGFloat { inspector.widths[inspectorWidthClass] }
}

/// The Agents tab: the session's subagents; a click on one reads its transcript in the list's place, under "‹ Agents".
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
            VStack(alignment: .leading, spacing: LoomTheme.Agents.sectionGap) {
                if content.isEmpty, records != nil {
                    InspectorEmptyState(text: Self.emptyText(isRunning: model.isRunning(row), readsFolder: readsFolder), art: .emptyAgents)
                }
                if !content.running.isEmpty {
                    InspectorSection(title: InspectorAgentsContent.runningTitle, note: "\(content.running.count)",
                                     noteFollowsTitle: true, titleGap: LoomTheme.Agents.headGap) {
                        rows(content.running)
                    }
                }
                if !content.finished.isEmpty {
                    InspectorSection(title: InspectorAgentsContent.finishedTitle, note: "\(content.finished.count)",
                                     noteFollowsTitle: true, titleGap: LoomTheme.Agents.headGap) {
                        rows(content.finished)
                    }
                }
            }
            .padding(LoomTheme.Inspector.bodyInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rows(_ rows: [InspectorAgentsContent.Row]) -> some View {
        VStack(spacing: LoomTheme.Agents.cardGap) {
            ForEach(rows) { agent in
                InspectorAgentRow(agent: agent) { model.openSubagent(agent.id, in: row.id) }
                    .padding(.leading, CGFloat(min(agent.depth - 1, LoomTheme.Inspector.agentMaxIndent))
                             * LoomTheme.Inspector.agentIndent)
            }
        }
    }

    /// A subagent open: "‹ Agents" and its state pill, its name and the notice of a request that waits, then the transcript.
    private func detail(viewed: ViewedSubagent, panel: SubagentTranscriptModel) -> some View {
        let record = model.viewedSubagentRecord()
        let notice = SubagentWaiting.notice(
            agentID: viewed.agentID, record: record, state: row.live, indicator: row.indicator, endpoint: model.runEndpoint(of: row))
        let isWaiting = record?.isRunning == true && SubagentWaiting.ids(in: row.live).contains(viewed.agentID)
        let finished = record.map { $0.endedAt != nil && !$0.wasInterrupted } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: LoomTheme.Space.detailSpacing) {
                    Button { model.closeSubagent() } label: {
                        HStack(spacing: LoomTheme.Agents.backGap) {
                            Image(systemName: "chevron.left").font(LoomTheme.Agents.backGlyph)
                                .accessibilityHidden(true)
                            Text("Agents").projectType(LoomTheme.Agents.back).foregroundStyle(LoomTheme.Text.primary)
                        }
                        .padding(.leading, LoomTheme.Agents.backLeading).padding(.trailing, LoomTheme.Agents.backTrailing)
                        .frame(height: LoomTheme.Agents.backHeight)
                        .background(RoundedRectangle(cornerRadius: LoomTheme.Agents.backRadius).fill(LoomTheme.Highlight.hover))
                        .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Agents.backRadius))
                    }
                    .buttonStyle(RowButtonStyle(radius: LoomTheme.Agents.backRadius, key: "agents-back")).focusEffectDisabled()
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
                Text(SubagentTitle.text(record)).projectType(LoomTheme.Agents.name)
                    .foregroundStyle(LoomTheme.Text.primary).lineLimit(LoomTheme.Agents.nameLines).textSelection(.enabled)
                    .padding(.top, LoomTheme.Agents.nameTop)
                if let notice {
                    SubagentWaitingNotice(notice: notice) { model.showAgentRequest(agentID: viewed.agentID, in: row.id) }
                        .padding(.top, LoomTheme.Agents.noticeTop)
                }
            }
            .padding(.horizontal, LoomTheme.Agents.headerInset)
            .padding(.top, LoomTheme.Agents.headerTop).padding(.bottom, LoomTheme.Agents.headerBottom)
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                .accessibilityHidden(true)
            // One view per panel model: a new model (the same subagent opened again) is put on screen too.
            SubagentTranscriptView(panel: panel, isWaiting: isWaiting, isFinished: finished).id(ObjectIdentifier(panel))
        }
        // Esc goes back, as "‹ Agents" does, while the focus is in the tab; it never reaches past it into the terminal.
        .focusable().focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard AgentsTranscriptKeys.reaction(to: press.key) == .back else { return .ignored }
            model.closeSubagent()
            return .handled
        }
    }
}

/// One subagent as a card in the list (DESIGN §4): the tree's status column, the type and the time on the first line, the
/// description under them, and "Waiting for you" or "Interrupted" under that. No badge and no accent.
struct InspectorAgentRow: View {
    typealias Metrics = LoomTheme.Agents
    let agent: InspectorAgentsContent.Row
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Metrics.columnGap) {
                status.frame(width: Metrics.statusColumn, height: Metrics.statusHeight)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.lineGap) {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.columnGap) {
                        Text(agent.title).projectType(Metrics.type).foregroundStyle(LoomTheme.Text.primary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(agent.time).projectType(Metrics.time).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                            .lineLimit(1).fixedSize()
                    }
                    .frame(minHeight: Metrics.statusHeight)
                    if let detail = agent.detail {
                        Text(detail).projectType(Metrics.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineLimit(Metrics.detailLines).multilineTextAlignment(.leading)
                    }
                    if let note = agent.underLine {
                        // The attention text tone, AA on every surface of the inspector (`ThemeAppearanceTests`).
                        Text(note.text).projectType(Metrics.note)
                            .foregroundStyle(note.isAttention ? AnyShapeStyle(LoomTheme.Status.attentionLight)
                                                              : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                            .accessibilityIdentifier(note.isAttention ? "agent-waiting:\(agent.id)" : "agent-note:\(agent.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Metrics.cardPaddingH)
            .padding(.top, Metrics.cardPaddingTop).padding(.bottom, Metrics.cardPaddingBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Metrics.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        }
        // The card keeps its own fill; the shared pill's hover and press tones lie over it.
        .buttonStyle(RowButtonStyle(radius: Metrics.cardRadius, key: "agent-row:\(agent.id)")).focusEffectDisabled()
        .accessibilityLabel(agent.accessibilityLabel)
        .accessibilityHint("Shows the transcript")
    }

    @ViewBuilder private var status: some View {
        switch agent.status {
        case .working: IndicatorView(indicator: .working)
        case .waiting: IndicatorView(indicator: .waitingForApproval)
        case .none: Color.clear
        }
    }
}
