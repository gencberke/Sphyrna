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

/// How a live run is driven: a terminal (the provider's TUI in a PTY) or pipes (Claude's stream-json child,
/// driven by the Chat face, V16). A running session is one with a run, whatever its endpoint: views must not take
/// "has a terminal view" for "running". Persisted with the session as its owning face (`SessionCatalog.runEndpoint`).
public enum RunEndpointKind: String, Equatable, Sendable, Codable {
    case terminal
    case pipe
}

/// The subagent that asked a request (V23): its `agent_id`, which is the stream's `task_id` and the ledger's record id, and
/// the name and description its card shows ("From <name> · <description>"). Memory only, like the rest of the request.
public struct ProviderRequestAgent: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// A request of a live run that waits for the user, whatever the provider: an approval, a question or a plan.
/// Keyed by the provider's request id and the tool call it is about. Home, the sidebar and the Dock read these;
/// the Chat face's cards (V18) are built on them. The summary is display text (a tool name, a question's
/// header); it is held in memory only and never logged.
public struct ProviderPendingRequest: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case approval
        case question
        case plan
    }

    public var id: String { requestID }
    public let requestID: String
    public let toolUseID: String?
    public let kind: Kind
    public let toolName: String
    /// An approval's command or path (the tool's name when it has none), a question's header, "Plan ready".
    public let summary: String
    /// Claude's own words about an approval (Bash's `description`), when it gave some.
    public let note: String?
    /// When Loom learned of it; nil when the provider's request does not say (Codex).
    public let arrivedAt: Date?
    /// The subagent that asked, when `agent_id` named one (the Chat face only); nil for a main-thread request, a
    /// terminal request and Codex's.
    public let agent: ProviderRequestAgent?

    public init(requestID: String, toolUseID: String?, kind: Kind, toolName: String, summary: String,
                note: String? = nil, arrivedAt: Date?, agent: ProviderRequestAgent? = nil) {
        self.requestID = requestID
        self.toolUseID = toolUseID
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.note = note
        self.arrivedAt = arrivedAt
        self.agent = agent
    }
}

extension StatusReason {
    /// The reason line a waiting request states (the sidebar's Active card, Home's Needs you, the inspector): the same
    /// words a hook-reported permission request gets, so a Chat-face request reads like a terminal one.
    public init(request: ProviderPendingRequest) {
        switch request.kind {
        case .approval:
            let tool = Self.oneLine(request.toolName, limit: 80) ?? "Tool"
            let detail = request.summary == request.toolName ? nil : Self.oneLine(request.summary)
            let note = request.note.flatMap { Self.oneLine($0) }
            self.init(.approval(tool: tool), detail: detail, note: note == detail ? nil : note)
        case .question:
            self.init(.question, detail: Self.oneLine(request.summary))
        case .plan:
            self.init(.planReady)
        }
    }
}

/// Where a live run stands for the activity view's Active section (FB4-2): a turn is under way, or it
/// ended while nobody was looking and the user has not read the end yet. Derived here, beside
/// `unviewedCompletion`, so card states keep one source (`SessionEventHub.publish`).
public enum ActivePhase: Equatable, Sendable {
    case inactive
    case underWay
    case endedUnread
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
    /// How the live run is driven; nil without a run (and for a moment after `runStarted`).
    public var runEndpoint: RunEndpointKind?
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
    /// Whether the run belongs in the Active section: under way from the start of a turn (work, an approval, a
    /// question during the turn, background work after it), then "ended unread" when the turn finished or
    /// failed while the conversation was not viewed. Viewing or "Mark as Read" ends it; so do a prompt, a new
    /// run and the end of the run. An idle notice after a turn the user read changes nothing.
    public var activePhase: ActivePhase
    /// The last thing that went wrong for this conversation outside a stop
    /// (start failure, missing history, lost provider connection). Cleared by a
    /// new run; survives skipped frames.
    public var issue: String?
    public var userRequests: [ProviderUserRequest]
    /// The live run's requests that wait for the user (provider-independent; the Chat face publishes them).
    /// Cleared by a new run and by the end of the run.
    public var pendingRequests: [ProviderPendingRequest]
    /// The subagents the run's conversation has under it (D-39). Only a live run has any: the list is
    /// cleared by a new run, a detach and the end of the run, and an update that arrives after the run
    /// ended is ignored.
    public var subagents: [SubagentRecord]
    /// Why the session shows its status: the tool and command of an approval, a question's header, "plan
    /// ready", the first line of the last message, a failure's details. Changes only at hook boundaries
    /// (and when the registry shows an approval was cancelled), never per frame. Memory only, never logged;
    /// cleared by a new run. A detach or the end of the run keeps the last line of a finished or failed turn
    /// (`.turnDone`, `.failure`) for the card that waits to be read, and drops any other reason.
    public var reason: StatusReason?
    /// The live run's permission mode and effort as Claude last reported them at a hook of its main thread (a prompt, a
    /// permission request), in the CLI's words (`ClaudeHookEvent.permissionMode`, `.effort`), so a terminal Shift+Tab or
    /// `/effort` shows at the next such hook. A report without one, or with a word Loom does not know, keeps the last
    /// known value. Nil until the run reports one (the stored launch choices hold until then); cleared by a new run and by
    /// the end of the run, when the stored choices are again what the next start passes. Memory only, never logged.
    public var permissionMode: String?
    public var effort: String?

