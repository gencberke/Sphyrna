import LoomChat
import LoomCore
import SwiftUI

extension View {
    /// A work row's line (DESIGN §7): 26 pt, its pill hanging `workRowPaddingH` outside the column so the icon stands on the
    /// column's edge; `indent` steps in the content (the steps of an open group), not the pill.
    func chatWorkLine(pill: HighlightState, indent: Int = 0) -> some View {
        padding(.leading, LoomTheme.Chat.workRowPaddingH + CGFloat(indent) * LoomTheme.Chat.indentStep)
            .padding(.trailing, LoomTheme.Chat.workRowPaddingH)
            .frame(height: LoomTheme.Chat.workRowHeight)
            .background(RowHighlight(state: pill, radius: LoomTheme.Chat.workRowRadius))
            .contentShape(Rectangle())
            .padding(.horizontal, -LoomTheme.Chat.workRowPaddingH)
    }
}

// MARK: Tool row

/// One quiet line per tool, 26 pt: the icon, the verb in secondary and its subject in mono, the counts, the time on hover and a
/// chevron when there is a body. Success is quiet, failure is loud (a failure dot, the row in primary, the exit code). A click
/// opens the body inline.
struct ChatToolRowView: View {
    let row: ChatRow
    let entry: ChatEntry
    let context: ChatRowContext

    private var call: ToolCall? { if case let .tool(call) = entry.body { call } else { nil } }

    var body: some View {
        if let call {
            let label = ChatWork.label(for: call, workingDirectory: context.workingDirectory)
            VStack(alignment: .leading, spacing: 0) {
                ChatToolHeader(call: call, label: label, row: row, context: context)
                if row.open {
                    ChatToolBody(call: call, label: label, row: row, entry: entry, context: context)
                        .padding(.leading, LoomTheme.Chat.bodyInset + CGFloat(row.indent) * LoomTheme.Chat.indentStep)
                        .padding(.top, LoomTheme.Chat.bodyTop)
                        .padding(.bottom, LoomTheme.Chat.bodyBottom)
                }
            }
            .chatTree(row.branch.map { .step($0) })
        }
    }

    static func timeText(_ call: ToolCall, _ start: Date) -> String {
        var text = ChatTime.label(for: start)
        if let end = call.endedAt, end.timeIntervalSince(start) >= 1 { text += " \u{00B7} " + ChatTime.duration(seconds: end.timeIntervalSince(start)) }
        return text
    }

    static func accessibilityText(_ call: ToolCall, _ label: ChatWork.Label) -> String {
        var text = ChatWork.sentence(label, running: call.status == .running)
        switch call.status {
        case .failed: text += ", failed"
        case .denied: text += ", denied"
        case .refusedInAsk: text += ", not allowed in Ask"
        case .interrupted: text += ", stopped"
        default: break
        }
        return text
    }
}

/// The line of a tool row. The pointer is its own state, so a hover redraws this line (its pill, its colours, its time) and not
/// the body under it.
private struct ChatToolHeader: View {
    let call: ToolCall
    let label: ChatWork.Label
    let row: ChatRow
    let context: ChatRowContext
    @State private var hovering = false

    var body: some View {
        let running = call.status == .running
        let loud = call.status == .failed || call.status == .denied
        let style = hovering || loud ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)
        Button { context.toggle(row.id) } label: {
            HStack(spacing: 8) {
                ChatToolIcon(status: call.status, symbol: label.symbol, animates: context.animates)
                Text(label.verbPhrase(running: running))
                    .font(LoomTheme.Chat.toolLabel)
                    .fixedSize()
                if !label.subject.isEmpty {
                    Text(verbatim: label.subject)
                        .font(label.mono ? LoomTheme.Chat.toolMono : LoomTheme.Chat.toolLabel)
                        .lineLimit(1)
                        .truncationMode(label.mono ? .middle : .tail)
                }
                Spacer(minLength: 8)
                trailing
                if ChatToolBody.hasBody(call, label: label) { ChatChevron(open: row.open) }
            }
            .foregroundStyle(style)
            .chatWorkLine(pill: hovering ? .hover : .none, indent: row.indent)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(ChatToolRowView.accessibilityText(call, label))
        .accessibilityValue(row.open ? "expanded" : "collapsed")
    }

    @ViewBuilder private var trailing: some View {
        if let changes = call.changes {
            ChatChangeCounts(added: changes.added, removed: changes.removed)
        }
        if call.status == .failed, let code = call.exitCode {
            Text("Exit code \(code)").font(LoomTheme.Chat.metaMono).foregroundStyle(LoomTheme.Status.failureLight)
        } else if call.status == .denied {
            Text("Denied").font(LoomTheme.Chat.metaMono).foregroundStyle(LoomTheme.Status.failureLight)
        } else if call.status == .refusedInAsk {
            Text("Not allowed in Ask").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
        } else if call.status == .interrupted {
            Text("Stopped").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
        }
        if let time = call.startedAt {
            Text(ChatToolRowView.timeText(call, time)).font(LoomTheme.Chat.timeMono).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .opacity(hovering ? 1 : 0)
        }
    }
}

