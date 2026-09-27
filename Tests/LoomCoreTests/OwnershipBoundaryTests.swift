import Darwin
import Foundation
import Testing
@testable import LoomCore

private final class OwnershipTestBundleAnchor: NSObject {}

@Suite(.serialized)
@MainActor
struct OwnershipBoundaryTests {
    @Test func foreignUIDDescendantsAreReportedAndNeverSelectedForSignals() throws {
        let leader = ProcessIdentity(pid: 2_000_001, startSeconds: 1, startMicroseconds: 0)
        let foreign = ProcessIdentity(pid: 2_000_002, startSeconds: 1, startMicroseconds: 0)
        let records = [
            ProcessRecord(identity: leader, parentPID: 1, processGroup: leader.pid, sessionID: leader.pid, userID: getuid(), zombie: false),
            ProcessRecord(identity: foreign, parentPID: leader.pid, processGroup: foreign.pid, sessionID: foreign.pid, userID: getuid() + 1, zombie: false),
        ]
        var ledger = OwnershipLedger(coalition: .probe(forceFailure: true))
        ledger.register(leader)
        #expect(ledger.observe(records).map(\.identity) == [leader])
        #expect(ledger.outsideOwnership?.map(\.identity) == [foreign])
        // Reparenting does not erase a previously observed foreign child.
        #expect(ledger.observe([records[1]]).isEmpty)
        #expect(ledger.outsideOwnership?.map(\.identity) == [foreign])
        let report = ShutdownReport(elapsedSeconds: 0, signals: [], remaining: [], errors: [],
                                    outsideOwnership: [records[1]], ownershipGuarantee: "test")
        #expect(!report.succeeded)
    }

    @Test func forcedCapabilityFailureReportsNarrowerGuaranteeAndLedgerRoundTrips() throws {
        let capability = CoalitionCapability.probe(forceFailure: true)
        #expect(capability.resourceID == nil)
        let ledger = OwnershipLedger(coalition: capability)
        let decoded = try JSONDecoder().decode(OwnershipLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded.coalition?.detail == capability.detail)
        let coordinator = try ShutdownCoordinator(ledger: decoded)
        let report = coordinator.shutdown()
        #expect(report.succeeded)
        #expect(report.ownershipGuarantee.contains("Narrowed"))
    }

    @Test func legacyLedgerRemainsRecoverable() throws {
        let data = Data("{\"runID\":\"\(UUID())\",\"descendants\":[],\"sessionLeaders\":[]}".utf8)
        let ledger = try JSONDecoder().decode(OwnershipLedger.self, from: data)
        #expect(ledger.coalition == nil)
        #expect(try ShutdownCoordinator(ledger: ledger).shutdown().ownershipGuarantee.contains("legacy"))
    }
    @Test func staleRecoveryFailureDoesNotBlockAnotherCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("runs/broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("invalid owner".utf8).write(to: broken.appendingPathComponent("owner.json"))
        let probe = Process()
        probe.executableURL = Bundle(for: OwnershipTestBundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("loom-probe")
        probe.arguments = ["synthetic", "inspect"]
        var environment = ProcessInfo.processInfo.environment
        environment["LOOM_PROBE_ROOT"] = root.path
        probe.environment = environment
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run(); probe.waitUntilExit()
        #expect(probe.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: broken.appendingPathComponent("recovery-error.txt").path))
        #expect(!FileManager.default.fileExists(atPath: broken.appendingPathComponent("recovered").path))
    }

    @Test func coalitionFromAnotherBootIsNotUsedForRecovery() throws {
        let capability = CoalitionCapability(resourceID: 42, detail: "old boot", bootSessionID: "old-boot")
        var ledger = OwnershipLedger(coalition: capability)
        #expect(ledger.observe([]).isEmpty)
        #expect(ledger.coalition?.resourceID == nil)
        #expect(ledger.coalition?.guarantee.contains("different boot") == true)
    }

    @Test func reusedMetadataPIDCannotClaimUnrelatedChildren() {
        let old = ProcessIdentity(pid: 2_000_010, startSeconds: 1, startMicroseconds: 0)
        let replacement = ProcessIdentity(pid: old.pid, startSeconds: 2, startMicroseconds: 0)
        let child = ProcessIdentity(pid: 2_000_011, startSeconds: 1, startMicroseconds: 0)
        func record(_ identity: ProcessIdentity, parent: Int32) -> ProcessRecord {
            ProcessRecord(identity: identity, parentPID: parent, processGroup: identity.pid, sessionID: identity.pid, userID: getuid(), zombie: false)
        }
        let unrelatedChild = record(child, parent: old.pid)
        var ledger = OwnershipLedger(coalition: .probe(forceFailure: true))
        let marker = ledger.runID.uuidString
        let result = ledger.observe([record(old, parent: 1), unrelatedChild],
            readRunID: { $0 == old.pid ? marker : nil }, readCoalition: { _ in nil },
            confirmSnapshot: { [record(replacement, parent: 1), unrelatedChild] })
        #expect(result.isEmpty)
        #expect(ledger.descendants.isEmpty)
    }

    @Test func liveCoalitionReadFailureNarrowsObservationGuarantee() {
        let identity = ProcessIdentity(pid: 2_000_020, startSeconds: 1, startMicroseconds: 0)
        let record = ProcessRecord(identity: identity, parentPID: 1, processGroup: identity.pid, sessionID: identity.pid, userID: getuid(), zombie: false)
        var ledger = OwnershipLedger(coalition: CoalitionCapability(resourceID: 42, detail: "test"))
        #expect(ledger.observe([record], readRunID: { _ in nil }, readCoalition: { _ in nil },
                               confirmSnapshot: { [record] }).isEmpty)
        #expect(ledger.observationIssue?.contains("cleanup is unverified") == true)
    }

    @Test func deadIdentitiesArePrunedAfterTheirUnixSessionEmpties() {
        let leader = ProcessIdentity(pid: 2_000_030, startSeconds: 1, startMicroseconds: 0)
        let child = ProcessIdentity(pid: 2_000_031, startSeconds: 1, startMicroseconds: 0)
        func record(_ identity: ProcessIdentity, parent: Int32) -> ProcessRecord {
            ProcessRecord(identity: identity, parentPID: parent, processGroup: leader.pid,
                          sessionID: leader.pid, userID: getuid(), zombie: false)
        }
        var ledger = OwnershipLedger(coalition: .probe(forceFailure: true))
        ledger.register(leader)
        _ = ledger.observe([record(leader, parent: 1), record(child, parent: leader.pid)])
        #expect(ledger.descendants == [leader, child])

        _ = ledger.observe([record(child, parent: 1)])
        #expect(ledger.descendants == [child])
        #expect(ledger.sessionLeaders == [leader])

        _ = ledger.observe([])
        #expect(ledger.descendants.isEmpty)
        #expect(ledger.sessionLeaders.isEmpty)
    }

}
