import AppKit
import LoomChat
import LoomCore
import SwiftUI

/// One row of the stream, drawn inside a table cell. The reading column is centred; each kind lives in its own view.
struct ChatRowView: View {
    let row: ChatRow
    let context: ChatRowContext
    /// The row is being measured, not drawn: a body whose height does not depend on its text (a long, scrolling output)
    /// may stand in a short text, so measuring never lays out megabytes.
    var measuring = false

    var body: some View {
        content
            .environment(\.chatMeasuring, measuring)
            .padding(.leading, ChatRowGeometry.foldInset(row.foldGuide))
            .chatTree(row.foldGuide.map { .fold($0) })
            .padding(.horizontal, context.columnPadding)
            .frame(maxWidth: ChatRowGeometry.column)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch row.kind {
        case let .start(date):
            ChatMarkerLine(text: ChatMarkerText.start(date))
        case let .marker(marker, date):
            switch marker {
            case let .notice(text): ChatNoticeView(text: text)
            case let .rewound(rewound): ChatRewoundMarkerView(marker: rewound, date: date, context: context)
            default: ChatMarkerLine(text: ChatMarkerText.text(marker))
            }
        case let .divider(text):
            ChatMarkerLine(text: text)
        case let .user(entry):
            ChatUserMessageView(entry: entry, open: row.open, context: context)
        case let .prose(entry, settled):
            ChatProseView(entry: entry, settled: settled, flags: row.flags, context: context)
        case let .thinking(entry):
            ChatThinkingView(entry: entry, open: row.open, rowID: row.id, context: context)
        case let .tool(entry):
            ChatToolRowView(row: row, entry: entry, context: context)
        case let .group(group):
            ChatGroupRowView(group: group, open: row.open, rowID: row.id, context: context)
        case let .subagent(entry):
            ChatSubagentCardView(entry: entry, header: row.agentsHeader, context: context)
        case let .plan(entry):
            ChatPlanCardView(entry: entry, open: row.open, flags: row.flags, rowID: row.id, context: context)
        case let .request(entry):
            ChatRequestLineView(entry: entry)
        case let .raw(entry):
            ChatRawRecordView(entry: entry, open: row.open, rowID: row.id, context: context)
        case let .turnFold(fold):
            ChatTurnFoldView(fold: fold, open: row.open, rowID: row.id, context: context)
        case let .changedFiles(card):
            ChatChangedFilesCard(card: card, context: context)
        case let .thought(text):
            ChatThoughtLineView(text: text)
        case let .live(live):
            ChatLiveRowView(live: live, open: row.open, rowID: row.id, context: context)
        case .empty:
            Text("Nothing to show yet. Messages appear here as the session writes them.")
                .font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }
}

/// The widths `ChatRowView` lays a row out with, in one place: the measurer works out a prose row's content width from the
/// same numbers the view pads and frames it with (`ChatStreamMeasureTests` fails when the two drift apart).
enum ChatRowGeometry {
    /// The widest a row is.
    static let column = LoomTheme.Chat.column

    /// The space a row hanging on an open turn fold's guide leaves for it.
    static func foldInset(_ guide: ChatTreePosition?) -> CGFloat {
        guide == nil ? 0 : LoomTheme.Chat.Tree.foldIndent
    }

    /// The width a row's content is laid out at, in a table `rowWidth` wide.
    static func contentWidth(rowWidth: CGFloat, columnPadding: CGFloat, foldGuide: ChatTreePosition?) -> CGFloat {
        max(0, min(rowWidth, column) - 2 * columnPadding - foldInset(foldGuide))
    }
}

// MARK: Text of markers

enum ChatMarkerText {
    static func start(_ date: Date?) -> String {
        guard let date else { return "Session started" }
        return "Session started \u{00B7} " + ChatTime.label(for: date)
    }

    /// A mode as the CLI reports it, under Loom's name. `dontAsk` is what Ask runs on, and Loom does not start the Chat face in
    /// that mode for any other reason.
    static func modeName(_ raw: String) -> String {
        raw == ClaudePermissionMode.ask.cliValue ? ClaudePermissionMode.ask.title : ClaudePermissionMode.title(forRaw: raw)
    }

