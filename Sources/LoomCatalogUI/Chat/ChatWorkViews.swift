import LoomChat
import LoomCore
import SwiftUI

// MARK: Tool row

/// One line per tool, about 26 pt tall: icon, label, counts, the time on hover and a chevron. Success is quiet (a plain
/// icon), failure is loud (the failure colour and the exit code). A click opens the body inline.
struct ChatToolRowView: View {
    let row: ChatRow
    let entry: ChatEntry
    let context: ChatRowContext
    @State private var hovering = false

    private var call: ToolCall? { if case let .tool(call) = entry.body { call } else { nil } }

    var body: some View {
        if let call {
            let label = ChatWork.label(for: call, workingDirectory: context.workingDirectory)
            VStack(alignment: .leading, spacing: 0) {
                Button { context.toggle(row.id) } label: { header(call, label) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.accessibilityText(call, label))
                    .accessibilityValue(row.open ? "expanded" : "collapsed")
                if row.open {
                    ChatToolBody(call: call, label: label, row: row, entry: entry, context: context)
                        .padding(.leading, LoomTheme.Chat.iconSlot + 8)
                        .padding(.bottom, 6)
                }
            }
            .onHover { hovering = $0 }
        }
    }

    private func header(_ call: ToolCall, _ label: ChatWork.Label) -> some View {
        let running = call.status == .running
        return HStack(spacing: 8) {
            ChatToolIcon(status: call.status, symbol: label.symbol, animates: context.animates)
            Text(label.verbPhrase(running: running))
                .font(LoomTheme.Chat.toolLabel)
                .foregroundStyle(statusStyle(call.status))
                .fixedSize()
            if !label.subject.isEmpty {
                Text(verbatim: label.subject)
                    .font(label.mono ? LoomTheme.Chat.toolMono : LoomTheme.Chat.toolLabel)
                    .foregroundStyle(call.status == .failed ? AnyShapeStyle(LoomTheme.Status.failureLight) : AnyShapeStyle(LoomTheme.Text.primary))
                    .lineLimit(1)
                    .truncationMode(label.mono ? .middle : .tail)
            }
            Spacer(minLength: 8)
            trailing(call)
            ChatChevron(open: row.open)
        }
        .padding(.horizontal, LoomTheme.Chat.workRowPaddingH - 4)
        .frame(height: LoomTheme.Chat.workRowHeight)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.workRowRadius).fill(hovering ? LoomTheme.Chat.hoverFill : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func trailing(_ call: ToolCall) -> some View {
        if let changes = call.changes {
            ChatChangeCounts(added: changes.added, removed: changes.removed)
        }
        if call.status == .failed, let code = call.exitCode {
            Text("Exit code \(code)").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Status.failureLight)
        } else if call.status == .denied {
            Text("Denied").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Status.failureLight)
        } else if call.status == .interrupted {
            Text("Stopped").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
        }
        if hovering, let time = call.startedAt {
            Text(Self.timeText(call, time)).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
        }
    }

    private func statusStyle(_ status: ToolCall.Status) -> AnyShapeStyle {
        status == .failed ? AnyShapeStyle(LoomTheme.Status.failureLight) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)
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
        case .interrupted: text += ", stopped"
        default: break
        }
        return text
    }
}

extension ChatWork.Label {
    /// The verb with its trailing space handled by the row's stack.
    func verbPhrase(running: Bool) -> String { running ? verbRunning : verb }
}

/// The status glyph of a tool row: the working chase while it runs, a plain icon otherwise.
struct ChatToolIcon: View {
    let status: ToolCall.Status
    let symbol: String
    let animates: Bool