extension ChatWork.Label {
    /// The verb with its trailing space handled by the row's stack.
    func verbPhrase(running: Bool) -> String { running ? verbRunning : verb }
}

/// The status glyph of a tool row: the working spinner while it runs, a failure dot when it failed or was denied, a plain
/// icon (14 in a 16 slot, tertiary) otherwise.
struct ChatToolIcon: View {
    let status: ToolCall.Status
    let symbol: String
    let animates: Bool

    var body: some View {
        Group {
            switch status {
            case .running:
                BrailleSpinner(animating: animates, style: .subagent)
            case .failed, .denied:
                IndicatorView(indicator: .failed(nil))
            case .refusedInAsk:
                Image(systemName: "bubble.left").font(LoomTheme.Chat.workIcon).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            case .interrupted:
                Image(systemName: "stop.circle").font(LoomTheme.Chat.workIcon).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            case .succeeded:
                Image(systemName: symbol).font(LoomTheme.Chat.workIcon).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
        }
        .frame(width: LoomTheme.Chat.iconSlot, height: LoomTheme.Chat.iconSlot)
        .accessibilityHidden(true)
    }
}

/// "+31 \u{2212}6" in the content colours of added and removed lines, mono 11.5. A count of zero is left out (an edit record that
/// carries no line counts gives zeros, and "+0" would say the file did not change), so with nothing known it
/// draws nothing.
struct ChatChangeCounts: View {
    let added: Int
    let removed: Int

    /// The parts that are drawn, in order: "+A" when lines were added, "\u{2212}R" when lines were removed.
    static func parts(added: Int, removed: Int) -> [String] {
        (added > 0 ? ["+\(added)"] : []) + (removed > 0 ? ["\u{2212}\(removed)"] : [])
    }

    var body: some View {
        if added > 0 || removed > 0 {
            HStack(spacing: 6) {
                if added > 0 { Text("+\(added)").foregroundStyle(LoomTheme.Success.light) }
                if removed > 0 { Text("\u{2212}\(removed)").foregroundStyle(LoomTheme.Status.failureLight) }
            }
            .font(LoomTheme.Chat.metaMono)
            .accessibilityLabel("\(added) lines added, \(removed) removed")
        }
    }
}

// MARK: Tool body

/// What opens under a tool row: a command's output, an edit's diff, a read's path, a search's pattern and results, other
/// tools' arguments. Bodies scroll after 16 lines and their text is selectable.
struct ChatToolBody: View {
    let call: ToolCall
    let label: ChatWork.Label
    let row: ChatRow
    let entry: ChatEntry
    let context: ChatRowContext

