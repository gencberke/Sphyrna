import Foundation

public enum OpenCodeExecutionState: Equatable, Sendable { case unknown, running, idle }
public enum OpenCodeExecutionOutcome: Equatable, Sendable { case succeeded, failed, interrupted }
public enum OpenCodeInputState: Equatable, Sendable {
    case pending, accepted, delivered
    /// Result of the observed native busy period that contained this input's
    /// exact delivery, not an invented native execution/turn identity.
    case settled(OpenCodeExecutionOutcome)
    case unknown
}
public struct OpenCodeTrackedInput: Equatable, Sendable {
    public let roundID: UUID
    public let inputID: String
    public var state: OpenCodeInputState
    public var creationSequence: Int64? = nil
    public var startSequence: Int64? = nil
    public var deliverySequence: Int64? = nil
    public var terminalSequence: Int64? = nil
}
public struct OpenCodeLiveSnapshot: Equatable, Sendable {
    public let appSessionID: UUID
    public let runID: UUID
    public let nativeSessionID: String
    public var execution: OpenCodeExecutionState
    /// Observed new-session creation at this native durable sequence. It is
    /// cleared by later activity or lost feed continuity.
    public var creationSequence: Int64?
    public var input: OpenCodeTrackedInput?
}

/// Reduces one connected feed in its delivery order. Session-wide terminal
/// outcomes are tied to an app input only after its exact inbox delivery in a
/// witnessed busy period; a coalesced competing input makes attribution unknown.
struct OpenCodeLiveState {
    private struct ReservationCheckpoint {
        let snapshot: OpenCodeLiveSnapshot
        let sequence: Int64?
        let receiptConfirmed: Bool
        let runningStart: Int64?
        let roundStart: Int64?
        let delivered: Int64?
        let terminal: OpenCodeExecutionOutcome?
        let ambiguous: Bool
    }
    let appSessionID: UUID
    let runID: UUID
    let nativeSessionID: String
    private(set) var snapshot: OpenCodeLiveSnapshot
    private var lastSequence: Int64?
    private var unreliable = false
    private var receiptConfirmed = false
    private var runningStart: Int64?
    private var roundStart: Int64?
    private var delivered: Int64?
    private var terminal: OpenCodeExecutionOutcome?
    private var ambiguous = false
    private var reservationCheckpoint: ReservationCheckpoint?

    var isReliable: Bool { !unreliable }

    init(appSessionID: UUID, runID: UUID, nativeSessionID: String) {
        self.appSessionID = appSessionID
        self.runID = runID
        self.nativeSessionID = nativeSessionID
        snapshot = .init(appSessionID: appSessionID, runID: runID, nativeSessionID: nativeSessionID,
                         execution: .unknown, creationSequence: nil, input: nil)
    }

    mutating func receive(_ event: OpenCodeEvent) {
        guard !unreliable else { return }
        guard let eventSession = event.sessionID else { invalidate(); return }
        guard eventSession == nativeSessionID else { return }
        let expectedVersion = event.type == "session.deleted" ? 2 : 1
        guard let sequence = event.sequence, sequence >= 0, event.version == expectedVersion,
              lastSequence.map({ sequence > $0 }) ?? true else { invalidate(); return }
        let previousSequence = lastSequence
        lastSequence = sequence
        switch event.type {
        case "session.created":
            // This is evidence of the creation event, not an idle snapshot.
            guard previousSequence == nil, runningStart == nil, snapshot.input == nil else { invalidate(); return }
            snapshot.creationSequence = sequence
        case "session.deleted":
            invalidate()
        case "session.execution.started":
            snapshot.creationSequence = nil
            guard runningStart == nil else { invalidate(); return }
            runningStart = sequence
            snapshot.execution = .running
            if snapshot.input != nil, terminal == nil, !ambiguous {
                roundStart = sequence
                snapshot.input?.startSequence = sequence
            }
        case "session.inbox.enqueued":
            snapshot.creationSequence = nil
            guard event.inboxID != nil else { invalidate(); return }
        case "session.inbox.cancelled":
            snapshot.creationSequence = nil
            guard let inputID = event.inboxID else { invalidate(); return }
            if terminal == nil, snapshot.input?.inputID == inputID { clearAttribution(); updateInput() }
        case "session.inbox.delivered":
            snapshot.creationSequence = nil
            guard let inputID = event.inboxID else { invalidate(); return }
            guard let tracked = snapshot.input, terminal == nil else { return }
            if tracked.inputID != inputID {
                clearAttribution()
            } else if !ambiguous, let roundStart, let runningStart, roundStart == runningStart,
                      sequence > runningStart, delivered == nil {
                delivered = sequence
                snapshot.input?.deliverySequence = sequence
            } else {
                clearAttribution()
            }
            updateInput()
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            snapshot.creationSequence = nil
            guard let runningStart else {
                // Subscription can begin in the middle of a busy period.
                // Do not bootstrap an idle state or a round result from it.
                snapshot.execution = .unknown
                if snapshot.input != nil { clearAttribution(); updateInput() }
                return
            }
            guard sequence > runningStart else { invalidate(); return }
            self.runningStart = nil
            snapshot.execution = .idle
            if !ambiguous, let roundStart, roundStart == runningStart,
               let delivered, delivered > runningStart, delivered < sequence {
                snapshot.input?.terminalSequence = sequence
                switch event.type {
                case "session.execution.succeeded": terminal = .succeeded
                case "session.execution.failed": terminal = .failed
                default: terminal = .interrupted
                }
            }
            self.roundStart = nil
            updateInput()
        default:
            invalidate()
        }
    }

