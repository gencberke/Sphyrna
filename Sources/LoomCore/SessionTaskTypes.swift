import Foundation

/// A launch-local claim, authenticated by the runtime owner. The credential is
/// never persisted and is not an app-wide control-socket token.
public struct SessionTaskClaim: Sendable {
    public let sessionID: UUID
    public let managedRunID: UUID
    public let generation: UUID
    public let credential: String

    public init(sessionID: UUID, managedRunID: UUID, generation: UUID, credential: String) {
        self.sessionID = sessionID
        self.managedRunID = managedRunID
        self.generation = generation
        self.credential = credential
    }
}

/// A value returned by the trusted host after authenticating a claim or a
/// provider launch. Native identity never stands in for an app or run ID.
public struct SessionTaskBinding: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let nativeSessionID: String
    public let managedRunID: UUID
    public let generation: UUID

    public init(sessionID: UUID, nativeSessionID: String, managedRunID: UUID, generation: UUID) {
        self.sessionID = sessionID
        self.nativeSessionID = nativeSessionID
        self.managedRunID = managedRunID
        self.generation = generation
    }
}

public enum SessionTaskError: Error, Equatable, Sendable {
    case unauthorized, notFound, invalidPayload, conflictingOperation, childAlreadyOwned
    case pendingInput, needsApproval, staleBinding, staleRound, alreadySettled
    case unverified, notReady, missingReport, tooManyWaiters, invalidDeadline, invalidPage
    case storage, capacityExceeded
}

public enum SessionTaskLifecycle: String, Codable, Sendable {
    case active, revoked, stopping, stopUnverified, stopped, identityChanged
}

public enum SessionTaskRoundPhase: String, Codable, Sendable {
    case queued, deliveringUnknown, active, awaitingParent, completed, failed, retired
}

public enum SessionTaskDelivery: String, Codable, Sendable {
    case queued, unknown, submitted, deferred, cancelled, verified, unverified, alreadySettled
}

public enum SessionTaskReportKind: String, Codable, Sendable {
    case completed, failed, needsParentInput
}

public enum SessionTaskNativeStatus: String, Codable, Sendable {
    case notStarted, ready, working, waitingForUser, stopped, unknown
}

/// A host-verified observation of the submitted input. A provider prompt or an
/// app-side observation is not a provider-native turn ID. App observations
/// must be correlated with an actual provider input event, not merely a write.
public enum SessionTaskExecutionReference: Codable, Equatable, Sendable {
    case nativeTurn(String)
    case providerPrompt(String)
    case appInputObservation(UUID)
}

public struct SessionTaskReceipt: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let taskID: UUID
    public let roundID: UUID?
    public var delivery: SessionTaskDelivery
    /// Only an actual native turn is recorded here. A successful write or an
    /// app notification is not evidence of input consumption.
    public var consumedTurnID: String? = nil
    public var consumedExecution: SessionTaskExecutionReference? = nil
    /// Version-one receipts can contain a native turn without the newer proof field.
    public var observedConsumption: SessionTaskExecutionReference? {
        consumedExecution ?? consumedTurnID.map(SessionTaskExecutionReference.nativeTurn)
    }
}

public struct SessionTaskRound: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let ordinal: Int
    public let operationID: UUID
    public let message: String
    public let replyToEventID: UUID?
    public var phase: SessionTaskRoundPhase
    public var binding: SessionTaskBinding?
    public var nativeTurnID: String?
    public var execution: SessionTaskExecutionReference? = nil
}

public struct SessionTaskEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let roundID: UUID
    public let nativeTurnID: String?
    public let execution: SessionTaskExecutionReference?
    public let kind: SessionTaskReportKind
    public let payload: String
    public let occurredAt: Date
    /// Events written by the earlier store already identify a native turn.
    public var observedExecution: SessionTaskExecutionReference? {
        execution ?? nativeTurnID.map(SessionTaskExecutionReference.nativeTurn)
    }
}