    var body: some View {
        Group {
            switch status {
            case .running:
                ChaseDots(animating: animates, scale: 0.75)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(LoomTheme.Status.failureLight)
            case .denied:
                Image(systemName: "hand.raised").foregroundStyle(LoomTheme.Status.failureLight)
            case .interrupted:
                Image(systemName: "stop.circle").foregroundStyle(LoomTheme.Text.secondaryStyle)
            case .succeeded:
                Image(systemName: symbol).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        }
        .font(LoomTheme.Chat.rowIcon)
        .frame(width: LoomTheme.Chat.iconSlot, height: LoomTheme.Chat.iconSlot)
        .accessibilityHidden(true)
    }
}

/// "+31 −6" in the content colours of added and removed lines.
struct ChatChangeCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 5) {
            if added > 0 || removed == 0 { Text("+\(added)").foregroundStyle(LoomTheme.Success.light) }
            if removed > 0 { Text("\u{2212}\(removed)").foregroundStyle(LoomTheme.Status.failureLight) }
        }
        .font(LoomTheme.Chat.metaMono)
        .accessibilityLabel("\(added) lines added, \(removed) removed")
    }
}

// MARK: Tool body

/// What opens under a tool row: a command's output, an edit's diff, a read's path, a search's pattern and results, other
/// tools' arguments. Bodies scroll after about 16 lines and their text is selectable.
struct ChatToolBody: View {
    let call: ToolCall
    let label: ChatWork.Label
    let row: ChatRow
    let entry: ChatEntry
    let context: ChatRowContext

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

    /// The result text, as a box. A failed command opens with its last 12 lines and the exit code.
    @ViewBuilder private var outputSection: some View {
        let full = row.fullText ?? call.output?.text
        if let full, !full.isEmpty {
            let failed = call.status == .failed
            let all = row.flags.contains("all")
            let tail = failed && !all && ChatText.lineCount(full) > LoomTheme.Chat.failedTailLines
            if failed, let code = call.exitCode {
                Text(tail ? "Exit code \(code) \u{00B7} the last \(LoomTheme.Chat.failedTailLines) lines" : "Exit code \(code)")
                    .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Status.failureLight)
            }
            ChatOutputBox(text: tail ? ChatText.lastLines(full, LoomTheme.Chat.failedTailLines) : full, maxLines: 16)
            HStack(spacing: 12) {
                if tail {
                    Button("Show all output") { context.toggleFlag(row.id, "all") }
                }
                if row.fullOutput == nil, let output = call.output, output.isClipped, entry.sourceOffset != nil {
                    Button("Show all \(ChatBytes.text(output.totalBytes))") { context.showAll(entry) }
                }
            }
            .buttonStyle(.plain).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Accent.high)
            if row.fullOutput == .missing {
                Text("The whole result could not be read from the transcript: its line is too large or the file changed.")
                    .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        } else if call.status == .succeeded {
            Text("No output").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
        }
    }

    // MARK: Edit

    @ViewBuilder private var edit: some View {
        let lines = ChatDiff.lines(for: call)
        if lines.isEmpty {
            outputSection
        } else {
            ChatDiffView(lines: lines)
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

/// A monospaced block that scrolls after `maxLines` lines. Output keeps basic ANSI colours.
struct ChatOutputBox: View {
    let text: String
    var maxLines = 16
    var plainOnly = false
    @Environment(\.chatMeasuring) private var measuring

    var body: some View {
        let lineCount = ChatText.lineCount(text)
        // A scrolling box is as high as `maxLines` lines whatever its text, so measuring a long one shows a short stand-in.
        let standIn = measuring && lineCount > maxLines
        let content = Group {
            if standIn {
                Text(verbatim: "x")
            } else if plainOnly || !ChatANSI.containsEscape(text) {
                Text(verbatim: ChatANSI.stripped(text))
            } else {
                Text(ChatANSI.attributed(text))
            }
        }
        .font(LoomTheme.Chat.body)
        .foregroundStyle(LoomTheme.Chat.output)
        .textSelection(.enabled)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if lineCount > maxLines {
                ScrollView(.vertical) { content }
                    .frame(height: CGFloat(maxLines) * LoomTheme.Chat.bodyLineHeight + 14)
            } else {
                content
            }
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).fill(LoomTheme.Chat.outputFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).strokeBorder(LoomTheme.Surface.hairlineStyle))
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

/// An inline diff up to about 200 lines.
struct ChatDiffView: View {
    let lines: [ChatDiff.Line]

    var body: some View {
        let shown = lines.prefix(LoomTheme.Chat.diffMaxLines)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 0) {
                    Text(line.kind == .added ? "+" : "\u{2212}")
                        .foregroundStyle(line.kind == .added ? LoomTheme.Success.light : LoomTheme.Status.failureLight)
                        .frame(width: 22)
                    Text(verbatim: line.text.isEmpty ? " " : line.text).foregroundStyle(LoomTheme.Chat.syntaxPlain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(line.kind == .added ? LoomTheme.Chat.diffAddFill : LoomTheme.Chat.diffRemoveFill)
            }
            if lines.count > shown.count {
                Text("\(lines.count - shown.count) more lines")
                    .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .padding(.horizontal, 22).padding(.vertical, 4)
            }
        }
        .font(LoomTheme.Chat.body)
        .textSelection(.enabled)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).fill(LoomTheme.Chat.outputFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.md).strokeBorder(LoomTheme.Surface.hairlineStyle))
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.md))
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

