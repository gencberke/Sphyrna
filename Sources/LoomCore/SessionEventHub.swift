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
    /// The user marked a "waiting for input" state as read (`SessionEventHub.markRead`). A display
    /// acknowledgement only: it holds through the at-prompt period (finished turn, waiting for input, at prompt)
    /// and ends with any other status, a new unseen completion, a new run or the end of the run. Nothing is sent to the provider.
    public var waitingAcknowledged: Bool
    /// The last thing that went wrong for this conversation outside a stop
    /// (start failure, missing history, lost provider connection). Cleared by a
    /// new run; survives skipped frames.
    public var issue: String?
    public var userRequests: [ProviderUserRequest]
    /// The subagents the run's conversation has under it (D-39). Only a live run has any: the list is
    /// cleared by a new run, a detach and the end of the run, and an update that arrives after the run
    /// ended is ignored.
    public var subagents: [SubagentRecord]

    public init(
        status: ProviderWorkState? = nil, lifecycle: SessionLifecycle? = nil,
        conversationID: String? = nil, identity: SessionIdentityState = .known,
        runID: UUID? = nil, blockers: Set<SessionIdleBlocker> = [],
        stopFailure: String? = nil, unviewedCompletion: Bool = false,
        waitingAcknowledged: Bool = false, issue: String? = nil, userRequests: [ProviderUserRequest] = [],
        subagents: [SubagentRecord] = []
    ) {
        self.status = status
        self.lifecycle = lifecycle
        self.conversationID = conversationID
        self.identity = identity
        self.runID = runID
        self.blockers = blockers
        self.stopFailure = stopFailure
        self.unviewedCompletion = unviewedCompletion
        self.waitingAcknowledged = waitingAcknowledged
        self.issue = issue
        self.userRequests = userRequests
        self.subagents = subagents
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
    /// The user marked the conversation's attention state as read: see `SessionEventHub.markRead`.
    case markedRead
    case issue(String?)
    case userRequests([ProviderUserRequest])
    /// The conversation's subagents changed (a start, a stop, details read, the next turn).
    case subagents([SubagentRecord])
    /// The catalog moved this many conversations to `lifecycle` in one batch
    /// (aging). The frame carries no per-conversation entries: the catalog row
    /// is authoritative, and `catalogRevision` tells a consumer that skipped
    /// this frame that it must re-read what it shows.
    case catalogLifecycle(SessionLifecycle, count: Int)
    /// The catalog row of this conversation took a new activity time (a prompt, a finished
    /// turn, a run that moved to it). No per-conversation state: the catalog row is the
    /// authority and a consumer re-reads what it shows (`catalogRevision` moves).
    case activityRecorded
    /// A conversation was deleted completely (its record is finished). The frame names it in
    /// `sessionID` but `sessions` no longer holds it: tabs, caches and lists drop it.
    case conversationDeleted
    /// A deletion stopped before it was complete; the conversation stays and the deletion
    /// record (state, last failure) is the authority (`SessionRuntime.pendingDeletions`).
    case deletionIncomplete
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
    /// Counts finished Claude turns (a published `turnComplete` status). A consumer that skipped
    /// frames still sees that a turn finished: the count in its latest frame differs from its last.
    public let turnCompletions: UInt64
}

