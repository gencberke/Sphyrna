import LoomChat
import SwiftUI

/// Claude's prose: no bubble, markdown blocks at the reading size. The final answer of a settled turn offers Copy on
/// hover (the source markdown of the whole message, not a re-serialised selection).
struct ChatProseView: View {
    let entry: ChatEntry
    let settled: Bool
    let flags: Set<String>
    let context: ChatRowContext
    @State private var hovering = false

    var body: some View {
        let _ = ChatRenderProbe.proseBody(in: context)
        if case let .assistantText(text) = entry.body {
            VStack(alignment: .leading, spacing: 4) {
                ChatMarkdownView(blocks: ChatContent.blocks(id: entry.id, text: text.text, isStreaming: text.isStreaming, in: context),
                                 flags: flags, rowID: entry.id, isStreaming: text.isStreaming, context: context)
                if settled {
                    HStack(spacing: 10) {
                        if let notes = context.sideNotes {
                            // A side chat's answer: the two actions stay in view (V22 part 3).
                            SideAnswerActions(entryID: entry.id, text: text.text, notes: notes, context: context)
                        } else if hovering {
                            ChatCopyButton(text: text.text, context: context)
                            if let time = entry.timestamp {
                                Text(ChatTime.label(for: time)).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            }
                        }
                    }
                    .frame(height: 18)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { if settled { hovering = $0 } }
        }
    }
}

/// A list of blocks. Links open only when they are web or mail links.
struct ChatMarkdownView: View {
    let blocks: [MarkdownBlock]
    let flags: Set<String>
    let rowID: String
    var isStreaming = false
    let context: ChatRowContext
    /// The top-level block this list belongs to, for the wrap flag of a code block inside a list or a quote.
    var topIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Chat.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, index: topIndex ?? index, isLast: index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in ChatContent.isFollowable(url) ? .systemAction : .discarded })
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock, index: Int, isLast: Bool) -> some View {
        switch block {
        case let .paragraph(source):
            inline(source)
        case let .heading(level, text):
            Text(ChatContent.inline(text, in: context))
                .font(level <= 1 ? LoomTheme.Chat.heading1 : level == 2 ? LoomTheme.Chat.heading2 : LoomTheme.Chat.heading3)
                .foregroundStyle(LoomTheme.Text.primary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case let .code(language, code, closed):
            ChatCodeBlockView(language: language, code: code, isStreaming: isStreaming && isLast && !closed,
                              wrapped: flags.contains("wrap:\(index)"), context: context) {
                context.toggleFlag(rowID, "wrap:\(index)")
            }
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + position, checked: item.checked)
                        ChatMarkdownView(blocks: item.blocks, flags: flags, rowID: rowID, isStreaming: isStreaming, context: context,
                                         topIndex: index)
                    }
                }
            }
        case let .quote(inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim).fill(LoomTheme.Chat.quoteBar).frame(width: LoomTheme.Chat.quoteBarWidth)
                ChatMarkdownView(blocks: inner, flags: flags, rowID: rowID, isStreaming: isStreaming, context: context, topIndex: index)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(table):
            ChatMarkdownTableView(table: table, context: context)
        case .rule:
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).padding(.vertical, 4)
        }
    }

    private func inline(_ source: String) -> some View {
        Text(ChatContent.inline(source, in: context))
            .font(LoomTheme.Chat.reading)
            .lineSpacing(LoomTheme.Chat.readingLineSpacing)
            .foregroundStyle(LoomTheme.Text.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        Group {
            if let checked {
                Image(systemName: checked ? "checkmark.square" : "square").font(LoomTheme.Chat.rowIcon)
            } else if ordered {
                Text("\(number).").font(LoomTheme.Chat.reading).monospacedDigit()
            } else {
                Text("\u{2022}").font(LoomTheme.Chat.reading)
            }
        }
        .foregroundStyle(LoomTheme.Text.secondaryStyle)
        .frame(minWidth: 18, alignment: .trailing)
    }
}

/// A table: it scrolls sideways when it is wider than the column.
struct ChatMarkdownTableView: View {
    let table: MarkdownTable
    let context: ChatRowContext

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column, header: true)
                    }
                }
                .background(LoomTheme.Chat.tableHeaderFill)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<table.header.count, id: \.self) { column in
                            cellView(column < row.count ? row[column] : "", column: column, header: false)
                        }
                    }
                    .overlay(alignment: .top) { Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).strokeBorder(LoomTheme.Surface.hairlineStyle))
            .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.md))
        }
    }

    private func cellView(_ source: String, column: Int, header: Bool) -> some View {
        let alignment: Alignment = switch column < table.alignments.count ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(ChatContent.inline(source, in: context))
            .font(header ? LoomTheme.Chat.toolLabelStrong : LoomTheme.Chat.toolLabel)
            .foregroundStyle(LoomTheme.Text.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 60, maxWidth: 320, alignment: alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A fenced code block: the language, Copy and a wrap toggle on a header; the code scrolls sideways unless it wraps.
struct ChatCodeBlockView: View {
    let language: String?
    let code: String
    let isStreaming: Bool
    let wrapped: Bool
    let context: ChatRowContext
    let toggleWrap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: language ?? "text").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                Spacer(minLength: 0)
                Button(action: toggleWrap) {
                    Image(systemName: wrapped ? "text.alignleft" : "arrow.turn.down.left").font(LoomTheme.Chat.rowIcon)
                }
                .buttonStyle(.plain).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(minWidth: 24, minHeight: 20)
                .help(wrapped ? "Do not wrap lines" : "Wrap lines")
                .accessibilityLabel(wrapped ? "Do not wrap lines" : "Wrap lines")
                ChatCopyButton(text: code, context: context)
            }
            .padding(.horizontal, 10)
            .frame(height: LoomTheme.Chat.codeHeaderHeight)
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
            if wrapped {
                codeText.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    codeText.padding(10).fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius).fill(LoomTheme.Surface.card))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius))
    }

    @ViewBuilder private var codeText: some View {
        let colored = ChatHighlighter.highlighted(code, language: language, isStreaming: isStreaming)
        Group {
            if let colored { Text(colored) } else { Text(verbatim: code) }
        }
        .font(LoomTheme.Chat.body)
        .lineSpacing(LoomTheme.Chat.bodyLineHeight - 15)
        .foregroundStyle(LoomTheme.Chat.syntaxPlain)
        .textSelection(.enabled)
    }
}
