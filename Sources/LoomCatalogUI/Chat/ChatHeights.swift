import AppKit
import SwiftUI

/// Row heights, cached by row id and width (CHAT-SPEC → Scrolling: "heights are cached by row id, width and open
/// state"; the open state is part of the row, and a changed row is `invalidate`d). A row that has not been measured
/// keeps the last known height, or an estimate, until it is drawn and measured for real.
struct ChatHeightCache {
    struct Entry: Equatable {
        var width: CGFloat
        var height: CGFloat
        var measured: Bool
    }

    private(set) var entries: [String: Entry] = [:]

    /// The measured height at this width, or nil.
    func measured(_ id: String, width: CGFloat) -> CGFloat? {
        guard let entry = entries[id], entry.measured, abs(entry.width - width) < 0.5 else { return nil }
        return entry.height
    }

    /// Any height known for the row, measured or not.
    func known(_ id: String) -> CGFloat? { entries[id]?.height }

    mutating func store(_ id: String, width: CGFloat, height: CGFloat) {
        entries[id] = Entry(width: width, height: height, measured: true)
    }

    /// The row's content changed: its height is stale, but still the best guess until it is measured again.
    mutating func invalidate(_ id: String) {
        entries[id]?.measured = false
    }

    mutating func forget(_ id: String) { entries[id] = nil }

    mutating func removeAll(except keep: Set<String>) {
        entries = entries.filter { keep.contains($0.key) }
    }

    var count: Int { entries.count }
}

/// A cheap guess of a row's height for rows that are not on screen yet, from their text and the width. It only has to be
/// close enough for the scroll bar; the row is measured when it is drawn.
enum ChatRowEstimate {
    static func height(_ row: ChatRow, width: CGFloat) -> CGFloat {
        let content = max(120, min(width, LoomTheme.Chat.column) - 2 * LoomTheme.Chat.columnPadding)
        switch row.kind {
        case .start, .divider: return LoomTheme.Chat.markerHeight
        case let .marker(marker, _):
            if case let .notice(text) = marker { return CGFloat(lines(text, charsPerLine: content / 7)) * 17 + 14 }
            return LoomTheme.Chat.markerHeight
        case let .user(entry):
            guard case let .user(prompt) = entry.body else { return 60 }
            let bubble = min(content * LoomTheme.Chat.userMaxWidthFraction, LoomTheme.Chat.userMaxWidth) - 2 * LoomTheme.Chat.userPaddingH
            // A collapsed row shows seven lines, so the start of a long message says as much as all of it (a chip can be 16 MB).
            let count = lines(row.open ? prompt.text : String(ChatUserText.collapsedPrefix(prompt.text)), charsPerLine: bubble / 7.4)
            let shown = row.open ? count : min(count, LoomTheme.Chat.userCollapsedLines)
            return CGFloat(shown) * 22 + 2 * LoomTheme.Chat.userPaddingV + LoomTheme.Chat.userFooterHeight + LoomTheme.Chat.userTopGap
                + (prompt.images.isEmpty ? 0 : 80) + (ChatUserText.isLong(prompt.text) ? 26 : 0)
        case let .prose(entry, settled):
            guard case let .assistantText(text) = entry.body else { return 40 }
            return proseHeight(text.text, width: content) + (settled ? 32 : 14)
        case let .thinking(entry):
            guard case let .thinking(thinking) = entry.body else { return 28 }
            return LoomTheme.Chat.workRowHeight + (row.open ? CGFloat(lines(thinking.text, charsPerLine: content / 7)) * LoomTheme.Chat.thinkingLineHeight + 12 : 0)
        case .tool:
            return LoomTheme.Chat.workRowHeight + (row.open ? 120 : 0)
        case .group: return LoomTheme.Chat.workRowHeight
        case .subagent: return 78 + (row.agentsHeader == nil ? 0 : 32)
        case let .plan(entry):
            guard case let .plan(plan) = entry.body else { return 120 }
            return 90 + min(proseHeight(plan.markdown, width: content), row.open ? .greatestFiniteMagnitude : 220)
        case .request: return 28
        case .raw: return LoomTheme.Chat.workRowHeight + (row.open ? 150 : 0)
        case .turnFold: return LoomTheme.Chat.foldHeight + 12
        case let .changedFiles(card): return 20 + LoomTheme.Chat.changesHeaderHeight + CGFloat(card.lines.count) * LoomTheme.Chat.changesFileHeight
        case .thought: return 52
        case .live: return LoomTheme.Chat.liveHeight + 6
        case .empty: return 140
        }
    }

    static func lines(_ text: String, charsPerLine: CGFloat) -> Int {
        let per = max(8, Int(charsPerLine))
        var total = 0
        text.enumerateLines { line, _ in total += max(1, (line.count + per - 1) / per) }
        return max(1, total)
    }

