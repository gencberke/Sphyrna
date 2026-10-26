import Foundation
import LoomCore

/// The work a finished turn left running, as every state surface says it (D-103): "1 background", "3 background". Working
/// means a turn is running; a finished turn with background shells or crons reads Ready and keeps this count on its card's
/// line, its header pill and the Overview. One helper, so the three word it alike.
enum BackgroundWorkText {
    static func of(_ reason: StatusReason?) -> String? {
        guard let reason, case .turnDone = reason.kind, !reason.work.isEmpty else { return nil }
        return "\(reason.work.total) background"
    }
}

/// The line an Active card shows between its title and its fixed bottom row (concept decision 8, D-69): what the
/// session waits for or did last. It is worded from a `StatusReason`, which the hub changes only at hook boundaries, so the
/// text never changes per frame. The text comes from commands, paths and Claude's replies: it is shown
/// as one bounded line, never logged, and never part of the evidence snapshot.
struct SessionReasonLine: Equatable {
    /// The card's line: one line, cut at the card's edge.
    let text: String
    /// More of the same, for the tooltip: the command's own description.
    let note: String?
    /// The end of `text` the machine said (the command or the path an approval names): the card draws it in mono.
    let mono: String?

    init(text: String, note: String? = nil, mono: String? = nil) {
        self.text = text
        self.note = note
        self.mono = mono.flatMap { !$0.isEmpty && text.hasSuffix($0) ? $0 : nil }
    }

    /// `text` without its mono end.
    var lead: String { mono.map { String(text.dropLast($0.count)) } ?? text }

    init?(_ reason: StatusReason?) {
        guard let reason else { return nil }
        switch reason.kind {
        case .approval(let tool):
            self.init(text: Self.approvalText(tool: tool, detail: reason.detail), note: reason.note, mono: reason.detail)
        case .question:
            self.init(text: reason.detail.map { "Asks: \($0)" } ?? "Asks a question")
        case .planReady:
            self.init(text: "Plan ready for review")
        case .input:
            self.init(text: "Waiting for your input")
        case .turnDone:
            // Work left running after the turn comes first, then the last message's line.
            var parts: [String] = []
            if let work = BackgroundWorkText.of(reason) { parts.append(work) }
            if let detail = reason.detail { parts.append(detail) }
            self.init(text: parts.isEmpty ? "Turn done" : parts.joined(separator: " · "))
        case .failure(let category):
            let cause = reason.detail ?? category?.replacingOccurrences(of: "_", with: " ")
            self.init(text: cause.map { "Failed: \($0)" } ?? "Turn failed")
        case .automaticTurn:
            self.init(text: reason.detail ?? "Continuing after a background task")
        }
    }

    /// What an approval reads on every surface and in both faces (Home, the sidebar, the palette, the inspector): what
    /// Claude asks to do, in words, then the command or path when it is known. A Chat-face request and a terminal-face one
    /// are the same `StatusReason`, so they read the same ("Asks to run: make test", "Asks to edit: src/App.swift").
    static func approvalText(tool: String, detail: String?) -> String {
        let asks: String
        let bare: String
        switch tool {
        case "Bash": (asks, bare) = ("Asks to run", "Asks to run a command")
        case "Edit", "MultiEdit", "NotebookEdit": (asks, bare) = ("Asks to edit", "Asks to edit a file")
        case "Write": (asks, bare) = ("Asks to write", "Asks to write a file")
        case "Read": (asks, bare) = ("Asks to read", "Asks to read a file")
        case "WebFetch": (asks, bare) = ("Asks to fetch", "Asks to fetch a page")
        default: (asks, bare) = ("Asks to use \(tool)", "Asks to use \(tool)")
        }
        guard let detail, !detail.isEmpty else { return bare }
        return "\(asks): \(detail)"
    }

    /// The tooltip: the whole line, then the note.
    var help: String { note.map { text + "\n" + $0 } ?? text }
}
