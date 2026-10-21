import Foundation
import LoomCore

/// How the palette orders what it shows. Pure: sessions, projects and actions in, groups out, so the order is a
/// function of the query and can be tested without a model or a window.
///
/// - Empty query: a small triage list. Needs you (every session that needs the user, most urgent first), then
///   the most recent sessions, then the first actions.
/// - A query: every word must match. A word matches a title best as the whole title, then as its start, then as the
///   start of a word in it, then anywhere in it, then as scattered letters; the project name, the provider's name
///   ("Claude") and an action's keywords count less. A session that needs you gains a margin and a recent one a smaller one. Needs you stays
///   the first group; the others follow by their best row. Conversation hits are not ranked here: they are
///   appended in the order the scan found them (newest session first) as the last group, so the rows above never
///   move when they arrive.
enum PaletteRanking {
    static let needsYouLimit = 8
    static let recentLimit = 6
    static let emptyActionLimit = 8
    static let sessionLimit = 8
    static let projectLimit = 4
    static let actionLimit = 6
    static let needsYouMargin = 40.0
    static let recencyMargin = 10.0
    /// Days after which the recency margin has halved.
    static let recencyHalfLife = 3.0

    // MARK: Matching

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The provider's name as the row says it ("Claude", "Codex"), folded once: a query finds a session by its harness too.
    private static let providerFolds: [ManagedSession.Provider: String] = Dictionary(
        uniqueKeysWithValues: [ManagedSession.Provider.claude, .codex, .synthetic].map { ($0, fold(ProviderName.title($0))) })

    static func providerFold(_ provider: ManagedSession.Provider) -> String { providerFolds[provider] ?? "" }

