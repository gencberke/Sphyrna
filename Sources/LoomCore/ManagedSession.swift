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

/// Provider failure text may contain user content. Retain only a fixed category
/// and numeric RPC code, independently from OS process verification.
public struct ProviderStopStage: Codable, Sendable, Equatable {
    public let stage: String
    public let threadID: String?
    public let outcome: String
    public let errorCategory: String?
    public let rpcCode: Int?

    init(stage: String, threadID: String?, error: (any Error)? = nil) {
        self.stage = stage
        self.threadID = threadID
        outcome = error == nil ? "succeeded" : "failed"
        var category: String?
        var code: Int?
        if let error {
            switch error {
            case let value as CodexAppServerError:
                switch value {
                case let .rpc(value, _, _): category = "rpc"; code = value
                case .closed: category = "connectionClosed"
                case .timeout: category = "timeout"
                case .protocolViolation: category = "protocolViolation"
                case .system: category = "system"
                }
            case is CancellationError: category = "cancelled"
            default: category = "providerError"
            }
        }
        errorCategory = category
        rpcCode = code
    }

    public var failureDescription: String {
        "Provider \(stage) failed (\(errorCategory ?? "unknown")" +
            (rpcCode.map { ", RPC \($0)" } ?? "") + ")"
    }
}

public struct SessionStopReport: Codable, Sendable {
    public var remainingCountVerified: Bool? = nil
    public var providerStages: [ProviderStopStage]? = nil
    public let sessionID: UUID
    public let runID: UUID
    public let elapsedSeconds: Double
    public let signals: [SignalAttempt]
    public let remaining: [ProcessRecord]
    public let errors: [String]
    public let outsideOwnership: [ProcessRecord]

    public var succeeded: Bool {
        remainingCountVerified != false && remaining.isEmpty && errors.isEmpty && outsideOwnership.isEmpty
    }
}

/// Optional provider cleanup around one run's OS process stop. A failed
/// preparation leaves the process alive and makes the stop report unsuccessful.
/// Thrown by a stop hook only when the provider process that owned the
/// conversation's work is verified gone, so no RPC can reach it. The stop then
/// relies on verified process destruction alone (the same rule Quit uses).
public struct ProviderUnavailableError: Error, CustomStringConvertible, Sendable {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var description: String { "Provider unavailable: \(detail)" }
}

public struct ManagedRunStopHooks: Sendable {
    public let threadID: String?
    public let prepare: @Sendable () async throws -> Void
    public let completed: @Sendable () async throws -> Void

    public init(
        threadID: String? = nil,
        prepare: @escaping @Sendable () async throws -> Void,
        completed: @escaping @Sendable () async throws -> Void
    ) {
        self.threadID = threadID
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
