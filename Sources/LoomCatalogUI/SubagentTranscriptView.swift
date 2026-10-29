import LoomCore
import SwiftUI

/// A projected row of the subagent transcript: Markdown prose, a folded group of calls and results, or the live tail.
/// Tool details keep their mono voice; the brief and a finished agent's last words carry their own labels.
struct TranscriptLine: Equatable, Identifiable {
    enum Tone: Equatable {
        case primary, secondary, tertiary, failure, attention
    }

    /// What stands in the glyph column.
    enum Mark: Equatable {
        case glyph(String)
        /// The working spinner (the tail of a running agent).
        case spinner
        /// The attention dot (the tail of an agent whose request waits).
        case attentionDot
        case none
    }

    enum Kind: Equatable {
        case brief, omitted, words, tools, call, result, thought, tail, tooLong
    }

    let id: String
    let kind: Kind
    let mark: Mark
    let markTone: Tone
    /// A label over the text, in Ink's label type: "Brief", "Result".
    var label: String?
    /// A tool call's name, drawn before `text` in the call's semibold, primary.
    var name: String?
    let text: String
    let style: LoomTheme.InkStyle
    let tone: Tone
    let lineLimit: Int?
    /// The text is Markdown (the agent's words and its Result, FB6-18).
    var markdown = false
    /// A result's lines past the three shown, kept behind "Show more", and the lines the parser did not keep at all.
    var hiddenLines: [String] = []
    var unkeptLines = 0
    /// The room above the line.
    let top: CGFloat
    var accessibilityLabel: String?
    /// A tool group's calls and results, in their original order.
    var children: [TranscriptLine] = []
    /// Changes when a later tool fails, even if this group already contained an error.
    var lastFailureID: String?
}

/// Turns what the panel holds into the lines it draws.
enum TranscriptLines {
    typealias Metrics = LoomTheme.Agents

    static let briefLabel = "Brief"
    static let resultLabel = "Result"
    static let omittedText = "Earlier entries are not shown"
    static let runningText = "Running…"
    static let waitingText = InspectorAgentsContent.waitingText

