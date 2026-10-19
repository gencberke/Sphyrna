import Foundation
import LoomChat

/// Where a `/` or `@` menu opens in the text, from the characters inserted (CHAT-SPEC → Menus). It reads a bounded window
/// before the caret, so a keystroke never scans the whole text; and it looks at inserted characters, not at keys, so it
/// works on any keyboard layout (on a Turkish Q keyboard `/` is ⇧7 and `@` is ⌥Q).
enum ComposerTrigger: Equatable {
    /// `/` at the very start of the message, up to the caret: commands and skills.
    case slash(query: String, range: NSRange)
    /// `@` at the start of a word, up to the caret: files, folders and sessions.
    case mention(query: String, range: NSRange)

    var range: NSRange {
        switch self {
        case let .slash(_, range), let .mention(_, range): range
        }
    }

    var query: String {
        switch self {
        case let .slash(query, _), let .mention(query, _): query
        }
    }

    /// How far back from the caret the trigger is looked for: a longer word is not a trigger.
    static let window = 200

    /// - Parameters:
    ///   - before: the text before the caret, at most `window + 1` UTF-16 units of it.
    ///   - caret: the caret's UTF-16 offset in the whole text.
    static func detect(before: String, caret: Int) -> ComposerTrigger? {
        let units = Array(before.utf16)
        guard !units.isEmpty, units.count <= window + 1 else { return nil }
        let start = caret - units.count
        guard start >= 0 else { return nil }
        // The word the caret is in: back to the first whitespace.
        var index = units.count
        while index > 0, !isWhitespace(units[index - 1]) { index -= 1 }
        if index == 0, start > 0 { return nil } // the word starts before the window: too long to be a trigger
        guard index < units.count else { return nil }
        let wordStart = index
        let first = units[wordStart]
        let word = String(decoding: units[wordStart...], as: UTF16.self)
        let range = NSRange(location: start + wordStart, length: units.count - wordStart)
        if first == 0x2F, start + wordStart == 0 { // "/" at the start of the message
            return .slash(query: String(word.dropFirst()), range: range)
        }
        if first == 0x40 { // "@" at the start of a word
            return .mention(query: String(word.dropFirst()), range: range)
        }
        return nil
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0xA0
    }
}

/// One row of a `/` or `@` menu.
struct ComposerMenuItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case command
        case skill
        /// Runs only in the terminal.
        case terminalOnly
        case file
        case folder
        case session
    }

    var id: String
    var kind: Kind
    /// What the row shows first: `/review`, `src/App.swift`, a session's title.
    var title: String
    var detail: String?
    /// A hint at the end of the row (an argument hint, a project name, "Terminal only").
    var trailing: String?
    /// The text that replaces the trigger when the row is chosen.
    var insertion: String

    var isTerminalOnly: Bool { kind == .terminalOnly }
}

/// The ranking of a menu's flat list [T3]: exact, prefix, word start, contains, fuzzy, each with a length penalty. The
/// bands are the palette's (`PaletteRanking.tier`); the penalty keeps a short match above a long one in the same band.
enum ComposerRanking {
    /// A band is at least 20 points from the next (fuzzy runs 20 to 30), so a penalty up to 9 never crosses one.
    static let maximumPenalty = 9.0

    /// The score of one candidate for `query`, or nil when it does not match. An empty query matches everything with
    /// the same score, so the list keeps its own order.
    static func score(query: String, title: String, alternatives: [String] = []) -> Double? {
        let word = PaletteRanking.fold(query)
        guard !word.isEmpty else { return 0 }
        var best = 0.0
        var matched = ""
        for candidate in [title] + alternatives {
            let folded = PaletteRanking.fold(candidate)
            let tier = PaletteRanking.tier(of: word, in: folded, fuzzy: true)
            if tier > best { best = tier; matched = folded }
        }
        guard best > 0 else { return nil }
        let extra = max(0, matched.count - word.count)
        return best - min(maximumPenalty, Double(extra) * 0.15)
    }

    /// The items that match, best first (ties keep the list's order), at most `limit`.
    static func rank(_ items: [ComposerMenuItem], query: String, limit: Int = 80,
                     alternatives: (ComposerMenuItem) -> [String] = { _ in [] }) -> [ComposerMenuItem] {
        guard !PaletteRanking.fold(query).isEmpty else { return Array(items.prefix(limit)) }
        var scored: [(item: ComposerMenuItem, score: Double, order: Int)] = []
        for (order, item) in items.enumerated() {
            if let score = score(query: query, title: item.title, alternatives: alternatives(item)) {
                scored.append((item, score, order))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.prefix(limit).map(\.item)
    }
}

/// The `/` menu's items from what the driver knows (CHAT-SPEC → Menus): the commands and skills of `initialize` and
/// `system/init`, then Loom's own actions. Skills that are not user-invocable are not in `initialize`'s command list, so
/// a name only `system/init`'s skill list knows is left out.
enum ComposerCommandItems {
    static func items(from state: ChatComposerState) -> [ComposerMenuItem] {
        let terminalOnly = Set(state.terminalOnlyCommands)
        let skills = Set(state.skills)
        var seen = Set<String>()
        var result: [ComposerMenuItem] = []
        func add(name: String, description: String?, hint: String?) {
            let clean = name.hasPrefix("/") ? String(name.dropFirst()) : name
            guard !clean.isEmpty, seen.insert(clean).inserted else { return }
            let isTerminal = terminalOnly.contains(clean)
            result.append(ComposerMenuItem(
                id: "command:" + clean, kind: isTerminal ? .terminalOnly : (skills.contains(clean) ? .skill : .command),
                title: "/" + clean, detail: description.flatMap { $0.isEmpty ? nil : $0 },
                trailing: isTerminal ? "Terminal only" : hint.flatMap { $0.isEmpty ? nil : $0 },
                insertion: isTerminal ? "" : "/" + clean + " "))
        }
        for command in state.commands { add(name: command.name, description: command.description, hint: command.argumentHint) }
        // Names `system/init` lists beyond the `initialize` answer (it lists commands only once a turn has begun).
        for name in state.slashCommands where !skills.contains(name) || state.commands.isEmpty {
            add(name: name, description: nil, hint: nil)
        }
        for name in terminalOnly { add(name: name, description: nil, hint: nil) }
        return result
    }
}