    /// Prose: 22 pt lines, 10 pt between blocks, 19 pt lines in code.
    static func proseHeight(_ text: String, width: CGFloat) -> CGFloat {
        let per = max(8, Int(width / 7.2))
        var height: CGFloat = 8
        var inCode = false
        var previousBlank = true
        text.enumerateLines { line, _ in
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("```") {
                if !inCode { height += 36 }
                inCode.toggle()
                previousBlank = false
                return
            }
            if inCode { height += 19; return }
            if trimmed.isEmpty { previousBlank = true; return }
            if previousBlank { height += 10 }
            height += CGFloat(max(1, (line.count + per - 1) / per)) * 22
            previousBlank = false
        }
        return height
    }
}

/// Measures a row exactly: the row's SwiftUI view, laid out at the table's width. One hosting controller is reused for
/// every measurement. It runs synchronously on the main actor and only for rows that are about to be drawn.
@MainActor
final class ChatRowMeasurer {
    private let host: NSHostingController<ChatRowView>
    private let context: ChatRowContext
    private(set) var measurements = 0

    init(context: ChatRowContext) {
        self.context = context
        host = NSHostingController(rootView: ChatRowView(row: ChatRow(id: "-", kind: .empty), context: context))
        host.sizingOptions = []
    }

    func height(of row: ChatRow, width: CGFloat) -> CGFloat {
        measurements += 1
        ChatRenderProbe.measured(row.id, in: context)
        let began = ChatRenderProbe.owns(context) ? ContinuousClock.now : nil
        host.rootView = ChatRowView(row: row, context: context, measuring: true)
        let size = host.sizeThatFits(in: CGSize(width: width, height: 100_000))
        if let began { ChatRenderProbe.measuredFor(row.id, ContinuousClock.now - began) }
        return max(1, ceil(size.height))
    }
}

/// Counts how often a row is configured or measured, so a test can state which rows a change redraws. It counts only
/// what one owner hosts: a test watches a scope (`watch(scope:)`) and counts the views whose `ChatRowContext.probeScope`
/// is that scope, so another suite's chat in the same process adds nothing. With nothing watched (every normal run) a
/// call costs one emptiness check; a context without a scope is never counted.
@MainActor
enum ChatRenderProbe {
    /// The scope being counted; nil while no test watches.
    private(set) static var watchedScope: String?
    private(set) static var configured: [String: Int] = [:]
    private(set) static var measuredRows: [String: Int] = [:]
    /// Stream controllers made since `watch(scope:)`: a screen that builds one per render shows here.
    private(set) static var controllersCreated = 0
    /// Evaluations of the prose row's body, markdown parses (`ChatContent.blocks`: calls and characters handed to the parser)
    /// and inline parses (cache misses of `ChatContent.inline`) since `watch(scope:)`: what a streaming answer costs per delta.
    private(set) static var proseBodies = 0
    private(set) static var markdownParses = 0
    private(set) static var markdownCharacters = 0
    private(set) static var inlineParses = 0

    /// Starts counting the views of `scope` (the `probeScope` of their context) from zero. Replaces what was watched; two
    /// tests never watch together (`.renderProbe` in the tests).
    static func watch(scope: String) {
        watchedScope = scope
        reset()
    }

    static func stop() {
        watchedScope = nil
        reset()
    }

    static func reset() {
        configured = [:]
        measuredRows = [:]
        controllersCreated = 0
        proseBodies = 0
        markdownParses = 0
        markdownCharacters = 0
        inlineParses = 0
        measureTime = [:]
    }

    private(set) static var measureTime: [String: Double] = [:]

    /// Whether a view of `context` is being counted.
    static func owns(_ context: ChatRowContext?) -> Bool {
        guard let watchedScope else { return false }
        return context?.probeScope == watchedScope
    }

    static func measuredFor(_ id: String, _ duration: Duration) {
        measureTime[id, default: 0] += Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func proseBody(in context: ChatRowContext?) {
        guard owns(context) else { return }
        proseBodies += 1
    }

    static func markdownParsed(characters: Int, in context: ChatRowContext?) {
        guard owns(context) else { return }
        markdownParses += 1
        markdownCharacters += characters
    }

    static func inlineParsed(in context: ChatRowContext?) {
        guard owns(context) else { return }
        inlineParses += 1
    }

    static func controllerCreated(_ context: ChatRowContext) {
        guard owns(context) else { return }
        controllersCreated += 1
    }

    static func configure(_ id: String, in context: ChatRowContext) {
        guard owns(context) else { return }
        configured[id, default: 0] += 1
    }

    static func measured(_ id: String, in context: ChatRowContext) {
        guard owns(context) else { return }
        measuredRows[id, default: 0] += 1
    }
}