    /// `isFinished` is an agent that ended with a result (not one interrupted): its last words are what went back to the session.
    static func make(brief: String?, omitsEarlier: Bool, items: [SubagentTranscriptModel.Item], isRunning: Bool,
                     isWaiting: Bool, isFinished: Bool) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        if let brief {
            lines.append(TranscriptLine(id: "brief", kind: .brief, mark: .none, markTone: .tertiary, label: briefLabel, text: brief,
                                        style: Metrics.brief, tone: .secondary, lineLimit: Metrics.briefLines, top: 0))
        }
        if omitsEarlier {
            lines.append(TranscriptLine(id: "omitted", kind: .omitted, mark: .none, markTone: .tertiary, text: omittedText,
                                        style: Metrics.omitted, tone: .tertiary, lineLimit: nil, top: gap(after: lines.last)))
        }
        let lastWords = isFinished && !isRunning ? items.lastIndex { if case .text = $0.entry { true } else { false } } : nil
        var index = 0
        var finalWords: SubagentTranscriptModel.Item?
        while index < items.count {
            let item = items[index]
            if index == lastWords {
                finalWords = item
                index += 1
                continue
            }
            if case .toolCall = item.entry {
                let start = index
                var children: [TranscriptLine] = []
                var count = 0
                var outstanding = 0
                while index < items.count {
                    let next = items[index]
                    guard isTool(next.entry) else { break }
                    switch next.entry {
                    case .toolCall:
                        count += 1
                        outstanding += 1
                    case .toolResult:
                        if outstanding > 0 { outstanding -= 1 }
                    default: break
                    }
                    children.append(line(next, isResult: false, top: gap(after: children.last, before: next.entry)))
                    index += 1
                }
                let toolCount = "\(count) \(count == 1 ? "tool" : "tools")"
                lines.append(TranscriptLine(id: "tools-\(items[start].id)", kind: .tools, mark: .none, markTone: .tertiary,
                                            text: outstanding == 0 ? "Ran \(toolCount)" : toolCount, style: Metrics.tail,
                                            tone: .secondary, lineLimit: 1, top: gap(after: lines.last), children: children,
                                            lastFailureID: children.last { $0.kind == .result && $0.tone == .failure }?.id))
            } else {
                lines.append(line(item, isResult: false, top: gap(after: lines.last, before: item.entry)))
                index += 1
            }
        }
        if let finalWords {
            lines.append(line(finalWords, isResult: true, top: gap(after: lines.last, before: finalWords.entry)))
        }
        if isRunning || isWaiting {
            lines.append(isWaiting
                ? TranscriptLine(id: "tail", kind: .tail, mark: .attentionDot, markTone: .attention, text: waitingText,
                                 style: Metrics.tail, tone: .attention, lineLimit: 1, top: gap(after: lines.last))
                : TranscriptLine(id: "tail", kind: .tail, mark: .spinner, markTone: .secondary, text: runningText,
                                 style: Metrics.tail, tone: .secondary, lineLimit: 1, top: gap(after: lines.last)))
        }
        return lines
    }

    private static func isTool(_ entry: SubagentTranscriptEntry) -> Bool {
        switch entry {
        case .toolCall, .toolResult: true
        default: false
        }
    }

    private static func line(_ item: SubagentTranscriptModel.Item, isResult: Bool, top: CGFloat) -> TranscriptLine {
        let id = "item-\(item.id)"
        switch item.entry {
        case let .brief(text):
            // A second brief in the stream (the panel keeps the first apart) reads like the first.
            return TranscriptLine(id: id, kind: .brief, mark: .none, markTone: .tertiary, label: briefLabel, text: text,
                                  style: Metrics.brief, tone: .secondary, lineLimit: Metrics.briefLines, top: top)
        case let .text(text):
            return TranscriptLine(id: id, kind: .words, mark: .glyph("⏺"), markTone: .primary,
                                  label: isResult ? resultLabel : nil, text: text, style: Metrics.words, tone: .primary,
                                  lineLimit: nil, markdown: true, top: top)
        case let .toolCall(name, argument):
            return TranscriptLine(id: id, kind: .call, mark: .glyph("⏺"), markTone: .tertiary, name: name,
                                  text: argument.isEmpty ? "" : "(\(argument))", style: Metrics.call, tone: .secondary,
                                  lineLimit: Metrics.callLines, top: top,
                                  accessibilityLabel: argument.isEmpty ? name : "\(name), \(argument)")
        case let .toolResult(lines, lineCount, isError):
            let first = lines.first ?? ""
            return TranscriptLine(id: id, kind: .result, mark: .glyph("⎿"), markTone: isError ? .failure : .tertiary,
                                  text: resultText(lines: lines), style: Metrics.result,
                                  tone: isError ? .failure : .tertiary, lineLimit: Metrics.resultWrapLines,
                                  hiddenLines: Array(lines.dropFirst(Metrics.resultLines)),
                                  unkeptLines: max(0, lineCount - lines.count), top: top,
                                  accessibilityLabel: isError ? "Error: \(first)" : first)
        case .tooLong:
            return TranscriptLine(id: id, kind: .tooLong, mark: .none, markTone: .tertiary, text: Metrics.tooLongText,
                                  style: Metrics.omitted, tone: .tertiary, lineLimit: nil, top: top)
        case let .thought(milliseconds):
            return TranscriptLine(id: id, kind: .thought, mark: .glyph("✻"), markTone: .tertiary,
                                  text: thoughtText(milliseconds: milliseconds), style: Metrics.thought, tone: .tertiary,
                                  lineLimit: 1, top: top)
        }
    }

    /// The room above a line: none for the first; 12 after the brief or the omitted line; 2 for a result under its call; 11 before
    /// the agent's words, a call, a thought and the tail.
    static func gap(after previous: TranscriptLine?, before entry: SubagentTranscriptEntry? = nil) -> CGFloat {
        guard let previous else { return 0 }
        if previous.kind == .brief || previous.kind == .omitted { return Metrics.afterBriefGap }
        if case .toolResult? = entry { return Metrics.resultGap }
        return Metrics.blockGap
    }

    /// The first lines of a result, as many as the tab shows at first; the rest is behind a click.
    static func resultText(lines: [String]) -> String {
        let shown = lines.prefix(Metrics.resultLines).joined(separator: "\n")
        return shown.isEmpty ? "(no output)" : shown
    }

    /// The button under a result with more: "Show 12 more lines", or "Show less" once open.
    static func moreLabel(hidden: Int, expanded: Bool) -> String {
        expanded ? "Show less" : (hidden == 1 ? "Show 1 more line" : "Show \(hidden) more lines")
    }

    static func thoughtText(milliseconds: Int?) -> String {
        guard let milliseconds else { return "Thought" }
        return "Thought for \(max(1, Int((Double(milliseconds) / 1_000).rounded())))s"
    }
}

