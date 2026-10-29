import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore

private extension ProcessSupervisor {
    func markerReadsForScopePrivacy(runID: UUID, snapshot: [ProcessRecord]) throws -> Set<pid_t> {
        markerInspected.removeAll()
        let reads = Mutex<Set<pid_t>>([])
        _ = try sample(runID: runID, snapshot: snapshot, markerReader: { pid in
            reads.withLock { $0.insert(pid) }
            return nil
        })
        return reads.withLock { $0 }
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct ProcessSupervisorScopePrivacyTests {
    @Test func aScopedRunReadsMarkersOnlyFromAlreadyVerifiedOwnedProcesses() async throws {
        let context = try await SessionRuntimeTests.makeContext(scoped: true)
        defer { context.cleanup() }
        let outsider = Process()
        outsider.executableURL = URL(fileURLWithPath: "/bin/sleep")
        outsider.arguments = ["60"]
        outsider.standardOutput = FileHandle.nullDevice
        outsider.standardError = FileHandle.nullDevice
        try outsider.run()
        defer {
            if outsider.isRunning { outsider.terminate() }
            outsider.waitUntilExit()
        }
        do {
            let launch = try await context.runtime.startConversation(provider: .claude, projectID: nil)
            let snapshot = try ProcessTable.snapshot()
            #expect(snapshot.contains { $0.identity.pid == outsider.processIdentifier })
            let reads = try await context.supervisor.markerReadsForScopePrivacy(runID: launch.runID, snapshot: snapshot)
            let ownedSession = try #require(await context.supervisor.session(id: launch.sessionID))
            let leader = try #require(ownedSession.currentRun?.leader)
            #expect(reads.contains(leader.pid))
            let inspectedOutsider = reads.contains(outsider.processIdentifier)
            #expect(!inspectedOutsider, "an unrelated live process must not have its environment inspected")
            let members = try await context.supervisor.liveScopeMembers()
            let owned = Set(members.map(\.identity.pid))
            let foreignReads = reads.subtracting(owned).count
            #expect(foreignReads == 0, "filter by the verified kernel scope before any marker lookup")
        } catch {
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
