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
            _ = try await fixture.input("scope fixture")
            try await fixture.coordinator.beginManagedLaunch(taskID: binding.taskID, childID: binding.sessionID,
                                                              runID: binding.runID, generation: binding.generation)
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
            try await fixture.coordinator.beginManagedLaunch(taskID: binding.taskID, childID: binding.sessionID,
                                                              runID: binding.runID, generation: binding.generation)
            try await fixture.coordinator.prepareManagedScope(binding)
            _ = try await fixture.coordinator.deliverPending(taskID: fixture.taskID)
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
            _ = try await fixture.input("scope fixture")
            try await fixture.coordinator.beginManagedLaunch(taskID: binding.taskID, childID: binding.sessionID,
                                                              runID: binding.runID, generation: binding.generation)
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

    @Test func restartCanForgetAChildWhoseScopeWasNeverOpened() async throws {
        let fixture = try await TaskFixture.make(recoveryLayout: true)
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup(); fixture.clean() }
        do {
            await fixture.host.setUnknown(true)
            _ = try await fixture.input("never opened")
            #expect(try await fixture.coordinator.deliverPending(taskID: fixture.taskID).delivery == .unknown)
            let reopened = try await SessionTaskCoordinator.open(url: fixture.url, host: SessionTaskRuntimeHost(runtime: context.runtime))
            await context.runtime.installRecoveredTaskCoordinatorForTest(reopened)
            try await context.runtime.forgetRecoveredParentForTest(fixture.parent.sessionID)
            #expect(try await reopened.projectionForUser(taskID: fixture.taskID) == nil)
        } catch { Issue.record("Never-opened restart cleanup failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func noEffectSettlementFencesLateLaunchAndDoesNotCoverAnOpeningScope() async throws {
        let unstarted = try await TaskFixture.make(), opening = try await TaskFixture.make()
        defer { unstarted.clean(); opening.clean() }
        _ = try await unstarted.input("no effect")
        let store = try SessionTaskStore(url: unstarted.url)
        try store.transaction {
            var task = try #require(try store.task(unstarted.taskID))
            task.lifecycle = .stopping
            try store.save(task)
        }
        #expect(try await unstarted.coordinator.settleUnstartedManagedLaunch(taskID: unstarted.taskID,
                                                                              childID: unstarted.childID))
        try store.transaction {
            var task = try #require(try store.task(unstarted.taskID))
            task.lifecycle = .active
            try store.save(task)
        }
        let reopened = try await SessionTaskCoordinator.open(url: unstarted.url, host: unstarted.host)
        #expect(try await reopened.managedChildStopped(taskID: unstarted.taskID, sessionID: unstarted.childID, binding: nil))
        await #expect(throws: SessionTaskError.self) {
            try await reopened.beginManagedLaunch(taskID: unstarted.taskID, childID: unstarted.childID,
                                                 runID: UUID(), generation: UUID())
        }
        _ = try await opening.input("opening")
        try await opening.coordinator.beginManagedLaunch(taskID: opening.taskID, childID: opening.childID,
                                                          runID: UUID(), generation: UUID())
        let openingStore = try SessionTaskStore(url: opening.url)
        try openingStore.transaction {
            var task = try #require(try openingStore.task(opening.taskID))
            task.lifecycle = .stopping
            try openingStore.save(task)
        }
        #expect(try await opening.coordinator.settleUnstartedManagedLaunch(taskID: opening.taskID, childID: opening.childID) == false)
        #expect(try await opening.coordinator.managedChildStopped(taskID: opening.taskID, sessionID: opening.childID, binding: nil) == false)
    }

    /// Moves `fixture`'s launch to `opening` under `owner`, as the coordinator of that app would while its first round's
    /// delivery is under way (so its outcome is unknown), and on to `scoped` when asked; the binding the launch would have.
    @discardableResult
    private func beginLaunch(_ fixture: TaskFixture, owner: ManagedLaunchOwner?, scoped: Bool = false) async throws
        -> ManagedTaskScopeBinding {
        await fixture.host.setUnknown(true)
        _ = try await fixture.input("opening under \(owner == nil ? "no owner" : "an owner")")
        #expect(try await fixture.coordinator.deliverPending(taskID: fixture.taskID).delivery == .unknown)
        let binding = ManagedTaskScopeBinding(taskID: fixture.taskID, sessionID: fixture.childID,
            runID: fixture.child.managedRunID, generation: fixture.child.generation, ownerRunID: UUID(),
            scope: RunScopeRecord(coalitionID: 1, bootSessionID: "fixture", hostPID: 99_998, hostIDVersion: 1))
        let store = try SessionTaskStore(url: fixture.url)
        try store.transaction {
            try store.beginManagedLaunch(taskID: binding.taskID, childID: binding.sessionID, runID: binding.runID,
                                         generation: binding.generation, owner: owner)
            if scoped { try store.prepareManagedScope(binding) }
        }
        return binding
    }

    /// The crash window between `opening` and the first record that ties a scope to the task: a launch that a gone
    /// app left `opening` never sent its provider SPAWN, so the next open settles it as not admitted and its task can
    /// be forgotten. What is not known of a scope host it may have started goes to the diagnostic journal. Before, the
    /// task could never be shown stopped and was never forgotten.
    @Test func aLaunchAGoneAppLeftOpeningIsNotAdmittedAndItsTaskCanBeForgotten() async throws {
        let fixture = try await TaskFixture.make(recoveryLayout: true)
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup(); fixture.clean() }
        do {
            let boot = try #require(ProcessTable.bootSessionID())
            let gone = ManagedLaunchOwner(process: ProcessIdentity(pid: 99_999, startSeconds: 1, startMicroseconds: 0),
                                          boot: boot)
            try await beginLaunch(fixture, owner: gone)
            #expect(try await fixture.coordinator.managedChildStopped(taskID: fixture.taskID, sessionID: fixture.childID,
                                                                      binding: nil) == false)
            let reopened = try await SessionTaskCoordinator.open(url: fixture.url, host: SessionTaskRuntimeHost(runtime: context.runtime))
            #expect(try await reopened.managedChildStopped(taskID: fixture.taskID, sessionID: fixture.childID, binding: nil))
            let journal = DiagnosticJournal.forDataRoot(fixture.root).lines().filter { $0.contains("\"taskLaunchRecovery\"") }
            #expect(journal.count == 1 && journal[0].contains("\"cleanupUnverified\":1") && journal[0].contains("\"notAdmitted\":1"),
                    "\(journal)")
            // A not-admitted launch is never begun again.
            await #expect(throws: SessionTaskError.self) {
                try await reopened.beginManagedLaunch(taskID: fixture.taskID, childID: fixture.childID,
                                                      runID: UUID(), generation: UUID())
            }
            await context.runtime.installRecoveredTaskCoordinatorForTest(reopened)
            try await context.runtime.forgetRecoveredParentForTest(fixture.parent.sessionID)
            #expect(try await reopened.projectionForUser(taskID: fixture.taskID) == nil)
        } catch { Issue.record("Not-admitted restart cleanup failed: \(error)") }
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// Only a launch whose owner is provably gone and that never reached `scoped` is settled: an owner that still runs
    /// (this process), a record of an older build (no owner, no rule) and a launch past `scoped` stay as they were. An
    /// owner of an earlier boot is gone even with a matching process identity.
    @Test func onlyAnOpeningOfAGoneOwnerUnderTheAdmissionRuleIsSettled() async throws {
        let live = try await TaskFixture.make(), legacy = try await TaskFixture.make()
        let scoped = try await TaskFixture.make(), rebooted = try await TaskFixture.make()
        defer { live.clean(); legacy.clean(); scoped.clean(); rebooted.clean() }
        let current = try #require(ManagedLaunchOwner.current())
        let gone = ManagedLaunchOwner(process: ProcessIdentity(pid: 99_999, startSeconds: 1, startMicroseconds: 0),
                                      boot: current.boot)
        try await beginLaunch(live, owner: current)
        try await beginLaunch(legacy, owner: nil)
        try await beginLaunch(scoped, owner: gone, scoped: true)
        try await beginLaunch(rebooted, owner: ManagedLaunchOwner(process: current.process, boot: "an-earlier-boot"))
        for (fixture, settled) in [(live, false), (legacy, false), (scoped, false), (rebooted, true)] {
            let reopened = try await SessionTaskCoordinator.open(url: fixture.url, host: fixture.host)
            #expect(try await reopened.managedChildStopped(taskID: fixture.taskID, sessionID: fixture.childID,
                                                           binding: nil) == settled)
        }
    }

    /// The runtime's own failure before `scoped` settles its launch as not admitted at once; past `scoped` the store
    /// refuses, so the runtime may ask after any failure.
    @Test func aLiveLaunchThatFailedBeforeScopedIsNotAdmittedAndOnePastItIsNot() async throws {
        let failed = try await TaskFixture.make(), admitted = try await TaskFixture.make()
        defer { failed.clean(); admitted.clean() }
        _ = try await failed.input("fails before its scope is tied to it")
        try await failed.coordinator.beginManagedLaunch(taskID: failed.taskID, childID: failed.childID,
                                                        runID: failed.child.managedRunID, generation: failed.child.generation)
        await #expect(throws: SessionTaskError.self) {
            try await failed.coordinator.confirmManagedLaunchNotAdmitted(taskID: failed.taskID, childID: failed.childID,
                                                                         runID: UUID(), generation: failed.child.generation)
        }
        try await failed.coordinator.confirmManagedLaunchNotAdmitted(taskID: failed.taskID, childID: failed.childID,
                                                                     runID: failed.child.managedRunID,
                                                                     generation: failed.child.generation)
        #expect(try await failed.coordinator.managedChildStopped(taskID: failed.taskID, sessionID: failed.childID, binding: nil))

        let binding = try await beginLaunch(admitted, owner: ManagedLaunchOwner.current(), scoped: true)
        await #expect(throws: SessionTaskError.self) {
            try await admitted.coordinator.confirmManagedLaunchNotAdmitted(taskID: binding.taskID, childID: binding.sessionID,
                                                                           runID: binding.runID, generation: binding.generation)
        }
        #expect(try await admitted.coordinator.managedChildStopped(taskID: admitted.taskID, sessionID: admitted.childID,
                                                                   binding: nil) == false)
    }

    @Test(arguments: [true, false])
    func interruptedStopUsesRecoveredProofWithoutTouchingASuccessor(receiptFirst: Bool) async throws {
        let fixture = try await TaskFixture.make(recoveryLayout: true)
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup(); fixture.clean() }
        var pendingStop: Task<SessionTaskReceipt, Error>?
        do {
            let scope = try await context.supervisor.openScope(), owner = UUID()
            let binding = ManagedTaskScopeBinding(taskID: fixture.taskID, sessionID: fixture.childID,
                runID: fixture.child.managedRunID, generation: fixture.child.generation, ownerRunID: owner, scope: scope.record)
            _ = try await fixture.input("work before interrupted stop")
            try await fixture.coordinator.beginManagedLaunch(taskID: binding.taskID, childID: binding.sessionID,
                                                              runID: binding.runID, generation: binding.generation)
            try await fixture.coordinator.prepareManagedScope(binding)
            _ = try await fixture.coordinator.deliverPending(taskID: fixture.taskID)
            let (runs, previous) = try previousLedger(root: fixture.root, binding: binding)
            await fixture.host.holdStop()
            let stopID = UUID()
            let stop = Task { try await fixture.coordinator.stopChild(taskID: fixture.taskID, parent: fixture.parent, operationID: stopID) }
            pendingStop = stop
            try #require(await SessionRuntimeTests.waitUntil(3) { await fixture.host.hasEnteredStop() })
            #expect(try await fixture.coordinator.projectionForUser(taskID: fixture.taskID)?.lifecycle == .stopping)
            await #expect(throws: SessionTaskError.unverified) {
                _ = try await fixture.coordinator.stopChild(taskID: fixture.taskID, parent: fixture.parent, operationID: UUID())
            }
            let reopened = try await SessionTaskCoordinator.open(url: fixture.url, host: SessionTaskRuntimeHost(runtime: context.runtime))
            await context.runtime.installRecoveredTaskCoordinatorForTest(reopened)
            try await context.supervisor.createSession(ManagedSession(id: fixture.childID, provider: .codex,
                                                                       workingDirectory: fixture.root.path))
            let successorID = UUID()
            let environment = LaunchEnvironment.make(base: ["PATH": "/usr/bin:/bin"],
                runID: context.supervisor.ownershipRunID, sessionID: fixture.childID)
            _ = try await context.supervisor.launch(sessionID: fixture.childID, executable: "/bin/sleep", arguments: ["30"],
                                                     environment: environment, managedRunID: successorID)
            if !receiptFirst {
                await #expect(throws: SessionTaskError.unverified) {
                    try await context.runtime.forgetRecoveredParentForTest(fixture.parent.sessionID)
                }
                #expect(try await reopened.projectionForUser(taskID: fixture.taskID)?.lifecycle == .stopUnverified)
                #expect(await context.supervisor.session(id: fixture.childID)?.currentRun?.id == successorID)
            }
            let beforeRecovery = try SessionTaskStore(url: fixture.url)
            #expect(try beforeRecovery.operation(stopID)?.receipt.delivery == .unknown)
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
            try RunScopeTable.signal(scope.host, coalitionID: scope.coalitionID, SIGKILL)
            let report = await PreviousRunRecovery.recover(runsDirectory: runs, current: nil, scopeTimeout: 5)
            #expect(report.leftovers.isEmpty && !FileManager.default.fileExists(atPath: previous.path))
            #expect(try await reopened.managedScopeStopped(binding))
            try await context.runtime.forgetRecoveredParentForTest(fixture.parent.sessionID)
            #expect(try await reopened.projectionForUser(taskID: fixture.taskID) == nil)
            #expect(await context.supervisor.session(id: fixture.childID)?.currentRun?.id == successorID)
            await fixture.host.releaseStop()
            _ = try? await stop.value
            pendingStop = nil
            #expect(try await context.supervisor.stop(sessionID: fixture.childID).succeeded)
        } catch {
            await fixture.host.releaseStop()
            _ = try? await pendingStop?.value
            Issue.record("Interrupted stop recovery fixture failed: \(error)")
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