    public init(
        status: ProviderWorkState? = nil, lifecycle: SessionLifecycle? = nil,
        conversationID: String? = nil, identity: SessionIdentityState = .known,
        runID: UUID? = nil, blockers: Set<SessionIdleBlocker> = [],
        stopFailure: String? = nil, unviewedCompletion: Bool = false,
        waitingAcknowledged: Bool = false, activePhase: ActivePhase = .inactive, issue: String? = nil,
        userRequests: [ProviderUserRequest] = [], subagents: [SubagentRecord] = [], reason: StatusReason? = nil,
        runEndpoint: RunEndpointKind? = nil, pendingRequests: [ProviderPendingRequest] = [],
        permissionMode: String? = nil, effort: String? = nil
    ) {
        self.permissionMode = permissionMode
        self.effort = effort
        self.runEndpoint = runEndpoint
        self.pendingRequests = pendingRequests
        self.status = status
        self.lifecycle = lifecycle
        self.conversationID = conversationID
        self.identity = identity
        self.runID = runID
        self.blockers = blockers
        self.stopFailure = stopFailure
        self.unviewedCompletion = unviewedCompletion
        self.waitingAcknowledged = waitingAcknowledged
        self.activePhase = activePhase
        self.issue = issue
        self.userRequests = userRequests
        self.subagents = subagents
        self.reason = reason
    }

    /// Why the session shows its status: the first waiting request (what the user is being asked, whichever provider
    /// and face asked it), else the hook-reported `reason`. Changes only when a request arrives or leaves, or at a hook
    /// boundary, never per frame.
    public var displayReason: StatusReason? {
        waitingRequests.first.map(StatusReason.init(request:)) ?? reason
    }

    /// Every request of the live run that waits for the user, in one list whatever the provider: the Chat face's
    /// (`pendingRequests`), then Codex's answerable ones (`userRequests`: a command or a file change is an approval).
    public var waitingRequests: [ProviderPendingRequest] {
        pendingRequests + userRequests.filter(\.isAnswerable).map { request in
            let toolName: String
            switch request.kind {
            // Named as Claude's tools are, so `SessionReasonLine.approvalText` words them as it words Claude's own
            // ("Asks to run: <command>", "Asks to edit: <file>") for either provider.
            case .command: toolName = "Bash"
            case .fileChange: toolName = "Edit"
            case let .unsupported(name): toolName = name
            }
            return ProviderPendingRequest(requestID: request.id, toolUseID: nil, kind: .approval, toolName: toolName,
                                          summary: request.summary, arrivedAt: nil)
        }
    }
}