    /// Whether the row has more to show than its line: a read's body is its path (already in the line) unless it has images or
    /// failed. The chevron is drawn only for a row with a body.
    static func hasBody(_ call: ToolCall, label: ChatWork.Label) -> Bool {
        switch label.kind {
        case .read: !call.images.isEmpty || call.status == .failed || call.status == .denied
        default: true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch label.kind {
            case .command: command
            case .edit: edit
            case .read: read
            case .search: search
            case .web, .agent, .other: other
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Command

    @ViewBuilder private var command: some View {
        if let text = call.input["command"]?.string, text.contains("\n") || text.count > 120 {
            ChatOutputBox(text: "$ " + text, maxLines: 8, plainOnly: true)
        }
        outputSection
    }

    /// The result text, as a box. A failed command opens with the failure's header: its exit code and its last 12 lines, with
    /// Copy and Show All; the box is edged in the failure colour.
    @ViewBuilder private var outputSection: some View {
        let full = row.fullText ?? call.output?.text
        if let full, !full.isEmpty {
            let failed = call.status == .failed
            let all = row.flags.contains("all")
            let lineCount = ChatText.lineCount(full)
            let tail = failed && !all && lineCount > LoomTheme.Chat.failedTailLines
            let shown = tail ? ChatText.lastLines(full, LoomTheme.Chat.failedTailLines) : full
            let clipped = row.fullOutput == nil && call.output?.isClipped == true && context.canShowAll(entry)
            ChatOutputBox(
                text: shown, context: context,
                header: failed ? ChatOutputHeader(
                    title: Self.failureTitle(code: call.exitCode, lines: lineCount, tail: tail, all: all),
                    isFailure: true, copy: shown, more: more(tail: tail, clipped: clipped)) : nil,
                footer: failed ? nil : more(tail: false, clipped: clipped).map {
                    ChatOutputFooter(note: "Output cut", more: $0)
                })
            if row.fullOutput == .missing {
                Text("The whole result could not be read from the transcript: its line is too large or the file changed.")
                    .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        } else if call.status == .succeeded {
            Text("No output").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
        }
    }

    /// "Exit code 1 \u{00B7} last 12 lines": a failed command's header.
    static func failureTitle(code: Int?, lines: Int, tail: Bool, all: Bool) -> String {
        let head = code.map { "Exit code \($0)" } ?? "Failed"
        guard !all else { return head }
        let shown = tail ? LoomTheme.Chat.failedTailLines : lines
        return head + " \u{00B7} last " + (shown == 1 ? "line" : "\(shown) lines")
    }

    /// The header's or footer's "Show All": the whole output, or the whole result from the transcript.
    private func more(tail: Bool, clipped: Bool) -> ChatOutputMore? {
        if tail { return ChatOutputMore(title: "Show All") { context.toggleFlag(row.id, "all") } }
        if clipped, let output = call.output {
            return ChatOutputMore(title: "Show All " + ChatBytes.text(output.totalBytes)) { context.showAll(entry) }
        }
        return nil
    }

    // MARK: Edit

    @ViewBuilder private var edit: some View {
        let lines = ChatDiff.lines(for: call)
        if lines.isEmpty {
            outputSection
        } else {
            ChatDiffView(lines: lines, path: label.subject, openChanges: context.openChanges.map { open in { open(entry.turnID) } })
            if call.status == .failed { outputSection }
        }
    }

    // MARK: Read, search, other

    @ViewBuilder private var read: some View {
        if let path = call.input["file_path"]?.string ?? call.input["notebook_path"]?.string {
            Text(verbatim: ChatWork.shorten(path, workingDirectory: context.workingDirectory))
                .font(LoomTheme.Chat.toolMono).foregroundStyle(LoomTheme.Text.secondaryStyle).textSelection(.enabled)
        }
        if !call.images.isEmpty {
            HStack(spacing: 6) { ForEach(Array(call.images.enumerated()), id: \.offset) { _, image in ChatThumbnail(image: image, context: context) } }
        } else if call.status == .failed || call.status == .denied { outputSection }
    }

    @ViewBuilder private var search: some View {
        if let pattern = call.input["pattern"]?.string ?? call.input["query"]?.string {
            Text(verbatim: pattern).font(LoomTheme.Chat.toolMono).foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled)
        }
        outputSection
    }

    @ViewBuilder private var other: some View {
        let arguments = ChatJSON.pretty(call.input)
        if !arguments.isEmpty, arguments != "{}" { ChatOutputBox(text: arguments, maxLines: 10, plainOnly: true) }
        outputSection
    }
}

/// A box's "Show All": its title and what it does.
struct ChatOutputMore {
    let title: String
    let action: () -> Void
}

/// A box's header (28 pt, mono 11): what it holds, Copy and Show All. A failure's is in the failure text over a rule of the
/// failure colour.
struct ChatOutputHeader {
    var title: String
    var isFailure = false
    /// The text Copy takes.
    var copy: String?
    var more: ChatOutputMore?
}

/// A box's footer (30 pt, mono 11, tertiary): a note and Show All.
struct ChatOutputFooter {
    var note: String
    var more: ChatOutputMore?
}

/// A monospaced box that scrolls after `maxLines` lines (the reference's `.out`): raised 1, radius 8, a hairline edge (the failure
/// colour at 36 % for a failure), text of 11.5 on 18 pt lines. Output keeps basic ANSI colours.
struct ChatOutputBox: View {
    let text: String
    var maxLines = LoomTheme.Chat.outputMaxLines
    var plainOnly = false
    /// Copy needs the context; a box without one draws no Copy.
    var context: ChatRowContext?
    var header: ChatOutputHeader?
    var footer: ChatOutputFooter?
    @Environment(\.chatMeasuring) private var measuring

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius)
        let failure = header?.isFailure == true
        VStack(spacing: 0) {
            if let header {
                headerRow(header)
                Rectangle().fill(failure ? AnyShapeStyle(LoomTheme.Status.failure.opacity(LoomTheme.Chat.failureRuleOpacity))
                                 : AnyShapeStyle(LoomTheme.Surface.hairlineStyle))
                    .frame(height: LoomTheme.Line.hairline)
            }
            content
            if let footer {
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                footerRow(footer)
            }
        }
        .background(shape.fill(LoomTheme.Chat.outputFill))
        .overlay(shape.strokeBorder(failure ? AnyShapeStyle(LoomTheme.Status.failure.opacity(LoomTheme.Chat.failureEdgeOpacity))
                                    : AnyShapeStyle(LoomTheme.Surface.hairlineStyle)))
        .clipShape(shape)
    }

    @ViewBuilder private var content: some View {
        let lineCount = ChatText.lineCount(text)
        // A scrolling box is as high as `maxLines` lines whatever its text, so measuring a long one shows a short stand-in.
        let standIn = measuring && lineCount > maxLines
        let lines = Group {
            if standIn {
                Text(verbatim: "x")
            } else if plainOnly || !ChatANSI.containsEscape(text) {
                Text(verbatim: ChatANSI.stripped(text))
            } else {
                Text(ChatANSI.attributed(text))
            }
        }
        .font(LoomTheme.Chat.outputFont)
        .lineSpacing(LoomTheme.Chat.outputLineSpacing)
        .foregroundStyle(LoomTheme.Chat.output)
        .textSelection(.enabled)
        .padding(.vertical, LoomTheme.Chat.outputLineSpacing / 2)
        .padding(.top, LoomTheme.Chat.outputPaddingTop).padding(.bottom, LoomTheme.Chat.outputPaddingBottom)
        .padding(.horizontal, LoomTheme.Chat.outputPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
        if lineCount > maxLines {
            ScrollView(.vertical) { lines }
                .frame(height: CGFloat(maxLines) * LoomTheme.Chat.outputLineHeight
                    + LoomTheme.Chat.outputPaddingTop + LoomTheme.Chat.outputPaddingBottom)
        } else {
            lines
        }
    }

    private func headerRow(_ header: ChatOutputHeader) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: header.title).font(LoomTheme.Chat.timeMono)
                .foregroundStyle(header.isFailure ? AnyShapeStyle(LoomTheme.Status.failureLight) : AnyShapeStyle(LoomTheme.Text.tertiaryStyle))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let copy = header.copy, let context { ChatCopyButton(text: copy, context: context) }
            if let more = header.more { ChatLinkButton(title: more.title, action: more.action) }
        }
        .padding(.leading, LoomTheme.Chat.outputPaddingH).padding(.trailing, 4)
        .frame(height: LoomTheme.Chat.outputHeaderHeight)
    }

