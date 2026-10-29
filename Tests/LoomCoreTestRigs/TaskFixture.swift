import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore
import LoomTestSupport

actor TaskFakeHost: SessionTaskHost {
    enum ProofKind: Equatable { case nativeTurn, providerPrompt, appInput }
    struct ChildObservation {
        let taskID: UUID
        let roundID: UUID
        var operationID: UUID
        let binding: SessionTaskBinding
        let execution: SessionTaskExecutionReference
        let nativeTurnID: String?
    }
    struct WakeObservation {
        var taskID: UUID
        let operationID: UUID
        let binding: SessionTaskBinding
        let execution: SessionTaskExecutionReference
    }
    var parent: SessionTaskBinding
    var child: SessionTaskBinding
    let parentCredential = "parent-local"
    let childCredential = "child-local"
    var native: SessionTaskNativeStatus = .ready
    var parentReady = true
    var submitOutcomeUnknown = false
    var submitStartedOnly = false
    var stopVerified = true
    var interruptVerified = true
    var forgetting = false
    var wakeUnknown = false
    var wakeDeferredAfterPause = false
    var proofKind = ProofKind.nativeTurn
    var childObservations: [UUID: ChildObservation] = [:]
    var wakeObservations: [UUID: WakeObservation] = [:]
    var wakeStopped = false
    var pauseInterrupt = false
    var interruptEntered = false
    var interruptContinuation: CheckedContinuation<Void, Never>?
    var interruptEffectProbe: (@Sendable () -> Bool)?
    var interruptEffects = 0
    var pauseStop = false
    var stopEntered = false
    var stopContinuation: CheckedContinuation<Void, Never>?
    var duringSubmit: (@Sendable (SessionTaskInputIntent) async -> Void)?
    var pauseSubmit = false
    var submitEntered = false
    var submitContinuation: CheckedContinuation<Void, Never>?
    var pauseBeforeInput = false
    var beforeInputEntered = false
    var beforeInputContinuation: CheckedContinuation<Void, Never>?
    var inputEffects = 0
    var returnedBinding: SessionTaskBinding?
    var pauseWake = false
    var wakeEntered = false
    var wakeContinuation: CheckedContinuation<Void, Never>?
    var pauseWakeBeforeEffect = false
    var wakeBeforeEffectEntered = false
    var wakeBeforeEffectContinuation: CheckedContinuation<Void, Never>?
    var wakeEffects = 0
    private(set) var submissions: [SessionTaskInputIntent] = []
    private(set) var wakes: [SessionTaskWakeIntent] = []
    private(set) var interrupts: [SessionTaskRoundTarget] = []
    private(set) var stops = 0

    init(parent: SessionTaskBinding, child: SessionTaskBinding) { self.parent = parent; self.child = child }
    func authenticate(_ claim: SessionTaskClaim) -> SessionTaskBinding? {
        if claim.sessionID == parent.sessionID && claim.managedRunID == parent.managedRunID &&
            claim.generation == parent.generation && claim.credential == parentCredential { return parent }
        if claim.sessionID == child.sessionID && claim.managedRunID == child.managedRunID &&
            claim.generation == child.generation && claim.credential == childCredential { return child }
        return nil
    }
    func ownsNewChild(taskID: UUID, parent: SessionTaskBinding, childID: UUID) -> Bool {
        parent == self.parent && childID == child.sessionID && taskID != childID
    }
    func observedChildExecution(_ target: SessionTaskRoundTarget) -> SessionTaskExecutionReference? {
        guard let observed = childObservations[target.roundID], target.binding == child,
              observed.binding == target.binding, observed.taskID == target.taskID,
              observed.roundID == target.roundID, observed.operationID == target.inputOperationID,
              target.nativeTurnID == nil || target.nativeTurnID == observed.nativeTurnID,
              target.execution == nil || target.execution == observed.execution else { return nil }
        return observed.execution
    }
    func observedWakeExecution(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) -> SessionTaskExecutionReference? {
        guard let observed = wakeObservations[operationID], binding == parent, observed.binding == binding,
              observed.taskID == taskID, observed.operationID == operationID else { return nil }
        return observed.execution
    }
    func nativeStatus(binding: SessionTaskBinding) -> SessionTaskNativeStatus { binding == child ? native : .unknown }
    func submitIfReady(_ intent: SessionTaskInputIntent) async -> SessionTaskInputEffect {
        guard native == .ready, intent.task.parentBinding == parent,
              intent.task.childBinding == nil || intent.task.childBinding == child else { return .deferred }
        submissions.append(intent)
        if submitOutcomeUnknown { return .unknown }
        if submitStartedOnly {
            if pauseSubmit {
                submitEntered = true
                await withCheckedContinuation { submitContinuation = $0 }
            }
            return .started(binding: returnedBinding ?? child)
        }
        if pauseBeforeInput {
            beforeInputEntered = true
            await withCheckedContinuation { beforeInputContinuation = $0 }
        }
        guard intent.attemptDelivery({ inputEffects += 1; return true }) else { return .deferred }
        native = .working
        let nativeTurn = proofKind == .nativeTurn ? "provider-turn-\(UUID().uuidString)" : nil
        let execution: SessionTaskExecutionReference
        switch proofKind {
        case .nativeTurn: execution = .nativeTurn(nativeTurn!)
        case .providerPrompt: execution = .providerPrompt("provider-prompt-\(UUID().uuidString)")
        case .appInput: execution = .appInputObservation(UUID())
        }
        childObservations[intent.round.id] = ChildObservation(taskID: intent.task.id, roundID: intent.round.id,
            operationID: intent.round.operationID, binding: child, execution: execution, nativeTurnID: nativeTurn)
        if pauseSubmit {
            submitEntered = true
            await withCheckedContinuation { submitContinuation = $0 }
        }
        if let duringSubmit { await duringSubmit(intent) }
        return .submitted(binding: returnedBinding ?? child, nativeTurnID: nativeTurn,
                          actualModel: "actual-model", actualEffort: "low", actualMode: .askBeforeEdits)
    }
    func wakeIfReady(_ intent: SessionTaskWakeIntent) async -> SessionTaskEffect {
        guard parentReady, intent.parentBinding == parent else { return .deferred }
        wakes.append(intent)
        if pauseWakeBeforeEffect {
            wakeBeforeEffectEntered = true
            await withCheckedContinuation { wakeBeforeEffectContinuation = $0 }
        }
        if wakeDeferredAfterPause { return .deferred }
        guard intent.attemptDelivery({ true }) else { return .deferred }
        wakeEffects += 1
        let execution: SessionTaskExecutionReference
        switch proofKind {
        case .nativeTurn: execution = .nativeTurn("provider-wake-\(UUID().uuidString)")
        case .providerPrompt: execution = .providerPrompt("provider-wake-prompt-\(UUID().uuidString)")
        case .appInput: execution = .appInputObservation(UUID())
        }
        wakeObservations[intent.operationID] = WakeObservation(taskID: intent.taskID, operationID: intent.operationID,
                                                                binding: parent, execution: execution)
        if pauseWake {
            wakeEntered = true
            await withCheckedContinuation { wakeContinuation = $0 }
        }
        return wakeUnknown ? .unknown : .verified
    }
    func interrupt(_ target: SessionTaskRoundTarget) async -> SessionTaskEffect {
        interrupts.append(target)
        if pauseInterrupt {
            interruptEntered = true
            await withCheckedContinuation { interruptContinuation = $0 }
        }
        guard target.attemptInterrupt({ interruptEffectProbe?() ?? true }) else { return .deferred }
        interruptEffects += 1
        if interruptVerified { native = .ready; return .verified }
        return .unknown
    }
    func stopChild(taskID: UUID, binding: SessionTaskBinding) async -> SessionTaskEffect {
        stops += 1
        if pauseStop {
            stopEntered = true
            await withCheckedContinuation { stopContinuation = $0 }
        }
        if binding == child && stopVerified { native = .stopped; return .verified }
        return .unknown
    }
    func stopUnknownChild(taskID: UUID, childSessionID: UUID) async -> SessionTaskEffect {
        stops += 1
        if pauseStop {
            stopEntered = true
            await withCheckedContinuation { stopContinuation = $0 }
        }
        if childSessionID == child.sessionID && stopVerified { native = .stopped; return .verified }
        return .unknown
    }
    func verifyUnknownWakeStopped(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) -> Bool {
        wakeStopped && binding == parent
    }
    func mayForget(sessionID: UUID) -> Bool {
        forgetting && native == .stopped && (sessionID == parent.sessionID || sessionID == child.sessionID)
    }
    func setNative(_ value: SessionTaskNativeStatus) { native = value }
    func setUnknown(_ value: Bool) { submitOutcomeUnknown = value }
    func setStartedOnly(_ value: Bool) { submitStartedOnly = value }
    func setStopVerified(_ value: Bool) { stopVerified = value }
    func holdStop() { pauseStop = true }
    func hasEnteredStop() -> Bool { stopEntered }
    func releaseStop() { pauseStop = false; stopContinuation?.resume(); stopContinuation = nil }
    func setWakeUnknown(_ value: Bool) { wakeUnknown = value }
    func deferWakeAfterPause() { wakeDeferredAfterPause = true }
    func usePromptProofOnly() { proofKind = .providerPrompt }
    func useAppInputProofOnly() { proofKind = .appInput }
    func childReference(_ roundID: UUID) -> SessionTaskExecutionReference? { childObservations[roundID]?.execution }
    func wakeReference(_ operationID: UUID) -> SessionTaskExecutionReference? { wakeObservations[operationID]?.execution }
    func replaceObservedInputOperation(_ roundID: UUID, operationID: UUID) {
        childObservations[roundID]?.operationID = operationID
    }
    func replaceObservedWakeTask(_ operationID: UUID, taskID: UUID) {
        wakeObservations[operationID]?.taskID = taskID
    }
    func confirmWakeStopped() { wakeStopped = true }
    func holdInterrupt() { pauseInterrupt = true }
    func onSubmit(_ callback: @escaping @Sendable (SessionTaskInputIntent) async -> Void) { duringSubmit = callback }
    func returnBinding(_ binding: SessionTaskBinding) { returnedBinding = binding }
    func holdWake() { pauseWake = true }
    func hasEnteredWake() -> Bool { wakeEntered }
    func releaseWake() { pauseWake = false; wakeContinuation?.resume(); wakeContinuation = nil }
    func holdWakeBeforeEffect() { pauseWakeBeforeEffect = true }
    func hasEnteredWakeBeforeEffect() -> Bool { wakeBeforeEffectEntered }
    func releaseWakeBeforeEffect() {
        pauseWakeBeforeEffect = false; wakeBeforeEffectContinuation?.resume(); wakeBeforeEffectContinuation = nil
    }
    func actualWakeEffects() -> Int { wakeEffects }
    func holdSubmit() { pauseSubmit = true }
    func hasEnteredSubmit() -> Bool { submitEntered }
    func releaseSubmit() { pauseSubmit = false; submitContinuation?.resume(); submitContinuation = nil }
    func holdBeforeInput() { pauseBeforeInput = true }
    func hasEnteredBeforeInput() -> Bool { beforeInputEntered }
    func releaseBeforeInput() { pauseBeforeInput = false; beforeInputContinuation?.resume(); beforeInputContinuation = nil }
    func actualInputEffects() -> Int { inputEffects }
    func hasEnteredInterrupt() -> Bool { interruptEntered }
    func releaseInterrupt() { pauseInterrupt = false; interruptContinuation?.resume(); interruptContinuation = nil }
    func setInterruptEffectProbe(_ effect: @escaping @Sendable () -> Bool) { interruptEffectProbe = effect }
    func actualInterruptEffects() -> Int { interruptEffects }
    func allowForget() { forgetting = true }
    func replaceParent(_ value: SessionTaskBinding) { parent = value }
    func replaceChild(_ value: SessionTaskBinding) { child = value }
    func counts() -> (Int, Int, Int, Int) { (submissions.count, wakes.count, interrupts.count, stops) }
    func lastWakeCount() -> Int? { wakes.last?.eventCount }
}

