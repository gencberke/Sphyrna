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

public enum SessionManagementError: Error, CustomStringConvertible, Equatable, Sendable {
    case shutdownStarted
    case sessionAlreadyExists(UUID)
    case sessionNotFound(UUID)
    case sessionAlreadyRunning(UUID)
    case sessionStopping(UUID)
    case sessionNotRunning(UUID)
    case runNotFound(UUID)
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
        case let .runNotFound(id):
            "Managed run not found: \(id)"
        case let .invalidOwnershipMarkers(id):
            "Launch requires this supervisor and managed session's ownership markers: \(id)"
        case let .leaderIdentityUnavailable(pid):
            "Managed run leader identity unavailable: \(pid)"
        }
    }
}