    private func footerRow(_ footer: ChatOutputFooter) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: footer.note).font(LoomTheme.Chat.timeMono).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
            Spacer(minLength: 0)
            if let more = footer.more { ChatLinkButton(title: more.title, action: more.action) }
        }
        .padding(.leading, LoomTheme.Chat.outputPaddingH).padding(.trailing, 4)
        .frame(height: LoomTheme.Chat.outputFooterHeight)
    }
}

// MARK: Diff

enum ChatDiff {
    struct Line: Equatable {
        enum Kind { case added, removed }
        var kind: Kind
        var text: String
    }

    /// A line longer than this (a minified file, a data blob) is cut, so one line never makes a huge row.
    static let maximumLineCharacters = 400

    static func clipped(_ line: String) -> String {
        line.count > maximumLineCharacters ? String(line.prefix(maximumLineCharacters)) + "\u{2026}" : line
    }

    /// The lines an edit call changes, from its input: the removed lines (`old_string`), then the added ones. A write is
    /// all added. The edit record's `structuredPatch` is not kept by the model, so no context lines or line numbers.
    static func lines(for call: ToolCall) -> [Line] {
        let input = call.input
        func split(_ text: String) -> [String] {
            var parts = text.components(separatedBy: "\n")
            if parts.last == "" { parts.removeLast() }
            return parts.map(clipped)
        }
        switch call.name {
        case "Write":
            return split(input["content"]?.string ?? "").map { Line(kind: .added, text: $0) }
        case "Edit":
            return split(input["old_string"]?.string ?? "").map { Line(kind: .removed, text: $0) }
                + split(input["new_string"]?.string ?? "").map { Line(kind: .added, text: $0) }
        case "MultiEdit":
            return (input["edits"]?.array ?? []).flatMap { edit in
                split(edit["old_string"]?.string ?? "").map { Line(kind: .removed, text: $0) }
                    + split(edit["new_string"]?.string ?? "").map { Line(kind: .added, text: $0) }
            }
        case "NotebookEdit":
            return split(input["new_source"]?.string ?? "").map { Line(kind: .added, text: $0) }
        default:
            return []
        }
    }
}

/// An inline diff up to about 200 lines, in a box: the file's name and its counts over the lines (sign gutter, changed lines on
/// the added and removed bands), and under the last one "N more lines" with "Open in Changes". The edit record's patch is not
/// kept by the model, so there are no line numbers or hunk lines yet.
struct ChatDiffView: View {
    let lines: [ChatDiff.Line]
    let path: String
    let openChanges: (() -> Void)?

    var body: some View {
        let shown = lines.prefix(LoomTheme.Chat.diffMaxLines)
        let added = lines.filter { $0.kind == .added }.count
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Chat.codeRadius)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: path).font(LoomTheme.Chat.timeMono).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                ChatChangeCounts(added: added, removed: lines.count - added)
            }
            .padding(.leading, LoomTheme.Chat.outputPaddingH).padding(.trailing, LoomTheme.Chat.outputPaddingH)
            .frame(height: LoomTheme.Chat.outputHeaderHeight)
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 0) {
                        Text(line.kind == .added ? "+" : "\u{2212}")
                            .foregroundStyle(line.kind == .added ? LoomTheme.Success.light : LoomTheme.Status.failureLight)
                            .frame(width: LoomTheme.Chat.diffGutter)
                        Text(verbatim: line.text.isEmpty ? " " : line.text).foregroundStyle(LoomTheme.Text.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, LoomTheme.Chat.outputPaddingH)
                    }
                    .frame(minHeight: LoomTheme.Chat.diffLineHeight)
                    .background(line.kind == .added ? LoomTheme.Chat.diffAddFill : LoomTheme.Chat.diffRemoveFill)
                }
            }
            .font(LoomTheme.Chat.outputFont)
            .textSelection(.enabled)
            .padding(.vertical, 4)
            if lines.count > shown.count {
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                HStack(spacing: 8) {
                    Text("\(lines.count - shown.count) more lines").font(LoomTheme.Chat.timeMono)
                        .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    Spacer(minLength: 0)
                    if let openChanges { ChatLinkButton(title: "Open in Changes", chevron: true, action: openChanges) }
                }
                .padding(.leading, LoomTheme.Chat.outputPaddingH).padding(.trailing, 4)
                .frame(height: LoomTheme.Chat.outputFooterHeight)
            }
        }
        .background(shape.fill(LoomTheme.Chat.outputFill))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle))
        .clipShape(shape)
    }
}