    mutating func begin(roundID: UUID, inputID: String) throws {
        guard !unreliable, OpenCodeLaunchProfile.validID(inputID, prefix: "msg_") else {
            throw OpenCodeError.invalidTarget
        }
        if let input = snapshot.input {
            switch input.state {
            case .settled: break
            case .unknown where snapshot.execution == .idle && runningStart == nil && terminal != nil: break
            default: throw OpenCodeError.conflict
            }
        }
        reservationCheckpoint = ReservationCheckpoint(snapshot: snapshot, sequence: lastSequence,
            receiptConfirmed: receiptConfirmed, runningStart: runningStart, roundStart: roundStart,
            delivered: delivered, terminal: terminal, ambiguous: ambiguous)
        let created = snapshot.creationSequence
        snapshot.creationSequence = nil
        snapshot.input = .init(roundID: roundID, inputID: inputID, state: .pending, creationSequence: created)
        receiptConfirmed = false
        roundStart = nil
        delivered = nil
        terminal = nil
        // An already-active period may have seen earlier input before this
        // reservation; its eventual outcome is not an exact app-round result.
        ambiguous = runningStart != nil
    }

    mutating func receipt(inputID: String) throws {
        guard !unreliable, snapshot.input?.inputID == inputID else { throw OpenCodeError.invalidTarget }
        reservationCheckpoint = nil
        receiptConfirmed = true
        updateInput()
    }

    mutating func indeterminate(inputID: String) {
        guard snapshot.input?.inputID == inputID else { return }
        reservationCheckpoint = nil
        clearAttribution()
        updateInput()
    }

    /// The authenticated TUI explicitly rejected the command before SDK
    /// dispatch. Restore only if no session event intervened; the caller's
    /// separate admission lease is still responsible for native ingress.
    mutating func rejectedBeforeDispatch(inputID: String) -> Bool {
        guard !unreliable, snapshot.input?.inputID == inputID,
              let saved = reservationCheckpoint, saved.sequence == lastSequence else {
            reservationCheckpoint = nil
            return false
        }
        snapshot = saved.snapshot
        receiptConfirmed = saved.receiptConfirmed
        runningStart = saved.runningStart
        roundStart = saved.roundStart
        delivered = saved.delivered
        terminal = saved.terminal
        ambiguous = saved.ambiguous
        reservationCheckpoint = nil
        return true
    }

    mutating func disconnected() { invalidate() }

    private mutating func invalidate() {
        unreliable = true
        reservationCheckpoint = nil
        snapshot.execution = .unknown
        snapshot.creationSequence = nil
        clearAttribution()
        if snapshot.input != nil { snapshot.input?.state = .unknown }
    }

    private mutating func clearAttribution() {
        ambiguous = true
        roundStart = nil
        delivered = nil
        terminal = nil
        snapshot.input?.creationSequence = nil
        snapshot.input?.startSequence = nil
        snapshot.input?.deliverySequence = nil
        snapshot.input?.terminalSequence = nil
    }

    private mutating func updateInput() {
        guard snapshot.input != nil else { return }
        if ambiguous {
            snapshot.input?.state = .unknown
        } else if !receiptConfirmed {
            snapshot.input?.state = .pending
        } else if let terminal {
            snapshot.input?.state = .settled(terminal)
        } else if delivered != nil {
            snapshot.input?.state = .delivered
        } else {
            snapshot.input?.state = .accepted
        }
    }
}
