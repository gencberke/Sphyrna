import Foundation

/// A question the provider asked that only the user can answer. Loom shows it
/// on the card of the conversation it belongs to; an answer is an explicit user
/// action, and a failed answer keeps the request open with the failure text.
public struct ProviderUserRequest: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case command
        case fileChange
        /// A request kind Loom cannot answer; the user handles it in the terminal.
        case unsupported(String)
    }

    public let id: String
    public let kind: Kind
    public let summary: String
    public var failure: String?

    public init(id: String, kind: Kind, summary: String, failure: String? = nil) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.failure = failure
    }

    public var isAnswerable: Bool {
        if case .unsupported = kind { return false }
        return true
    }
}

/// Latest event-derived state of one conversation. It only exists for
/// conversations something happened to in this process: history restored from
/// the catalog is not put here (the catalog page carries it), so the event map
/// stays proportional to live activity, not to history size. `nil` lifecycle or
/// conversation ID means "not reported here; the catalog row is authoritative".
public struct SessionViewState: Equatable, Sendable {
    public var status: ProviderWorkState?
    public var lifecycle: SessionLifecycle?
    public var conversationID: String?
    public var identity: SessionIdentityState
    public var runID: UUID?
    public var blockers: Set<SessionIdleBlocker>
    /// Why the last stop of this conversation could not be verified; cleared by
    /// a verified stop or a new run. Survives skipped frames.
    public var stopFailure: String?
    /// A reliable provider turn completion nobody was looking at. Cleared when
    /// the conversation is viewed (`SessionEventHub.setViewed`) or works again.
    public var unviewedCompletion: Bool
    /// The last thing that went wrong for this conversation outside a stop
    /// (start failure, missing history, lost provider connection). Cleared by a
    /// new run; survives skipped frames.
    public var issue: String?
    public var userRequests: [ProviderUserRequest]

    public init(
        status: ProviderWorkState? = nil, lifecycle: SessionLifecycle? = nil,
        conversationID: String? = nil, identity: SessionIdentityState = .known,
        runID: UUID? = nil, blockers: Set<SessionIdleBlocker> = [],
        stopFailure: String? = nil, unviewedCompletion: Bool = false,
        issue: String? = nil, userRequests: [ProviderUserRequest] = []
    ) {
        self.status = status
        self.lifecycle = lifecycle
        self.conversationID = conversationID
        self.identity = identity
        self.runID = runID
        self.blockers = blockers
        self.stopFailure = stopFailure
        self.unviewedCompletion = unviewedCompletion
        self.issue = issue
        self.userRequests = userRequests
    }
}

public enum SessionEventChange: Equatable, Sendable {
    case snapshot
    case status(ProviderWorkState?)
    case lifecycle(SessionLifecycle)
    case conversationIdentity(String?)
    case identityState(SessionIdentityState)
    case runStarted(UUID)
    case runDetached(UUID)
    case runEnded(UUID, ManagedRunEndReason)
    case blockers(Set<SessionIdleBlocker>)
    case stopFailure(String?)
    case unviewedCompletion(Bool)
    case issue(String?)
    case userRequests([ProviderUserRequest])
    /// The catalog moved this many conversations to `lifecycle` in one batch
    /// (aging). The frame carries no per-conversation entries: the catalog row
    /// is authoritative, and `catalogRevision` tells a consumer that skipped
    /// this frame that it must re-read what it shows.
    case catalogLifecycle(SessionLifecycle, count: Int)
}

/// Each frame carries the latest state of every session. The stream retains one
/// frame per consumer, so a slow consumer can miss intermediate changes but can
/// always reconstruct the latest state without polling.
public struct SessionEventFrame: Equatable, Sendable {
    public let sequence: UInt64
    public let sessionID: UUID?
    public let change: SessionEventChange
    public let sessions: [UUID: SessionViewState]
    /// Counts batched catalog changes that live state cannot express.
    public let catalogRevision: UInt64
}

