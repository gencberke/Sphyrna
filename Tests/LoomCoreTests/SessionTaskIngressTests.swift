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
