import Foundation
import LoomCore

/// The command palette's rows and the groups they sit in. Plain values: the ranking builds them, the view
/// draws them and the tests compare them.
public enum PaletteSection: Int, CaseIterable, Sendable {
    /// Ask Remora, when the text reads as a question (DESIGN §20 ⌘K): it heads the list.
    case remora
    case needsYou
    case sessions
    case projects
    case actions
    case conversations
}

/// A line of a conversation that matched the query: the words around the match, with the match itself apart so the
/// row can draw it in the accent colour.
public struct PaletteSnippet: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case you
        case claude
        case codex

        public var label: String {
            switch self {
            case .you: "You"
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }
    }

    public let role: Role
    public let before: String
    public let match: String
    public let after: String
}

public struct PaletteItem: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case session(UUID)
        case project(UUID)
        case action(PaletteAction)
        /// A conversation hit: opens the session it belongs to.
        case hit(UUID)
        /// "Search older sessions": runs the wider pass.
        case searchOlder
        /// Ask Remora: asks the typed question in the scope ⇥ chose.
        case askRemora
    }

    public let id: String
    public let target: Target
    public let title: String
    /// The reason after a title ("allow git push"), the project of a session, "in api-gateway" after an action.
    public let detail: String?
    /// The right edge: the project and age of a session, the key of an action.
    public let trailing: String?
    /// A session's indicator, drawn in the leading slot.
    public let indicator: SessionIndicator?
    /// An SF Symbol for an action, a project or a hit.
    public let symbol: String?
    public let snippet: PaletteSnippet?

    public var sessionID: UUID? {
        switch target {
        case .session(let id), .hit(let id): id
        case .project, .action, .searchOlder, .askRemora: nil
        }
    }
}

public struct PaletteGroup: Identifiable, Equatable, Sendable {
    public let section: PaletteSection
    public let title: String
    public var items: [PaletteItem]

    public var id: PaletteSection { section }
}

/// What the palette knows about one session when it ranks: the card's facts, no model.
struct PaletteSessionInfo: Equatable, Sendable {
    let id: UUID
    let title: String
    let project: String?
    let provider: ManagedSession.Provider
    let lastActivityAt: Date
    let indicator: SessionIndicator
    /// "allow git push", "asks which PDF library": why a session in the needs-you set needs the user.
    let reason: String?
    /// The title, project and reason folded for matching, when the caller kept them from an earlier ranking
    /// (`PaletteFoldCache`); nil is folded when the session is matched.
    let folded: Folded?

    /// The fields a query is matched against, folded for case and accents.
    struct Folded: Equatable, Sendable {
        let title: String
        /// The project and the reason, the weaker fields.
        let others: [String]

        init(title: String, project: String?, reason: String?) {
            self.title = PaletteRanking.fold(title)
            others = [project, reason].compactMap { $0 }.map(PaletteRanking.fold)
        }
    }

    init(id: UUID, title: String, project: String?, provider: ManagedSession.Provider, lastActivityAt: Date,
         indicator: SessionIndicator, reason: String?, folded: Folded? = nil) {
        self.id = id
        self.title = title
        self.project = project
        self.provider = provider
        self.lastActivityAt = lastActivityAt
        self.indicator = indicator
        self.reason = reason
        self.folded = folded
    }

    var needsYou: Bool { AttentionOrder.rank(of: indicator) != nil }
}

/// Folds each session's title, project and reason once per open of the palette. A keystroke ranks the same
/// sessions again; a session whose title, project or reason changed meanwhile is folded again, one that did not
/// is not.
@MainActor
final class PaletteFoldCache {
    private struct Entry {
        let title: String
        let project: String?
        let reason: String?
        let folded: PaletteSessionInfo.Folded
    }

    private var entries: [UUID: Entry] = [:]
    /// How many times a session was folded.
    private(set) var computed = 0

    func folded(for id: UUID, title: String, project: String?, reason: String?) -> PaletteSessionInfo.Folded {
        if let entry = entries[id], entry.title == title, entry.project == project, entry.reason == reason { return entry.folded }
        computed += 1
        let folded = PaletteSessionInfo.Folded(title: title, project: project, reason: reason)
        entries[id] = Entry(title: title, project: project, reason: reason, folded: folded)
        return folded
    }
}

/// A project the palette can open the page of.
struct PaletteProjectInfo: Equatable, Sendable {
    let id: UUID
    let name: String
    let path: String
}
