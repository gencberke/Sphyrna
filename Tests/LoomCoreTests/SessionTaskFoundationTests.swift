import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore

actor TaskFakeHost: SessionTaskHost {
    private enum ProofKind: Equatable { case nativeTurn, providerPrompt, appInput }
    private struct ChildObservation {
        let taskID: UUID
        let roundID: UUID
        var operationID: UUID
        let binding: SessionTaskBinding
        let execution: SessionTaskExecutionReference
        let nativeTurnID: String?
    }
    private struct WakeObservation {
        var taskID: UUID
        let operationID: UUID
        let binding: SessionTaskBinding
        let execution: SessionTaskExecutionReference
    }
    var parent: SessionTaskBinding
    var child: SessionTaskBinding
    private let parentCredential = "parent-local"
    private let childCredential = "child-local"
    var native: SessionTaskNativeStatus = .ready
    var parentReady = true
    var submitOutcomeUnknown = false
    var submitStartedOnly = false
    var stopVerified = true
    var interruptVerified = true
    var forgetting = false
    var wakeUnknown = false
    var wakeDeferredAfterPause = false
    private var proofKind = ProofKind.nativeTurn
    private var childObservations: [UUID: ChildObservation] = [:]
    private var wakeObservations: [UUID: WakeObservation] = [:]
    var wakeStopped = false
    var pauseInterrupt = false
    var interruptEntered = false
    var interruptContinuation: CheckedContinuation<Void, Never>?
    var interruptEffectProbe: (@Sendable () -> Bool)?
    var interruptEffects = 0
    var duringSubmit: (@Sendable (SessionTaskInputIntent) async -> Void)?
    var pauseSubmit = false
    var submitEntered = false
    var submitContinuation: CheckedContinuation<Void, Never>?
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
    func stopChild(taskID: UUID, binding: SessionTaskBinding) -> SessionTaskEffect {
        stops += 1
        if binding == child && stopVerified { native = .stopped; return .verified }
        return .unknown
    }
    func stopUnknownChild(taskID: UUID, childSessionID: UUID) -> SessionTaskEffect {
        stops += 1
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

private actor TaskEarlyReportObservation {
    private(set) var accepted = false
    func markAccepted() { accepted = true }
}

private actor TaskProjectionFrames {
    private var frames: [UInt64] = []
    func append(_ frame: UInt64) { frames.append(frame) }
    var count: Int { frames.count }
}

final class TaskFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)
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

    static func make(parentHarness: HarnessID = .claude, childHarness: HarnessID = .codex) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-foundation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("tasks.sqlite")
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

@Suite(.serialized)
struct SessionTaskFoundationTests {
    @Test func taskEventCapacityKeepsReceiptsAndAllowsStop() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let firstOperation = UUID()
        let first = try await f.report(round, kind: .needsParentInput, payload: "first", operationID: firstOperation)
        for index in 1..<64 {
            _ = try await f.report(round, kind: .needsParentInput, payload: "event \(index)")
        }
        await #expect(throws: SessionTaskError.capacityExceeded) {
            try await f.report(round, kind: .needsParentInput, payload: "over capacity")
        }
        #expect(try await f.report(round, kind: .needsParentInput, payload: "first", operationID: firstOperation) == first)
        let stopped = try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID())
        #expect(stopped.delivery == .verified)
    }

    @Test func taskOperationCapacityKeepsOldIdempotenceAndReservesStop() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        let firstOperation = UUID(), next = UUID()
        let first = try await f.coordinator.interruptAndUpdate(taskID: f.taskID, parent: f.parent, roundID: round,
            operationID: firstOperation, nextOperationID: next, message: "unused")
        #expect(first.delivery == .alreadySettled)
        var rejected = false
        for _ in 0..<128 {
            do {
                _ = try await f.coordinator.interruptAndUpdate(taskID: f.taskID, parent: f.parent, roundID: round,
                    operationID: UUID(), nextOperationID: UUID(), message: "unused")
            } catch SessionTaskError.capacityExceeded {
                rejected = true
                break
            }
        }
        #expect(rejected)
        #expect(try await f.coordinator.interruptAndUpdate(taskID: f.taskID, parent: f.parent, roundID: round,
            operationID: firstOperation, nextOperationID: next, message: "unused") == first)
        let reopened = try await SessionTaskCoordinator.open(url: f.url, host: f.host, now: { f.clock.now() })
        #expect(try await reopened.interruptAndUpdate(taskID: f.taskID, parent: f.parent, roundID: round,
            operationID: firstOperation, nextOperationID: next, message: "unused") == first)
        let stopped = try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID())
        #expect(stopped.delivery == .verified)
    }

    @Test func emptyStartedChildIsBoundWithoutSpendingAnInputAndStopTargetsIt() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        await f.host.setStartedOnly(true)
        _ = try await f.input("first")
        #expect(try await f.coordinator.deliverPending(taskID: f.taskID).delivery == .deferred)
        let before = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        let owned = await f.host.child
        #expect(before.task.childBinding == owned)
        #expect(before.task.childInputsUsed == 0 && before.pendingRound?.phase == .queued)
        #expect(try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID()).delivery == .verified)
        #expect(await f.host.stops == 1)
    }

    @Test func stopDuringEmptySpawnRetainsLateBindingAndNeverClaimsAnUnverifiedStop() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        await f.host.setStartedOnly(true)
        await f.host.setStopVerified(false)
        await f.host.holdSubmit()
        _ = try await f.input("first")
        let delivery = Task { try await f.coordinator.deliverPending(taskID: f.taskID) }
        #expect(await SessionRuntimeTests.waitUntil(2) { await f.host.hasEnteredSubmit() })
        let stop = try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID())
        #expect(stop.delivery == .unverified)
        await f.host.releaseSubmit()
        _ = try await delivery.value
        let fenced = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        let owned = await f.host.child
        #expect(fenced.task.lifecycle == .stopUnverified && fenced.task.childBinding == owned)
        #expect(fenced.activeRound == nil && fenced.pendingRound == nil)
        await f.host.setStopVerified(true)
        #expect(try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID()).delivery == .verified)
        #expect(await f.host.stops == 2)
    }
    @Test func userLatestEventsAreBoundedOrderedAndDoNotAcknowledgeTheParent() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        for number in 1...3 {
            let round = try #require(try await f.input("round \(number)").roundID)
            _ = try await f.coordinator.deliverPending(taskID: f.taskID)
            _ = try await f.report(round, payload: "result \(number)")
            await f.host.setNative(.ready)
        }
        let recent = try await f.coordinator.latestEventsForUser(taskID: f.taskID, limit: 2)
        #expect(recent.map(\.payload) == ["result 2", "result 3"])
        await #expect(throws: SessionTaskError.notFound) {
            try await f.coordinator.latestEventsForUser(taskID: UUID(), limit: 2)
        }
        await #expect(throws: SessionTaskError.invalidPage) {
            try await f.coordinator.latestEventsForUser(taskID: f.taskID, limit: 11)
        }
        _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID())
        #expect(await f.host.lastWakeCount() == 3)
    }

    @Test func userProjectionPagesAndCoalescedUpdatesContainOnlyTaskMetadata() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let frames = TaskProjectionFrames()
        let stream = await f.coordinator.projectionUpdatesForUser()
        let observer = Task { for await frame in stream { await frames.append(frame) } }
        defer { observer.cancel() }
        #expect(try await SessionRuntimeTests.waitUntil(1) { await frames.count == 1 })
        let nextChild = SessionTaskBinding(sessionID: UUID(), nativeSessionID: "other-native",
            managedRunID: UUID(), generation: UUID())
        await f.host.replaceChild(nextChild)
        _ = try await f.coordinator.createApproved(taskID: UUID(), parent: f.parent, childID: nextChild.sessionID,
            harness: .claude, childName: "review", choices: HarnessLaunchChoices(harness: .claude))
        #expect(try await SessionRuntimeTests.waitUntil(1) { await frames.count >= 2 })
        let first = try await f.coordinator.projectionsForUser(after: nil, limit: 1)
        let cursor = try #require(first.next)
        let second = try await f.coordinator.projectionsForUser(after: cursor, limit: 1)
        #expect(first.items.count == 1 && second.items.count == 1 && first.items[0].id != second.items[0].id)
        #expect(Set((first.items + second.items).map(\.childName)) == ["implementation", "review"])
        #expect(try await f.coordinator.projectionsForUser(parentSessionID: UUID(), after: nil, limit: 50).items.isEmpty)
        #expect(try await f.coordinator.projectionsForUser(parentSessionID: f.parent.sessionID, after: nil, limit: 50).items.count == 2)
        await #expect(throws: SessionTaskError.invalidPage) {
            try await f.coordinator.projectionsForUser(after: nil, limit: 51)
        }
        let encoded = String(decoding: try JSONEncoder().encode(first.items + second.items), as: UTF8.self)
        #expect(!encoded.contains("scoped child message") && !encoded.contains("payload"))
        await f.coordinator.finishProjectionUpdates()
    }

    @Test func aPartialWirePageAcknowledgesOnlyEventsActuallyReturned() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        for index in 0..<8 {
            _ = try await f.report(round, kind: .needsParentInput,
                payload: "\(index)" + String(repeating: "x", count: SessionTaskLimits.payloadBytes - 1))
        }
        let entries = try await f.coordinator.eventEntries(taskID: f.taskID, parent: f.parent)
        let packed = try SessionTaskWirePacking.page(entries.items, next: entries.next)
        let page = try JSONDecoder().decode(SessionTaskWirePage.self, from: packed.data)
        #expect(!page.events.isEmpty && page.events.count < entries.items.count)
        try await f.coordinator.acknowledgeEvents(taskID: f.taskID, parent: f.parent, eventIDs: packed.returnedIDs)
        _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID())
        #expect(await f.host.lastWakeCount() == entries.items.count - page.events.count)
        let remaining = try await f.coordinator.eventEntries(taskID: f.taskID, parent: f.parent,
                                                             after: try #require(page.next))
        #expect(remaining.items.map(\.event.id) == Array(entries.items.dropFirst(page.events.count)).map(\.event.id))
    }

    @Test func acknowledgedTaskEventDoesNotTriggerAnExtraWake() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round, payload: "result")
        let page = try await f.coordinator.events(taskID: f.taskID, parent: f.parent)
        let event = try #require(page.items.first)
        try await f.coordinator.acknowledgeEvents(taskID: f.taskID, parent: f.parent, eventIDs: [event.id])
        await #expect(throws: SessionTaskError.notReady) {
            _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID())
        }
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.parentWakesUsed == 0 && status.task.parentWakesConsumed == 0)
        #expect((await f.host.counts()).1 == 0)
    }

    @Test func readingAClaimedEventSurvivesADeferredWake() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        let event = try #require(try await f.coordinator.events(taskID: f.taskID, parent: f.parent).items.first)
        await f.host.holdWakeBeforeEffect()
        let pending = Task { try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()) }
        for _ in 0..<100 {
            if await f.host.hasEnteredWakeBeforeEffect() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredWakeBeforeEffect())
        try await f.coordinator.acknowledgeEvents(taskID: f.taskID, parent: f.parent, eventIDs: [event.id])
        await f.host.deferWakeAfterPause()
        await f.host.releaseWakeBeforeEffect()
        #expect(try await pending.value.delivery == .deferred)
        await #expect(throws: SessionTaskError.notReady) {
            _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID())
        }
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.parentWakesUsed == 0 && status.task.parentWakesConsumed == 0)
    }

    @Test func readWinsBeforeAnInFlightWakeWrites() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        let event = try #require(try await f.coordinator.events(taskID: f.taskID, parent: f.parent).items.first)
        await f.host.holdWakeBeforeEffect()
        let pending = Task { try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()) }
        for _ in 0..<100 {
            if await f.host.hasEnteredWakeBeforeEffect() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredWakeBeforeEffect())
        try await f.coordinator.acknowledgeEvents(taskID: f.taskID, parent: f.parent, eventIDs: [event.id])
        await f.host.releaseWakeBeforeEffect()
        #expect(try await pending.value.delivery == .deferred)
        #expect(await f.host.actualWakeEffects() == 0)
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.parentWakesUsed == 0 && status.task.parentWakesConsumed == 0)
    }

    @Test func stoppingTheChildFencesAnInFlightWakeBeforeItWrites() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        await f.host.holdWakeBeforeEffect()
        let pending = Task { try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()) }
        for _ in 0..<100 {
            if await f.host.hasEnteredWakeBeforeEffect() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredWakeBeforeEffect())
        #expect(try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID()).delivery == .verified)
        await f.host.releaseWakeBeforeEffect()
        #expect(try await pending.value.delivery == .deferred)
        #expect(await f.host.actualWakeEffects() == 0)
    }

    @Test func interruptAndUpdateFencesAnInFlightWakeBeforeItWrites() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round, kind: .needsParentInput, payload: "question")
        await f.host.holdWakeBeforeEffect()
        let pending = Task { try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()) }
        for _ in 0..<100 {
            if await f.host.hasEnteredWakeBeforeEffect() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredWakeBeforeEffect())
        let interrupted = try await f.coordinator.interruptAndUpdate(taskID: f.taskID, parent: f.parent,
            roundID: round, operationID: UUID(), nextOperationID: UUID(), message: "update")
        #expect(interrupted.delivery == .verified)
        await f.host.releaseWakeBeforeEffect()
        #expect(try await pending.value.delivery == .deferred)
        #expect(await f.host.actualWakeEffects() == 0)
    }

    @Test(arguments: [false, true])
    func lifecycleFenceStopsAnInFlightWakeBeforeItWrites(identityChanged: Bool) async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        await f.host.holdWakeBeforeEffect()
        let pending = Task { try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()) }
        for _ in 0..<100 {
            if await f.host.hasEnteredWakeBeforeEffect() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredWakeBeforeEffect())
        let child = await f.host.child
        try await f.coordinator.fence(taskID: f.taskID, binding: child, identityChanged: identityChanged)
        await f.host.releaseWakeBeforeEffect()
        #expect(try await pending.value.delivery == .deferred)
        #expect(await f.host.actualWakeEffects() == 0)
    }

    @Test func readDuringAnUnknownWakeIsNotRequeuedAfterVerifiedStop() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        let event = try #require(try await f.coordinator.events(taskID: f.taskID, parent: f.parent).items.first)
        await f.host.setWakeUnknown(true)
        await f.host.holdWake()
        let wakeID = UUID()
        let pending = Task { try await f.coordinator.wakePending(taskID: f.taskID, operationID: wakeID) }
        for _ in 0..<100 {
            if await f.host.hasEnteredWake() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredWake())
        try await f.coordinator.acknowledgeEvents(taskID: f.taskID, parent: f.parent, eventIDs: [event.id])
        await f.host.releaseWake()
        #expect(try await pending.value.delivery == .unknown)
        await f.host.confirmWakeStopped()
        #expect(try await f.coordinator.verifyUnknownWakeStopped(taskID: f.taskID, operationID: wakeID).delivery == .unverified)
        try await f.coordinator.requeueUnknownWakeAfterApproval(taskID: f.taskID, operationID: wakeID)
        await #expect(throws: SessionTaskError.notReady) {
            _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID())
        }
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.parentWakesUsed == 1 && status.task.parentWakesConsumed == 0)
    }

    @Test(arguments: [false, true])
    func providerPromptProofDoesNotInventNativeTurnIDs(appInputOnly: Bool) async throws {
        let f = try await TaskFixture.make(parentHarness: .claude, childHarness: .claude)
        defer { f.clean() }
        if appInputOnly { await f.host.useAppInputProofOnly() } else { await f.host.usePromptProofOnly() }
        let input = try await f.input("claude work")
        let round = try #require(input.roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let before = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(before.activeRound?.nativeTurnID == nil)
        let proof = try #require(await f.host.childReference(round))
        await f.host.replaceObservedInputOperation(round, operationID: UUID())
        await #expect(throws: SessionTaskError.unauthorized) { _ = try await f.report(round, payload: "reported") }
        #expect(try await f.coordinator.events(taskID: f.taskID, parent: f.parent).items.isEmpty)
        await f.host.replaceObservedInputOperation(round, operationID: input.operationID)
        let reportID = UUID()
        let report = try await f.report(round, payload: "reported", operationID: reportID)
        #expect(try await f.report(round, payload: "reported", operationID: reportID) == report)
        let events = try await f.coordinator.events(taskID: f.taskID, parent: f.parent)
        #expect(events.items.first?.nativeTurnID == nil && events.items.first?.execution == proof)
        let wakeID = UUID()
        _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: wakeID)
        let parent = await f.host.parent
        let wakeProof = try #require(await f.host.wakeReference(wakeID))
        await f.host.replaceObservedWakeTask(wakeID, taskID: UUID())
        await #expect(throws: SessionTaskError.unauthorized) {
            _ = try await f.coordinator.observeWakeConsumption(taskID: f.taskID, operationID: wakeID, binding: parent)
        }
        await f.host.replaceObservedWakeTask(wakeID, taskID: f.taskID)
        let consumed = try await f.coordinator.observeWakeConsumption(taskID: f.taskID, operationID: wakeID, binding: parent)
        #expect(consumed.consumedTurnID == nil && consumed.observedConsumption == wakeProof)
        #expect(try await f.coordinator.observeWakeConsumption(taskID: f.taskID, operationID: wakeID, binding: parent) == consumed)
        let reopened = try await SessionTaskCoordinator.open(url: f.url, host: f.host, now: { f.clock.now() })
        let restoredEvent = try #require(try await reopened.events(taskID: f.taskID, parent: f.parent).items.first)
        #expect(restoredEvent.id == reportID && restoredEvent.observedExecution == proof && restoredEvent.nativeTurnID == nil)
        #expect(try await reopened.report(taskID: f.taskID, child: f.child, roundID: round,
            operationID: reportID, kind: .completed, payload: "reported") == report)
        #expect(try await reopened.observeWakeConsumption(taskID: f.taskID, operationID: wakeID, binding: parent) == consumed)
        await f.host.setNative(.ready)
        let next = try #require(try await f.input("next round").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        await #expect(throws: SessionTaskError.staleBinding) { _ = try await f.report(round, payload: "stale") }
        let after = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(after.activeRound?.id == next && after.activeRound?.nativeTurnID == nil)
    }

    @Test func reopeningAVersionOneStoreIndexesOperationCascade() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let input = try await f.input("preserve")
        let round = try #require(input.roundID)
        let delivered = try await f.coordinator.deliverPending(taskID: f.taskID)
        let active = try await f.coordinator.status(taskID: f.taskID, parent: f.parent).activeRound
        let turn = try #require(active?.nativeTurnID)
        let reportID = UUID()
        let report = try await f.report(round, payload: "preserve result", operationID: reportID)
        let wakeID = UUID()
        _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: wakeID)
        let parent = await f.host.parent
        let consumed = try await f.coordinator.observeWakeConsumption(taskID: f.taskID, operationID: wakeID, binding: parent)
        let wakeTurn = try #require(consumed.consumedTurnID)
        let legacyParts = ["report", f.taskID.uuidString, round.uuidString, turn, reportID.uuidString,
                           SessionTaskReportKind.completed.rawValue, "preserve result"]
        let legacyText = legacyParts.map { "\($0.utf8.count):\($0)" }.joined()
        let legacyFingerprint = SHA256.hash(data: Data(legacyText.utf8)).map { String(format: "%02x", $0) }.joined()
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(f.url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        let legacy = """
            DROP INDEX IF EXISTS operations_task;
            UPDATE rounds SET body=json_remove(body, '$.execution');
            UPDATE events SET body=json_remove(body, '$.execution');
            UPDATE operations SET body=json_remove(body, '$.receipt.consumedExecution');
            UPDATE operations SET body=json_set(body, '$.fingerprint', '\(legacyFingerprint)') WHERE id='\(reportID.uuidString)';
            """
        try #require(sqlite3_exec(db, legacy, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let reopened = try await SessionTaskCoordinator.open(url: f.url, host: f.host, now: { f.clock.now() })
        #expect(try await reopened.requestRound(taskID: f.taskID, parent: f.parent,
                                               operationID: input.operationID, message: "preserve") == delivered)
        #expect(try await reopened.report(taskID: f.taskID, child: f.child, roundID: round,
            operationID: reportID, kind: .completed, payload: "preserve result") == report)
        let oldEvent = try #require(try await reopened.events(taskID: f.taskID, parent: f.parent).items.first)
        #expect(oldEvent.id == reportID && oldEvent.nativeTurnID == turn && oldEvent.observedExecution == .nativeTurn(turn))
        let oldWake = try await reopened.observeWakeConsumption(taskID: f.taskID, operationID: wakeID, binding: parent)
        #expect(oldWake.consumedTurnID == wakeTurn && oldWake.observedConsumption == .nativeTurn(wakeTurn))
        db = nil
        try #require(sqlite3_open_v2(f.url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN DELETE FROM tasks WHERE id='owned'", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var usesIndex = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 3), String(cString: text).contains("operations_task") { usesIndex = true }
        }
        #expect(usesIndex)
    }

    @Test func oldWakeObservationCannotConsumeAReboundParentRun() async throws {
        let f = try await TaskFixture.make(parentHarness: .claude, childHarness: .claude)
        defer { f.clean() }
        await f.host.usePromptProofOnly()
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        let wakeID = UUID()
        _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: wakeID)
        let oldParent = await f.host.parent
        try await f.coordinator.fence(taskID: f.taskID, binding: oldParent)
        let newParent = SessionTaskBinding(sessionID: oldParent.sessionID, nativeSessionID: oldParent.nativeSessionID,
                                           managedRunID: UUID(), generation: UUID())
        await f.host.replaceParent(newParent)
        let claim = SessionTaskClaim(sessionID: newParent.sessionID, managedRunID: newParent.managedRunID,
                                     generation: newParent.generation, credential: "parent-local")
        _ = try await f.coordinator.rebindAndApprove(taskID: f.taskID, parent: claim, child: f.child)
        await #expect(throws: SessionTaskError.staleBinding) {
            _ = try await f.coordinator.observeWakeConsumption(taskID: f.taskID, operationID: wakeID, binding: oldParent)
        }
        let status = try await f.coordinator.status(taskID: f.taskID, parent: claim)
        #expect(status.task.parentWakesUsed == 0 && status.task.parentWakesConsumed == 0)
    }

    @Test(arguments: [(HarnessID.claude, HarnessID.codex), (HarnessID.codex, HarnessID.claude),
                      (HarnessID.claude, HarnessID("gemini")), (HarnessID.codex, HarnessID.opencode)])
    func threeRoundsKeepChildAndWakeEachTime(_ direction: (HarnessID, HarnessID)) async throws {
        let f = try await TaskFixture.make(parentHarness: direction.0, childHarness: direction.1)
        defer { f.clean() }
        var ids: Set<UUID> = []
        for number in 1...3 {
            let queued = try await f.input("work \(number)")
            let round = try #require(queued.roundID)
            #expect(ids.insert(round).inserted)
            let delivered = try await f.coordinator.deliverPending(taskID: f.taskID)
            #expect(delivered.roundID == round && delivered.delivery == .submitted)
            let running = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
            #expect(running.task.childSessionID == f.childID && running.nativeStatus == .working)
            #expect(running.task.requestedChoices.model == "requested-model" && running.task.effectiveModel == "actual-model")
            _ = try await f.report(round, payload: "result \(number)")
            await f.host.setNative(.ready)
            let wakeID = UUID()
            let wake = try await f.coordinator.wakePending(taskID: f.taskID, operationID: wakeID)
            #expect(wake.delivery == .submitted)
            #expect(wake.consumedTurnID == nil)
            let parentBinding = await f.host.parent
            let proof = try #require(await f.host.wakeReference(wakeID))
            guard case let .nativeTurn(turn) = proof else { throw SessionTaskError.unverified }
            let consumed = try await f.coordinator.observeWakeConsumption(taskID: f.taskID, operationID: wakeID,
                                                                            binding: parentBinding)
            #expect(consumed.consumedTurnID == turn && consumed.observedConsumption == proof)
            #expect(try await f.coordinator.observeWakeConsumption(taskID: f.taskID, operationID: wakeID,
                binding: parentBinding) == consumed)
        }
        let events = try await f.coordinator.events(taskID: f.taskID, parent: f.parent)
        #expect(events.items.map(\.payload) == ["result 1", "result 2", "result 3"])
        #expect(Set(events.items.map(\.roundID)) == ids)
        #expect(events.items.allSatisfy { event in
            guard let turn = event.nativeTurnID else { return false }
            return event.observedExecution == .nativeTurn(turn) && !turn.contains(event.roundID.uuidString)
        })
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.childInputsUsed == 3 && status.task.parentWakesUsed == 3 && status.task.parentWakesConsumed == 3)
        #expect(status.task.lifecycle == .active && status.nativeStatus == .ready)
        await #expect(throws: SessionTaskError.needsApproval) { _ = try await f.input("fourth") }
        let counts = await f.host.counts()
        #expect(counts.0 == 3 && counts.1 == 3 && counts.2 == 0 && counts.3 == 0)
    }

    @Test func workingAttentionAndMissingReportDoNotDeliverQueuedInput() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let first = try #require(try await f.input("first").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let second = try #require(try await f.input("follow-up").roundID)
        await #expect(throws: SessionTaskError.missingReport) { _ = try await f.coordinator.deliverPending(taskID: f.taskID) }
        await f.host.setNative(.ready)
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.missingReport && status.activeRound?.id == first && status.pendingRound?.id == second)
        _ = try await f.report(first)
        await f.host.setNative(.waitingForUser)
        let deferred = try await f.coordinator.deliverPending(taskID: f.taskID)
        let countsBeforeReady = await f.host.counts()
        #expect(deferred.delivery == .deferred && countsBeforeReady.0 == 1)
        await f.host.setNative(.ready)
        #expect(try await f.coordinator.deliverPending(taskID: f.taskID).delivery == .submitted)
        #expect((await f.host.counts()).0 == 2)
    }

    @Test func duplicatesAreStableButUnknownDeliveryNeverReplaysAfterRestart() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let operation = UUID()
        let first = try await f.input("only once", operationID: operation)
        #expect(try await f.input("only once", operationID: operation) == first)
        await #expect(throws: SessionTaskError.conflictingOperation) { _ = try await f.input("different", operationID: operation) }
        await f.host.setUnknown(true)
        #expect(try await f.coordinator.deliverPending(taskID: f.taskID).delivery == .unknown)
        let restarted = try await SessionTaskCoordinator.open(url: f.url, host: f.host, now: { f.clock.now() })
        #expect(try await restarted.deliverPending(taskID: f.taskID).delivery == .unknown)
        #expect((await f.host.counts()).0 == 1)
        let retry = try await restarted.requestRound(taskID: f.taskID, parent: f.parent, operationID: operation, message: "only once")
        #expect(retry.roundID == first.roundID && retry.delivery == .unknown)
    }

    @Test func sameReportRetryIsIdempotentAndOldRoundCannotInterruptNewOne() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let first = try #require(try await f.input("first").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let reportID = UUID()
        let receipt = try await f.report(first, operationID: reportID)
        #expect(try await f.report(first, operationID: reportID) == receipt)
        await f.host.setNative(.ready)
        let second = try #require(try await f.input("second").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let late = try await f.coordinator.interruptAndUpdate(taskID: f.taskID, parent: f.parent, roundID: first,
            operationID: UUID(), nextOperationID: UUID(), message: "must not run")
        let afterLate = await f.host.counts()
        #expect(late.delivery == .alreadySettled && afterLate.2 == 0)
        let sameEvent = try await f.coordinator.report(taskID: f.taskID, child: f.child, roundID: first,
            operationID: UUID(), eventID: reportID,
            kind: .completed, payload: "done")
        #expect(sameEvent.delivery == .verified)
        #expect(try await f.coordinator.events(taskID: f.taskID, parent: f.parent).items.count == 1)
        await #expect(throws: SessionTaskError.staleBinding) { _ = try await f.report(first, payload: "late") }
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.activeRound?.id == second && status.activeRound?.phase == .active)
    }

    @Test func interruptUpdateCreatesNewRoundAndStopIsNotCompletion() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let first = try #require(try await f.input("first").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let updateID = UUID()
        let interrupted = try await f.coordinator.interruptAndUpdate(taskID: f.taskID, parent: f.parent, roundID: first,
            operationID: UUID(), nextOperationID: updateID, message: "updated")
        let afterInterrupt = await f.host.counts()
        #expect(interrupted.delivery == .verified && afterInterrupt.2 == 1)
        let queued = try await f.input("updated", operationID: updateID)
        #expect(queued.roundID != first)
        #expect(try await f.coordinator.deliverPending(taskID: f.taskID).roundID == queued.roundID)
        await f.host.setStopVerified(false)
        let firstStop = try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID())
        #expect(firstStop.delivery == .unverified)
        let uncertain = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(uncertain.task.lifecycle == .stopUnverified)
        await f.host.setStopVerified(true)
        let retry = try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID())
        #expect(retry.delivery == .verified)
        let stopped = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(stopped.task.lifecycle == .stopped && stopped.nativeStatus == .stopped)
        #expect(try await f.coordinator.events(taskID: f.taskID, parent: f.parent).items.isEmpty)
    }

    @Test func waitReportsAndNudgesAreBoundedAndExpiryRequiresApproval() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("question").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let revision = try await f.coordinator.status(taskID: f.taskID, parent: f.parent).task.revision
        let waiter = Task { try await f.coordinator.wait(taskID: f.taskID, parent: f.parent, afterRevision: revision, seconds: 2) }
        try await Task.sleep(for: .milliseconds(25))
        let ask = UUID()
        _ = try await f.report(round, kind: .needsParentInput, payload: "Which option?", operationID: ask)
        #expect(try await waiter.value?.revision ?? 0 > revision)
        for number in 0..<6 {
            if number > 0 { _ = try await f.report(round, kind: .needsParentInput, payload: "question \(number)") }
            #expect(try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()).delivery == .submitted)
        }
        let latestAsk = UUID()
        _ = try await f.report(round, kind: .needsParentInput, payload: "one more", operationID: latestAsk)
        await #expect(throws: SessionTaskError.needsApproval) { _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()) }
        await #expect(throws: SessionTaskError.staleRound) { _ = try await f.input("old answer", replyTo: ask) }
        let reply = try await f.input("option A", replyTo: latestAsk)
        #expect(reply.roundID != round)
        f.clock.advance(3601)
        await #expect(throws: SessionTaskError.needsApproval) { _ = try await f.coordinator.deliverPending(taskID: f.taskID) }
        await #expect(throws: SessionTaskError.invalidDeadline) {
            _ = try await f.coordinator.wait(taskID: f.taskID, parent: f.parent, afterRevision: 0, seconds: 61)
        }
    }

    @Test func scopedReadsBoundsAndForgettingRequireLiveAuthority() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let bad = SessionTaskClaim(sessionID: f.parent.sessionID, managedRunID: f.parent.managedRunID,
                                   generation: f.parent.generation, credential: "other")
        await #expect(throws: SessionTaskError.unauthorized) { _ = try await f.coordinator.status(taskID: f.taskID, parent: bad) }
        await #expect(throws: SessionTaskError.unauthorized) { _ = try await f.coordinator.status(taskID: f.taskID, parent: f.child) }
        let permissions = try FileManager.default.attributesOfItem(atPath: f.url.path)[.posixPermissions] as? NSNumber
        #expect((permissions?.intValue ?? 0o777) & 0o077 == 0)
        await #expect(throws: SessionTaskError.invalidPayload) { _ = try await f.input(String(repeating: "x", count: 16_385)) }
        await #expect(throws: SessionTaskError.invalidPayload) { _ = try await f.input("x\0y") }
        await #expect(throws: SessionTaskError.invalidPage) { _ = try await f.coordinator.events(taskID: f.taskID, parent: f.parent, limit: 51) }
        let round = try #require(try await f.input("start").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        for number in 0..<52 { _ = try await f.report(round, kind: .needsParentInput, payload: "ask \(number)") }
        let first = try await f.coordinator.events(taskID: f.taskID, parent: f.parent, limit: 50)
        let rest = try await f.coordinator.events(taskID: f.taskID, parent: f.parent, after: try #require(first.next), limit: 50)
        #expect(first.items.count == 50 && rest.items.count == 2 && rest.next == nil)
        await #expect(throws: SessionTaskError.unverified) { try await f.coordinator.forgetAfterVerifiedStop(sessionID: f.childID) }
        #expect(try await f.coordinator.events(taskID: f.taskID, parent: f.parent, limit: 1).items.count == 1)
        #expect(try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID()).delivery == .verified)
        await f.host.allowForget()
        try await f.coordinator.forgetAfterVerifiedStop(sessionID: f.childID)
        try await f.coordinator.forgetAfterVerifiedStop(sessionID: f.childID)
        await #expect(throws: SessionTaskError.notFound) { _ = try await f.coordinator.status(taskID: f.taskID, parent: f.parent) }
    }

    @Test func lifecycleFenceWinsOverLateInterruptAndRebindKeepsNativeIdentity() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let first = try #require(try await f.input("first").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        await f.host.holdInterrupt()
        let interrupt = Task { try await f.coordinator.interruptAndUpdate(taskID: f.taskID, parent: f.parent,
            roundID: first, operationID: UUID(), nextOperationID: UUID(), message: "replacement") }
        for _ in 0..<100 {
            if await f.host.hasEnteredInterrupt() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredInterrupt())
        let oldChild = await f.host.child
        try await f.coordinator.fence(taskID: f.taskID, binding: oldChild)
        await f.host.releaseInterrupt()
        #expect(try await interrupt.value.delivery == .unverified)
        let fenced = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(fenced.task.lifecycle == .revoked && fenced.pendingRound == nil && fenced.activeRound == nil)
        let resumed = SessionTaskBinding(sessionID: oldChild.sessionID, nativeSessionID: oldChild.nativeSessionID,
                                         managedRunID: UUID(), generation: UUID())
        await f.host.replaceChild(resumed)
        let claim = SessionTaskClaim(sessionID: resumed.sessionID, managedRunID: resumed.managedRunID,
                                     generation: resumed.generation, credential: "child-local")
        let rebound = try await f.coordinator.rebindAndApprove(taskID: f.taskID, parent: f.parent, child: claim)
        #expect(rebound.childBinding == resumed && rebound.lifecycle == .active)
        await #expect(throws: SessionTaskError.unauthorized) { _ = try await f.report(first, payload: "late") }
        try await f.coordinator.fence(taskID: f.taskID, binding: resumed)
        let different = SessionTaskBinding(sessionID: resumed.sessionID, nativeSessionID: "different-native",
                                           managedRunID: UUID(), generation: UUID())
        await f.host.replaceChild(different)
        let differentClaim = SessionTaskClaim(sessionID: different.sessionID, managedRunID: different.managedRunID,
                                              generation: different.generation, credential: "child-local")
        await #expect(throws: SessionTaskError.staleBinding) {
            _ = try await f.coordinator.rebindAndApprove(taskID: f.taskID, parent: f.parent, child: differentClaim)
        }
    }

    @Test func stopWinsBeforeTheExactInterruptSocketWrite() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let output = sockets[0], input = sockets[1]
        defer { close(output); close(input) }
        _ = fcntl(input, F_SETFL, O_NONBLOCK)
        await f.host.setInterruptEffectProbe {
            var byte: UInt8 = 0x1b
            return Darwin.send(output, &byte, 1, 0) == 1
        }
        let first = try #require(try await f.input("first").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        await f.host.holdInterrupt()
        let interrupt = Task { try await f.coordinator.interruptAndUpdate(taskID: f.taskID, parent: f.parent,
            roundID: first, operationID: UUID(), nextOperationID: UUID(), message: "replacement") }
        for _ in 0..<100 {
            if await f.host.hasEnteredInterrupt() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredInterrupt())
        #expect(try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID()).delivery == .verified)
        await f.host.releaseInterrupt()
        #expect(try await interrupt.value.delivery == .unverified)
        var received: UInt8 = 0
        #expect(Darwin.recv(input, &received, 1, 0) == -1 && errno == EAGAIN)
        #expect(await f.host.actualInterruptEffects() == 0)
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.lifecycle == .stopped && status.pendingRound == nil)
    }

    @Test func unknownStartAndWakeStayFencedUntilOwnerVerifiesStop() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        _ = try await f.input("first")
        await f.host.setUnknown(true)
        #expect(try await f.coordinator.deliverPending(taskID: f.taskID).delivery == .unknown)
        await f.host.setStopVerified(false)
        #expect(try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID()).delivery == .unverified)
        let uncertain = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(uncertain.task.lifecycle == .stopUnverified && uncertain.task.uncertainChildEffects == 1)
        await f.host.setStopVerified(true)
        #expect(try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID()).delivery == .verified)
        _ = try await f.coordinator.rebindAndApprove(taskID: f.taskID, parent: f.parent)
        await f.host.setUnknown(false)
        await f.host.setNative(.ready)
        let round = try #require(try await f.input("new authorized input").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        await f.host.setWakeUnknown(true)
        let wakeID = UUID()
        #expect(try await f.coordinator.wakePending(taskID: f.taskID, operationID: wakeID).delivery == .unknown)
        let binding = await f.host.child
        try await f.coordinator.fence(taskID: f.taskID, binding: binding)
        await #expect(throws: SessionTaskError.unverified) {
            _ = try await f.coordinator.rebindAndApprove(taskID: f.taskID, parent: f.parent, child: f.child)
        }
        await #expect(throws: SessionTaskError.unverified) {
            _ = try await f.coordinator.verifyUnknownWakeStopped(taskID: f.taskID, operationID: wakeID)
        }
        await f.host.confirmWakeStopped()
        let settled = try await f.coordinator.verifyUnknownWakeStopped(taskID: f.taskID, operationID: wakeID)
        #expect(settled.delivery == .unverified)
        #expect(try await f.coordinator.verifyUnknownWakeStopped(taskID: f.taskID, operationID: wakeID) == settled)
        _ = try await f.coordinator.rebindAndApprove(taskID: f.taskID, parent: f.parent, child: f.child)
        await #expect(throws: SessionTaskError.notReady) { _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()) }
        #expect((await f.host.counts()).1 == 1)
        try await f.coordinator.requeueUnknownWakeAfterApproval(taskID: f.taskID, operationID: wakeID)
        await f.host.setWakeUnknown(false)
        #expect(try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()).delivery == .submitted)
        #expect((await f.host.counts()).1 == 2)
    }

    @Test func repeatedEventDoesNotCreateAnotherNudgeOrReplaceItsPayload() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("start").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let eventID = UUID()
        _ = try await f.coordinator.report(taskID: f.taskID, child: f.child, roundID: round,
            operationID: UUID(), eventID: eventID,
            kind: .needsParentInput, payload: "pick one")
        let duplicate = try await f.coordinator.report(taskID: f.taskID, child: f.child, roundID: round,
            operationID: UUID(), eventID: eventID,
            kind: .needsParentInput, payload: "pick one")
        #expect(duplicate.delivery == .verified)
        await #expect(throws: SessionTaskError.conflictingOperation) {
            _ = try await f.coordinator.report(taskID: f.taskID, child: f.child, roundID: round,
                operationID: UUID(), eventID: eventID,
                kind: .needsParentInput, payload: "changed")
        }
        let events = try await f.coordinator.events(taskID: f.taskID, parent: f.parent)
        #expect(events.items.count == 1 && events.items.first?.payload == "pick one")
        _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID())
        #expect(await f.host.lastWakeCount() == 1)
        await #expect(throws: SessionTaskError.notReady) { _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()) }
    }

    @Test func reportBeforeInitialSubmitReturnsIsRetainedOnce() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let observation = TaskEarlyReportObservation()
        let coordinator = f.coordinator, child = f.child, taskID = f.taskID
        await f.host.onSubmit { intent in
            do {
                _ = try await coordinator.report(taskID: taskID, child: child, roundID: intent.round.id,
                    operationID: UUID(),
                    kind: .completed, payload: "early result")
                await observation.markAccepted()
            } catch { }
        }
        let queued = try await f.input("first")
        let sent = try await coordinator.deliverPending(taskID: taskID)
        #expect(sent.roundID == queued.roundID && sent.delivery == .submitted)
        #expect(await observation.accepted)
        let status = try await coordinator.status(taskID: taskID, parent: f.parent)
        #expect(status.activeRound == nil && status.pendingRound == nil && status.task.uncertainChildEffects == 0)
        let events = try await coordinator.events(taskID: taskID, parent: f.parent)
        #expect(events.items.count == 1 && events.items.first?.payload == "early result")
    }

    @Test func verifiedStopFencesAnInFlightInitialSubmission() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let input = try await f.input("only once")
        let roundID = try #require(input.roundID)
        await f.host.holdSubmit()
        let delivery = Task { try await f.coordinator.deliverPending(taskID: f.taskID) }
        for _ in 0..<100 {
            if await f.host.hasEnteredSubmit() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredSubmit())
        let stopped = try await f.coordinator.stopChild(taskID: f.taskID, parent: f.parent, operationID: UUID())
        #expect(stopped.delivery == .verified)
        await f.host.releaseSubmit()
        #expect(try await delivery.value.delivery == .submitted)
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.lifecycle == .stopped && status.activeRound == nil && status.pendingRound == nil)
        let rounds = try await f.coordinator.rounds(taskID: f.taskID, parent: f.parent)
        #expect(rounds.items.first?.id == input.roundID && rounds.items.first?.phase == .retired)
        await #expect(throws: SessionTaskError.staleBinding) { _ = try await f.report(roundID) }
        #expect((await f.host.counts()).0 == 1)
    }

    @Test func observedWakeConsumptionResolvesUnknownWithoutResending() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        await f.host.setWakeUnknown(true)
        let wakeID = UUID()
        #expect(try await f.coordinator.wakePending(taskID: f.taskID, operationID: wakeID).delivery == .unknown)
        let binding = await f.host.parent
        let proof = try #require(await f.host.wakeReference(wakeID))
        guard case let .nativeTurn(turn) = proof else { throw SessionTaskError.unverified }
        let receipt = try await f.coordinator.observeWakeConsumption(taskID: f.taskID, operationID: wakeID,
            binding: binding)
        #expect(receipt.delivery == .submitted && receipt.consumedTurnID == turn && receipt.observedConsumption == proof)
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.parentWakesUsed == 1 && status.task.parentWakesConsumed == 1 && status.task.uncertainWakeEffects == 0)
        #expect((await f.host.counts()).1 == 1)
        await #expect(throws: SessionTaskError.notReady) { _ = try await f.coordinator.wakePending(taskID: f.taskID, operationID: UUID()) }
    }

    @Test func contradictoryLateLaunchIdentityRevokesTheTask() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let coordinator = f.coordinator, child = f.child, taskID = f.taskID
        await f.host.onSubmit { intent in
            _ = try? await coordinator.report(taskID: taskID, child: child, roundID: intent.round.id,
                operationID: UUID(),
                kind: .completed, payload: "bound result")
        }
        let actual = await f.host.child
        let mismatched = SessionTaskBinding(sessionID: actual.sessionID, nativeSessionID: "different-native",
                                             managedRunID: actual.managedRunID, generation: actual.generation)
        await f.host.returnBinding(mismatched)
        _ = try await f.input("first")
        _ = try await coordinator.deliverPending(taskID: taskID)
        let status = try await coordinator.status(taskID: taskID, parent: f.parent)
        #expect(status.task.lifecycle == .identityChanged)
        #expect(status.task.childBinding == actual)
        await #expect(throws: SessionTaskError.needsApproval) { _ = try await f.input("never delivered") }
        #expect(try await coordinator.events(taskID: taskID, parent: f.parent).items.count == 1)
    }

    @Test func providerConsumptionMayPrecedeWakeWriteReceipt() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("work").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        _ = try await f.report(round)
        await f.host.setWakeUnknown(true)
        await f.host.holdWake()
        let operation = UUID()
        let waking = Task { try await f.coordinator.wakePending(taskID: f.taskID, operationID: operation) }
        for _ in 0..<100 {
            if await f.host.hasEnteredWake() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredWake())
        let binding = await f.host.parent
        let consumed = try await f.coordinator.observeWakeConsumption(taskID: f.taskID, operationID: operation,
            binding: binding)
        await f.host.releaseWake()
        #expect(try await waking.value == consumed)
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.parentWakesUsed == 1 && status.task.parentWakesConsumed == 1 && status.task.uncertainWakeEffects == 0)
        #expect((await f.host.counts()).1 == 1)
    }

    @Test func childReservationCannotAdoptOrBelongToTwoTasks() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let otherChild = UUID()
        await #expect(throws: SessionTaskError.unauthorized) {
            _ = try await f.coordinator.createApproved(taskID: UUID(), parent: f.parent, childID: otherChild,
                harness: .codex, childName: "other", choices: HarnessLaunchChoices(harness: .codex))
        }
        await #expect(throws: SessionTaskError.childAlreadyOwned) {
            _ = try await f.coordinator.createApproved(taskID: UUID(), parent: f.parent, childID: f.childID,
                harness: .codex, childName: "duplicate", choices: HarnessLaunchChoices(harness: .codex))
        }
    }

    @Test func lifecycleFenceRetiresQueuedReceiptWithoutReplayingIt() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let first = try #require(try await f.input("first").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let operation = UUID()
        let queued = try await f.input("pending", operationID: operation)
        let childBinding = await f.host.child
        try await f.coordinator.fence(taskID: f.taskID, binding: childBinding)
        let retry = try await f.input("pending", operationID: operation)
        #expect(retry.roundID == queued.roundID && retry.delivery == .cancelled)
        let rounds = try await f.coordinator.rounds(taskID: f.taskID, parent: f.parent)
        #expect(rounds.items.first { $0.id == first }?.phase == .retired)
        #expect(rounds.items.first { $0.id == queued.roundID }?.phase == .retired)
        #expect((await f.host.counts()).0 == 1)
    }

    @Test func newerAttentionRetiresAnUnsentReplyToTheOldRequest() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("first").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let oldAsk = UUID(), newAsk = UUID(), oldReply = UUID()
        _ = try await f.report(round, kind: .needsParentInput, payload: "old question", operationID: oldAsk)
        _ = try await f.input("old answer", operationID: oldReply, replyTo: oldAsk)
        _ = try await f.report(round, kind: .needsParentInput, payload: "new question", operationID: newAsk)
        #expect(try await f.input("old answer", operationID: oldReply, replyTo: oldAsk).delivery == .cancelled)
        let next = try await f.input("new answer", replyTo: newAsk)
        await f.host.setNative(.ready)
        #expect(try await f.coordinator.deliverPending(taskID: f.taskID).roundID == next.roundID)
        #expect((await f.host.counts()).0 == 2)
    }

    @Test func withdrawingAQueuedInputDoesNotStopTheWorkingChild() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let first = try #require(try await f.input("working").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let inputID = UUID(), cancelID = UUID()
        let queued = try await f.input("withdraw", operationID: inputID)
        let round = try #require(queued.roundID)
        let cancelled = try await f.coordinator.cancelQueued(taskID: f.taskID, parent: f.parent,
                                                              roundID: round, operationID: cancelID)
        #expect(cancelled.delivery == .verified)
        #expect(try await f.coordinator.cancelQueued(taskID: f.taskID, parent: f.parent,
                                                     roundID: round, operationID: cancelID) == cancelled)
        #expect(try await f.input("withdraw", operationID: inputID).delivery == .cancelled)
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.activeRound?.id == first && status.pendingRound == nil && status.nativeStatus == .working)
        let counts = await f.host.counts()
        #expect(counts.2 == 0 && counts.3 == 0)
    }

    @Test func aLateStaleReplyCannotConsumeANewerAttentionRequest() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("start").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let oldAsk = UUID(), newAsk = UUID()
        _ = try await f.report(round, kind: .needsParentInput, payload: "old", operationID: oldAsk)
        _ = try await f.input("old answer", replyTo: oldAsk)
        await f.host.setNative(.ready)
        await f.host.holdSubmit()
        let delivery = Task { try await f.coordinator.deliverPending(taskID: f.taskID) }
        for _ in 0..<100 {
            if await f.host.hasEnteredSubmit() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.host.hasEnteredSubmit())
        _ = try await f.report(round, kind: .needsParentInput, payload: "new", operationID: newAsk)
        await f.host.releaseSubmit()
        #expect(try await delivery.value.delivery == .submitted)
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.task.lifecycle == .revoked && status.activeRound?.id == round &&
                status.task.currentAttentionID == newAsk && status.pendingRound == nil)
        let events = try await f.coordinator.events(taskID: f.taskID, parent: f.parent)
        #expect(events.items.map(\.payload) == ["old", "new"])
    }

    @Test func completionRetiresAnUnsentReplyToAnOldQuestion() async throws {
        let f = try await TaskFixture.make()
        defer { f.clean() }
        let round = try #require(try await f.input("start").roundID)
        _ = try await f.coordinator.deliverPending(taskID: f.taskID)
        let ask = UUID(), reply = UUID()
        _ = try await f.report(round, kind: .needsParentInput, payload: "question", operationID: ask)
        _ = try await f.input("answer", operationID: reply, replyTo: ask)
        _ = try await f.report(round, kind: .completed, payload: "finished")
        let receipt = try await f.input("answer", operationID: reply, replyTo: ask)
        #expect(receipt.delivery == .cancelled)
        let status = try await f.coordinator.status(taskID: f.taskID, parent: f.parent)
        #expect(status.pendingRound == nil && status.activeRound == nil)
        #expect((await f.host.counts()).0 == 1)
    }
}