public actor SessionEventHub {
    private var sequence: UInt64 = 0
    private var catalogRevision: UInt64 = 0
    private var turnCompletions: UInt64 = 0
    private var states: [UUID: SessionViewState] = [:]
    private var subscribers: [UUID: AsyncStream<SessionEventFrame>.Continuation] = [:]
    private var viewedSessionID: UUID?

    public init() {}

    public func snapshot() -> SessionEventFrame {
        SessionEventFrame(
            sequence: sequence, sessionID: nil, change: .snapshot,
            sessions: states, catalogRevision: catalogRevision, turnCompletions: turnCompletions
        )
    }

    public func subscribe() -> AsyncStream<SessionEventFrame> {
        subscribe(bufferingPolicy: .bufferingNewest(1))
    }

    /// A consumer that must see every change rather than the latest state (a test asserting a
    /// transient change such as `.deletionIncomplete`) passes `.unbounded`.
    func subscribe(
        bufferingPolicy: AsyncStream<SessionEventFrame>.Continuation.BufferingPolicy
    ) -> AsyncStream<SessionEventFrame> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
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
            if !Self.isAtPromptPeriod(value?.activity) { state.waitingAcknowledged = false }
            if value?.activity == .working {
                state.unviewedCompletion = false
            } else if value?.activity == .turnComplete, !wasComplete,
                      viewedSessionID != sessionID {
                state.unviewedCompletion = true
                state.waitingAcknowledged = false
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
            state.waitingAcknowledged = false
            state.subagents = []
        // A late event of an earlier run must not end a newer run.
        case let .runDetached(value):
            if state.runID == value {
                state.runID = nil; state.status = nil; state.waitingAcknowledged = false; state.subagents = []
            }
        case let .runEnded(value, _):
            if state.runID == value {
                state.runID = nil
                state.status = nil
                state.waitingAcknowledged = false
                state.userRequests = []
                state.subagents = []
            }
        case let .blockers(value): state.blockers = value
        case let .stopFailure(value): state.stopFailure = value
        case let .unviewedCompletion(value): state.unviewedCompletion = value
        case .markedRead:
            state.unviewedCompletion = false
            if Self.isAtPromptPeriod(state.status?.activity) { state.waitingAcknowledged = true }
        case let .issue(value): state.issue = value
        case let .userRequests(value): state.userRequests = value
        case let .subagents(value):
            // A late update must not bring subagents back to a session whose run is over.
            guard state.runID != nil || value.isEmpty else { return }
            state.subagents = value
        case .catalogLifecycle, .conversationDeleted, .deletionIncomplete, .activityRecorded: return
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
        if case let .status(value) = change, value?.activity == .turnComplete { turnCompletions &+= 1 }
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

    /// Announces that the catalog stamped real use of a conversation, without keeping state for it.
    public func publishActivity(sessionID: UUID) {
        catalogRevision &+= 1
        sequence &+= 1
        yield(sessionID: sessionID, change: .activityRecorded)
    }

    /// Announces the outcome of a deletion without keeping state for the conversation
    /// (`.conversationDeleted` must not recreate the entry `forget` just dropped). The catalog
    /// revision moves, so a consumer that skips this frame still re-reads what it shows.
    public func publishDeletion(sessionID: UUID, change: SessionEventChange) {
        guard change == .conversationDeleted || change == .deletionIncomplete else { return }
        catalogRevision &+= 1
        sequence &+= 1
        yield(sessionID: sessionID, change: change)
    }

    private func yield(sessionID: UUID?, change: SessionEventChange) {
        let frame = SessionEventFrame(
            sequence: sequence, sessionID: sessionID, change: change,
            sessions: states, catalogRevision: catalogRevision, turnCompletions: turnCompletions
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

    /// The statuses of one at-prompt period: a finished turn, the provider idling for input, a fresh prompt.
    /// A real Claude goes from a finished turn to waiting for input on its own, about a minute later.
    private static func isAtPromptPeriod(_ activity: AgentActivity?) -> Bool {
        switch activity {
        case .turnComplete?, .waitingForInput?, .atPrompt?: true
        default: false
        }
    }

    /// "Mark as Read": a finished turn nobody looked at counts as seen, and a conversation waiting at its
    /// prompt is acknowledged, so both show the neutral Ready. The acknowledgement survives repeats of the
    /// same waiting state (later idle samples, a repeated idle notification) and ends with the next change
    /// of status, so a new turn that finishes and idles shows "waiting" again. Display state only.
    public func markRead(sessionID: UUID) {
        publish(sessionID: sessionID, change: .markedRead)
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
