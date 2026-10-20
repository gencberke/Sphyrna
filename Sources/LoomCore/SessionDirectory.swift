import Foundation

/// The harness behind a session, by its stable name. Synthetic sessions (test fixtures) have none and are not listed.
public enum SessionHarness: String, Codable, Sendable, Equatable {
    case claude
    case codex

    init?(_ provider: ManagedSession.Provider) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        case .synthetic: return nil
        }
    }
}

/// The face a live run is driven in.
public enum SessionLiveFace: String, Codable, Sendable, Equatable {
    case terminal
    case chat
}

/// A session's state as one word, whatever its harness. The raw values are the wire names.
public enum SessionStateWord: String, Codable, Sendable, Equatable, CaseIterable {
    case working
    case needsApproval = "needs-approval"
    case waiting
    case failed
    case problem
    case finished
    case ready
    case idle
    case stale
    case stopped
    case unknown

    /// The word for a record, its live state and whether its agent waits for an answer to an open-session request.
    /// The same rules as the sidebar's `SessionIndicator` (LoomCatalogUI), case by case: working; needs approval; waiting for
    /// you (`waiting`); failed; stop not verified and problem (`problem`); identity unclear and state unknown (`unknown`);
    /// finished and unviewed (`finished`); ready; idle; stale; ended (`stopped`). `SessionDirectoryAgreementTests` holds the
    /// two together.
    public static func of(record: CatalogSession, live: SessionViewState?, awaitingOpenApproval: Bool = false) -> SessionStateWord {
        if live?.stopFailure != nil { return .problem }
        if live?.issue != nil { return .problem }
        if let live, live.runID != nil {
            if live.identity == .ambiguous { return .unknown }
            if awaitingOpenApproval || !live.waitingRequests.isEmpty { return .needsApproval }
            switch live.status?.activity {
            case nil, .unknown?: return .unknown
            case .atPrompt?: return .ready
            case .working?: return .working
            case .waitingForApproval?: return .needsApproval
            case .waitingForInput?: return live.waitingAcknowledged ? .ready : .waiting
            case .failed?: return .failed
            case .sessionEnded?: return .stopped
            case .turnComplete?:
                if (live.status?.pendingProviderWorkCount ?? 0) > 0 { return .working }
                return live.unviewedCompletion ? .finished : .ready
            }
        }
        // The run is over; a reliable finish nobody saw stays visible until viewed.
        if live?.unviewedCompletion == true { return .finished }
        switch live?.lifecycle ?? record.lifecycle {
        case .idle: return .idle
        case .stale: return .stale
        case .active: return .stopped
        }
    }
}

/// What the directory says about one session: no transcript content and no path, only what an agent or a pack needs to
/// pick a session.
public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let harness: SessionHarness
    /// The catalog's title, custom or not; nil when the session has none yet.
    public let title: String?
    public let projectID: UUID?
    /// The project's name; nil for a session without a project.
    public let projectName: String?
    public let state: SessionStateWord
    /// The face of the live run; nil without one.
    public let face: SessionLiveFace?
    public let lastActivityAt: Date

    public init(id: UUID, harness: SessionHarness, title: String?, projectID: UUID?, projectName: String?,
                state: SessionStateWord, face: SessionLiveFace?, lastActivityAt: Date) {
        self.id = id
        self.harness = harness
        self.title = title
        self.projectID = projectID
        self.projectName = projectName
        self.state = state
        self.face = face
        self.lastActivityAt = lastActivityAt
    }
}

/// Which sessions the directory lists.
public struct SessionQuery: Equatable, Sendable {
    public static let defaultLimit = 20
    public static let maxLimit = 100

    /// One project's sessions; nil lists every project and the sessions without one.
    public var project: UUID?
    /// At most this many (clamped to 1...`maxLimit`).
    public var limit: Int
    /// Sessions to leave out, typically the asker.
    public var excluding: Set<UUID>

    public init(project: UUID? = nil, limit: Int = SessionQuery.defaultLimit, excluding: Set<UUID> = []) {
        self.project = project
        self.limit = limit
        self.excluding = excluding
    }

    var boundedLimit: Int { min(max(1, limit), Self.maxLimit) }
}

/// The harness-neutral read model of Loom's sessions: "which sessions exist, in which state". One catalog read (the lists'
/// predicate: no side chat, nothing being deleted) joined with one hub snapshot. It writes nothing and starts nothing.
public struct SessionDirectory: Sendable {
    let catalog: SessionCatalog
    let events: SessionEventHub
    /// The agents' open-session requests (D-40); a requester that waits for the user reads as needing approval.
    let openRequests: @Sendable () async -> [OpenSessionRequest]

    init(catalog: SessionCatalog, events: SessionEventHub,
         openRequests: @escaping @Sendable () async -> [OpenSessionRequest] = { [] }) {
        self.catalog = catalog
        self.events = events
        self.openRequests = openRequests
    }

    /// The matching sessions, newest activity first (ties by id, as the lists).
    public func summaries(_ query: SessionQuery = SessionQuery()) async throws -> [SessionSummary] {
        let rows = try await catalog.directoryRows(project: query.project, excluding: query.excluding,
                                                   limit: query.boundedLimit)
        let live = await events.snapshot().sessions
        let awaiting = Set(await openRequests().filter(Self.needsUser).map(\.requesterID))
        return rows.compactMap { row in
            guard let harness = SessionHarness(row.record.session.provider) else { return nil }
            let id = row.record.session.id
            let state = live[id]
            return SessionSummary(
                id: id, harness: harness, title: row.record.title,
                projectID: row.record.projectID, projectName: row.projectName,
                state: SessionStateWord.of(record: row.record, live: state, awaitingOpenApproval: awaiting.contains(id)),
                face: Self.face(of: state), lastActivityAt: row.record.lastActivityAt)
        }
    }

    /// The face of a live run (from the run endpoint); nil without a run.
    static func face(of live: SessionViewState?) -> SessionLiveFace? {
        guard let live, live.runID != nil, let endpoint = live.runEndpoint else { return nil }
        switch endpoint {
        case .terminal: return .terminal
        case .pipe: return .chat
        }
    }

    /// A request nobody answered, or one that failed to start (its box stays until dismissed); one that is starting does not.
    static func needsUser(_ request: OpenSessionRequest) -> Bool {
        switch request.phase {
        case .waiting, .failed: true
        case .starting: false
        }
    }
}
