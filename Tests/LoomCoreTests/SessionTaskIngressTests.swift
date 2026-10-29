import Foundation
import Testing
@testable import LoomCore

@Suite(.serialized)
struct SessionTaskIngressTests {
    @Test func claudeHookIngressFencesAdmissionUntilConsumptionAndOverflowStaysClosed() async throws {
        let supervisor = try ProcessSupervisor()
        let adapter = ClaudeSessionAdapter(supervisor: supervisor)
        let registry = SessionTaskIngressRegistry()
        let run = UUID(), lease = SessionTaskRunLease()
        registry.register(runID: run, lease: lease)
        let ingress = ClaudeHookIngress(adapter: adapter, capacity: 1, taskIngress: registry)
        let envelope = ClaudeHookEnvelope(sessionID: UUID(), managedRunID: run, payload: Data())
        ingress.receive(envelope)
        #expect(lease.permits { true } == nil)
        var iterator = ingress.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        registry.finish(runID: run)
        #expect(lease.permits { true } == true)
        ingress.receive(envelope)
        ingress.receive(envelope)
        #expect(await iterator.next() != nil)
        registry.finish(runID: run)
        #expect(lease.permits { true } == nil)
    }

    @Test func consumedIngressInvalidatesAnEarlierAdmission() throws {
        let lease = SessionTaskRunLease()
        let admission = try #require(lease.admit { $0 })
        #expect(lease.permits(revision: admission))
        lease.beginHook()
        lease.finishHook()
        #expect(!lease.permits(revision: admission))
        let renewed = try #require(lease.admit { $0 })
        #expect(lease.permits(revision: renewed))
        lease.beginCodexEvent(42)
        lease.finishCodexEvent(42)
        #expect(!lease.permits(revision: renewed))
    }

    @Test func codexFenceMatchesSequenceAndNeverReopensAfterLoss() {
        let lease = SessionTaskRunLease()
        lease.beginCodexEvent(42)
        #expect(lease.permits { true } == nil)
        lease.finishCodexEvent(41)
        #expect(lease.permits { true } == nil)
        lease.finishCodexEvent(42)
        #expect(lease.permits { true } == true)
        lease.invalidate()
        #expect(lease.permits { true } == nil)
    }
}
