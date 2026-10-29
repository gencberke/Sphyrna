import Darwin
import Foundation

/// Per-terminal authority, independent of process-owner markers. Revocation
/// and admission share a lock so a stopped run cannot admit later input.
final class SessionTaskRunLease: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var reliable = true
    private var hooksInFlight = 0
    private var codexEvents: Set<UInt64> = []
    private var revision: UInt64 = 0
    func revoke() { lock.withLock { enabled = false } }
    private func advanceRevision() {
        guard revision < .max else { reliable = false; return }
        revision += 1
    }
    func beginHook() {
        lock.withLock {
            guard enabled, reliable else { return }
            advanceRevision()
            hooksInFlight += 1
        }
    }
    func finishHook() { lock.withLock { hooksInFlight = max(0, hooksInFlight - 1) } }
    func beginCodexEvent(_ sequence: UInt64) {
        lock.withLock {
            guard enabled, reliable else { return }
            advanceRevision()
            if codexEvents.count >= 4_096 { reliable = false; codexEvents.removeAll(); return }
            codexEvents.insert(sequence)
        }
    }
    func finishCodexEvent(_ sequence: UInt64) { lock.withLock { codexEvents.remove(sequence) } }
    func invalidate() { lock.withLock { reliable = false } }
    func permits<T>(_ body: () -> T?) -> T? {
        lock.withLock { enabled && reliable && hooksInFlight == 0 && codexEvents.isEmpty ? body() : nil }
    }
    // The caller captures this at admission, then rechecks it at the write boundary.
    func admit<T>(_ body: (UInt64) -> T?) -> T? {
        lock.withLock {
            enabled && reliable && hooksInFlight == 0 && codexEvents.isEmpty ? body(revision) : nil
        }
    }
    func permits(revision admitted: UInt64) -> Bool {
        lock.withLock { enabled && reliable && hooksInFlight == 0 && codexEvents.isEmpty && revision == admitted }
    }
    /// Keep provider ingress and revocation ordered with the actual syscall.
    func withAdmission(revision admitted: UInt64, _ write: () throws -> Int) rethrows -> Int? {
        try lock.withLock {
            guard enabled, reliable, hooksInFlight == 0, codexEvents.isEmpty, revision == admitted else { return nil }
            return try write()
        }
    }
    var isEnabled: Bool { lock.withLock { enabled } }
}

/// Hook arrival occurs off the runtime actor; this registry closes the gap
/// before a buffered event reaches the ordered consumer.
final class SessionTaskIngressRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [UUID: SessionTaskRunLease] = [:]
    func register(runID: UUID, lease: SessionTaskRunLease) { lock.withLock { leases[runID] = lease } }
    func remove(runID: UUID) { lock.withLock { leases.removeValue(forKey: runID) } }
    func begin(runID: UUID) { lock.withLock { leases[runID] }?.beginHook() }
    func finish(runID: UUID) { lock.withLock { leases[runID] }?.finishHook() }
    func dropped(runID: UUID) {
        guard let lease = lock.withLock({ leases[runID] }) else { return }
        lease.invalidate()
        lease.finishHook()
    }
}

struct SessionTaskRunPlan: Sendable {
    let claim: SessionTaskClaim
    let lease = SessionTaskRunLease()

    init(sessionID: UUID, runID: UUID) {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        claim = SessionTaskClaim(sessionID: sessionID, managedRunID: runID,
                                 generation: UUID(), credential: secret)
    }

    func environment(socket: String, helper: String) -> [String: String] {
        ["SPHYRNA_TASK_SOCKET": socket, "SPHYRNA_TASK_TOKEN": claim.credential,
         "SPHYRNA_TASK_SESSION_ID": claim.sessionID.uuidString,
         "SPHYRNA_TASK_RUN_ID": claim.managedRunID.uuidString,
         "SPHYRNA_TASK_GENERATION": claim.generation.uuidString, "SPHYRNA_CLI": helper]
    }
}

struct SessionTaskRetiredRun: Sendable {
    let runID: UUID
    let generation: UUID
}

struct SessionTaskChildReservation: Sendable {
    let parent: SessionTaskClaim
    let childID: UUID
}

struct SessionTaskExpectedInput: Sendable {
    enum Purpose: Sendable, Equatable {
        case child(taskID: UUID, roundID: UUID, operationID: UUID)
        case wake(taskID: UUID, operationID: UUID)
    }
    let purpose: Purpose
    let binding: SessionTaskBinding
    let digest: Data
    let ticket: TerminalInputQueue.AutomaticInputTicket?
    var observed: SessionTaskExecutionReference?
    var lastSequence: UInt64 = 0
}

/// This is a bridge to the existing runtime, never another process owner.
final class SessionTaskRuntimeHost: SessionTaskHost, @unchecked Sendable {
    private weak var runtime: SessionRuntime?
    init(runtime: SessionRuntime) { self.runtime = runtime }

    func authenticate(_ claim: SessionTaskClaim) async -> SessionTaskBinding? { await runtime?.authenticateTaskRun(claim) }
    func ownsNewChild(taskID: UUID, parent: SessionTaskBinding, childID: UUID) async -> Bool {
        await runtime?.ownsReservedTaskChild(taskID: taskID, parent: parent, childID: childID) ?? false
    }
    func observedChildExecution(_ target: SessionTaskRoundTarget) async -> SessionTaskExecutionReference? { nil }
    func observedWakeExecution(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) async -> SessionTaskExecutionReference? { nil }
    func nativeStatus(binding: SessionTaskBinding) async -> SessionTaskNativeStatus {
        await runtime?.taskNativeStatus(binding) ?? .unknown
    }
    func submitIfReady(_ intent: SessionTaskInputIntent) async -> SessionTaskInputEffect { .deferred }
    func wakeIfReady(_ intent: SessionTaskWakeIntent) async -> SessionTaskEffect { .deferred }
    func interrupt(_ target: SessionTaskRoundTarget) async -> SessionTaskEffect { .unknown }
    func stopChild(taskID: UUID, binding: SessionTaskBinding) async -> SessionTaskEffect { .unknown }
    func stopUnknownChild(taskID: UUID, childSessionID: UUID) async -> SessionTaskEffect { .unknown }
    func verifyUnknownWakeStopped(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) async -> Bool { false }
    func mayForget(sessionID: UUID) async -> Bool { false }
}

extension ProcessSupervisor {
    /// Checks native identity and terminal ownership in the same actor that
    /// performs conversation transitions and run stops.
    func taskBinding(for claim: SessionTaskClaim) -> SessionTaskBinding? {
        guard let runtime = runtimes[claim.managedRunID],
              runtime.launchSessionID == claim.sessionID, runtime.activeSessionID == claim.sessionID,
              !transitioningRuns.contains(claim.managedRunID), !stoppingRuns.contains(claim.managedRunID),
              case .terminal = runtime.endpoint,
              let session = sessions[claim.sessionID], session.currentRun?.id == claim.managedRunID,
              session.currentRun?.state == .running,
              let nativeID = session.providerConversationID, !nativeID.isEmpty else { return nil }
        return SessionTaskBinding(sessionID: claim.sessionID, nativeSessionID: nativeID,
                                  managedRunID: claim.managedRunID, generation: claim.generation)
    }
}