enum ChatJSON {
    static func pretty(_ value: JSONValue) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: value.serialized(), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        return lines.count > 40 ? lines.prefix(40).joined(separator: "\n") + "\n\u{2026}" : text
    }
}

// MARK: Group

/// Two or more tools in a row: a summary line that names the top two kinds of work and opens into the tools, which branch from
/// its icon on lines of the tree colour (the steps draw their own part, `ChatRow.branch`).
struct ChatGroupRowView: View {
    let group: ToolGroup
    let open: Bool
    let rowID: String
    let context: ChatRowContext
    @State private var hovering = false

    var body: some View {
        let loud = group.status == .failed
        let style = hovering || loud ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)
        Button { context.toggle(rowID) } label: {
            HStack(spacing: 8) {
                ChatToolIcon(status: group.status, symbol: "square.stack.3d.up", animates: context.animates)
                Text(verbatim: group.summary)
                    .font(LoomTheme.Chat.toolLabel)
                    .lineLimit(1)
                if group.failedCount > 0 {
                    Text("\u{00B7} \(group.failedCount) failed").font(LoomTheme.Chat.metaMono).foregroundStyle(LoomTheme.Status.failureLight)
                }
                Spacer(minLength: 8)
                ChatChevron(open: open)
            }
            .foregroundStyle(style)
            .chatWorkLine(pill: hovering ? .hover : .none)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .chatTree(open ? .head : nil)
        .accessibilityLabel(group.summary + (group.failedCount > 0 ? ", \(group.failedCount) failed" : ""))
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}

// MARK: Turn fold

/// "Worked for 4m 12s \u{00B7} changed 5 files and ran 3 commands": a settled turn's work in one 28 pt line in tertiary, the
/// duration in mono, a hairline running on to the right. Opened, its work hangs on a guide (`ChatRow.foldGuide`).
struct ChatTurnFoldView: View {
    let fold: TurnFold
    let open: Bool
    let rowID: String
    let context: ChatRowContext
    @State private var hovering = false

    var body: some View {
        Button { context.toggle(rowID) } label: {
            HStack(spacing: 8) {
                ChatChevron(open: open)
                title.lineLimit(1).layoutPriority(1)
                if fold.failedCount > 0 {
                    Text("\u{00B7} \(fold.failedCount) failed").font(LoomTheme.Chat.metaMono).foregroundStyle(LoomTheme.Status.failureLight)
                }
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).padding(.leading, 6)
            }
            .font(LoomTheme.Chat.toolLabel)
            .foregroundStyle(hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.tertiaryStyle))
            .frame(height: LoomTheme.Chat.foldHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, 8).padding(.bottom, 4)
        .accessibilityLabel(fold.title + (fold.detail.isEmpty ? "" : ", " + fold.detail))
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    /// The title with its duration in mono, and what the work did.
    private var title: Text {
        let detail = fold.detail.isEmpty ? Text("") : Text(" \u{00B7} " + fold.detail)
        let prefix = "Worked for "
        if fold.title.hasPrefix(prefix) {
            return Text(prefix) + Text(verbatim: String(fold.title.dropFirst(prefix.count))).font(LoomTheme.Chat.metaMono) + detail
        }
        return Text(verbatim: fold.title) + detail
    }
}

// MARK: Thinking

/// A thinking block as it occurred (Thinking and Verbose views): a work row with the CLI's \u{273B} and "Thought for 4s", and
/// the text in italics under it. A block with no text (redacted, or the default display) is one line.
struct ChatThinkingView: View {
    let entry: ChatEntry
    let open: Bool
    let rowID: String
    let context: ChatRowContext
    @State private var hovering = false