/// Two or more tools in a row: a summary that names the top two kinds of work and opens into the tools.
struct ChatGroupRowView: View {
    let group: ToolGroup
    let open: Bool
    let rowID: String
    let context: ChatRowContext
    @State private var hovering = false

    var body: some View {
        Button { context.toggle(rowID) } label: {
            HStack(spacing: 8) {
                ChatToolIcon(status: group.status, symbol: "square.stack.3d.up", animates: context.animates)
                Text(verbatim: group.summary)
                    .font(LoomTheme.Chat.toolLabel)
                    .foregroundStyle(group.status == .failed ? AnyShapeStyle(LoomTheme.Status.failureLight) : AnyShapeStyle(LoomTheme.Text.primary))
                    .lineLimit(1)
                if group.failedCount > 0 {
                    Text("\u{00B7} \(group.failedCount) failed").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Status.failureLight)
                }
                Spacer(minLength: 8)
                ChatChevron(open: open)
            }
            .padding(.horizontal, LoomTheme.Chat.workRowPaddingH - 4)
            .frame(height: LoomTheme.Chat.workRowHeight)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.workRowRadius).fill(hovering ? LoomTheme.Chat.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(group.summary + (group.failedCount > 0 ? ", \(group.failedCount) failed" : ""))
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}

// MARK: Turn fold

/// "Worked for 4m 12s \u{00B7} changed 5 files and ran 3 commands": a settled turn's work in one row.
struct ChatTurnFoldView: View {
    let fold: TurnFold
    let open: Bool
    let rowID: String
    let context: ChatRowContext

    var body: some View {
        Button { context.toggle(rowID) } label: {
            HStack(spacing: 8) {
                ChatChevron(open: open)
                Text(verbatim: fold.title).font(LoomTheme.Chat.toolLabelStrong).foregroundStyle(LoomTheme.Text.primary)
                if !fold.detail.isEmpty {
                    Text("\u{00B7} " + fold.detail).font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                }
                if fold.failedCount > 0 {
                    Text("\u{00B7} \(fold.failedCount) failed").font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Status.failureLight)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.workRowRadius).fill(LoomTheme.Chat.foldFill))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Chat.workRowRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .accessibilityLabel(fold.title + (fold.detail.isEmpty ? "" : ", " + fold.detail))
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}

// MARK: Thinking

/// A thinking block as it occurred (Thinking and Verbose views): an italic block that can be collapsed. A block with no
/// text (redacted, or the default display) is one line.
struct ChatThinkingView: View {
    let entry: ChatEntry
    let open: Bool
    let rowID: String
    let context: ChatRowContext

