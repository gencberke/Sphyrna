import Foundation
import Testing
@testable import LoomCore
@testable import LoomCoreTestRigs

private actor TaskDeletionRaceHost: SessionTaskHost {
    let parent: SessionTaskBinding
    let children: [UUID: SessionTaskBinding]
    private var holdStops = false
    private var stopEntered = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var holdOwnership = false
    private var ownershipEntered = false
    private var ownershipContinuation: CheckedContinuation<Void, Never>?

    init(parent: SessionTaskBinding, children: [SessionTaskBinding]) {
        self.parent = parent
        self.children = Dictionary(uniqueKeysWithValues: children.map { ($0.sessionID, $0) })
    }
    func authenticate(_ claim: SessionTaskClaim) -> SessionTaskBinding? {
        guard claim.credential == "synthetic" else { return nil }
        let binding = claim.sessionID == parent.sessionID ? parent : children[claim.sessionID]
        guard binding?.managedRunID == claim.managedRunID, binding?.generation == claim.generation else { return nil }
        return binding
    }
    func ownsNewChild(taskID: UUID, parent: SessionTaskBinding, childID: UUID) async -> Bool {
        if holdOwnership {
            ownershipEntered = true
            await withCheckedContinuation { ownershipContinuation = $0 }
        }
        return parent == self.parent && children[childID] != nil
    }
    func observedChildExecution(_ target: SessionTaskRoundTarget) -> SessionTaskExecutionReference? {
        guard children[target.binding.sessionID] == target.binding else { return nil }
        return .nativeTurn("turn-\(target.roundID.uuidString)")
    }
    func observedWakeExecution(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) -> SessionTaskExecutionReference? { nil }
    func nativeStatus(binding: SessionTaskBinding) -> SessionTaskNativeStatus { .ready }
    func submitIfReady(_ intent: SessionTaskInputIntent) -> SessionTaskInputEffect {
        guard let child = children[intent.task.childSessionID] else { return .unknown }
        return .submitted(binding: child, nativeTurnID: "turn-\(intent.round.id.uuidString)",
                          actualModel: nil, actualEffort: nil, actualMode: nil)
    }
    func wakeIfReady(_ intent: SessionTaskWakeIntent) -> SessionTaskEffect { .deferred }
    func interrupt(_ target: SessionTaskRoundTarget) -> SessionTaskEffect { .unknown }
    func stopChild(taskID: UUID, binding: SessionTaskBinding) async -> SessionTaskEffect {
        if holdStops {
            stopEntered = true
            await withCheckedContinuation { stopContinuation = $0 }
        }
        return children[binding.sessionID] == binding ? .verified : .unknown
    }
    func stopUnknownChild(taskID: UUID, childSessionID: UUID) -> SessionTaskEffect { .unknown }
    func verifyUnknownWakeStopped(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) -> Bool { false }
    func mayForget(sessionID: UUID) -> Bool { sessionID == parent.sessionID }
    func holdNextStop() { holdStops = true }
    func hasEnteredStop() -> Bool { stopEntered }
    func releaseStop() { holdStops = false; stopContinuation?.resume(); stopContinuation = nil }
    func holdNextOwnership() { holdOwnership = true }
    func hasEnteredOwnership() -> Bool { ownershipEntered }
    func releaseOwnership() { holdOwnership = false; ownershipContinuation?.resume(); ownershipContinuation = nil }
}

private struct TaskDeletionRaceFixture {
    let root: URL
    let coordinator: SessionTaskCoordinator
    let host: TaskDeletionRaceHost
    let parent: SessionTaskClaim
    let childClaims: [SessionTaskClaim]

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-delete-race-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        func binding() -> SessionTaskBinding {
            SessionTaskBinding(sessionID: UUID(), nativeSessionID: UUID().uuidString,
                               managedRunID: UUID(), generation: UUID())
        }
        func claim(_ binding: SessionTaskBinding) -> SessionTaskClaim {
            SessionTaskClaim(sessionID: binding.sessionID, managedRunID: binding.managedRunID,
                             generation: binding.generation, credential: "synthetic")
        }
        let parent = binding(), children = [binding(), binding(), binding()]
        let host = TaskDeletionRaceHost(parent: parent, children: children)
        let coordinator = try await SessionTaskCoordinator.open(url: root.appendingPathComponent("tasks.sqlite"), host: host)
        return Self(root: root, coordinator: coordinator, host: host, parent: claim(parent),
                    childClaims: children.map(claim))
    }
    func create(task: UUID, child: SessionTaskClaim) async throws {
        _ = try await coordinator.createApproved(taskID: task, parent: parent, childID: child.sessionID,
            harness: .claude, childName: "child", choices: HarnessLaunchChoices(harness: .claude))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct SessionTaskDeletionRaceTests {
    @Test func deletionFencesEveryChildBeforeTheFirstStopFinishes() async throws {
        let fixture = try await TaskDeletionRaceFixture.make(); defer { fixture.cleanup() }
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        try await fixture.create(task: first, child: fixture.childClaims[0])
        try await fixture.create(task: second, child: fixture.childClaims[1])
        var targetRound: UUID?, targetOperation: UUID?
        for task in [first, second] {
            let operation = UUID()
            let receipt = try await fixture.coordinator.requestRound(taskID: task, parent: fixture.parent,
                                                                      operationID: operation, message: "private task input")
            _ = try await fixture.coordinator.deliverPending(taskID: task)
            if task == second { targetRound = receipt.roundID; targetOperation = operation }
        }
        let round = try #require(targetRound), operation = try #require(targetOperation)
        #expect(try await fixture.coordinator.childInput(taskID: second, child: fixture.childClaims[1],
                                                        roundID: round, inputOperationID: operation) == "private task input")
        await fixture.host.holdNextStop()
        let deletion = Task { try await fixture.coordinator.forgetAfterVerifiedStop(sessionID: fixture.parent.sessionID) }
        #expect(await SessionRuntimeRig.waitUntil(2) { await fixture.host.hasEnteredStop() })
        await #expect(throws: SessionTaskError.staleRound) {
            _ = try await fixture.coordinator.childInput(taskID: second, child: fixture.childClaims[1],
                                                          roundID: round, inputOperationID: operation)
        }
        await fixture.host.releaseStop()
        try await deletion.value
        #expect(try await fixture.coordinator.projectionForUser(taskID: second) == nil)
    }

    @Test func anInFlightCreateCannotRecreateADeletedRelationship() async throws {
        let fixture = try await TaskDeletionRaceFixture.make(); defer { fixture.cleanup() }
        let original = UUID(), late = UUID()
        try await fixture.create(task: original, child: fixture.childClaims[0])
        await fixture.host.holdNextOwnership()
        let creation = Task { try await fixture.create(task: late, child: fixture.childClaims[1]) }
        #expect(await SessionRuntimeRig.waitUntil(2) { await fixture.host.hasEnteredOwnership() })
        try await fixture.coordinator.forgetAfterVerifiedStop(sessionID: fixture.parent.sessionID)
        await fixture.host.releaseOwnership()
        await #expect(throws: SessionTaskError.unverified) { try await creation.value }
        #expect(try await fixture.coordinator.projectionForUser(taskID: late) == nil)
    }
}
