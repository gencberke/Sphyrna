import Foundation
import Testing
@testable import LoomCore

/// R7: the runtime asks a harness where the provider matters. The table below is what each site reads, so a harness that
/// returns another answer changes the runtime's behaviour and this test says so.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HarnessRegistryTests {
    private func registry() throws -> HarnessRegistry {
        HarnessRegistry(supervisor: try ProcessSupervisor(ledger: OwnershipLedger()), hookSilenceGrace: 1)
    }

    @Test func theRegistryHoldsClaudeAndCodexAndNothingForASyntheticSession() throws {
        let harnesses = try registry()
        #expect(harnesses.providers == [.claude, .codex])
        #expect(harnesses[.claude]?.provider == .claude)
        #expect(harnesses[.codex]?.provider == .codex)
        #expect(harnesses[.synthetic] == nil)
        #expect(harnesses[.claude]?.taskTransport == .terminalHook)
        #expect(harnesses[.codex]?.taskTransport == .ownedAppServer)
        #expect(harnesses[.synthetic]?.taskTransport == nil)
    }

    @Test func eachHarnessAnswersTheRulesTheRuntimeAsksOfIt() throws {
        let harnesses = try registry()
        // Both supported terminal harnesses take openings and drafts; only Claude data can be removed from Loom.
        #expect(harnesses.claude.takesOpeningOrDraft)
        #expect(harnesses.claude.deletionRefusal == nil)
        #expect(harnesses.codex.takesOpeningOrDraft)
        #expect(harnesses.codex.deletionRefusal == "Codex sessions cannot be deleted from Sphyrna yet")
    }

    @Test func sideChatsAreClaudesAlone() {
        #expect(HarnessCapabilities.of(.claude, startable: []).sideChats)
        #expect(!HarnessCapabilities.of(.codex, startable: []).sideChats)
        #expect(!HarnessCapabilities.of(.synthetic, startable: []).sideChats)
    }
}