/// Stored choices are the user's requested choices; effective fields are only
/// supplied by the host after a real provider reports them.
public struct SessionTaskProjection: Codable, Equatable, Sendable {
    public let id: UUID
    public let parentSessionID: UUID
    public let childSessionID: UUID
    public let harness: HarnessID
    public let childName: String
    public let requestedChoices: HarnessLaunchChoices
    public var effectiveModel: String?
    public var effectiveEffort: String?
    public var effectiveMode: HarnessMode?
    public var parentBinding: SessionTaskBinding
    public var childBinding: SessionTaskBinding?
    public var lifecycle: SessionTaskLifecycle
    public var expiresAt: Date
    public var childInputLimit: Int
    public var parentWakeLimit: Int
    public var childInputsUsed: Int
    public var parentWakesUsed: Int
    public var parentWakesConsumed: Int
    public var uncertainChildEffects: Int
    public var uncertainWakeEffects: Int
    public var authorityEpoch: Int64
    public var activeRoundID: UUID?
    public var pendingRoundID: UUID?
    public var currentAttentionID: UUID?
    public var nextOrdinal: Int
    public var revision: Int64
    /// Internal idempotence key for the initial approved request, never a credential.
    var creationOperationID: UUID? = nil
    var creationFingerprint: String? = nil
}

public struct SessionTaskPage<Element: Sendable>: Sendable {
    public let items: [Element]
    /// A cursor when the page is full; the next page can still be empty.
    public let next: Int64?
}

/// App-only metadata for a bounded view of task relationships. It contains no
/// round messages or result payloads.
public struct SessionTaskProjectionPage: Sendable {
    public let items: [SessionTaskProjection]
    public let next: UUID?
}

/// A durable event cursor allows a bounded transport to return and acknowledge
/// only the events that actually fit in one reply.
public struct SessionTaskEventEntry: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let event: SessionTaskEvent
}

public struct SessionTaskStatus: Sendable {
    public let task: SessionTaskProjection
    public let activeRound: SessionTaskRound?
    public let pendingRound: SessionTaskRound?
    public let nativeStatus: SessionTaskNativeStatus
    /// A Ready provider is not a declared result for an unreported round.
    public let missingReport: Bool
}

public struct SessionTaskInputIntent: Sendable {
    public let task: SessionTaskProjection
    public let round: SessionTaskRound
}

/// A nudge carries only a task pointer and count. Payloads are read explicitly
/// through the task-scoped paged API, never injected into the parent's context.
public struct SessionTaskWakeIntent: Sendable {
    public let taskID: UUID
    public let operationID: UUID
    public let parentBinding: SessionTaskBinding
    public let eventCount: Int
    let lease: SessionTaskWakeLease

    /// The host must put the synchronous queue admission inside this fence.
    /// A read or lifecycle fence that wins first prevents the pointer write.
    public func attemptDelivery(_ admit: () -> Bool) -> Bool { lease.attempt(admit) }
}

final class SessionTaskWakeLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func attempt(_ admit: () -> Bool) -> Bool {
        lock.withLock { !cancelled && admit() }
    }

    func cancel() { lock.withLock { cancelled = true } }

    /// Keep acknowledgement and admission ordered across the SQLite commit.
    func cancelIfChanged(_ mutation: () throws -> Bool) rethrows -> Bool {
        try lock.withLock {
            let changed = try mutation()
            if changed { cancelled = true }
            return changed
        }
    }
}

public struct SessionTaskRoundTarget: Sendable {
    public let taskID: UUID
    public let roundID: UUID
    public let inputOperationID: UUID
    public let binding: SessionTaskBinding
    public let nativeTurnID: String?
    public let execution: SessionTaskExecutionReference?
    var interruptLease: SessionTaskInterruptLease? = nil

    /// Only the coordinator's currently live exact-round effect may write.
    public func attemptInterrupt(_ admit: () -> Bool) -> Bool { interruptLease?.attempt(admit) ?? false }
}

