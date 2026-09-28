import Foundation

/// A durable Loom conversation. Provider conversation identity and OS execution
/// identity intentionally remain separate: `/clear` and `/new` can move one PTY
/// run to a new conversation record.
public struct ManagedSession: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case claude
        case codex
        case synthetic
    }

    public let id: UUID
    public let provider: Provider
    public var providerConversationID: String?
    public let workingDirectory: String
    public internal(set) var currentRun: ManagedRun?

    public init(id: UUID = UUID(), provider: Provider, providerConversationID: String? = nil,
                workingDirectory: String) {
        self.id = id
        self.provider = provider
        self.providerConversationID = providerConversationID
        self.workingDirectory = workingDirectory
        currentRun = nil
    }
}

/// One OS execution of a managed conversation. This ID is also carried in the
/// environment so late provider events and reparented descendants cannot be
/// confused with a later resume of the same conversation.
public struct ManagedRun: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case running
        case stopping
        case exited
    }

    public let id: UUID
    public let leader: ProcessIdentity
    public let startedAt: Date
    public internal(set) var state: State
    public internal(set) var exitStatus: Int32?
    public internal(set) var descendants: Set<ProcessIdentity>
}

public struct ManagedSessionLaunch: Sendable {
    public let session: ManagedSession
    public let terminal: TerminalEndpoint
}

public enum SessionIdentityState: String, Equatable, Sendable {
    case known
    case ambiguous
}

public enum ConversationTransition: Sendable {
    case bind
    case automatic
    case new
    case resume
}

public struct ManagedRunContext: Sendable {
    public let launchSessionID: UUID
    public let activeSessionID: UUID
    public let session: ManagedSession

    public init(
        launchSessionID: UUID, activeSessionID: UUID, session: ManagedSession
    ) {
        self.launchSessionID = launchSessionID
        self.activeSessionID = activeSessionID
        self.session = session
    }
}

public struct SessionStopReport: Codable, Sendable {
    public let sessionID: UUID
    public let runID: UUID
    public let elapsedSeconds: Double
    public let signals: [SignalAttempt]
    public let remaining: [ProcessRecord]
    public let errors: [String]
    public let outsideOwnership: [ProcessRecord]

    public var succeeded: Bool {
        remaining.isEmpty && errors.isEmpty && outsideOwnership.isEmpty
    }
}

/// Optional provider cleanup around one run's OS process stop. A failed
/// preparation leaves the process alive and makes the stop report unsuccessful.
public struct ManagedRunStopHooks: Sendable {
    public let prepare: @Sendable () async throws -> Void
    public let completed: @Sendable () async throws -> Void

    public init(
        prepare: @escaping @Sendable () async throws -> Void,
        completed: @escaping @Sendable () async throws -> Void
    ) {
        self.prepare = prepare
        self.completed = completed
    }
}

public enum SessionManagementError: Error, CustomStringConvertible, Equatable, Sendable {
    case shutdownStarted
    case sessionAlreadyExists(UUID)
    case sessionNotFound(UUID)
    case sessionAlreadyRunning(UUID)
    case sessionStopping(UUID)
    case sessionNotRunning(UUID)
    case runAlreadyExists(UUID)
    case runNotFound(UUID)
    case conversationAlreadyRunning(provider: ManagedSession.Provider, conversationID: String)
    case invalidOwnershipMarkers(sessionID: UUID)
    case leaderIdentityUnavailable(Int32)

    public var description: String {
        switch self {
        case .shutdownStarted:
            "Operation rejected: shutdown has started"
        case let .sessionAlreadyExists(id):
            "Managed session already exists: \(id)"
        case let .sessionNotFound(id):
            "Managed session not found: \(id)"
        case let .sessionAlreadyRunning(id):
            "Managed session is already running: \(id)"
        case let .sessionStopping(id):
            "Managed session is stopping: \(id)"
        case let .sessionNotRunning(id):
            "Managed session is not running: \(id)"
        case let .runAlreadyExists(id):
            "Managed run already exists: \(id)"
        case let .runNotFound(id):
            "Managed run not found: \(id)"
        case let .conversationAlreadyRunning(provider, conversationID):
            "Provider conversation is already running: \(provider.rawValue)/\(conversationID)"
        case let .invalidOwnershipMarkers(id):
            "Launch requires this supervisor and managed session's ownership markers: \(id)"
        case let .leaderIdentityUnavailable(pid):
            "Managed run leader identity unavailable: \(pid)"
        }
    }
}
