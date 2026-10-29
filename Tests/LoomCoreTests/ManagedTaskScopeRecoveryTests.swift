import Darwin
import Foundation
import Testing
@testable import LoomCore

extension SessionRuntime {
    func installRecoveredTaskCoordinatorForTest(_ coordinator: SessionTaskCoordinator) {
        taskCoordinator = coordinator
    }

    func forgetRecoveredParentForTest(_ sessionID: UUID) async throws {
        deletionsInFlight.insert(sessionID)
        defer { deletionsInFlight.remove(sessionID) }
        guard let taskCoordinator else { throw SessionTaskError.storage }
        try await taskCoordinator.forgetAfterVerifiedStop(sessionID: sessionID)
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct ManagedTaskScopeRecoveryTests {
    private func previousLedger(root: URL, binding: ManagedTaskScopeBinding) throws -> (URL, URL) {
        let runs = root.appendingPathComponent("runs", isDirectory: true)
        let previous = runs.appendingPathComponent("previous", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        var ledger = OwnershipLedger(runID: binding.ownerRunID)
        ledger.register(scope: binding.scope)
        try ledger.register(managedTask: binding)
        try ledger.save(to: previous.appendingPathComponent("ledger.json"))
        try JSONEncoder().encode(ProcessIdentity(pid: 99_999, startSeconds: 1, startMicroseconds: 0))
            .write(to: previous.appendingPathComponent("owner.json"))
        return (runs, previous)
    }

    @Test func scopeReleaseKeepsLedgerUntilExactStopReceiptIsDurable() async throws {
        let fixture = try await TaskFixture.make()
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true, durableLedger: true)
        defer { context.cleanup(); fixture.clean() }
        do {
            try await context.supervisor.createSession(ManagedSession(id: fixture.childID, provider: .codex,
                                                                       workingDirectory: context.home.path))
            let scope = try await context.supervisor.openScope()
            let binding = ManagedTaskScopeBinding(taskID: fixture.taskID, sessionID: fixture.childID,
                runID: fixture.child.managedRunID, generation: fixture.child.generation,
                ownerRunID: context.supervisor.ownershipRunID, scope: scope.record)
            await context.supervisor.setManagedScopeReceiptWriter { _ in throw SessionTaskError.storage }
            try await context.supervisor.registerManagedScope(binding, scope: scope)
            try await fixture.coordinator.prepareManagedScope(binding)
            let ledgerURL = context.root.appendingPathComponent("ledger.json")
            #expect(try OwnershipLedger.load(from: ledgerURL).managedTaskScopes?.contains(binding) == true)
            #expect(!(await context.supervisor.releaseScope(scope)).isEmpty)
            #expect(try OwnershipLedger.load(from: ledgerURL).managedTaskScopes?.contains(binding) == true)
            let beforeRetry = try await fixture.coordinator.managedScopeStopped(binding)
            #expect(!beforeRetry)
            await context.supervisor.setManagedScopeReceiptWriter { record in
                try await fixture.coordinator.recordManagedScopeStopped(record)
            }
            #expect((await context.supervisor.releaseScope(scope)).isEmpty)
            #expect(try await fixture.coordinator.managedScopeStopped(binding))
            #expect(try OwnershipLedger.load(from: ledgerURL).managedTaskScopes?.isEmpty == true)
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func recoveryRecordsTheExactStoppedRunBeforeRemovingItsLedger() async throws {
        let fixture = try await TaskFixture.make(recoveryLayout: true)
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup(); fixture.clean() }
        do {
            let scope = try await context.supervisor.openScope()
            let owner = UUID()
            let binding = ManagedTaskScopeBinding(taskID: fixture.taskID, sessionID: fixture.childID,
                runID: fixture.child.managedRunID, generation: fixture.child.generation, ownerRunID: owner, scope: scope.record)
            _ = try await fixture.input("persisted work")
            _ = try await fixture.coordinator.deliverPending(taskID: fixture.taskID)
            try await fixture.coordinator.prepareManagedScope(binding)
            let (runs, previous) = try previousLedger(root: fixture.root, binding: binding)
            let resumed = try await SessionTaskCoordinator.open(url: fixture.url, host: SessionTaskRuntimeHost(runtime: context.runtime))
            await context.runtime.installRecoveredTaskCoordinatorForTest(resumed)
            await #expect(throws: SessionTaskError.unverified) {
                try await context.runtime.forgetRecoveredParentForTest(fixture.parent.sessionID)
            }
            #expect(try await resumed.projectionForUser(taskID: fixture.taskID) != nil)
            let null = open("/dev/null", O_RDWR | O_CLOEXEC)
            try #require(null >= 0)
            defer { close(null) }
            let child = try await scope.spawn(executable: "/bin/sleep", arguments: ["30"], environment: ["PATH": "/usr/bin:/bin"],
                                              directory: fixture.root.path, stdio: .descriptors(input: null, output: null, error: null))
            defer {
                if let member = RunScopeTable.lineage(pid: child), member.identity.pid == child {
                    try? RunScopeTable.signal(member, coalitionID: scope.coalitionID, SIGKILL)
                }
            }
            // Simulate only this test's owned run-host crashing; the scope signal
            // rechecks its process identity and coalition before sending.
            try RunScopeTable.signal(scope.host, coalitionID: scope.coalitionID, SIGKILL)
            let report = await PreviousRunRecovery.recover(runsDirectory: runs, current: nil, scopeTimeout: 5)
            #expect(report.leftovers.isEmpty)
            #expect(report.stoppedProcesses >= 1)
            #expect(!FileManager.default.fileExists(atPath: previous.path))
            #expect(try await fixture.coordinator.managedScopeStopped(binding))
            let other = ManagedTaskScopeBinding(taskID: binding.taskID, sessionID: binding.sessionID,
                runID: UUID(), generation: binding.generation, ownerRunID: owner, scope: binding.scope)
            let wrongRunStopped = try await fixture.coordinator.managedScopeStopped(other)
            #expect(!wrongRunStopped)
            try await context.runtime.forgetRecoveredParentForTest(fixture.parent.sessionID)
            #expect(try await resumed.projectionForUser(taskID: fixture.taskID) == nil)
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func recoveryRetainsTheLedgerWhenTaskProofCannotBeStored() async throws {
        let fixture = try await TaskFixture.make(recoveryLayout: true)
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup(); fixture.clean() }
        do {
            let scope = try await context.supervisor.openScope()
            let owner = UUID()
            let binding = ManagedTaskScopeBinding(taskID: fixture.taskID, sessionID: fixture.childID,
                runID: fixture.child.managedRunID, generation: fixture.child.generation, ownerRunID: owner, scope: scope.record)
            try await fixture.coordinator.prepareManagedScope(binding)
            let (runs, previous) = try previousLedger(root: fixture.root, binding: binding)
            scope.dropConnectionForTesting()
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.url.path) }
            let report = await PreviousRunRecovery.recover(runsDirectory: runs, current: nil, scopeTimeout: 5)
            #expect(!report.leftovers.isEmpty)
            #expect(FileManager.default.fileExists(atPath: previous.path))
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