final class SessionTaskInterruptLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func attempt(_ admit: () -> Bool) -> Bool { lock.withLock { !cancelled && admit() } }
    func cancel() { lock.withLock { cancelled = true } }
    func cancelIfChanged(_ mutation: () throws -> Bool) rethrows -> Bool {
        try lock.withLock {
            let changed = try mutation()
            if changed { cancelled = true }
            return changed
        }
    }
}

public enum SessionTaskInputEffect: Sendable {
    /// A newly owned empty child is bound, but no input has been submitted.
    case started(binding: SessionTaskBinding)
    /// The host accepted one input and returned the actual owned session/run.
    /// A write acknowledgement is not proof of exactly-once model execution.
    case submitted(binding: SessionTaskBinding, nativeTurnID: String?, actualModel: String?, actualEffort: String?, actualMode: HarnessMode?)
    /// The host atomically checked readiness/binding and performed no effect.
    case deferred
    /// The effect may have occurred. It must never be retried automatically.
    case unknown
}

public enum SessionTaskEffect: Sendable {
    case verified, deferred, unknown
}

/// Implemented only by the existing runtime owner. Authentication checks the
/// launch-local secret and live run; new-child reservation proves the app owns
/// a new child rather than adopting another session. Delivery must atomically
/// recheck the exact binding, Ready state and any referenced attention
/// occurrence immediately before writing. An
/// approval prompt is never Ready. The host enforces the user-approved
/// permission ceiling before execution and never answers provider approvals on
/// the parent's behalf. A resumed native session retains provider-authoritative
/// settings; requested choices are not reapplied. Unknown effects cannot be replayed.
public protocol SessionTaskHost: Sendable {
    func authenticate(_ claim: SessionTaskClaim) async -> SessionTaskBinding?
    func ownsNewChild(taskID: UUID, parent: SessionTaskBinding, childID: UUID) async -> Bool
    /// Resolve an actual input observation for the exact task, round, input
    /// operation and live binding, including an initial submit still in flight.
    /// The host must correlate the observation with that submission, not trust
    /// a caller-supplied identifier or infer it from an app round ID.
    func observedChildExecution(_ target: SessionTaskRoundTarget) async -> SessionTaskExecutionReference?
    /// Consumption is a provider/input observation tied to the exact wake
    /// operation and live parent binding; a successful write alone is not it.
    func observedWakeExecution(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) async -> SessionTaskExecutionReference?
    /// An on-demand observation, not a model call or a cached second owner.
    func nativeStatus(binding: SessionTaskBinding) async -> SessionTaskNativeStatus
    func submitIfReady(_ intent: SessionTaskInputIntent) async -> SessionTaskInputEffect
    /// Check readiness first, then admit the synchronous pointer write through
    /// `intent.attemptDelivery`. A false result must perform no provider effect.
    func wakeIfReady(_ intent: SessionTaskWakeIntent) async -> SessionTaskEffect
    func interrupt(_ target: SessionTaskRoundTarget) async -> SessionTaskEffect
    func stopChild(taskID: UUID, binding: SessionTaskBinding) async -> SessionTaskEffect
    /// Verify/stop only this app-owned child's uncertain initial launch; never
    /// attach to an unrelated native session or start a replacement.
    func stopUnknownChild(taskID: UUID, childSessionID: UUID) async -> SessionTaskEffect
    /// Establish that an uncertain wake can no longer execute. It does not
    /// claim the parent consumed it and never causes it to be replayed.
    func verifyUnknownWakeStopped(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) async -> Bool
    /// The owner must already have fenced this session and verified that its
    /// relevant owned effects are stopped. The fence holds through forgetting.
    func mayForget(sessionID: UUID) async -> Bool
}

public enum SessionTaskLimits {
    public static let payloadBytes = 16 * 1024
    public static let pageSize = 50
    public static let childInputs = 3
    public static let parentWakes = 6
    public static let grantLifetime: TimeInterval = 60 * 60
    public static let maxWait: TimeInterval = 60
    public static let maxWaiters = 64

    static func text(_ value: String, empty: Bool = false) throws {
        guard value.utf8.count <= payloadBytes, !value.utf8.contains(0),
              empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionTaskError.invalidPayload
        }
    }
}
