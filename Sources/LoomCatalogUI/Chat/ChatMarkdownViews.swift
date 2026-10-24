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

    /// The space above and below the blocks. The measurer adds them to the blocks' heights (`ChatRowMeasurer`).
    static let topInset: CGFloat = 10
    static let bottomInset: CGFloat = 4

    var body: some View {
        let _ = ChatRenderProbe.proseBody(in: context)
        if case let .assistantText(text) = entry.body {
            VStack(alignment: .leading, spacing: 0) {
                if text.isStreaming {
                    ChatStreamingMarkdownView(parts: ChatContent.streamingBlocks(id: entry.id, text: text.text, in: context),
                                              flags: flags, rowID: entry.id, context: context)
                } else {
                    ChatMarkdownView(blocks: ChatContent.blocks(id: entry.id, text: text.text, isStreaming: false, in: context),
                                     flags: flags, rowID: entry.id, isStreaming: false, context: context)
                }
                if settled {
                    HStack(spacing: 6) {
                        if let notes = context.sideNotes {
                            // A side chat's answer: the two actions stay in view (V22 part 3).
                            SideAnswerActions(entryID: entry.id, text: text.text, notes: notes, context: context)
                        } else if hovering {
                            ChatCopyButton(text: text.text, context: context)
                            if let time = entry.timestamp {
                                Text(ChatTime.label(for: time)).font(LoomTheme.Chat.timeMono).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                            }
                        }
                    }
                    .frame(height: LoomTheme.Chat.replyFooterHeight)
                    .padding(.leading, -6)
                }
            }
            .padding(.top, Self.topInset).padding(.bottom, Self.bottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { if settled { hovering = $0 } }
        }
    }
}

/// A streaming message: the settled head as one view that is drawn again only when the head or its wrap flags change, and the
/// open tail, which is drawn every time. Laid out as one list of blocks: the head, the same 12 pt, the tail, and every
/// block keeps the index it has in the whole message (the wrap flag and Copy use it).
struct ChatStreamingMarkdownView: View {
    let parts: ChatContent.StreamingBlocks
    let flags: Set<String>
    let rowID: String
    let context: ChatRowContext

    var body: some View {
        if parts.isComposable {
            VStack(alignment: .leading, spacing: LoomTheme.Chat.blockSpacing) {
                if !parts.head.isEmpty {
                    ChatSettledBlocksView(blocks: parts.head, token: parts.headToken,
                                          wrapped: ChatSettledBlocksView.wrappedIndexes(in: flags, below: parts.head.count),
                                          flags: flags, rowID: rowID, context: context)
                        .equatable()
                }
                if !parts.tail.isEmpty {
                    ChatMarkdownView(blocks: parts.tail, flags: flags, rowID: rowID, isStreaming: true, context: context,
                                     firstIndex: parts.head.count)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ChatMarkdownView(blocks: parts.blocks, flags: flags, rowID: rowID, isStreaming: true, context: context)
        }
    }
}

/// The settled blocks of a streaming message. Two of them are equal when they are the same head (the token: row, block count,
/// hash of the text) with the same wrap flags, so a flush that only grows the tail does not evaluate them again. What else
/// changes how a block looks does not come through here: the width is layout, and the appearance and the tone are read by the
/// views inside from the environment and `ThemeState`, which redraw them on their own.
struct ChatSettledBlocksView: View, Equatable {
    let blocks: [MarkdownBlock]
    let token: ChatContent.HeadToken
    /// The top-level indexes below the head's count whose code block wraps.
    let wrapped: [Int]
    /// Not compared: only the wrap flags below the head's count are read from it.
    let flags: Set<String>
    let rowID: String
    let context: ChatRowContext

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token && lhs.wrapped == rhs.wrapped }

    static func wrappedIndexes(in flags: Set<String>, below count: Int) -> [Int] {
        flags.compactMap { flag in
            guard flag.hasPrefix("wrap:"), let index = Int(flag.dropFirst(5)), index < count else { return nil }
            return index
        }.sorted()
    }

    var body: some View {
        ChatMarkdownView(blocks: blocks, flags: flags, rowID: rowID, isStreaming: false, context: context)
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
    /// The index of `blocks[0]` among the message's top-level blocks: a list that is the open tail of a streaming message
    /// starts after the settled head, and its blocks keep the indexes they have in the whole message.
    var firstIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Chat.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { position, block in
                // The probe counts where a top-level block's view is built (once per evaluation of this list) and where its body runs.
                let _ = topIndex == nil ? ChatRenderProbe.blockBuilt(index: firstIndex + position, block: block, in: context) : ()
                ChatMarkdownBlockView(block: block, index: topIndex ?? (firstIndex + position), isLast: position == blocks.count - 1,
                                      flags: flags, rowID: rowID, isStreaming: isStreaming, context: context,
                                      isTopLevel: topIndex == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in ChatContent.isFollowable(url) ? .systemAction : .discarded })
    }
}

/// One block of a message: the unit the stream's settled head keeps and the measurer measures.
struct ChatMarkdownBlockView: View {
    let block: MarkdownBlock
    /// The index the block's flags use: its place among the message's top-level blocks, or the one of the top-level block it
    /// sits in.
    let index: Int
    let isLast: Bool
    let flags: Set<String>
    let rowID: String
    let isStreaming: Bool
    let context: ChatRowContext
    /// A block of the message's own list, not one inside a list item or a quote: the render probe counts its evaluations.
    var isTopLevel = false

