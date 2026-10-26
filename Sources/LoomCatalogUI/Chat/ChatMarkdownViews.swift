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
/// block keeps the index it has in the whole message (the wrap flag and Copy use it). A long fence open at the end follows
/// the tail as one code block whose settled chunks are not drawn again (`ChatContent.OpenFence`).
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
                if let fence = parts.fence {
                    ChatCodeBlockView(fence: fence, flags: flags, rowID: rowID, context: context)
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
        // Not selectable while the answer streams: selectable text is a key view each, and the stream's every flush makes
        // AppKit and SwiftUI walk them again for the key view loop. Selection returns when the answer finishes.
        ChatMarkdownView(blocks: blocks, flags: flags, rowID: rowID, isStreaming: false, selectable: false, context: context)
    }
}

/// The type a list of Markdown blocks is drawn in: the Chat's reading size, or a smaller scale a narrower surface injects (the
/// Agents tab's transcript, FB6-18).
struct ChatMarkdownScale {
    var reading: Font = LoomTheme.Chat.reading
    var lineSpacing: CGFloat = LoomTheme.Chat.readingLineSpacing
    var heading1: Font = LoomTheme.Chat.heading1
    var heading2: Font = LoomTheme.Chat.heading2
    var heading3: Font = LoomTheme.Chat.heading3
}

private struct ChatMarkdownScaleKey: EnvironmentKey {
    static let defaultValue = ChatMarkdownScale()
}

extension EnvironmentValues {
    var chatMarkdownScale: ChatMarkdownScale {
        get { self[ChatMarkdownScaleKey.self] }
        set { self[ChatMarkdownScaleKey.self] = newValue }
    }
}

/// A list of blocks. Links open only when they are web or mail links.
struct ChatMarkdownView: View {
    let blocks: [MarkdownBlock]
    let flags: Set<String>
    let rowID: String
    var isStreaming = false
    /// Whether its text may be selected; an open (streaming) block never is.
    var selectable = true
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
                                      flags: flags, rowID: rowID, isStreaming: isStreaming, selectable: selectable, context: context,
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
    var selectable = true
    let context: ChatRowContext
    /// A block of the message's own list, not one inside a list item or a quote: the render probe counts its evaluations.
    var isTopLevel = false
    @Environment(\.chatMarkdownScale) private var scale

    var body: some View {
        let _ = isTopLevel ? ChatRenderProbe.blockBody(index: index, block: block, in: context) : ()
        let _ = isTopLevel ? ChatSelectionProbe.drawn(index: index, block: block, selectable: takesSelection, in: context) : ()
        blockView(block, index: index, isLast: isLast)
    }

    private var takesSelection: Bool { selectable && !isStreaming }

    @ViewBuilder private func blockView(_ block: MarkdownBlock, index: Int, isLast: Bool) -> some View {
        switch block {
        case let .paragraph(source):
            inline(source)
        case let .heading(level, text):
            Text(ChatContent.inline(text, in: context))
                .font(level <= 1 ? scale.heading1 : level == 2 ? scale.heading2 : scale.heading3)
                .foregroundStyle(LoomTheme.Text.primary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatTextSelection(takesSelection)
        case let .code(language, code, closed):
            ChatCodeBlockView(language: language, code: code, isStreaming: isStreaming && isLast && !closed,
                              wrapped: flags.contains("wrap:\(index)"), index: index, context: context, selectable: takesSelection) {
                context.toggleFlag(rowID, "wrap:\(index)")
            }
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + position, checked: item.checked)
                        ChatMarkdownView(blocks: item.blocks, flags: flags, rowID: rowID, isStreaming: isStreaming, selectable: selectable, context: context,
                                         topIndex: index)
                    }
                }
            }
        case let .quote(inner):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim).fill(LoomTheme.Chat.quoteBar).frame(width: LoomTheme.Chat.quoteBarWidth)
                ChatMarkdownView(blocks: inner, flags: flags, rowID: rowID, isStreaming: isStreaming, selectable: selectable, context: context, topIndex: index)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(table):
            ChatMarkdownTableView(table: table, context: context, selectable: takesSelection)
        case .rule:
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).padding(.vertical, 4)
        }
    }

    private func inline(_ source: String) -> some View {
        Text(ChatContent.inline(source, in: context))
            .font(scale.reading)
            .lineSpacing(scale.lineSpacing)
            .foregroundStyle(LoomTheme.Text.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chatTextSelection(takesSelection)
    }

    @ViewBuilder private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        Group {
            if let checked {
                Image(systemName: checked ? "checkmark.square" : "square").font(LoomTheme.Chat.rowIcon)
            } else if ordered {
                Text("\(number).").font(scale.reading).monospacedDigit()
            } else {
                Text("\u{2022}").font(scale.reading)
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
/// tertiary, a wrap toggle and Copy) over the code in 12.5 / 20; the code scrolls sideways unless it wraps. Copy is there once
/// the block is no longer streaming. A long fence that is still open draws its settled chunks, each kept as it was drawn, and
/// the lines after them as one text cut in pieces (`ChatCodePieces`); a settled block is one text.
struct ChatCodeBlockView: View {
    let language: String?
    /// Settled chunks of the code, drawn before `code`; empty for a block drawn whole.
    var chunks: [String] = []
    /// The code, or the lines after the chunks; nil when none of them has come.
    let code: String?
    let isStreaming: Bool
    let wrapped: Bool
    let index: Int
    let context: ChatRowContext
    var selectable = true
    let toggleWrap: () -> Void

    init(language: String?, chunks: [String] = [], code: String?, isStreaming: Bool, wrapped: Bool, index: Int = 0,
         context: ChatRowContext, selectable: Bool = true, toggleWrap: @escaping () -> Void) {
        self.language = language
        self.chunks = chunks
        self.code = code
        self.isStreaming = isStreaming
        self.wrapped = wrapped
        self.index = index
        self.context = context
        self.selectable = selectable
        self.toggleWrap = toggleWrap
    }

    /// The open fence of a streaming message, drawn in chunks.
    init(fence: ChatContent.OpenFence, flags: Set<String>, rowID: String, context: ChatRowContext) {
        self.init(language: fence.language, chunks: fence.chunks, code: fence.open, isStreaming: true,
                  wrapped: flags.contains("wrap:\(fence.index)"), index: fence.index, context: context, selectable: false) {
            context.toggleFlag(rowID, "wrap:\(fence.index)")
        }
    }

    var body: some View {
        let _ = ChatSelectionProbe.codeBlockDrawn(index: index, chunks: chunks.count, offersCopy: !isStreaming, in: context)
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(verbatim: language ?? "text").font(LoomTheme.Chat.timeMono).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                Spacer(minLength: 0)
                ChatIconButton(symbol: wrapped ? "text.alignleft" : "arrow.turn.down.left",
                               label: wrapped ? "Do not wrap lines" : "Wrap lines", action: toggleWrap)
                // Held in place while the block streams, so the header does not move when Copy comes.
                if isStreaming {
                    ChatCopyButton(text: "", context: context).hidden()
                } else {
                    ChatCopyButton(text: chunks.isEmpty ? code ?? "" : ([chunks.joined(separator: "\n")] + (code.map { [$0] } ?? [])).joined(separator: "\n"),
                                   context: context)
                }
            }
            .padding(.leading, LoomTheme.Chat.outputPaddingH).padding(.trailing, 4)
            .frame(height: LoomTheme.Chat.codeHeaderHeight)
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
            if wrapped {
                lines.padding(Self.codePadding).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    lines.padding(Self.codePadding).fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius).fill(LoomTheme.Chat.cardFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius))
    }

    static var codePadding: EdgeInsets {
        EdgeInsets(top: LoomTheme.Chat.codePaddingTop, leading: LoomTheme.Chat.codePaddingH,
                   bottom: LoomTheme.Chat.codePaddingBottom, trailing: LoomTheme.Chat.codePaddingH)
    }

    @ViewBuilder private var lines: some View {
        if chunks.isEmpty {
            if let code {
                ChatCodeLines(code: code, colored: ChatHighlighter.highlighted(code, language: language, isStreaming: isStreaming),
                              selectable: selectable)
            }
        } else {
            // An open fence's settled chunks are drawn as the open lines are: plain, and not selectable while it streams.
            ChatCodePieces {
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    ChatCodeLines(code: chunk, selectable: selectable).equatable()
                }
                if let code { ChatCodeLines(code: code, selectable: selectable) }
            }
        }
    }
}

