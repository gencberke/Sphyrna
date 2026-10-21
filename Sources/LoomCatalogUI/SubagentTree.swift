import Foundation
import LoomCore
import SwiftUI

/// What the subagent tree under a session card shows (D-39, design "V3 · Tree with a guide line"),
/// as a plain value so the rules can be tested without a view:
/// - one row per running subagent, at most `maximumRunningRows`; more shows a "+N more" row that
///   expands (and then collapses again);
/// - finished subagents of the current turn fold into one "N finished" row that expands to their rows;
///   with only finished ones, only that row shows;
/// - a subagent a subagent started (`depth` > 1) is indented one step per level on the same guide.
/// - a running subagent whose request waits for the user (V23) takes the attention mark in place of the spinner, and is
///   always among the shown rows, even past the cap: the order of the rows does not change.
/// Elapsed and duration text is derived from `now`, the sidebar's minute tick: no timer of its own.
struct SubagentTreeContent: Equatable {
    static let maximumRunningRows = 3

    struct Row: Equatable, Identifiable {
        enum Kind: Equatable {
            case running
            case finished
            /// The "N finished" row; `expanded` while the finished rows below it are shown.
            case finishedFold(expanded: Bool)
            /// The "+N more" row for running subagents beyond the cap; "Show fewer" while expanded.
            case more(expanded: Bool)
        }

        let id: String
        let kind: Kind
        /// Its request waits for the user: the attention mark and "waiting for you" in the row's label.
        var isWaiting = false
        /// 1 for a direct subagent of the session; the row is indented `depth - 1` steps.
        let depth: Int
        /// The agent type, or the text of a fold row.
        let title: String
        let detail: String?
        /// Elapsed time of a running subagent, duration of a finished one; empty on fold rows.
        let trailing: String
        let accessibilityLabel: String
        let accessibilityValue: String?

        /// What a click on the row does. A subagent has no terminal of its own, so its row opens its
        /// transcript in its session's detail pane (FB4-5), selecting the session first; a fold row only
        /// opens or closes.
        enum Tap: Equatable { case openSubagent, toggleFinished, toggleRunning }

        var tap: Tap {
            switch kind {
            case .running, .finished: .openSubagent
            case .finishedFold: .toggleFinished
            case .more: .toggleRunning
            }
        }

        var opensSubagent: Bool { tap == .openSubagent }
    }

    let rows: [Row]
    let finishedCount: Int

    var isEmpty: Bool { rows.isEmpty }

    init(records: [SubagentRecord], now: Date, finishedExpanded: Bool, runningExpanded: Bool, waiting: Set<String> = []) {
        let running = records.filter { $0.isRunning }
        let finished = records.filter { !$0.isRunning }
        finishedCount = finished.count
        var rows: [Row] = []
        var shown = running
        if !runningExpanded, running.count > Self.maximumRunningRows {
            // The first rows, except that the ones that wait for the user take their places before the others.
            var keep = Set(running.filter { waiting.contains($0.id) }.prefix(Self.maximumRunningRows).map(\.id))
            for record in running where keep.count < Self.maximumRunningRows { keep.insert(record.id) }
            shown = running.filter { keep.contains($0.id) }
        }
        rows += shown.map { Self.row($0, now: now, isWaiting: waiting.contains($0.id)) }
        let hidden = running.count - Self.maximumRunningRows
        if hidden > 0 {
            rows.append(Row(
                id: "more", kind: .more(expanded: runningExpanded), depth: 1,
                title: runningExpanded ? "Show fewer" : "+\(hidden) more", detail: nil, trailing: "",
                accessibilityLabel: runningExpanded ? "Show fewer running subagents" : "\(hidden) more running subagents",
                accessibilityValue: runningExpanded ? "expanded" : "collapsed"))
        }
        if !finished.isEmpty {
            let noun = finished.count == 1 ? "subagent" : "subagents"
            rows.append(Row(
                id: "finished", kind: .finishedFold(expanded: finishedExpanded), depth: 1,
                title: "\(finished.count) finished", detail: nil, trailing: "",
                accessibilityLabel: "\(finished.count) \(noun) finished",
                accessibilityValue: finishedExpanded ? "expanded" : "collapsed"))
            if finishedExpanded { rows += finished.map { Self.row($0, now: now, isWaiting: false) } }
        }
        self.rows = rows
    }