    var body: some View {
        if case let .thinking(thinking) = entry.body {
            let hasText = !thinking.text.isEmpty && !thinking.isHidden
            VStack(alignment: .leading, spacing: 0) {
                Button { if hasText { context.toggle(rowID) } } label: {
                    HStack(spacing: 8) {
                        Group {
                            if thinking.isStreaming {
                                BrailleSpinner(animating: context.animates, style: .subagent)
                            } else {
                                Text("\u{273B}").font(LoomTheme.Chat.thinkingMark).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                            }
                        }
                        .frame(width: LoomTheme.Chat.iconSlot, height: LoomTheme.Chat.iconSlot)
                        .accessibilityHidden(true)
                        title(thinking).font(LoomTheme.Chat.thinkingLabel)
                        Spacer(minLength: 8)
                        if let time = entry.timestamp {
                            Text(ChatTime.label(for: time)).font(LoomTheme.Chat.timeMono)
                                .foregroundStyle(LoomTheme.Text.tertiaryStyle).opacity(hovering ? 1 : 0)
                        }
                        if hasText { ChatChevron(open: open) }
                    }
                    .foregroundStyle(hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                    .chatWorkLine(pill: hovering && hasText ? .hover : .none)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                if hasText, open {
                    Text(verbatim: thinking.text)
                        .font(LoomTheme.Chat.thinkingText)
                        .lineSpacing(LoomTheme.Chat.thinkingLineSpacing)
                        .padding(.vertical, LoomTheme.Chat.thinkingLineSpacing / 2)
                        .foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, LoomTheme.Chat.bodyInset)
                        .padding(.top, 2).padding(.bottom, LoomTheme.Chat.bodyBottom)
                }
            }
        }
    }

    /// "Thought for 4s" with the duration in mono.
    private func title(_ thinking: Thinking) -> Text {
        if thinking.isStreaming { return Text("Thinking") }
        // Redacted thinking has no duration: "Thinking (hidden)". With the default display only the text is empty.
        if let duration = thinking.durationMs, duration >= 1000 {
            return Text("Thought for ") + Text(verbatim: ChatTime.duration(milliseconds: duration)).font(LoomTheme.Chat.toolMono)
        }
        return Text(thinking.isHidden && thinking.durationMs == nil ? "Thinking (hidden)" : "Thought")
    }
}

// MARK: Subagent

/// A subagent: a card (raised 1, radius 12) with its status mark, its type and task, the elapsed time, its newest words and
/// "Open in Agents". The first card of a run says how many agents there are over it. While it runs the detail line is its
/// newest words (one line, cut at the end), updated as each block arrives; when it is done, its result. The card as a whole
/// opens it in the inspector's Agents tab (the closure the host passes). A running card never folds.
struct ChatSubagentCardView: View {
    let entry: ChatEntry
    var header: String?
    let context: ChatRowContext
    @State private var hovering = false

    var body: some View {
        if case let .subagent(run) = entry.body {
            VStack(alignment: .leading, spacing: 0) {
                if let header {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2").font(LoomTheme.Chat.workIcon).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                            .frame(width: LoomTheme.Chat.iconSlot).accessibilityHidden(true)
                        Text(verbatim: header).font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                    .frame(height: LoomTheme.Chat.agentsHeaderHeight)
                    .padding(.bottom, 6)
                    .accessibilityElement(children: .combine)
                }
                Button { context.openSubagent?(run) } label: { card(run) }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Subagent \(run.subagentType ?? ""), \(run.description), \(Self.statusWord(run.status))")
                    .accessibilityHint(context.openSubagent != nil ? Self.openLabel : "")
            }
            .padding(.top, header == nil ? 6 : 12).padding(.bottom, 6)
        }
    }

    private func card(_ run: SubagentRun) -> some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Chat.agentCardRadius)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ChatSubagentMark(run: run, context: context)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let type = run.subagentType {
                        Text(verbatim: type).font(LoomTheme.Chat.toolLabelStrong).foregroundStyle(LoomTheme.Text.primary)
                            .lineLimit(1).fixedSize()
                    }
                    Text(verbatim: run.description.isEmpty ? "Subagent" : run.description)
                        .font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                }
                Spacer(minLength: 8)
                ChatSubagentTime(run: run, context: context)
            }
            footer(run).padding(.leading, LoomTheme.Chat.iconSlot + 8)
        }
        .padding(.horizontal, LoomTheme.Chat.agentCardPaddingH).padding(.vertical, LoomTheme.Chat.agentCardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LoomTheme.Chat.cardFill))
        .overlay(shape.strokeBorder(hovering ? AnyShapeStyle(LoomTheme.Surface.strongHairline) : AnyShapeStyle(LoomTheme.Surface.hairlineStyle)))
        .contentShape(shape)
    }

    static let openLabel = "Open in Agents"

    /// The detail line (12.5 / 19, cut at the end) and, on a card that is still working, "Open in Agents" under it.
    @ViewBuilder private func footer(_ run: SubagentRun) -> some View {
        if let detail = ChatWork.subagentDetail(run) {
            Text(verbatim: detail).font(LoomTheme.Chat.toolLabel)
                .lineSpacing(LoomTheme.Chat.thoughtLineSpacing)
                .foregroundStyle(run.status == .running ? AnyShapeStyle(LoomTheme.Text.secondaryStyle) : AnyShapeStyle(LoomTheme.Text.tertiaryStyle))
                .lineLimit(run.status == .running ? 1 : 3).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("subagent-card-line")
        }
        if run.status == .running, context.openSubagent != nil {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ChatLinkLabel(title: Self.openLabel, chevron: true, hovering: hovering)
            }
            .padding(.trailing, -6).padding(.bottom, -4)
        }
    }

    static func statusWord(_ status: SubagentRun.Status) -> String {
        switch status {
        case .running: "running"
        case .succeeded: "done"
        case .failed: "failed"
        case .interrupted: "stopped"
        }
    }
}