    static func words(of query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// How well `word` matches the folded `field`, 0 for no match: whole 100, start 90, start of a word 75,
    /// inside 55, scattered letters (`fuzzy`, words of three letters or more) 20 to 30.
    static func tier(of word: String, in field: String, fuzzy: Bool) -> Double {
        guard !word.isEmpty, !field.isEmpty else { return 0 }
        if field == word { return 100 }
        if field.hasPrefix(word) { return 90 }
        guard field.range(of: word) != nil else {
            return fuzzy && word.count >= 3 ? scattered(word, in: field) : 0
        }
        // An occurrence right after a space, dash, slash or dot is the start of a word.
        var from = field.startIndex
        while let found = field.range(of: word, range: from..<field.endIndex) {
            let previous = field[field.index(before: found.lowerBound)]
            if !(previous.isLetter || previous.isNumber) { return 75 }
            from = field.index(after: found.lowerBound)
        }
        return 55
    }

    private static func scattered(_ word: String, in field: String) -> Double {
        var index = field.startIndex
        var first: String.Index?
        var last = field.startIndex
        for character in word {
            guard let found = field[index...].firstIndex(of: character) else { return 0 }
            if first == nil { first = found }
            last = found
            index = field.index(after: found)
        }
        guard let first else { return 0 }
        let span = field.distance(from: first, to: last) + 1
        return 20 + 10 * Double(word.count) / Double(span)
    }

    /// The match of all `words` against a title and the weaker fields; nil when a word matches nowhere.
    static func match(_ words: [String], title: String, others: [String]) -> Double? {
        guard !words.isEmpty else { return 0 }
        return match(words, foldedTitle: fold(title), foldedOthers: others.map(fold))
    }

    /// `match` for fields that are folded already (a session's, kept for the whole open of the palette).
    static func match(_ words: [String], foldedTitle: String, foldedOthers: [String]) -> Double? {
        guard !words.isEmpty else { return 0 }
        var total = 0.0
        for word in words {
            var best = tier(of: word, in: foldedTitle, fuzzy: true)
            for other in foldedOthers { best = max(best, 0.6 * tier(of: word, in: other, fuzzy: false)) }
            guard best > 0 else { return nil }
            total += best
        }
        return total / Double(words.count)
    }

    static func recencyBonus(_ date: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date)) / 86_400
        return recencyMargin * pow(0.5, days / recencyHalfLife)
    }

    // MARK: Rows

    static func item(for session: PaletteSessionInfo, now: Date) -> PaletteItem {
        let age = RelativeTime.string(from: session.lastActivityAt, to: now)
        let trailing = [session.project, age].compactMap { $0 }.joined(separator: " · ")
        return PaletteItem(
            id: "session:" + session.id.uuidString, target: .session(session.id), title: session.title,
            detail: session.needsYou ? session.reason.map { "· " + $0 } : nil, trailing: trailing,
            indicator: session.indicator, symbol: nil, snippet: nil)
    }

    static func item(for project: PaletteProjectInfo) -> PaletteItem {
        PaletteItem(id: "project:" + project.id.uuidString, target: .project(project.id), title: project.name,
                    detail: nil, trailing: "Project page", indicator: nil, symbol: "folder", snippet: nil)
    }

    static func item(for action: PaletteAction, detail: String?) -> PaletteItem {
        PaletteItem(id: "action:" + action.rawValue, target: .action(action), title: action.title,
                    detail: detail, trailing: action.keyHint, indicator: nil, symbol: action.symbol, snippet: nil)
    }

    // MARK: Groups

    /// The groups for a query. `actions` are the enabled ones with their detail text; the order of `sessions`
    /// does not matter (the needs-you order and the recency order are computed here).
    static func groups(query: String, sessions: [PaletteSessionInfo], projects: [PaletteProjectInfo],
                       actions: [(action: PaletteAction, detail: String?)], now: Date) -> [PaletteGroup] {
        let words = words(of: query)
        let byUrgency = sessions.filter(\.needsYou).sorted { lhs, rhs in
            let (left, right) = (AttentionOrder.rank(of: lhs.indicator) ?? 0, AttentionOrder.rank(of: rhs.indicator) ?? 0)
            if left != right { return left < right }
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard !words.isEmpty else {
            let waiting = Set(byUrgency.map(\.id))
            let recent = sessions.filter { !waiting.contains($0.id) }.sorted(by: newestFirst).prefix(recentLimit)
            var groups: [PaletteGroup] = []
            if !byUrgency.isEmpty {
                groups.append(PaletteGroup(section: .needsYou, title: "Needs you",
                                           items: byUrgency.prefix(needsYouLimit).map { item(for: $0, now: now) }))
            }
            if !recent.isEmpty {
                groups.append(PaletteGroup(section: .sessions, title: "Recent", items: recent.map { item(for: $0, now: now) }))
            }
            let shown = actions.prefix(emptyActionLimit)
            if !shown.isEmpty {
                groups.append(PaletteGroup(section: .actions, title: "Actions",
                                           items: shown.map { item(for: $0.action, detail: $0.detail) }))
            }
            return groups
        }

        var scoredSessions: [(PaletteSessionInfo, Double)] = []
        for session in sessions {
            let folded = session.folded ?? PaletteSessionInfo.Folded(title: session.title, project: session.project, reason: session.reason)
            guard let score = match(words, foldedTitle: folded.title,
                                    foldedOthers: folded.others + [providerFold(session.provider)]) else { continue }
            scoredSessions.append((session, score + (session.needsYou ? needsYouMargin : 0)
                                   + recencyBonus(session.lastActivityAt, now: now)))
        }
        let ranked = scoredSessions.sorted { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 > rhs.1 : newestFirst(lhs.0, rhs.0)
        }
        let waitingRows = ranked.filter { $0.0.needsYou }
        let otherRows = ranked.filter { !$0.0.needsYou }

        var rest: [(group: PaletteGroup, best: Double)] = []
        if !otherRows.isEmpty {
            rest.append((PaletteGroup(section: .sessions, title: "Sessions",
                                      items: otherRows.prefix(sessionLimit).map { item(for: $0.0, now: now) }),
                         otherRows[0].1))
        }
        let projectRows = projects.compactMap { project -> (PaletteProjectInfo, Double)? in
            match(words, title: project.name, others: [project.path]).map { (project, $0) }
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
        if !projectRows.isEmpty {
            rest.append((PaletteGroup(section: .projects, title: "Projects",
                                      items: projectRows.prefix(projectLimit).map { item(for: $0.0) }), projectRows[0].1))
        }
        let actionRows = actions.compactMap { entry -> (action: PaletteAction, detail: String?, score: Double)? in
            match(words, title: entry.action.title, others: entry.action.keywords + [entry.detail].compactMap { $0 })
                .map { (entry.action, entry.detail, $0) }
        }.sorted { $0.score != $1.score ? $0.score > $1.score : canonicalIndex($0.action) < canonicalIndex($1.action) }
        if !actionRows.isEmpty {
            rest.append((PaletteGroup(section: .actions, title: "Actions",
                                      items: actionRows.prefix(actionLimit).map { item(for: $0.action, detail: $0.detail) }),
                         actionRows[0].score))
        }
        rest.sort { lhs, rhs in
            lhs.best != rhs.best ? lhs.best > rhs.best : lhs.group.section.rawValue < rhs.group.section.rawValue
        }

        var groups: [PaletteGroup] = []
        if !waitingRows.isEmpty {
            groups.append(PaletteGroup(section: .needsYou, title: "Needs you",
                                       items: waitingRows.prefix(needsYouLimit).map { item(for: $0.0, now: now) }))
        }
        return groups + rest.map(\.group)
    }

    private static func newestFirst(_ lhs: PaletteSessionInfo, _ rhs: PaletteSessionInfo) -> Bool {
        lhs.lastActivityAt != rhs.lastActivityAt ? lhs.lastActivityAt > rhs.lastActivityAt : lhs.id.uuidString < rhs.id.uuidString
    }

    private static func canonicalIndex(_ action: PaletteAction) -> Int {
        PaletteAction.allCases.firstIndex(of: action) ?? 0
    }
}
