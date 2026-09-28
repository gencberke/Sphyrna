import Foundation

public struct SessionViewState: Equatable, Sendable {
    public var status: ProviderWorkState?
    public var lifecycle: SessionLifecycle
    public var conversationID: String?
    public var identity: SessionIdentityState
    public var runID: UUID?
    public var blockers: Set<SessionIdleBlocker>

    public init(
        status: ProviderWorkState? = nil, lifecycle: SessionLifecycle = .active,
        conversationID: String? = nil, identity: SessionIdentityState = .known,
        runID: UUID? = nil, blockers: Set<SessionIdleBlocker> = []
    ) {
        self.status = status
        self.lifecycle = lifecycle
        self.conversationID = conversationID
        self.identity = identity
        self.runID = runID
        self.blockers = blockers
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
}

/// Each frame carries the latest state of every session. The stream retains one
/// frame per consumer, so a slow consumer can miss intermediate changes but can
/// always reconstruct the latest state without polling.
public struct SessionEventFrame: Equatable, Sendable {
    public let sequence: UInt64
    public let sessionID: UUID?
    public let change: SessionEventChange
    public let sessions: [UUID: SessionViewState]
}

public actor SessionEventHub {
    private var sequence: UInt64 = 0
    private var states: [UUID: SessionViewState] = [:]
    private var subscribers: [UUID: AsyncStream<SessionEventFrame>.Continuation] = [:]

    public init() {}

    public func snapshot() -> SessionEventFrame {
        SessionEventFrame(
            sequence: sequence, sessionID: nil, change: .snapshot,
            sessions: states
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
        var state = states[sessionID] ?? SessionViewState()
        switch change {
        case .snapshot: break
        case let .status(value): state.status = value
        case let .lifecycle(value): state.lifecycle = value
        case let .conversationIdentity(value): state.conversationID = value
        case let .identityState(value): state.identity = value
        case let .runStarted(value): state.runID = value
        case .runDetached: state.runID = nil; state.status = nil
        case .runEnded: state.runID = nil; state.status = nil
        case let .blockers(value): state.blockers = value
        }
        states[sessionID] = state
        sequence &+= 1
        let frame = SessionEventFrame(
            sequence: sequence, sessionID: sessionID, change: change,
            sessions: states
        )
        for continuation in subscribers.values { continuation.yield(frame) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
