import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// How long launch-time recovery waits on a scope that does not empty (S3). A live run host is such a scope: it is a
/// launchd-spawned member, so recovery never signals it and waits for it until the scope's timeout.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2))) // serialized: wall-clock bounds on the drains and one busy run host each
struct PreviousRunRecoveryWaitTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("loom-recovery-wait-\(UUID().uuidString.prefix(8))", isDirectory: true)

    private func busyScope() async throws -> RunScope {
        let bundle = try SharedRunHost.bundle(for: Products.executable("loom-run-host"))
        return try await RunScopeLauncher(hostBundle: bundle, socketDirectory: root.appendingPathComponent("s")).launch()
    }

    /// A runs directory holding one previous run, gone, whose ledger names `scope` (bound to a task when `bound`).
    private func runs(_ name: String, scope: RunScope, bound: Bool = false) throws -> (runs: URL, previous: URL) {
        let runs = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("runs", isDirectory: true)
        let previous = runs.appendingPathComponent("previous", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        var ledger = OwnershipLedger()
        ledger.register(scope: scope.record)
        if bound {
            try ledger.register(managedTask: ManagedTaskScopeBinding(
                taskID: UUID(), sessionID: UUID(), runID: UUID(), generation: UUID(),
                ownerRunID: ledger.runID, scope: scope.record))
        }
        try ledger.save(to: previous.appendingPathComponent("ledger.json"))
        try JSONEncoder().encode(ProcessIdentity(pid: 99_999, startSeconds: 1, startMicroseconds: 0))
            .write(to: previous.appendingPathComponent("owner.json"))
        return (runs, previous)
    }

    /// The drain sleeps and polls on a thread of its own: more recoveries of a busy scope than the cooperative pool has
    /// threads wait side by side, not in waves.
    @Test func recoveriesOfABusyScopeWaitTogetherOffTheCooperativePool() async throws {
        let scope = try await busyScope()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let directories = try (0..<count).map { try runs("r\($0)", scope: scope).runs }
        var leftovers: [Int] = []
        let elapsed = await ContinuousClock().measure {
            leftovers = await withTaskGroup(of: Int.self) { group in
                for runs in directories {
                    group.addTask { await PreviousRunRecovery.recover(runsDirectory: runs, current: nil, scopeTimeout: 2).leftovers.count }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }
        #expect(leftovers == Array(repeating: 1, count: count), "each recovery reports the scope that stayed busy")
        #expect(elapsed < .seconds(3), "\(count) recoveries of a busy scope (2 s each) took \(elapsed): they queued for pool threads")
        #expect(await scope.release(timeout: 5).isEmpty)
    }

    /// A scope the previous launch in this boot already waited on in full, and kept, gets a short look at the next
    /// launch: still reported, but no second full wait. A scope bound to a task still gets the full wait, since its
    /// stop receipt depends on it.
    @Test func aScopeAlreadyWaitedOnInThisBootIsCheckedBrieflyUnlessATaskIsBoundToIt() async throws {
        let scope = try await busyScope()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = try runs("plain", scope: scope)
        let first = await PreviousRunRecovery.recover(runsDirectory: plain.runs, current: nil, scopeTimeout: 1)
        #expect(first.leftovers.count == 1 && first.brieflyCheckedScopes == 0)
        #expect(FileManager.default.fileExists(atPath: plain.previous.appendingPathComponent("recovery-error.txt").path))

        var second = PreviousRunRecovery.Report()
        let brief = await ContinuousClock().measure {
            second = await PreviousRunRecovery.recover(runsDirectory: plain.runs, current: nil, scopeTimeout: 10)
        }
        #expect(second.leftovers.count == 1, "the busy scope is still reported")
        #expect(second.brieflyCheckedScopes == 1)
        #expect(brief < .seconds(3), "the second look at a scope already waited on took \(brief)")
        #expect(FileManager.default.fileExists(atPath: plain.previous.path), "the directory stays for a later launch")

        let bound = try runs("bound", scope: scope, bound: true)
        _ = await PreviousRunRecovery.recover(runsDirectory: bound.runs, current: nil, scopeTimeout: 1)
        var again = PreviousRunRecovery.Report()
        let full = await ContinuousClock().measure {
            again = await PreviousRunRecovery.recover(runsDirectory: bound.runs, current: nil, scopeTimeout: 2)
        }
        #expect(again.brieflyCheckedScopes == 0)
        #expect(again.leftovers.contains { $0.contains("\(scope.coalitionID)") })
        #expect(full >= .seconds(1.8), "a scope bound to a task waits its full timeout again; took \(full)")
        #expect(await scope.release(timeout: 5).isEmpty)
    }
}