    var body: some View {
        if case let .thinking(thinking) = entry.body {
            let hasText = !thinking.text.isEmpty && !thinking.isHidden
            VStack(alignment: .leading, spacing: 4) {
                Button { if hasText { context.toggle(rowID) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(LoomTheme.Chat.rowIcon).frame(width: LoomTheme.Chat.iconSlot)
                        Text(verbatim: title(thinking)).font(LoomTheme.Chat.thinkingLabel)
                        Spacer(minLength: 0)
                        if hasText { ChatChevron(open: open) }
                    }
                    .frame(height: LoomTheme.Chat.workRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LoomTheme.Text.secondaryStyle)
                if hasText, open {
                    Text(verbatim: thinking.text)
                        .font(LoomTheme.Chat.thinkingText)
                        .lineSpacing(3)
                        .foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, LoomTheme.Chat.iconSlot + 8)
                        .padding(.bottom, 6)
                }
            }
        }
    }

    private func title(_ thinking: Thinking) -> String {
        if thinking.isStreaming { return "Thinking" }
        // Redacted thinking has no duration: "Thinking (hidden)". With the default display only the text is empty.
        if let duration = thinking.durationMs, duration >= 1000 { return "Thought for \(ChatTime.duration(milliseconds: duration))" }
        return thinking.isHidden && thinking.durationMs == nil ? "Thinking (hidden)" : "Thought"
    }
}

// MARK: Subagent

/// A subagent: a status mark, its task, one detail line and the elapsed time. A click opens it in the inspector's
/// Agents tab (the closure the host passes). A running card never folds.
struct ChatSubagentCardView: View {
    let entry: ChatEntry
    let context: ChatRowContext
    @State private var hovering = false

    var body: some View {
        if case let .subagent(run) = entry.body {
            Button { context.openSubagent?(run) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2").font(LoomTheme.Chat.cardIcon).foregroundStyle(LoomTheme.Accent.high)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).fill(LoomTheme.Chat.agentBadgeFill))
                        HStack(spacing: 6) {
                            if let type = run.subagentType {
                                Text(verbatim: type).font(LoomTheme.Chat.toolLabelStrong).foregroundStyle(LoomTheme.Accent.high)
                            }
                            Text(verbatim: run.description.isEmpty ? "Subagent" : run.description)
                                .font(LoomTheme.Chat.toolLabelStrong).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        ChatSubagentStatus(run: run, context: context)
                    }
                    if let detail = ChatWork.subagentDetail(run) {
                        Text(verbatim: detail).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 32)
                    }
                }
                .padding(LoomTheme.Chat.cardPadding)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.cardRadius).fill(hovering ? LoomTheme.Surface.raised : LoomTheme.Surface.card))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Chat.cardRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Subagent \(run.subagentType ?? ""), \(run.description), \(Self.statusWord(run.status))")
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

struct ChatSubagentStatus: View {
    let run: SubagentRun
    let context: ChatRowContext

    var body: some View {
        HStack(spacing: 6) {
            switch run.status {
            case .running:
                ChaseDots(animating: context.animates, scale: 0.75).frame(width: 12, height: 12)
                ChatElapsedText(start: run.startedAt, end: nil, clock: context.clock)
            case .succeeded:
                Image(systemName: "checkmark").font(LoomTheme.Chat.chevron).foregroundStyle(LoomTheme.Success.light)
                ChatElapsedText(start: run.startedAt, end: run.endedAt, clock: context.clock)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(LoomTheme.Chat.chevron).foregroundStyle(LoomTheme.Status.failureLight)
                ChatElapsedText(start: run.startedAt, end: run.endedAt, clock: context.clock)
            case .interrupted:
                Image(systemName: "stop.circle").font(LoomTheme.Chat.chevron).foregroundStyle(LoomTheme.Text.secondaryStyle)
                if run.endedAt != nil { ChatElapsedText(start: run.startedAt, end: run.endedAt, clock: context.clock) } else { Text("Stopped") }
            }
        }
        .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
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

/// A plan as a document card: the first heading as its title, a preview with "Show full plan" over 900 characters or 20
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(LoomTheme.Chat.cardIcon).foregroundStyle(LoomTheme.Accent.high)
                    Text(verbatim: plan.title ?? "Plan").font(LoomTheme.Chat.toolLabelStrong).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Self.statusText(plan.status)).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    ChatCopyButton(text: plan.markdown, context: context)
                }
                ChatMarkdownView(blocks: ChatContent.blocks(id: entry.id, text: Self.visibleText(plan.markdown, expanded: open || !long), isStreaming: false),
                                 flags: flags, rowID: rowID, context: context)
                if long {
                    Button(open ? "Show less" : "Show full plan") { context.toggle(rowID) }
                        .buttonStyle(.plain).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Accent.high)
                }
            }
            .padding(LoomTheme.Chat.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.cardRadius).fill(LoomTheme.Surface.card))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Chat.cardRadius).strokeBorder(LoomTheme.Accent.low.opacity(0.5)))
            .padding(.vertical, 4)
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