/// Lines of code in 12.5 / 20.
struct ChatCodeLines: View, Equatable {
    let code: String
    var colored: AttributedString?
    let selectable: Bool

    var body: some View {
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

    /// A text's line fragment is the font's line height rounded up, and the lines are that plus the spacing apart.
    static let fragment = (LoomTheme.Chat.bodyLineHeight - LoomTheme.Chat.codeLineSpacing).rounded(.up)
    static let pitch = fragment + LoomTheme.Chat.codeLineSpacing

    /// The visual lines of a `ChatCodeLines` of this height: a text is as high as its lines, rounded up on its own.
    static func lines(height: CGFloat) -> Int { max(1, Int((height / pitch).rounded())) }

    /// The height of one `ChatCodeLines` holding these lines: what pieces of these heights stack to (`ChatCodePieces`).
    static func height(lines: Int) -> CGFloat {
        (CGFloat(lines) * fragment + CGFloat(lines - 1) * LoomTheme.Chat.codeLineSpacing).rounded(.up) + LoomTheme.Chat.codeLineSpacing
    }
}

/// Pieces of one code text, stacked a line pitch apart from the lines they hold rather than by their own heights: each
/// text's height is rounded up on its own, and the stack is as high as one text of all their lines, rounded once. So an
/// open fence drawn in chunks is as high as the same lines in one text.
struct ChatCodePieces: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let lines = sizes.reduce(0) { $0 + ChatCodeLines.lines(height: $1.height) }
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.isEmpty ? 0 : ChatCodeLines.height(lines: lines))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: proposal.width, height: size.height))
            y += CGFloat(ChatCodeLines.lines(height: size.height)) * ChatCodeLines.pitch
        }
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

/// For the scope `ChatRenderProbe` watches: whether its top-level blocks were last drawn selectable, by
/// `"<index>#<content hash>"`, and how its code blocks were last drawn, by index.
@MainActor
enum ChatSelectionProbe {
    struct CodeBlock: Equatable {
        var chunks: Int
        var offersCopy: Bool
    }

    private(set) static var selectable: [String: Bool] = [:]
    private(set) static var codeBlocks: [Int: CodeBlock] = [:]

    static func drawn(index: Int, block: MarkdownBlock, selectable value: Bool, in context: ChatRowContext?) {
        guard ChatRenderProbe.owns(context) else { return }
        selectable["\(index)#\(block.hashValue)"] = value
    }

    static func codeBlockDrawn(index: Int, chunks: Int, offersCopy: Bool, in context: ChatRowContext?) {
        guard ChatRenderProbe.owns(context) else { return }
        codeBlocks[index] = CodeBlock(chunks: chunks, offersCopy: offersCopy)
    }

    static func reset() {
        selectable = [:]
        codeBlocks = [:]
    }
}
