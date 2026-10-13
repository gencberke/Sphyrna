import LoomCore
import SwiftUI

/// One subagent's transcript in Claude's own style (FB4-5): ⏺ for text and tool calls, ⎿ for a result,
/// ✻ for thinking. Plain text only: nothing is rendered as markdown and no link is opened. The list is lazy
/// and bounded by the model's ring; it follows the newest entry only while the reader is at the bottom.
struct SubagentTranscriptView: View {
    let panel: SubagentTranscriptModel
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
        .onAppear { panel.setOnScreen(true) }
        .onDisappear { panel.setOnScreen(false) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LoomTheme.Space.transcriptRowGap) {
                if let brief = panel.brief { TranscriptEntryRow(entry: .brief(brief)) }
                if panel.omitsEarlier {
                    TranscriptRow(glyph: "", glyphStyle: LoomTheme.Text.secondaryStyle) {
                        Text("Earlier entries are not shown").foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                }
                ForEach(panel.items) { item in TranscriptEntryRow(entry: item.entry) }
                if panel.isRunning {
                    TranscriptRow(glyph: "✻", glyphStyle: LoomTheme.Text.secondaryStyle) {
                        Text("Running…").foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                }
            }
            .font(LoomTheme.Typography.transcript)
            .textSelection(.enabled)
            .padding(LoomTheme.Space.transcriptInset)
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

/// A glyph column and the text after it.
private struct TranscriptRow<Content: View>: View {
    let glyph: String
    let glyphStyle: AnyShapeStyle
    @ViewBuilder let content: () -> Content

    init(glyph: String, glyphStyle: some ShapeStyle, @ViewBuilder content: @escaping () -> Content) {
        self.glyph = glyph
        self.glyphStyle = AnyShapeStyle(glyphStyle)
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: glyph).foregroundStyle(glyphStyle)
                .frame(width: LoomTheme.Space.transcriptGlyphColumn, alignment: .leading)
                .accessibilityHidden(true)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TranscriptEntryRow: View {
    let entry: SubagentTranscriptEntry

    var body: some View {
        switch entry {
        case let .brief(text):
            TranscriptRow(glyph: "", glyphStyle: LoomTheme.Text.secondaryStyle) {
                Text(verbatim: "Brief  \(text)").lineLimit(4).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        case let .text(text):
            TranscriptRow(glyph: "⏺", glyphStyle: LoomTheme.Text.primary) {
                Text(verbatim: text).foregroundStyle(LoomTheme.Text.primary)
            }
        case let .toolCall(name, argument):
            TranscriptRow(glyph: "⏺", glyphStyle: LoomTheme.Text.primary) {
                Text("\(Text(verbatim: name).font(LoomTheme.Typography.transcriptStrong).foregroundStyle(LoomTheme.Text.primary))\(Text(verbatim: argument.isEmpty ? "" : "(\(argument))").foregroundStyle(LoomTheme.Text.secondaryIncreasedRGB.color))")
                    .lineLimit(3)
            }
            .accessibilityElement(children: .combine)
        case let .toolResult(firstLine, lineCount, isError):
            let style = isError ? AnyShapeStyle(LoomTheme.Status.failure) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)
            TranscriptRow(glyph: "⎿", glyphStyle: style) {
                Text(verbatim: Self.resultText(firstLine: firstLine, lineCount: lineCount)).foregroundStyle(style).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isError ? "Error: \(firstLine)" : firstLine)
        case let .thought(milliseconds):
            TranscriptRow(glyph: "✻", glyphStyle: LoomTheme.Text.secondaryStyle) {
                Text(verbatim: Self.thoughtText(milliseconds: milliseconds)).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        }
    }

    /// The first line, and how much more there was: "Read 142 lines" style, but from the result itself.
    static func resultText(firstLine: String, lineCount: Int) -> String {
        let more = lineCount > 1 ? "  (+\(lineCount - 1) lines)" : ""
        return (firstLine.isEmpty ? "(no output)" : firstLine) + more
    }

    static func thoughtText(milliseconds: Int?) -> String {
        guard let milliseconds else { return "Thought" }
        return "Thought for \(max(1, Int((Double(milliseconds) / 1_000).rounded())))s"
    }
}
