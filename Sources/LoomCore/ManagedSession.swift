import Foundation

/// A durable Loom conversation. Provider conversation identity and OS execution
/// identity intentionally remain separate: `/clear` and `/new` can move one PTY
/// run to a new conversation record.
public struct ManagedSession: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case claude
        case codex
        case agy
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

    /// The session's harness as the catalogue names it (`HarnessID(provider)`); the stored provider keeps the catalog's
    /// column and every existing switch.
    public var harnessID: HarnessID { HarnessID(provider) }
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

/// A run started with stdin, stdout and stderr pipes instead of a terminal.
public struct ManagedPipeLaunch: Sendable {
    public let session: ManagedSession
    public let pipe: PipeEndpoint
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
    /// Pipe runs only, on Stop and on Quit: asks the child to end its work the way its protocol says, before its
    /// stdin closes (the Chat face interrupts a running turn or a waiting request and waits for the turn's
    /// `result`, spike S1 §D6). It gets the stop's input-close grace as its bound and the stop's reason, must
    /// return within the grace, and cannot fail the stop: whatever it leaves, the closed stdin and the signals
    /// after the grace end. Not called when the leader already exited (`processExited`): there is nobody to ask.
    public let leave: (@Sendable (ManagedRunLeave) async -> Void)?
    /// The run moved to another card (`/clear`, a fork: `adoptConversation` with a new conversation), with the
    /// card it is on now. Called once per move, after the move's events are published, from a task of its own.
    public let moved: (@Sendable (_ sessionID: UUID) async -> Void)?

    public init(
        threadID: String? = nil,
        prepare: @escaping @Sendable () async throws -> Void,
        completed: @escaping @Sendable () async throws -> Void,
        leave: (@Sendable (ManagedRunLeave) async -> Void)? = nil,
        moved: (@Sendable (_ sessionID: UUID) async -> Void)? = nil
    ) {
        self.threadID = threadID
        self.prepare = prepare
        self.completed = completed
        self.leave = leave
        self.moved = moved
    }
}

/// What a pipe run's `leave` hook is told: how long it may take, and why the run is stopping (a Stop, an idle stop,
/// Quit). The owner tells a stop it asked for from an end it did not.
public struct ManagedRunLeave: Sendable, Equatable {
    public let graceSeconds: Double
    public let reason: ManagedRunEndReason

    public init(graceSeconds: Double, reason: ManagedRunEndReason) {
        self.graceSeconds = graceSeconds
        self.reason = reason
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
    /// The conversation has a deletion record: no run may start or be adopted for it.
    case deletionPending(UUID)
    /// A provider conversation id that is being deleted (or was, in this process) must not come back.
    case conversationBeingDeleted(provider: ManagedSession.Provider)

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
            "Provider session is already running: \(provider.rawValue)/\(conversationID)"
        case let .invalidOwnershipMarkers(id):
            "Launch requires this supervisor and managed session's ownership markers: \(id)"
        case let .leaderIdentityUnavailable(pid):
            "Managed run leader identity unavailable: \(pid)"
        case let .deletionPending(id):
            "The session is being deleted: \(id)"
        case let .conversationBeingDeleted(provider):
            "A deleted \(provider.rawValue) session cannot be brought back"
        }
    }
}