/// The words a transcript entry is drawn with, kept under the name the panel's tests know.
enum TranscriptEntryRow {
    static func resultText(lines: [String]) -> String { TranscriptLines.resultText(lines: lines) }

    static func thoughtText(milliseconds: Int?) -> String { TranscriptLines.thoughtText(milliseconds: milliseconds) }
}

/// A subagent's transcript: prose and the Result are Markdown, while consecutive tool calls and results share a disclosure.
/// Only web and mail links open; tool input and output stay plain text. The lazy list follows the tail only at the bottom.
struct SubagentTranscriptView: View {
    let panel: SubagentTranscriptModel
    var isWaiting = false
    var isFinished = false
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var followsTail = true

    /// How close to the end counts as being at the bottom.
    private static let bottomTolerance: CGFloat = 24

    var body: some View {
        // One view that stays: its appearance, not the note's or the transcript's, says the panel is on screen.
        ZStack {
            switch panel.phase {
            case .unavailable:
                note("The transcript is not available.")
            case .loading:
                note("Reading the transcript…")
            case .live:
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            panel.setPresentation(isWaiting: isWaiting, isFinished: isFinished)
            panel.setOnScreen(true)
        }
        .onChange(of: isWaiting) { panel.setPresentation(isWaiting: isWaiting, isFinished: isFinished) }
        .onChange(of: isFinished) { panel.setPresentation(isWaiting: isWaiting, isFinished: isFinished) }
        .onDisappear { panel.setOnScreen(false) }
    }

    private func note(_ text: String) -> some View {
        Text(text).projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(panel.lines) { line in
                    TranscriptLineView(line: line).padding(.top, line.top)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, LoomTheme.Agents.streamInset)
            .padding(.top, LoomTheme.Agents.streamTop).padding(.bottom, LoomTheme.Agents.streamBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - Self.bottomTolerance
        } action: { _, atBottom in
            followsTail = atBottom
        }
        // The change is seen before the new rows are laid out, while `followsTail` still says whether the
        // reader was at the bottom.
        .onChange(of: panel.items.last?.id) {
            if followsTail { position.scrollTo(edge: .bottom) }
        }
    }
}

/// Draws one `TranscriptLine`: the glyph column and the text after it; the brief takes the full width with a hairline under it.
private struct TranscriptLineView: View {
    typealias Metrics = LoomTheme.Agents
    let line: TranscriptLine
    @Environment(\.inspectorOverlays) private var overlays
    @State private var expanded = false

