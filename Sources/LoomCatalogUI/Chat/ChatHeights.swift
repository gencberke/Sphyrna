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
            let bubble = content * LoomTheme.Chat.userMaxWidthFraction - 28
            let count = lines(prompt.text, charsPerLine: bubble / 7.4)
            let shown = row.open ? count : min(count, LoomTheme.Chat.userCollapsedLines)
            return CGFloat(shown) * 22 + 18 + 26 + (prompt.images.isEmpty ? 0 : 80)
        case let .prose(entry, settled):
            guard case let .assistantText(text) = entry.body else { return 40 }
            return proseHeight(text.text, width: content) + (settled ? 28 : 8)
        case let .thinking(entry):
            guard case let .thinking(thinking) = entry.body else { return 28 }
            return 28 + (row.open ? CGFloat(lines(thinking.text, charsPerLine: content / 7)) * 20 + 12 : 0)
        case .tool:
            return LoomTheme.Chat.workRowHeight + (row.open ? 120 : 0)
        case .group: return LoomTheme.Chat.workRowHeight
        case .subagent: return 78
        case let .plan(entry):
            guard case let .plan(plan) = entry.body else { return 120 }
            return 90 + min(proseHeight(plan.markdown, width: content), row.open ? .greatestFiniteMagnitude : 220)
        case .request: return 28
        case .raw: return LoomTheme.Chat.workRowHeight + (row.open ? 150 : 0)
        case .turnFold: return 38
        case let .changedFiles(card): return 56 + CGFloat(card.lines.count) * 20
        case .thought: return 30
        case .live: return LoomTheme.Chat.workRowHeight + 4
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
        ChatRenderProbe.measured(row.id)
        host.rootView = ChatRowView(row: row, context: context, measuring: true)
        let size = host.sizeThatFits(in: CGSize(width: width, height: 100_000))
        return max(1, ceil(size.height))
    }
}

/// Counts how often a row is configured or measured, so a test can state which rows a change redraws. It counts only
/// the rows a test asked to watch; with none (every normal run) a call costs one emptiness check.
@MainActor
enum ChatRenderProbe {
    static var watching = false
    private(set) static var configured: [String: Int] = [:]
    private(set) static var measuredRows: [String: Int] = [:]
    /// Stream controllers made since `watch()`: a screen that builds one per render shows here.
    private(set) static var controllersCreated = 0

    static func watch() {
        watching = true
        reset()
    }

    static func stop() {
        watching = false
        reset()
    }

    static func reset() {
        configured = [:]
        measuredRows = [:]
        controllersCreated = 0
    }

    static func controllerCreated() {
        guard watching else { return }
        controllersCreated += 1
    }

    static func configure(_ id: String) {
        guard watching else { return }
        configured[id, default: 0] += 1
    }

    static func measured(_ id: String) {
        guard watching else { return }
        measuredRows[id, default: 0] += 1
    }
}
