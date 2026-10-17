import Foundation
import Observation

/// Where the user is in the window: the one fact the detail panel and the persisted selection derive from.
/// `nil` (no destination) is today's "nothing selected". `CatalogModel.selectedSessionID` is derived from it.
public enum Destination: Equatable, Sendable {
    case home
    case session(UUID)
    /// A project's new-session draft; `nil` is a draft with no project.
    case draft(projectID: UUID?)
    case projectPage(UUID)

    public var sessionID: UUID? {
        if case .session(let id) = self { id } else { nil }
    }

    /// The project a destination belongs to by itself (a session's project is read from its record).
    public var projectID: UUID? {
        switch self {
        case .draft(let id): id
        case .projectPage(let id): id
        case .home, .session: nil
        }
    }

    /// A draft is not kept for the next launch: an empty draft is invisible, and its text belongs to the
    /// new-session slice. The last real place stays in the file instead.
    var isRestorable: Bool {
        if case .draft = self { false } else { true }
    }
}

/// The preferences file stores a destination as `{"kind": "...", "id": "..."}`; a kind or id it cannot
/// read decodes as an error, and the preferences then read it as absent.
extension Destination: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case home, session, draft, project }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .home: self = .home
        case .session: self = .session(try container.decode(UUID.self, forKey: .id))
        case .draft: self = .draft(projectID: try container.decodeIfPresent(UUID.self, forKey: .id))
        case .project: self = .projectPage(try container.decode(UUID.self, forKey: .id))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .home: try container.encode(Kind.home, forKey: .kind)
        case .session(let id):
            try container.encode(Kind.session, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .draft(let id):
            try container.encode(Kind.draft, forKey: .kind)
            try container.encodeIfPresent(id, forKey: .id)
        case .projectPage(let id):
            try container.encode(Kind.project, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

/// The two faces of a Claude session. The terminal is today's panel; the chat is the read-only rendering of
/// the transcript (V13).
public enum SessionFace: String, Equatable, Sendable {
    case chat
    case terminal
}

/// Which face the user picked per session, in memory only, and the flag that turns the read-only Chat view
/// on. Not persisted: a relaunch starts from the defaults (stopped: chat, running: terminal).
@MainActor @Observable
public final class SessionFaces {
    /// Off until V13's view exists: with it off, no route is `.chat` and nothing changes on screen.
    public var readOnlyChatEnabled = false
    public private(set) var choices: [UUID: SessionFace] = [:]

    public init() {}

    public func choice(for id: UUID) -> SessionFace? { choices[id] }

    func choose(_ face: SessionFace, for id: UUID) { choices[id] = face }
}