public enum SessionEventChange: Equatable, Sendable {
    case snapshot
    case status(ProviderWorkState?)
    case lifecycle(SessionLifecycle)
    case conversationIdentity(String?)
    case identityState(SessionIdentityState)
    case runStarted(UUID)
    /// The endpoint of a run that started (published right after its `runStarted`).
    case runEndpoint(UUID, RunEndpointKind)
    /// The live run's pending requests, the whole list.
    case pendingRequests([ProviderPendingRequest])
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
    /// The reason for the conversation's status changed (a permission request, a stop, a failure, a
    /// prompt) or no longer holds. Published before the status it explains.
    case reason(StatusReason?)
    /// The live run reported its permission mode or effort (see `SessionViewState.permissionMode`); nil leaves a value as
    /// it was.
    case reportedChoices(permissionMode: String?, effort: String?)
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
            let phase = Self.activePhase(after: value, from: state.activePhase,
                                         viewed: viewedSessionID == sessionID,
                                         newFailure: value?.isFailure == true && previous?.status?.isFailure != true)
            // Background work that ends while nobody looks is the task's real end, even when the turn itself
            // was seen or still had work pending: it shows as finished, like a turn that ends unseen.
            if phase == .endedUnread, state.activePhase == .underWay, value?.activity == .turnComplete {
                state.unviewedCompletion = true
                state.waitingAcknowledged = false
            }
            state.activePhase = phase
        case let .lifecycle(value): state.lifecycle = value
        case let .conversationIdentity(value): state.conversationID = value
        case let .identityState(value): state.identity = value
        case let .runStarted(value):
            state.runID = value
            state.runEndpoint = nil
            state.pendingRequests = []
            state.stopFailure = nil
            state.issue = nil
            state.userRequests = []
            state.unviewedCompletion = false
            state.waitingAcknowledged = false
            state.activePhase = .inactive
            state.subagents = []
            state.reason = nil
            state.permissionMode = nil
            state.effort = nil
        // A late event of an earlier run must not end a newer run.
        case let .runDetached(value):
            if state.runID == value {
                state.runID = nil; state.status = nil; state.waitingAcknowledged = false; state.subagents = []
                state.runEndpoint = nil; state.pendingRequests = []
                state.activePhase = .inactive
                state.permissionMode = nil; state.effort = nil
                state.reason = state.reason.flatMap(Self.keptAfterRun)
            }
        case let .runEnded(value, _):
            if state.runID == value {
                state.runID = nil
                state.runEndpoint = nil
                state.pendingRequests = []
                state.status = nil
                state.waitingAcknowledged = false
                state.activePhase = .inactive
                state.userRequests = []
                state.subagents = []
                state.permissionMode = nil
                state.effort = nil
                state.reason = state.reason.flatMap(Self.keptAfterRun)
            }
        case let .blockers(value): state.blockers = value
        case let .stopFailure(value): state.stopFailure = value
        case let .unviewedCompletion(value):
            state.unviewedCompletion = value
            if !value, state.activePhase == .endedUnread { state.activePhase = .inactive }
        case .markedRead:
            state.unviewedCompletion = false
            // An acknowledged question (the turn is still marked under way) is read like an unread end.
            if state.activePhase == .endedUnread
                || (state.activePhase == .underWay && state.status?.activity == .waitingForInput) {
                state.activePhase = .inactive
            }
            if Self.isAtPromptPeriod(state.status?.activity) { state.waitingAcknowledged = true }
        case let .issue(value): state.issue = value
        case let .userRequests(value): state.userRequests = value
        case let .runEndpoint(run, kind):
            guard state.runID == run else { return }
            state.runEndpoint = kind
        case let .pendingRequests(value):
            // A late list must not bring requests back to a session whose run is over.
            guard state.runID != nil || value.isEmpty else { return }
            state.pendingRequests = value
        case let .subagents(value):
            // A late update must not bring subagents back to a session whose run is over.
            guard state.runID != nil || value.isEmpty else { return }
            state.subagents = value
        case let .reason(value):
            // A late reason must not come back to a session whose run is over.
            guard state.runID != nil || value == nil else { return }
            state.reason = value
        case let .reportedChoices(mode, effort):
            // A late report must not bring values back to a session whose run is over.
            guard state.runID != nil else { return }
            if let mode { state.permissionMode = mode }
            if let effort { state.effort = effort }
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
        // A failed turn has no unviewed completion but still ends unread (Active section).
        guard let sessionID, let state = states[sessionID],
              state.unviewedCompletion || state.activePhase == .endedUnread else { return }
        publish(sessionID: sessionID, change: .unviewedCompletion(false))
    }

    /// The reason that outlives its run: what the turn ended with, for a card nobody has read yet. An
    /// approval or a question cannot be answered once the run is gone.
    private static func keptAfterRun(_ reason: StatusReason) -> StatusReason? {
        switch reason.kind {
        case .turnDone, .failure: reason
        default: nil
        }
    }

    /// The Active-section phase after a status. Work, an approval and background work after a turn put the run
    /// under way; a finished or failed turn ends it as unread unless the user is looking (a new failure is
    /// unread even with no turn seen under way before it). A question during the
    /// turn and an unknown state change nothing, so Claude's idle notice about a minute after a turn the user
    /// read cannot bring the run back; a prompt or the end of the session takes it out.
    private static func activePhase(after status: ProviderWorkState?, from phase: ActivePhase,
                                    viewed: Bool, newFailure: Bool = false) -> ActivePhase {
        guard let status else { return .inactive }
        switch status.activity {
        case .working, .waitingForApproval: return .underWay
        case .turnComplete where status.pendingProviderWorkCount > 0: return .underWay
        case .failed where newFailure:
            // A failure is news whether or not a turn was seen under way before it (a failure at the start of
            // a run has no "working" before it): unread until the user looks.
            return viewed ? .inactive : .endedUnread
        case .turnComplete, .failed:
            guard phase == .underWay else { return phase }
            return viewed ? .inactive : .endedUnread
        case .waitingForInput, .unknown: return phase
        case .atPrompt, .sessionEnded: return .inactive
        }
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

private extension ProviderWorkState {
    var isFailure: Bool {
        if case .failed = activity { true } else { false }
    }
}