/// A card's status mark: the working spinner, a check once done, the failure dot or the stop glyph.
struct ChatSubagentMark: View {
    let run: SubagentRun
    let context: ChatRowContext

    var body: some View {
        Group {
            switch run.status {
            case .running:
                BrailleSpinner(animating: context.animates, style: .subagent)
            case .succeeded:
                Image(systemName: "checkmark").font(LoomTheme.Chat.chevron).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            case .failed:
                IndicatorView(indicator: .failed(nil))
            case .interrupted:
                Image(systemName: "stop.circle").font(LoomTheme.Chat.rowIcon).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
        }
        .frame(width: LoomTheme.Chat.iconSlot, height: LoomTheme.Chat.iconSlot)
        .accessibilityHidden(true)
    }
}

/// The card's time (mono 11, tertiary): the clock of a running card, the run time of a finished one.
struct ChatSubagentTime: View {
    let run: SubagentRun
    let context: ChatRowContext

    var body: some View {
        Group {
            if run.status == .interrupted, run.endedAt == nil {
                Text("Stopped")
            } else {
                ChatElapsedText(start: run.startedAt, end: run.status == .running ? nil : run.endedAt, clock: context.clock)
            }
        }
        .font(LoomTheme.Chat.timeMono).foregroundStyle(LoomTheme.Text.tertiaryStyle)
    }
}

/// The elapsed time of something that started: from the timestamps, never from when a view appeared. Only a running one
/// reads the clock.
struct ChatElapsedText: View {
    let start: Date?
    let end: Date?
    let clock: ChatLiveClock

    var body: some View {
        if let start {
            if let end {
                Text(ChatTime.duration(seconds: end.timeIntervalSince(start))).monospacedDigit()
            } else {
                Text(ChatTime.duration(seconds: clock.now.timeIntervalSince(start))).monospacedDigit()
            }
        }
    }
}

// MARK: Plan

/// A plan as a document card: the first heading as its title, a preview with "Show Full Plan" over 900 characters or 20
/// lines. It stays visible when its turn is folded.
struct ChatPlanCardView: View {
    let entry: ChatEntry
    let open: Bool
    let flags: Set<String>
    let rowID: String
    let context: ChatRowContext

    var body: some View {
        if case let .plan(plan) = entry.body {
            let long = Self.isLong(plan.markdown)
            let shape = RoundedRectangle(cornerRadius: LoomTheme.Chat.cardRadius)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(LoomTheme.Chat.cardIcon)
                        .foregroundStyle(LoomTheme.Composer.ModeTone.planPair.color)
                    Text(verbatim: plan.title ?? "Plan").font(LoomTheme.InkType.header.font).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Self.statusText(plan.status)).font(LoomTheme.Chat.timeMono).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    ChatCopyButton(text: plan.markdown, context: context)
                }
                ChatMarkdownView(blocks: ChatContent.blocks(id: entry.id, text: Self.visibleText(plan.markdown, expanded: open || !long), isStreaming: false, in: context),
                                 flags: flags, rowID: rowID, context: context)
                if long {
                    ChatLinkButton(title: open ? "Show Less" : "Show Full Plan", prominent: true) { context.toggle(rowID) }
                        .padding(.leading, -6)
                }
            }
            .padding(LoomTheme.Chat.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(LoomTheme.Chat.cardFill))
            .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle))
            .padding(.vertical, 6)
        }
    }

    static func isLong(_ markdown: String) -> Bool {
        markdown.count > LoomTheme.Chat.planCollapseCharacters
            || markdown.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } > LoomTheme.Chat.planCollapseLines
    }

    static func visibleText(_ markdown: String, expanded: Bool) -> String {
        guard !expanded else { return markdown }
        return markdown.components(separatedBy: "\n").prefix(LoomTheme.Chat.planPreviewLines).joined(separator: "\n")
    }

    static func statusText(_ status: PlanDocument.Status) -> String {
        switch status {
        case .proposed: "Proposed"
        case .approved: "Approved"
        case .rejected: "Not approved"
        }
    }
}

// MARK: Changed files