    var body: some View {
        let _ = isTopLevel ? ChatRenderProbe.blockBody(index: index, block: block, in: context) : ()
        let _ = isTopLevel ? ChatSelectionProbe.drawn(index: index, block: block, selectable: !isStreaming, in: context) : ()
        blockView(block, index: index, isLast: isLast)
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
                .chatTextSelection(!isStreaming)
        case let .code(language, code, closed):
            ChatCodeBlockView(language: language, code: code, isStreaming: isStreaming && isLast && !closed,
                              wrapped: flags.contains("wrap:\(index)"), context: context, selectable: !isStreaming) {
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
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim).fill(LoomTheme.Chat.quoteBar).frame(width: LoomTheme.Chat.quoteBarWidth)
                ChatMarkdownView(blocks: inner, flags: flags, rowID: rowID, isStreaming: isStreaming, context: context, topIndex: index)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(table):
            ChatMarkdownTableView(table: table, context: context, selectable: !isStreaming)
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
            .chatTextSelection(!isStreaming)
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
    var selectable = true

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
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
            .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius))
        }
    }

    private func cellView(_ source: String, column: Int, header: Bool) -> some View {
        let alignment: Alignment = switch column < table.alignments.count ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(ChatContent.inline(source, in: context))
            .font(header ? LoomTheme.Chat.linkLabel : LoomTheme.Chat.toolLabel)
            .foregroundStyle(header ? AnyShapeStyle(LoomTheme.Text.secondaryStyle) : AnyShapeStyle(LoomTheme.Text.primary))
            .chatTextSelection(selectable)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(minWidth: 60, maxWidth: 320, minHeight: LoomTheme.Chat.tableRowHeight, alignment: alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A fenced code block (DESIGN §7): a card (raised 1, radius 8, a hairline) with a 30 pt header (the language in mono 11
/// tertiary, a wrap toggle and Copy) over the code in 12.5 / 20; the code scrolls sideways unless it wraps.
struct ChatCodeBlockView: View {
    let language: String?
    let code: String
    let isStreaming: Bool
    let wrapped: Bool
    let context: ChatRowContext
    var selectable = true
    let toggleWrap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(verbatim: language ?? "text").font(LoomTheme.Chat.timeMono).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                Spacer(minLength: 0)
                ChatIconButton(symbol: wrapped ? "text.alignleft" : "arrow.turn.down.left",
                               label: wrapped ? "Do not wrap lines" : "Wrap lines", action: toggleWrap)
                ChatCopyButton(text: code, context: context)
            }
            .padding(.leading, LoomTheme.Chat.outputPaddingH).padding(.trailing, 4)
            .frame(height: LoomTheme.Chat.codeHeaderHeight)
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
            if wrapped {
                codeText.padding(codePadding).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    codeText.padding(codePadding).fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius).fill(LoomTheme.Chat.cardFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius))
    }

    private var codePadding: EdgeInsets {
        EdgeInsets(top: LoomTheme.Chat.codePaddingTop, leading: LoomTheme.Chat.codePaddingH,
                   bottom: LoomTheme.Chat.codePaddingBottom, trailing: LoomTheme.Chat.codePaddingH)
    }

    @ViewBuilder private var codeText: some View {
        let colored = ChatHighlighter.highlighted(code, language: language, isStreaming: isStreaming)
        Group {
            if let colored { Text(colored) } else { Text(verbatim: code) }
        }
        .font(LoomTheme.Chat.body)
        .lineSpacing(LoomTheme.Chat.codeLineSpacing)
        .foregroundStyle(LoomTheme.Chat.syntaxPlain)
        .chatTextSelection(selectable)
        // Line spacing falls between lines only; half of it above and below makes every line 20 high.
        .padding(.vertical, LoomTheme.Chat.codeLineSpacing / 2)
    }
}

/// Text selection of a block's text: on for settled text, off for the open tail of a streaming message, which every flush
/// draws again and which would otherwise build a second text layout of itself each time. Copy copies the source, so it does
/// not depend on it. The enabled and disabled selections are different types, hence the branch.
private struct ChatTextSelection: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}

extension View {
    func chatTextSelection(_ enabled: Bool) -> some View { modifier(ChatTextSelection(enabled: enabled)) }
}

/// Whether the top-level blocks of the scope `ChatRenderProbe` watches were last drawn selectable, by `"<index>#<content hash>"`.
@MainActor
enum ChatSelectionProbe {
    private(set) static var selectable: [String: Bool] = [:]

    static func drawn(index: Int, block: MarkdownBlock, selectable value: Bool, in context: ChatRowContext?) {
        guard ChatRenderProbe.owns(context) else { return }
        selectable["\(index)#\(block.hashValue)"] = value
    }

    static func reset() { selectable = [:] }
}