    static func text(_ marker: Marker) -> String {
        switch marker {
        case let .sessionStart(model, mode):
            return (["Session started"] + [model, mode.map(modeName)].compactMap { $0 }).joined(separator: " \u{00B7} ")
        case let .resumed(seconds):
            if let seconds, seconds >= 60 { return "Resumed after \(ChatTime.gap(seconds: seconds))" }
            return "Resumed"
        case let .compaction(_, pre, post):
            if let pre, let post { return "Context compacted \u{00B7} \(tokens(pre)) \u{2192} \(tokens(post)) tokens" }
            return "Context compacted"
        case .reset:
            return "Session cleared"
        case let .interrupted(afterMs):
            return afterMs.map { "You stopped after \(ChatTime.duration(milliseconds: $0))" } ?? "You stopped"
        case let .retry(attempt, maxRetries, _):
            if let attempt, let maxRetries { return "Retrying \u{00B7} attempt \(attempt) of \(maxRetries)" }
            return "Retrying"
        case let .modeChanged(mode):
            return "Mode changed to \(modeName(mode))"
        case let .modelChanged(model):
            return "Model changed to \(model)"
        case .face:
            return "Continued in Terminal"
        case let .notice(text):
            return text
        case let .rewound(rewound):
            return ChatRewoundMarkerView.text(rewound, date: nil)
        }
    }

    static func tokens(_ count: Int) -> String {
        count >= 1000 ? "\(Int((Double(count) / 1000).rounded()))k" : "\(count)"
    }
}

// MARK: Markers

/// A hairline with a centred label in the machine's voice: mono 11, tertiary, 12 from each line.
struct ChatMarkerLine: View {
    let text: String

    var body: some View {
        HStack(spacing: LoomTheme.Chat.markerGap) {
            line
            Text(text).font(LoomTheme.Chat.markerText).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
                .layoutPriority(1)
            line
        }
        .frame(height: LoomTheme.Chat.markerLineHeight)
        .padding(.vertical, LoomTheme.Chat.markerPaddingV)
        .accessibilityElement(children: .combine)
    }

    private var line: some View { Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline) }
}

/// Output of a local command or a system notice (`/context`, a finished background task).
struct ChatNoticeView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            InkIcon(.info, size: LoomTheme.Icon.compact).foregroundStyle(LoomTheme.Text.secondaryStyle)
            Text(text).font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(8).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }
}

// MARK: Your message

struct ChatUserMessageView: View {
    let entry: ChatEntry
    let open: Bool
    let context: ChatRowContext
    /// The row's hover. It lives in an object only the footer reads, so the pointer entering or leaving never evaluates this
    /// view's body, which is where a long message would be measured (`ChatUserText`).
    @State private var hover: ChatRowHover

    init(entry: ChatEntry, open: Bool, context: ChatRowContext, hover: ChatRowHover = ChatRowHover()) {
        self.entry = entry
        self.open = open
        self.context = context
        _hover = State(initialValue: hover)
    }

    private var prompt: UserPrompt? { if case let .user(prompt) = entry.body { prompt } else { nil } }

    /// The evidence run's name for this row: `chat-user:<entry id>`.
    static func highlightKey(_ id: String) -> String { "chat-user:\(id)" }

    var body: some View {
        if let prompt {
            let _ = ChatUserText.bubbleEvaluated(entry.id)
            let long = ChatUserText.isLong(prompt.text)
            VStack(alignment: .trailing, spacing: 0) {
                ChatCappedWidth(fraction: LoomTheme.Chat.userMaxWidthFraction, maximum: LoomTheme.Chat.userMaxWidth) {
                    bubble(prompt, collapsed: long && !open)
                }
                if long {
                    ChatLinkButton(title: open ? "Show Less" : "Show Full Message", prominent: true) { context.toggle(entry.id) }
                        .padding(.top, 4).padding(.trailing, -6)
                }
                ChatUserFooter(entry: entry, prompt: prompt, context: context, hover: hover)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, LoomTheme.Chat.userTopGap)
            .onHover { hover.isOver = $0 }
        }
    }

