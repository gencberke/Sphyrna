import Darwin
import Foundation
import Testing
@testable import LoomCore

private final class OwnershipTestBundleAnchor: NSObject {}

@Suite(.serialized)
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

    @Test func forcedCapabilityFailureReportsNarrowerGuaranteeAndLedgerRoundTrips() async throws {
        let capability = CoalitionCapability.probe(forceFailure: true)
        #expect(capability.resourceID == nil)
        let ledger = OwnershipLedger(coalition: capability)
        let decoded = try JSONDecoder().decode(OwnershipLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded.coalition?.detail == capability.detail)
        let supervisor = try ProcessSupervisor(ledger: decoded)
        let report = await supervisor.shutdown()
        #expect(report.succeeded)
        #expect(report.ownershipGuarantee.contains("Narrowed"))
    }

    @Test func legacyLedgerRemainsRecoverable() async throws {
        let data = Data("{\"runID\":\"\(UUID())\",\"descendants\":[],\"sessionLeaders\":[]}".utf8)
        let ledger = try JSONDecoder().decode(OwnershipLedger.self, from: data)
        #expect(ledger.coalition == nil)
        let supervisor = try ProcessSupervisor(ledger: ledger)
        #expect(await supervisor.shutdown().ownershipGuarantee.contains("legacy"))
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

    @Test func metadataIsReadOncePerLiveIdentityAndPrunedAfterExit() throws {
        let original = ProcessIdentity(pid: 2_000_040, startSeconds: 1, startMicroseconds: 0)
        let replacement = ProcessIdentity(pid: original.pid, startSeconds: 2, startMicroseconds: 0)
        func record(_ identity: ProcessIdentity) -> ProcessRecord {
            ProcessRecord(identity: identity, parentPID: 1, processGroup: identity.pid,
                          sessionID: identity.pid, userID: getuid(), zombie: false)
        }
        var ledger = OwnershipLedger(coalition: CoalitionCapability(resourceID: 42, detail: "test"))
        let unchanged = ledger
        var runReads = 0
        var coalitionReads = 0
        func observe(_ records: [ProcessRecord]) -> [ProcessRecord] {
            ledger.observe(records, readRunID: { _ in runReads += 1; return nil },
                           readCoalition: { _ in coalitionReads += 1; return 99 },
                           confirmSnapshot: { records })
        }
        #expect(observe([record(original)]).isEmpty)
        #expect(observe([record(original)]).isEmpty)
        #expect(runReads == 1)
        #expect(coalitionReads == 1)
        // Unrelated metadata changes neither persisted state nor its equality.
        #expect(ledger == unchanged)
        let encoded = try JSONEncoder().encode(ledger)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("metadataCache"))
        var recovered = try JSONDecoder().decode(OwnershipLedger.self, from: encoded)
        _ = recovered.observe([record(original)], readRunID: { _ in runReads += 1; return nil },
                              readCoalition: { _ in coalitionReads += 1; return 99 },
                              confirmSnapshot: { [record(original)] })
        #expect(runReads == 2)
        #expect(coalitionReads == 2)

        #expect(observe([record(replacement)]).isEmpty)
        #expect(runReads == 3)
        #expect(coalitionReads == 3)
        #expect(observe([]).isEmpty)
        // Reintroducing an identity in this synthetic snapshot proves its cache was evicted.
        #expect(observe([record(replacement)]).isEmpty)
        #expect(runReads == 4)
        #expect(coalitionReads == 4)
    }

    @Test func cachedMetadataStillRequiresIdentityConfirmationBeforeClaimingProcess() {
        let identity = ProcessIdentity(pid: 2_000_050, startSeconds: 1, startMicroseconds: 0)
        let record = ProcessRecord(identity: identity, parentPID: 1, processGroup: identity.pid,
                                   sessionID: identity.pid, userID: getuid(), zombie: false)
        var ledger = OwnershipLedger(coalition: .probe(forceFailure: true))
        let marker = ledger.runID.uuidString
        var reads = 0
        #expect(ledger.observe([record], readRunID: { _ in reads += 1; return marker },
                               readCoalition: { _ in nil }, confirmSnapshot: { nil }).isEmpty)
        #expect(ledger.observationIssue != nil)
        #expect(ledger.observe([record], readRunID: { _ in reads += 1; return marker },
                               readCoalition: { _ in nil }, confirmSnapshot: { [record] }) == [record])
        #expect(reads == 1)
        #expect(ledger.observationIssue == nil)
    }

    @Test func thousandsOfShortLivedDescendantsDoNotGrowDurableLedger() throws {
        let leader = ProcessIdentity(
            pid: 2_100_000, startSeconds: 1, startMicroseconds: 0
        )
        func record(_ identity: ProcessIdentity, parent: Int32) -> ProcessRecord {
            ProcessRecord(
                identity: identity, parentPID: parent,
                processGroup: leader.pid, sessionID: leader.pid,
                userID: getuid(), zombie: false
            )
        }
        let leaderRecord = record(leader, parent: 1)
        var ledger = OwnershipLedger(coalition: .probe(forceFailure: true))
        ledger.register(leader)
        for index in 0..<5_000 {
            let child = ProcessIdentity(
                pid: Int32(2_100_001 + index),
                startSeconds: Int64(index + 2), startMicroseconds: 0
            )
            _ = ledger.observe(
                [leaderRecord, record(child, parent: leader.pid)],
                readRunID: { _ in nil }, readCoalition: { _ in nil },
                confirmSnapshot: { [leaderRecord, record(child, parent: leader.pid)] }
            )
            #expect(ledger.descendants.count <= 2)
        }
        _ = ledger.observe(
            [leaderRecord], readRunID: { _ in nil },
            readCoalition: { _ in nil }, confirmSnapshot: { [leaderRecord] }
        )
        #expect(ledger.descendants == [leader])
        #expect(try JSONEncoder().encode(ledger).count < 1_024)
    }

}