    var body: some View {
        if line.kind == .tools {
            toolGroup
        } else if line.kind == .brief {
            VStack(alignment: .leading, spacing: 0) {
                content(of: line)
                    .padding(.bottom, Metrics.briefBottom)
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                    .accessibilityHidden(true)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                mark.frame(width: Metrics.glyphColumn, alignment: .leading)
                    .accessibilityHidden(true)
                content(of: line).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: line.accessibilityLabel == nil ? .contain : .combine)
            .modifier(OptionalAccessibilityLabel(label: line.accessibilityLabel))
        }
    }

    private var toolGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Metrics.toolFoldGap) {
                    InkIcon(expanded ? .chevronDown : .chevronRight, size: LoomTheme.Icon.small)
                        .accessibilityHidden(true)
                    Text(line.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ControlButtonStyle(kind: .ghost, size: .regular))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(line.children) { child in
                        TranscriptLineView(line: child).padding(.top, child.top)
                    }
                }
                .padding(.leading, Metrics.toolFoldIndent)
            }
        }
        .onAppear { if line.lastFailureID != nil { expanded = true } }
        .onChange(of: line.lastFailureID) { _, failure in if failure != nil { expanded = true } }
    }

    @ViewBuilder private var mark: some View {
        switch line.mark {
        case let .glyph(glyph):
            Text(verbatim: glyph).projectType(Metrics.glyph).foregroundStyle(style(line.markTone))
        case .spinner:
            IndicatorView(indicator: .working)
        case .attentionDot:
            IndicatorView(indicator: .waitingForApproval)
        case .none:
            Color.clear.frame(height: 0)
        }
    }

    private func content(of line: TranscriptLine) -> some View {
        VStack(alignment: .leading, spacing: line.kind == .brief ? Metrics.briefLabelGap : Metrics.resultLabelGap) {
            if let label = line.label {
                Text(verbatim: label).inspectorType(LoomTheme.Inspector.sectionLabel)
                    .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
            }
            if line.markdown {
                SubagentMarkdownView(id: line.id, text: line.text)
            } else {
                text(of: line)
                    .modifier(TranscriptLineHeight(points: line.style.lineHeight))
                    .lineLimit(expanded ? nil : line.lineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if line.kind == .result, expanded {
                let rest = line.hiddenLines.joined(separator: "\n")
                if !rest.isEmpty {
                    Text(verbatim: rest).font(line.style.font).foregroundStyle(style(line.tone))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if line.kind == .result, hiddenCount > 0 {
                Button(TranscriptLines.moreLabel(hidden: hiddenCount, expanded: expanded)) { expanded.toggle() }
                    .buttonStyle(ControlButtonStyle(kind: .link, size: .small))
                    .padding(.top, Metrics.resultLabelGap / 2)
            }
        }
    }

    /// The lines a click shows: the ones the entry kept past three; lines it could not keep are named, not shown.
    private var hiddenCount: Int { line.hiddenLines.count + line.unkeptLines }

    private func text(of line: TranscriptLine) -> Text {
        let base = Text(verbatim: line.text).font(line.style.font).foregroundStyle(style(line.tone))
        guard let name = line.name else { return base }
        return Text("\(Text(verbatim: name).font(Metrics.callName.font).foregroundStyle(LoomTheme.Text.primary))\(base)")
    }

    private func style(_ tone: TranscriptLine.Tone) -> AnyShapeStyle {
        switch tone {
        case .primary: AnyShapeStyle(LoomTheme.Text.primary)
        case .secondary: AnyShapeStyle(LoomTheme.Text.secondaryStyle)
        case .tertiary: AnyShapeStyle(LoomTheme.Inspector.quiet(overlays: overlays))
        case .failure: AnyShapeStyle(LoomTheme.Status.failureLight)
        case .attention: AnyShapeStyle(LoomTheme.Status.attentionLight)
        }
    }
}

private struct TranscriptLineHeight: ViewModifier {
    let points: CGFloat?

    func body(content: Content) -> some View {
        if let points { content.lineHeight(.exact(points: points)) } else { content }
    }
}

private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label { content.accessibilityLabel(label) } else { content }
    }
}
