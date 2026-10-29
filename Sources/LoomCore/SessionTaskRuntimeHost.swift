import Darwin
import Foundation

/// Per-terminal authority, independent of process-owner markers. Revocation
/// and admission share a lock so a stopped run cannot admit later input.
final class SessionTaskRunLease: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    func revoke() { lock.withLock { enabled = false } }
    func permits<T>(_ body: () -> T?) -> T? { lock.withLock { enabled ? body() : nil } }
    var isEnabled: Bool { lock.withLock { enabled } }
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

/// This is a bridge to the existing runtime, never another process owner.
final class SessionTaskRuntimeHost: SessionTaskHost, @unchecked Sendable {
    private weak var runtime: SessionRuntime?
    init(runtime: SessionRuntime) { self.runtime = runtime }

    func authenticate(_ claim: SessionTaskClaim) async -> SessionTaskBinding? { await runtime?.authenticateTaskRun(claim) }
    func ownsNewChild(taskID: UUID, parent: SessionTaskBinding, childID: UUID) async -> Bool { false }
    func observedChildExecution(_ target: SessionTaskRoundTarget) async -> SessionTaskExecutionReference? { nil }
    func observedWakeExecution(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) async -> SessionTaskExecutionReference? { nil }
    func nativeStatus(binding: SessionTaskBinding) async -> SessionTaskNativeStatus { .unknown }
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