final class TaskFakeClock: @unchecked Sendable {
    let lock = NSLock()
    var date = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

struct TaskFixture {
    let root: URL
    let url: URL
    let host: TaskFakeHost
    let coordinator: SessionTaskCoordinator
    let clock: TaskFakeClock
    let parent: SessionTaskClaim
    let child: SessionTaskClaim
    let taskID: UUID
    let childID: UUID

    static func make(parentHarness: HarnessID = .claude, childHarness: HarnessID = .codex,
                     recoveryLayout: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-foundation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = recoveryLayout ? root.appendingPathComponent("session-tasks/tasks.sqlite3") : root.appendingPathComponent("tasks.sqlite")
        let parent = SessionTaskBinding(sessionID: UUID(), nativeSessionID: "parent-\(parentHarness.rawValue)",
                                        managedRunID: UUID(), generation: UUID())
        let child = SessionTaskBinding(sessionID: UUID(), nativeSessionID: "child-\(childHarness.rawValue)",
                                       managedRunID: UUID(), generation: UUID())
        let host = TaskFakeHost(parent: parent, child: child)
        let clock = TaskFakeClock()
        let coordinator = try await SessionTaskCoordinator.open(url: url, host: host, now: { clock.now() })
        let p = SessionTaskClaim(sessionID: parent.sessionID, managedRunID: parent.managedRunID,
                                 generation: parent.generation, credential: "parent-local")
        let c = SessionTaskClaim(sessionID: child.sessionID, managedRunID: child.managedRunID,
                                 generation: child.generation, credential: "child-local")
        let taskID = UUID()
        _ = try await coordinator.createApproved(taskID: taskID, parent: p, childID: child.sessionID,
            harness: childHarness, childName: "implementation",
            choices: HarnessLaunchChoices(harness: childHarness, model: "requested-model", effort: "low"))
        return Self(root: root, url: url, host: host, coordinator: coordinator, clock: clock,
                    parent: p, child: c, taskID: taskID, childID: child.sessionID)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func input(_ text: String, operationID: UUID = UUID(), replyTo: UUID? = nil) async throws -> SessionTaskReceipt {
        try await coordinator.requestRound(taskID: taskID, parent: parent, operationID: operationID, message: text,
                                           replyToEventID: replyTo)
    }
    func report(_ roundID: UUID, kind: SessionTaskReportKind = .completed, payload: String = "done",
                operationID: UUID = UUID()) async throws -> SessionTaskReceipt {
        try await coordinator.report(taskID: taskID, child: child, roundID: roundID,
            operationID: operationID, kind: kind, payload: payload)
    }
}
