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
            .padding(.leading, CGFloat(row.indent) * LoomTheme.Chat.indentStep)
            .padding(.horizontal, LoomTheme.Chat.columnPadding)
            .frame(maxWidth: LoomTheme.Chat.column)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch row.kind {
        case let .start(date):
            ChatMarkerLine(text: ChatMarkerText.start(date))
        case let .marker(marker, _):
            if case let .notice(text) = marker {
                ChatNoticeView(text: text)
            } else {
                ChatMarkerLine(text: ChatMarkerText.text(marker))
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
            ChatSubagentCardView(entry: entry, context: context)
        case let .plan(entry):
            ChatPlanCardView(entry: entry, open: row.open, flags: row.flags, rowID: row.id, context: context)
        case let .request(entry):
            ChatRequestLineView(entry: entry)
        case let .raw(entry):
            ChatRawRecordView(entry: entry, open: row.open, rowID: row.id, context: context)
        case let .turnFold(fold):
            ChatTurnFoldView(fold: fold, open: row.open, rowID: row.id, context: context)
        case let .changedFiles(card):
            ChatChangedFilesCard(card: card)
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
        case let .face(face):
            return face == .continuedInTerminal ? "Continued in Terminal" : "Back in Chat"
        case let .notice(text):
            return text
        }
    }

    static func tokens(_ count: Int) -> String {
        count >= 1000 ? "\(Int((Double(count) / 1000).rounded()))k" : "\(count)"
    }
}

// MARK: Markers

/// A hairline with a centred label.
struct ChatMarkerLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(text).font(LoomTheme.Chat.markerText).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                .layoutPriority(1)
            line
        }
        .frame(height: LoomTheme.Chat.markerHeight)
        .accessibilityElement(children: .combine)
    }

    private var line: some View { Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline) }
}

/// Output of a local command or a system notice (`/context`, a finished background task).
struct ChatNoticeView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").font(LoomTheme.Chat.rowIcon).foregroundStyle(LoomTheme.Text.secondaryStyle)
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
    @State private var hovering = false

    private var prompt: UserPrompt? { if case let .user(prompt) = entry.body { prompt } else { nil } }

    var body: some View {
        if let prompt {
            VStack(alignment: .trailing, spacing: 2) {
                bubble(prompt)
                footer(prompt)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 4)
            .onHover { hovering = $0 }
        }
    }

    private func bubble(_ prompt: UserPrompt) -> some View {
        let collapsed = Self.isLong(prompt.text) && !open
        return VStack(alignment: .leading, spacing: 8) {
            if !prompt.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(prompt.images.enumerated()), id: \.offset) { _, image in
                        ChatThumbnail(image: image, context: context)
                    }
                }
            }
            if !prompt.text.isEmpty {
                Text(verbatim: prompt.text)
                    .font(prompt.command != nil ? LoomTheme.Chat.readingMono : LoomTheme.Chat.reading)
                    .lineSpacing(LoomTheme.Chat.readingLineSpacing)
                    .foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(collapsed ? LoomTheme.Chat.userCollapsedLines : nil)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Self.isLong(prompt.text) {
                Button(open ? "Show less" : "Show full message") { context.toggle(entry.id) }
                    .buttonStyle(.plain).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Accent.high)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(userShape.fill(LoomTheme.Chat.userFill))
        .overlay(userShape.strokeBorder(LoomTheme.Chat.userStroke, lineWidth: LoomTheme.Line.hairline))
        // Dimmed until the CLI has it (`queued`); after that it looks normal and only the mark says it waits (spec).
        .opacity(prompt.delivery == .pending ? 0.6 : 1)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var userShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: .init(topLeading: LoomTheme.Chat.userRadius, bottomLeading: LoomTheme.Chat.userRadius,
                                                  bottomTrailing: LoomTheme.Chat.userTailRadius, topTrailing: LoomTheme.Chat.userRadius))
    }

    /// The time and Copy on hover, or what became of a message that was not read.
    @ViewBuilder private func footer(_ prompt: UserPrompt) -> some View {
        HStack(spacing: 8) {
            switch prompt.delivery {
            case .notDelivered:
                Text("Not delivered").foregroundStyle(LoomTheme.Status.failureLight)
                switch prompt.followUp {
                case .sentAgain?: Text("Sent again below").foregroundStyle(LoomTheme.Text.secondaryStyle)
                case .handedBack?: Text("Back where you wrote it").foregroundStyle(LoomTheme.Text.secondaryStyle)
                case nil: EmptyView()
                }
                if context.canReadNow, prompt.followUp == nil {
                    ChatLinkButton(title: "Retry") { context.retry(entry.id) }
                    ChatCopyButton(text: prompt.text, context: context)
                }
            case .cancelled:
                Text("Withdrawn before Claude read it").foregroundStyle(LoomTheme.Text.secondaryStyle)
            case .pending:
                EmptyView()
            case .queued:
                // Only a message sent while a turn ran waits for its step; an idle send's echo is just a moment away.
                if prompt.sentWhileWorking {
                    Text("Waiting for the current step").foregroundStyle(LoomTheme.Text.secondaryStyle)
                    if context.canReadNow { ChatLinkButton(title: "Read now") { context.readNow(entry.id) } }
                }
            case .read:
                if hovering {
                    if let time = entry.timestamp { Text(ChatTime.label(for: time)).foregroundStyle(LoomTheme.Text.secondaryStyle) }
                    ChatCopyButton(text: prompt.text, context: context)
                }
            }
        }
        .font(LoomTheme.Chat.meta)
        .frame(height: 16)
    }

    static func isLong(_ text: String) -> Bool {
        text.count > LoomTheme.Chat.userCollapseCharacters
            || text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + 1 > LoomTheme.Chat.userCollapseLines
    }
}

/// A small text button of a row's footer (Retry, Read now).
struct ChatLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Accent.high)
            .frame(minHeight: 18)
            .accessibilityIdentifier("chat-row-" + title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

/// Copy, with "Copied" for 1.2 s.
struct ChatCopyButton: View {
    let text: String
    let context: ChatRowContext
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            context.copy(text)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(LoomTheme.Chat.copiedDuration))
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(LoomTheme.Chat.chevron)
                Text(copied ? "Copied" : label)
            }
        }
        .buttonStyle(.plain)
        .font(LoomTheme.Chat.meta)
        .foregroundStyle(LoomTheme.Text.secondaryStyle)
        .frame(minWidth: 24, minHeight: 18)
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

struct ChatThoughtLineView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles").font(LoomTheme.Chat.rowIcon).frame(width: LoomTheme.Chat.iconSlot)
            Text(verbatim: text).italic().lineLimit(LoomTheme.Chat.thoughtLineLimit).fixedSize(horizontal: false, vertical: true)
        }
        .font(LoomTheme.Chat.toolLabel)
        .foregroundStyle(LoomTheme.Text.secondaryStyle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thinking: \(text)")
    }
}

struct ChatRequestLineView: View {
    let entry: ChatEntry

    var body: some View {
        if case let .request(record) = entry.body {
            HStack(spacing: 8) {
                Image(systemName: icon(record.kind)).font(LoomTheme.Chat.rowIcon).frame(width: LoomTheme.Chat.iconSlot)
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
                    .frame(maxHeight: LoomTheme.Chat.bodyMaxHeight)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).fill(LoomTheme.Chat.outputFill))
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
        Image(systemName: "chevron.right").font(LoomTheme.Chat.chevron)
            .rotationEffect(.degrees(open ? 90 : 0))
            .foregroundStyle(LoomTheme.Text.secondaryStyle)
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