public actor SessionEventHub {
    private var sequence: UInt64 = 0
    private var catalogRevision: UInt64 = 0
    private var states: [UUID: SessionViewState] = [:]
    private var subscribers: [UUID: AsyncStream<SessionEventFrame>.Continuation] = [:]
    private var viewedSessionID: UUID?

    public init() {}

    public func snapshot() -> SessionEventFrame {
        SessionEventFrame(
            sequence: sequence, sessionID: nil, change: .snapshot,
            sessions: states, catalogRevision: catalogRevision
        )
    }

    public func subscribe() -> AsyncStream<SessionEventFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    public func publish(sessionID: UUID, change: SessionEventChange) {
        let previous = states[sessionID]
        var state = previous ?? SessionViewState()
        switch change {
        case .snapshot: break
        case let .status(value):
            let wasComplete = state.status?.activity == .turnComplete
            state.status = value
            if value?.activity == .working {
                state.unviewedCompletion = false
            } else if value?.activity == .turnComplete, !wasComplete,
                      viewedSessionID != sessionID {
                state.unviewedCompletion = true
            }
        case let .lifecycle(value): state.lifecycle = value
        case let .conversationIdentity(value): state.conversationID = value
        case let .identityState(value): state.identity = value
        case let .runStarted(value):
            state.runID = value
            state.stopFailure = nil
            state.issue = nil
            state.userRequests = []
            state.unviewedCompletion = false
        // A late event of an earlier run must not end a newer run.
        case let .runDetached(value):
            if state.runID == value { state.runID = nil; state.status = nil }
        case let .runEnded(value, _):
            if state.runID == value {
                state.runID = nil
                state.status = nil
                state.userRequests = []
            }
        case let .blockers(value): state.blockers = value
        case let .stopFailure(value): state.stopFailure = value
        case let .unviewedCompletion(value): state.unviewedCompletion = value
        case let .issue(value): state.issue = value
        case let .userRequests(value): state.userRequests = value
        case .catalogLifecycle: return
        }
        // A pure state event that changes nothing wakes nobody and does not
        // advance the sequence (consumers rely on contiguous sequences for the
        // fast path). Run events always publish: they carry run identity.
        switch change {
        case .runStarted, .runDetached, .runEnded, .snapshot: break
        default:
            if state == (previous ?? SessionViewState()) { return }
        }
        states[sessionID] = state
        sequence &+= 1
        yield(sessionID: sessionID, change: change)
    }

    /// Batched lifecycle change of catalog history. Conversations that already
    /// have live state follow the catalog (their stop failure, unviewed
    /// completion and run facts stay); the rest are not added, so the map is
    /// bounded by live activity and not by how many rows aged at once.
    public func publishCatalogLifecycle(_ lifecycle: SessionLifecycle, ids: [UUID]) {
        for id in ids where states[id] != nil { states[id]?.lifecycle = lifecycle }
        catalogRevision &+= 1
        sequence &+= 1
        yield(sessionID: nil, change: .catalogLifecycle(lifecycle, count: ids.count))
    }

    private func yield(sessionID: UUID?, change: SessionEventChange) {
        let frame = SessionEventFrame(
            sequence: sequence, sessionID: sessionID, change: change,
            sessions: states, catalogRevision: catalogRevision
        )
        for continuation in subscribers.values { continuation.yield(frame) }
    }

    /// Drops the live state of a session that no longer exists (a discarded
    /// internal session), so the map stays bounded by what is alive. No frame:
    /// nothing a consumer shows changes.
    public func forget(sessionID: UUID) {
        states[sessionID] = nil
        if viewedSessionID == sessionID { viewedSessionID = nil }
    }

    /// The one conversation the user is looking at in a visible, active window
    /// (nil otherwise). Only this call, never a list refresh, counts as viewing.
    public func setViewed(sessionID: UUID?) {
        viewedSessionID = sessionID
        guard let sessionID, states[sessionID]?.unviewedCompletion == true else { return }
        publish(sessionID: sessionID, change: .unviewedCompletion(false))
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