    /// The one bubble: the fill, no edge, radius 12, padded 9 \u{00D7} 14.
    private func bubble(_ prompt: UserPrompt, collapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !prompt.images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(prompt.images.enumerated()), id: \.offset) { _, image in
                        ChatThumbnail(image: image, context: context)
                    }
                }
            }
            if !prompt.text.isEmpty {
                Text(verbatim: collapsed ? String(ChatUserText.collapsedPrefix(prompt.text)) : prompt.text)
                    .font(prompt.command != nil ? LoomTheme.Chat.readingMono : LoomTheme.Chat.reading)
                    .lineSpacing(LoomTheme.Chat.readingLineSpacing)
                    .foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(collapsed ? LoomTheme.Chat.userCollapsedLines : nil)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // Line spacing falls between lines only; half of it above and below makes every line 22 high, as the reference's.
                    .padding(.vertical, LoomTheme.Chat.readingLineSpacing / 2)
            }
        }
        .padding(.horizontal, LoomTheme.Chat.userPaddingH)
        .padding(.vertical, LoomTheme.Chat.userPaddingV)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.userRadius).fill(LoomTheme.Chat.userFill))
        // Dimmed until the CLI has it (`queued`); after that it looks normal and only the mark says it waits (spec).
        .opacity(prompt.delivery == .pending ? 0.5 : 1)
    }
}

/// The widest a view gets: `fraction` of the width it is offered and at most `maximum`. Your message takes it (80 % of the
/// column, 560 at most), and its own text sets the width below that.
struct ChatCappedWidth: Layout {
    let fraction: CGFloat
    let maximum: CGFloat

    /// The width the content is offered when `width` is offered to this layout.
    static func cap(_ width: CGFloat?, fraction: CGFloat, maximum: CGFloat) -> CGFloat {
        width.map { min($0 * fraction, maximum) } ?? maximum
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: Self.cap(proposal.width, fraction: fraction, maximum: maximum),
                                                   height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
/// What became of your message, or its time, Copy and Rewind Files on hover. One line (26 pt) under the bubble, in 11.5
/// tertiary. It reads the row's hover itself, so a hover evaluates this view and nothing above it.
private struct ChatUserFooter: View {
    let entry: ChatEntry
    let prompt: UserPrompt
    let context: ChatRowContext
    let hover: ChatRowHover

    var body: some View {
        let hovering = hover.isOver || LookEvidence.forcesHover(ChatUserMessageView.highlightKey(entry.id))
        let _ = ChatUserText.footerEvaluated(entry.id)
        HStack(spacing: 6) {
            switch prompt.delivery {
            case .notDelivered:
                Group {
                    Text("Not delivered")
                    switch prompt.followUp {
                    case .sentAgain?: separator; Text("Sent again below")
                    case .handedBack?: separator; Text("Back where you wrote it")
                    case nil: EmptyView()
                    }
                }
                .foregroundStyle(LoomTheme.Status.failureLight)
                if context.canReadNow, prompt.followUp == nil {
                    ChatLinkButton(title: "Retry") { context.retry(entry.id) }
                    ChatCopyButton(text: prompt.text, context: context, showsIcon: false)
                }
            case .cancelled:
                Text("Withdrawn before Claude read it")
            case .pending:
                EmptyView()
            case .queued:
                // Only a message sent while a turn ran waits for its step; an idle send's echo is just a moment away.
                if prompt.sentWhileWorking {
                    Text("Sent while Claude worked")
                    separator
                    Text("Waiting for the current step")
                    if context.canReadNow { ChatLinkButton(title: "Read Now", prominent: true) { context.readNow(entry.id) } }
                }
            case .read:
                if hovering {
                    if let time = entry.timestamp {
                        Text(ChatTime.label(for: time)).font(LoomTheme.Chat.timeMono).padding(.horizontal, 4)
                    }
                    ChatCopyButton(text: prompt.text, context: context, iconOnly: true)
                    ChatRewindButton(state: ChatRewindAction.state(for: entry, availability: context.rewind.availability)) {
                        context.rewindFiles(entry.id)
                    }
                }
            }
        }
        .font(LoomTheme.Chat.meta)
        .foregroundStyle(LoomTheme.Text.tertiaryStyle)
        .lineLimit(1)
        .frame(height: LoomTheme.Chat.userFooterHeight)
        .padding(.trailing, -6)
    }

    private var separator: some View { Text("\u{00B7}").foregroundStyle(LoomTheme.Text.faint) }
}

/// A small link of a row or a card (the reference's `lk2`): 22 pt, radius 6, 11.5 medium, secondary and primary under the
/// pointer, or the accent for the one action a row leads to. The hover is its own, so a hover redraws this button only.
struct ChatLinkButton: View {
    let title: String
    var symbol: String?
    /// A chevron after the title ("Open in Changes").
    var chevron = false
    /// The accent: the action the row leads to (Read Now, Show Full Message).
    var prominent = false
    /// The accessibility identifier is derived from the title (the evidence run and tests find the button by it).
    var identified = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LoomTheme.Space.detailSpacing) {
                if let symbol { InkIcon(systemName: symbol, size: LoomTheme.Icon.compact) }
                Text(title)
                if chevron { InkIcon(.chevronRight, size: LoomTheme.Icon.tiny) }
            }
            .lineLimit(1)
        }
            .buttonStyle(ControlButtonStyle(kind: prominent ? .link : .ghost, size: .small))
            .modifier(Identified(id: identified ? "chat-row-" + title.lowercased().replacingOccurrences(of: " ", with: "-") : nil))
    }

    private struct Identified: ViewModifier {
        let id: String?

        func body(content: Content) -> some View {
            if let id { content.accessibilityIdentifier(id) } else { content }
        }
    }
}