/// Under the final answer of a turn that edited files: "3 files changed +120 −34" and the file tree. The counts come from
/// the edit records. ("Open in Changes" waits for the Changes tab.)
struct ChatChangedFilesCard: View {
    let card: ChangedFiles

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").font(LoomTheme.Chat.rowIcon).foregroundStyle(LoomTheme.Text.secondaryStyle)
                Text("\(card.files.count) file\(card.files.count == 1 ? "" : "s") changed")
                    .font(LoomTheme.Chat.toolLabelStrong).foregroundStyle(LoomTheme.Text.primary)
                ChatChangeCounts(added: card.added, removed: card.removed)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 6) {
                        Image(systemName: line.isFolder ? "folder" : "doc.text").font(LoomTheme.Chat.chevron)
                            .foregroundStyle(LoomTheme.Text.secondaryStyle).frame(width: 12)
                        Text(verbatim: line.name).font(LoomTheme.Chat.toolMono)
                            .foregroundStyle(line.isFolder ? AnyShapeStyle(LoomTheme.Text.secondaryStyle) : AnyShapeStyle(LoomTheme.Text.primary))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if !line.isFolder { ChatChangeCounts(added: line.added, removed: line.removed) }
                    }
                    .padding(.leading, CGFloat(line.depth) * 14)
                }
            }
        }
        .padding(LoomTheme.Chat.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Chat.cardRadius).fill(LoomTheme.Surface.card))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Chat.cardRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Live row

/// The one row at the end of a running turn: what Claude is doing and for how long. After 40 s with nothing new it says so
/// instead of looking busy. Only the label reads the clock.
struct ChatLiveRowView: View {
    let live: LiveRow
    let open: Bool
    let rowID: String
    let context: ChatRowContext

    var body: some View {
        Button { if !live.hiddenTools.isEmpty { context.toggle(rowID) } } label: {
            HStack(spacing: 9) {
                ChaseDots(animating: context.animates).frame(width: 12, height: 12)
                ChatLiveStatusText(live: live, clock: context.clock)
                Spacer(minLength: 8)
                if !live.hiddenTools.isEmpty {
                    Text("\(live.hiddenTools.count) step\(live.hiddenTools.count == 1 ? "" : "s")")
                        .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    ChatChevron(open: open)
                }
            }
            .frame(height: LoomTheme.Chat.workRowHeight)
            .padding(.horizontal, LoomTheme.Chat.workRowPaddingH - 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityLabel(live.label)
        .accessibilityValue(live.hiddenTools.isEmpty ? "" : (open ? "steps shown" : "steps hidden"))
    }
}

struct ChatLiveStatusText: View {
    let live: LiveRow
    let clock: ChatLiveClock

    var body: some View {
        let now = clock.now
        Text(Self.text(live, now: now))
            .font(LoomTheme.Chat.toolLabel).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1).truncationMode(.middle)
    }

    static func text(_ live: LiveRow, now: Date) -> String {
        if let last = live.lastActivity, now.timeIntervalSince(last) >= LoomTheme.Chat.quietAfter {
            return "No activity for \(Int(now.timeIntervalSince(last)))s"
        }
        guard let start = live.startedAt else { return live.label }
        return "\(live.label) \u{00B7} \(ChatTime.clock(seconds: now.timeIntervalSince(start)))"
    }
}
