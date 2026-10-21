import Foundation
import LoomCore
import SwiftUI

/// What the subagent tree under a session card shows (D-39; Ink's branches, D-74),
/// as a plain value so the rules can be tested without a view:
/// - one row per running subagent, at most `maximumRunningRows`; more shows a "+N more" row that
///   expands (and then collapses again);
/// - finished subagents of the current turn fold into one "N finished" row that expands to their rows;
///   with only finished ones, only that row shows;
/// - a subagent a subagent started (`depth` > 1) branches one step further per level.
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
        /// 1 for a direct subagent of the session; the row branches `depth - 1` steps further.
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

/// The branches of a subagent tree as plain geometry (DESIGN §4, A8): one branch per row, leaving the session's status column
/// (`Branches.column`), turning into its 24 pt row with a 7 pt curve; a middle branch carries the line on to the next sibling,
/// the last one ends at its curve; a deeper row branches one step (`Branches.step`) further, and an ancestor's line runs on
/// beside it while that ancestor has a sibling below. `x` is a line's left edge, `y` counts from the first row's top.
struct SubagentBranches: Equatable {
    /// What one row hangs on.
    struct Branch: Equatable {
        let depth: Int
        /// No sibling of its depth below it (before a shallower row): its branch ends at the curve.
        let isLast: Bool
        /// The shallower depths whose line runs on beside this row.
        let passing: [Int]
    }

    /// A stroke of the one path. `turn` is a branch's own: down from `overhang` above the row, the curve, the arm.
    enum Segment: Equatable {
        case line(x: CGFloat, from: CGFloat, to: CGFloat)
        case turn(x: CGFloat, rowTop: CGFloat)
    }

    typealias Metrics = LoomTheme.Branches

    let branches: [Branch]

    /// `depths`: the depth of each row, in order (1 for a direct subagent of the session).
    init(depths: [Int]) {
        // Scanning from the end: `below[level]` says a row of that depth comes later, before a shallower one.
        var below: [Int: Bool] = [:]
        var result: [Branch] = []
        for depth in depths.reversed().map({ max(1, $0) }) {
            let passing = (1..<max(1, depth)).filter { below[$0] == true }
            result.append(Branch(depth: depth, isLast: below[depth] != true, passing: passing))
            below[depth] = true
            for level in Array(below.keys) where level > depth { below[level] = false }
        }
        branches = result.reversed()
    }

    var height: CGFloat { CGFloat(branches.count) * Metrics.rowHeight }

    /// The left edge of the line of a row at this depth.
    static func x(depth: Int) -> CGFloat { Metrics.column + CGFloat(max(1, depth) - 1) * Metrics.step }

    /// Where the row's mark starts, from the list's edge.
    static func contentLeading(depth: Int) -> CGFloat { x(depth: depth) + Metrics.contentGap }

    var segments: [Segment] {
        var result: [Segment] = []
        for (index, branch) in branches.enumerated() {
            let top = CGFloat(index) * Metrics.rowHeight
            let x = Self.x(depth: branch.depth)
            result.append(.turn(x: x, rowTop: top))
            // A middle branch runs on to the bottom of its row, where the next one takes over.
            if !branch.isLast { result.append(.line(x: x, from: top - Metrics.overhang, to: top + Metrics.rowHeight)) }
            for depth in branch.passing {
                result.append(.line(x: Self.x(depth: depth), from: top, to: top + Metrics.rowHeight))
            }
        }
        return result
    }

    /// The segments as one path with its origin at `origin` (the first row's top left). The line is 1 pt wide with its left
    /// edge on `x`, so its centre is half a point in; the turn's radius is the centre line's.
    func path(from origin: CGPoint = .zero) -> Path {
        var path = Path()
        let half = Metrics.lineWidth / 2
        let radius = Metrics.curveRadius - half
        for segment in segments {
            switch segment {
            case let .line(x, from, to):
                path.move(to: CGPoint(x: origin.x + x + half, y: origin.y + from))
                path.addLine(to: CGPoint(x: origin.x + x + half, y: origin.y + to))
            case let .turn(x, rowTop):
                let line = origin.x + x + half
                let middle = origin.y + rowTop + Metrics.rowHeight / 2 - half
                path.move(to: CGPoint(x: line, y: origin.y + rowTop - Metrics.overhang))
                path.addLine(to: CGPoint(x: line, y: middle - radius))
                path.addArc(tangent1End: CGPoint(x: line, y: middle),
                            tangent2End: CGPoint(x: line + radius, y: middle), radius: radius)
                path.addLine(to: CGPoint(x: origin.x + x + Metrics.arm, y: middle))
            }
        }
        return path
    }
}

/// The branches of the tree, stroked once in the opaque tree colour: crossing lines never brighten.
struct SubagentBranchesShape: Shape {
    let branches: SubagentBranches

    func path(in rect: CGRect) -> Path { branches.path(from: rect.origin) }
}

/// The tree under a session card: a branch per row, drawn over the rows from the session's status column, which the list's
/// leading edge places 22 pt in (`Branches.column`).
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
            let branches = SubagentBranches(depths: content.rows.map(\.depth))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(content.rows) { row in
                    SubagentRowView(
                        row: row, animates: indicatorsAnimate,
                        action: { perform(row) })
                }
            }
            .overlay(alignment: .topLeading) {
                SubagentBranchesShape(branches: branches)
                    .stroke(LoomTheme.Surface.tree, style: StrokeStyle(lineWidth: LoomTheme.Branches.lineWidth))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
    typealias Metrics = LoomTheme.Branches
    let row: SubagentTreeContent.Row
    let animates: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.rowGap) {
                leading.frame(width: LoomTheme.Layout.indicatorSlot.width)
                HStack(spacing: Metrics.rowGap) {
                    Text(row.title).font(titleStyle.font).tracking(titleStyle.trackingPoints)
                        .foregroundStyle(titleColor).lineLimit(1).layoutPriority(1)
                    if let detail = row.detail {
                        Text(detail).font(Metrics.text.font).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.leading, SubagentBranches.contentLeading(depth: row.depth))
            .padding(.trailing, Metrics.rowTrailing)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(radius: Metrics.pillRadius))
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue ?? "")
        .accessibilityAddTraits(.isButton)
    }

    /// Running: the type in 12 medium, primary. Finished and fold rows: regular, secondary.
    private var titleStyle: LoomTheme.InkStyle { row.kind == .running ? Metrics.runningType : Metrics.text }

    private var titleColor: AnyShapeStyle {
        row.kind == .running ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)
    }

    @ViewBuilder private var leading: some View {
        switch row.kind {
        case .running where row.isWaiting:
            IndicatorView(indicator: .waitingForApproval)
        case .running:
            BrailleSpinner(animating: animates, style: .subagent)
        case .finished, .finishedFold:
            Image(systemName: "checkmark").font(Metrics.check).foregroundStyle(LoomTheme.Text.faint)
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
            Text(row.trailing).font(Metrics.time.font).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .lineLimit(1)
        }
    }

    private var helpText: String {
        guard row.opensSubagent else { return "" }
        let name = [row.title, row.detail].compactMap { $0 }.joined(separator: ": ")
        return row.isWaiting ? name + " (waiting for you)" : name
    }
}