/// The look of a link: shared by `ChatLinkButton` and the buttons that keep their own state (Copy).
struct ChatLinkLabel: View {
    let title: String
    var symbol: String?
    var chevron = false
    var prominent = false
    let hovering: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { InkIcon(systemName: symbol, size: LoomTheme.Icon.compact) }
            Text(title)
            if chevron { InkIcon(.chevronRight, size: LoomTheme.Icon.tiny) }
        }
        .font(LoomTheme.Chat.linkLabel)
        .foregroundStyle(prominent ? AnyShapeStyle(LoomTheme.Accent.high)
                         : hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: LoomTheme.Chat.linkHeight)
        .background(RowHighlight(state: hovering ? .hover : .none, radius: LoomTheme.InkRadius.control))
        .contentShape(Rectangle())
    }
}

/// An icon-only button of a row (22 pt, the reference's `ib sm`).
struct ChatIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            InkIcon(systemName: symbol, size: LoomTheme.Icon.body)
                .foregroundStyle(hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .frame(width: LoomTheme.Chat.linkHeight, height: LoomTheme.Chat.linkHeight)
                .background(RowHighlight(state: hovering ? .hover : .none, radius: LoomTheme.InkRadius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Copy, with "Copied" for 1.2 s: a link with the copy glyph, or the glyph alone.
struct ChatCopyButton: View {
    let text: String
    let context: ChatRowContext
    var label = "Copy"
    var showsIcon = true
    var iconOnly = false
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            context.copy(text)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(LoomTheme.Chat.copiedDuration))
                copied = false
            }
        } label: {
            if iconOnly {
                InkIcon(copied ? .check : .copy, size: LoomTheme.Icon.body)
                    .foregroundStyle(hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                    .frame(width: LoomTheme.Chat.linkHeight, height: LoomTheme.Chat.linkHeight)
                    .background(RowHighlight(state: hovering ? .hover : .none, radius: LoomTheme.InkRadius.control))
                    .contentShape(Rectangle())
            } else {
                ChatLinkLabel(title: copied ? "Copied" : label, symbol: showsIcon ? (copied ? "checkmark" : "doc.on.doc") : nil,
                              hovering: hovering)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// An image block as a thumbnail; a click opens it in Quick Look.
struct ChatThumbnail: View {
    let image: ImageRef
    let context: ChatRowContext

    var body: some View {
        if let picture = ChatImages.thumbnail(image) {
            Button { context.openImage(image) } label: {
                Image(nsImage: picture).resizable().scaledToFill()
                    .frame(width: LoomTheme.Chat.thumbnail.width, height: LoomTheme.Chat.thumbnail.height).clipShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
            }
            .buttonStyle(.plain).accessibilityLabel("Image")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "photo").font(LoomTheme.Chat.rowIcon)
                Text("Image").font(LoomTheme.Chat.meta)
            }
            .foregroundStyle(LoomTheme.Text.secondaryStyle)
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).fill(LoomTheme.Surface.control))
        }
    }
}

// MARK: Small rows

/// Claude's latest thought above the live row (Normal view): italic 12.5 / 19 in tertiary, 21 in, cut after 4 lines.
struct ChatThoughtLineView: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(LoomTheme.Chat.thoughtText).italic()
            .lineSpacing(LoomTheme.Chat.thoughtLineSpacing)
            .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            .lineLimit(LoomTheme.Chat.thoughtLineLimit).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, LoomTheme.Chat.thoughtLineSpacing / 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, LoomTheme.Chat.thoughtInset)
            .padding(.top, 12).padding(.bottom, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Thinking: \(text)")
    }
}

struct ChatRequestLineView: View {
    let entry: ChatEntry