/// Under the final answer of a turn that edited files: "3 files changed +120 \u{2212}34" and the file tree. The counts come from
/// the edit records. "Open in Changes" opens the inspector's Changes tab on this turn (the newest turn's card) or on the
/// whole session. The status letters (M, A, D, R) need the edit scan's kinds, which the card does not carry yet.
struct ChatChangedFilesCard: View {
    let card: ChangedFiles
    let context: ChatRowContext

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Chat.cardRadius)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("\(card.files.count) file\(card.files.count == 1 ? "" : "s") changed")
                    .font(LoomTheme.Chat.toolLabelStrong).foregroundStyle(LoomTheme.Text.primary)
                ChatChangeCounts(added: card.added, removed: card.removed)
                Spacer(minLength: 0)
                if let open = context.openChanges {
                    ChatLinkButton(title: "Open in Changes", chevron: true) { open(card.turnID) }
                        .accessibilityHint("Shows the changes in the inspector")
                }
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .frame(height: LoomTheme.Chat.changesHeaderHeight)
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                if line.isFolder {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down").font(LoomTheme.Chat.chevron).frame(width: 12)
                        Text(verbatim: line.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(LoomTheme.Chat.metaMono).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .padding(.leading, 12 + CGFloat(line.depth) * 14).padding(.trailing, 12)
                    .frame(height: LoomTheme.Chat.changesFolderHeight)
                } else {
                    HStack(spacing: 8) {
                        Text(verbatim: line.name).font(LoomTheme.Chat.toolMono).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        ChatChangeCounts(added: line.added, removed: line.removed)
                    }
                    .padding(.leading, 30 + CGFloat(max(0, line.depth - 1)) * 14).padding(.trailing, 12)
                    .frame(height: LoomTheme.Chat.changesFileHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LoomTheme.Chat.cardFill))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle))
        .clipShape(shape)
        .padding(.top, 14).padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Live row

/// The one row at the end of a running turn, 28 pt: the working spinner, what Claude does now (the verb in primary, its subject
/// in mono), a dot and the clock from your send. After 40 s with nothing new it says so, in secondary, with a ring in place of
/// the spinner. Only the line itself reads the clock.
struct ChatLiveRowView: View {
    let live: LiveRow
    let open: Bool
    let rowID: String
    let context: ChatRowContext

    var body: some View {
        Button { if !live.hiddenTools.isEmpty { context.toggle(rowID) } } label: {
            HStack(spacing: 9) {
                ChatLiveStatusText(live: live, clock: context.clock, animates: context.animates)
                Spacer(minLength: 8)
                if !live.hiddenTools.isEmpty {
                    Text("\(live.hiddenTools.count) step\(live.hiddenTools.count == 1 ? "" : "s")")
                        .font(LoomTheme.Chat.timeMono).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    ChatChevron(open: open)
                }
            }
            .frame(height: LoomTheme.Chat.liveHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .accessibilityLabel(live.label)
        .accessibilityValue(live.hiddenTools.isEmpty ? "" : (open ? "steps shown" : "steps hidden"))
    }
}

/// The live line: its mark, its words and its clock. It reads the clock, so it is the one view of the row that redraws each second.
struct ChatLiveStatusText: View {
    let live: LiveRow
    let clock: ChatLiveClock
    var animates = false

    var body: some View {
        let now = clock.now
        let quiet = Self.quietSeconds(live, now: now)
        HStack(spacing: 9) {
            Group {
                if quiet != nil { IndicatorView(indicator: .unknown) } else { BrailleSpinner(animating: animates) }
            }
            .frame(width: LoomTheme.Layout.indicatorSlot.width)
            .accessibilityHidden(true)
            if let quiet {
                Text("No activity for \(quiet)s").font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.secondaryStyle)
            } else {
                words
            }
            if let start = live.startedAt {
                Text("\u{00B7}").font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.faint)
                Text(ChatTime.clock(seconds: now.timeIntervalSince(start))).font(LoomTheme.Chat.metaMono)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle).monospacedDigit()
            }
        }
        .lineLimit(1)
    }

    /// "Editing" and its path: the verb in primary, the subject in mono (or in the same face when it is words).
    @ViewBuilder private var words: some View {
        let subject = live.subject
        if !subject.isEmpty, live.label.hasSuffix(subject) {
            Text(verbatim: String(live.label.dropLast(subject.count)).trimmingCharacters(in: .whitespaces))
                .font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.primary).fixedSize()
            Text(verbatim: subject).font(live.subjectIsMono ? LoomTheme.Chat.toolMono : LoomTheme.Chat.toolLabel)
                .foregroundStyle(LoomTheme.Text.primary).truncationMode(live.subjectIsMono ? .middle : .tail).layoutPriority(-1)
        } else {
            Text(verbatim: live.label).font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.primary).truncationMode(.middle)
        }
    }

    /// Whole seconds without news once it has been quiet for 40 s; nil while it is not.
    static func quietSeconds(_ live: LiveRow, now: Date) -> Int? {
        guard let last = live.lastActivity, now.timeIntervalSince(last) >= LoomTheme.Chat.quietAfter else { return nil }
        return Int(now.timeIntervalSince(last))
    }

    /// The text of the line as the accessibility tree and the tests read it.
    static func text(_ live: LiveRow, now: Date) -> String {
        if let quiet = quietSeconds(live, now: now) { return "No activity for \(quiet)s" }
        guard let start = live.startedAt else { return live.label }
        return "\(live.label) \u{00B7} \(ChatTime.clock(seconds: now.timeIntervalSince(start)))"
    }
}