    private static func row(_ record: SubagentRecord, now: Date, isWaiting: Bool) -> Row {
        let state = isWaiting ? "running, waiting for you" : record.isRunning ? "running" : "finished"
        let end = record.endedAt
        return Row(
            id: record.id, kind: record.isRunning ? .running : .finished, isWaiting: isWaiting, depth: max(1, record.depth),
            title: record.agentType, detail: record.description,
            trailing: end.map { duration(from: record.startedAt, to: $0) } ?? RelativeTime.string(from: record.startedAt, to: now),
            accessibilityLabel: "Subagent \(record.agentType)"
                + (record.description.map { ", \($0)" } ?? "") + ", \(state)",
            accessibilityValue: nil)
    }

    /// A finished subagent's run time: static, so seconds are fine ("18s", "2m", "1h").
    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }
}

/// The tree under a session card: a hairline guide below the card's indicator column and the rows beside it.
struct SubagentTreeView: View {
    let sessionID: UUID
    let records: [SubagentRecord]
    let model: CatalogModel
    /// The subagents whose request waits for the user (`SubagentWaiting.ids`).
    var waiting: Set<String> = []
    @State private var finishedExpanded = false
    @State private var runningExpanded = false
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate

    var body: some View {
        let content = SubagentTreeContent(
            records: records, now: model.now, finishedExpanded: finishedExpanded, runningExpanded: runningExpanded,
            waiting: waiting)
        if !content.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(content.rows) { row in
                    SubagentRowView(
                        row: row, animates: indicatorsAnimate,
                        action: { perform(row) })
                }
            }
            .padding(.leading, LoomTheme.Space.subagentGuidePad)
            .overlay(alignment: .leading) {
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(width: LoomTheme.Line.hairline)
            }
            .padding(.leading, LoomTheme.Space.subagentGuideInset)
            .padding(.bottom, LoomTheme.Space.subagentTreeBottom)
            // Nothing finished any more: the next finished ones start folded again.
            .onChange(of: content.finishedCount) { _, count in if count == 0 { finishedExpanded = false } }
        }
    }

    private func perform(_ row: SubagentTreeContent.Row) {
        switch row.tap {
        case .openSubagent: model.openSubagent(row.id, in: sessionID)
        case .toggleFinished: finishedExpanded.toggle()
        case .toggleRunning: runningExpanded.toggle()
        }
    }
}

private struct SubagentRowView: View {
    let row: SubagentTreeContent.Row
    let animates: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LoomTheme.Space.subagentColumnGap) {
                leading.frame(width: LoomTheme.Layout.indicatorSlot.width)
                HStack(spacing: LoomTheme.Space.subagentTextGap) {
                    Text(row.title).font(titleFont).foregroundStyle(titleStyle)
                        .lineLimit(1).layoutPriority(1)
                    if let detail = row.detail {
                        Text(detail).font(LoomTheme.Typography.caption).foregroundStyle(detailStyle)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.leading, LoomTheme.Space.subagentRowLeading + CGFloat(row.depth - 1) * LoomTheme.Space.subagentIndent)
            .padding(.trailing, LoomTheme.Space.subagentRowTrailing)
            .frame(height: LoomTheme.Layout.subagentRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue ?? "")
        .accessibilityAddTraits(.isButton)
    }

    private var titleFont: Font { row.kind == .running ? LoomTheme.Typography.subagentType : LoomTheme.Typography.caption }

    /// Running: primary type. Finished and fold rows: secondary (they are told apart by the check glyph and
    /// the regular weight). Every text is primary or secondary; tertiary stays on the decorative check glyph.
    private var titleStyle: AnyShapeStyle {
        row.kind == .running ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)
    }

    private var detailStyle: AnyShapeStyle { AnyShapeStyle(LoomTheme.Text.secondaryStyle) }

    @ViewBuilder private var leading: some View {
        switch row.kind {
        case .running where row.isWaiting:
            IndicatorView(indicator: .waitingForApproval)
        case .running:
            BrailleSpinner(animating: animates, style: .subagent)
        case .finished, .finishedFold:
            Image(systemName: "checkmark").font(LoomTheme.Typography.subagentGlyph)
                .foregroundStyle(LoomTheme.Text.faint)
        case .more:
            Color.clear
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.kind {
        case let .finishedFold(expanded), let .more(expanded):
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(LoomTheme.Typography.chevron).foregroundStyle(LoomTheme.Text.secondaryStyle)
        case .running, .finished:
            Text(row.trailing).font(LoomTheme.Typography.subagentTime).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(1)
        }
    }

    private var helpText: String {
        guard row.opensSubagent else { return "" }
        let name = [row.title, row.detail].compactMap { $0 }.joined(separator: ": ")
        return row.isWaiting ? name + " (waiting for you)" : name
    }
}