    var body: some View {
        if case let .request(record) = entry.body {
            HStack(spacing: 8) {
                InkIcon(systemName: icon(record.kind), size: LoomTheme.Icon.compact).frame(width: LoomTheme.Chat.iconSlot)
                Text(verbatim: record.summary).font(LoomTheme.Chat.toolLabel).lineLimit(2)
            }
            .foregroundStyle(LoomTheme.Text.secondaryStyle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func icon(_ kind: RequestRecord.Kind) -> String {
        switch kind {
        case .approval: "checkmark.shield"
        case .question: "questionmark.circle"
        case .plan: "list.bullet.rectangle"
        }
    }
}

/// A record this build does not know: one collapsed line, the JSON on a click.
struct ChatRawRecordView: View {
    let entry: ChatEntry
    let open: Bool
    let rowID: String
    let context: ChatRowContext

    var body: some View {
        if case let .unknown(raw) = entry.body {
            VStack(alignment: .leading, spacing: 0) {
                Button { context.toggle(rowID) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.square.dashed").font(LoomTheme.Chat.rowIcon).frame(width: LoomTheme.Chat.iconSlot)
                        Text(verbatim: Self.title(raw)).font(LoomTheme.Chat.toolLabel).lineLimit(1)
                        Spacer(minLength: 0)
                        ChatChevron(open: open)
                    }
                    .frame(height: LoomTheme.Chat.workRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LoomTheme.Text.secondaryStyle)
                if open {
                    ScrollView(.vertical) {
                        Text(verbatim: Self.detail(raw)).font(LoomTheme.Chat.metaMono).foregroundStyle(LoomTheme.Chat.output)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .frame(maxHeight: LoomTheme.Chat.outputMaxHeight)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius).fill(LoomTheme.Chat.outputFill))
                    .padding(.bottom, 4)
                }
            }
        }
    }

    static func title(_ raw: RawRecord) -> String {
        switch raw.reason {
        case .oversized: return "Record too large to show \u{00B7} \(ChatBytes.text(raw.byteCount))"
        case .malformed: return "Record that is not JSON"
        case .unknownType:
            let kind = [raw.type, raw.subtype].compactMap { $0 }.joined(separator: " \u{00B7} ")
            return kind.isEmpty ? "Unrecognised record" : "Unrecognised record \u{00B7} \(kind)"
        }
    }

    static func detail(_ raw: RawRecord) -> String {
        switch raw.reason {
        case .oversized: "This record is \(ChatBytes.text(raw.byteCount)); it was not read."
        default: raw.json + (raw.isTruncated ? "\n\u{2026}" : "")
        }
    }
}

private struct ChatMeasuringKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatMeasuring: Bool {
        get { self[ChatMeasuringKey.self] }
        set { self[ChatMeasuringKey.self] = newValue }
    }
}

enum ChatText {
    /// Lines in a text (a trailing text without a break counts as one), by one pass over the bytes.
    static func lineCount(_ text: String) -> Int {
        var count = 1
        for byte in text.utf8 where byte == 10 { count += 1 }
        return count
    }

    /// The last `count` lines, found from the end.
    static func lastLines(_ text: String, _ count: Int) -> String {
        var breaks = 0
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == "\n" {
                breaks += 1
                if breaks == count { return String(text[index...]) }
            }
            index = previous
        }
        return text
    }
}

enum ChatBytes {
    static func text(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The chevron of a row that opens: right when closed, down when open.
struct ChatChevron: View {
    let open: Bool

    var body: some View {
        InkIcon(.chevronRight, size: LoomTheme.Icon.tiny)
            .rotationEffect(.degrees(open ? 90 : 0))
            .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            .frame(width: 14)
            .accessibilityHidden(true)
    }
}

/// Image data to thumbnails (small, cached).
@MainActor
enum ChatImages {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func image(_ ref: ImageRef) -> NSImage? {
        guard let data = ref.data else { return nil }
        // The key is cheap: the length and both ends of the base64 text, never a hash of all of it on every render.
        let key = "\(data.utf8.count)#\(data.prefix(48))#\(data.suffix(48))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let bytes = Data(base64Encoded: data, options: .ignoreUnknownCharacters), let image = NSImage(data: bytes) else { return nil }
        cache.setObject(image, forKey: key, cost: bytes.count)
        return image
    }

    static func thumbnail(_ ref: ImageRef) -> NSImage? { image(ref) }
}
