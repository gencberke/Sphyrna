import Foundation
import LoomCore

/// The command palette's rows and the groups they sit in. Plain values: the ranking builds them, the view
/// draws them and the tests compare them.
public enum PaletteSection: Int, CaseIterable, Sendable {
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

        public var label: String { self == .you ? "You" : "Claude" }
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
        case .project, .action, .searchOlder: nil
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

    var needsYou: Bool { AttentionOrder.rank(of: indicator) != nil }
}

/// A project the palette can open the page of.
struct PaletteProjectInfo: Equatable, Sendable {
    let id: UUID
    let name: String
    let path: String
}
