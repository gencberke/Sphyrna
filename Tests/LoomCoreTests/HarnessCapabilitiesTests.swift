import Foundation
import Testing
@testable import LoomCore

/// R3: what each harness may do per build identity. Both current identities can start Claude and Codex.
/// Nothing here starts a run. D-94: the table is the one gate (the guard at the end).
struct HarnessCapabilitiesTests {
    private static let production: Set<ManagedSession.Provider> = [.claude, .codex]
    private static let development: Set<ManagedSession.Provider> = [.claude, .codex]
    private static let claudeOnly: Set<ManagedSession.Provider> = [.claude]

    /// Claude's row, with `startable` as the build says.
    private static func claude(startable: Bool) -> HarnessCapabilities {
        HarnessCapabilities(
            hasHarness: true, startable: startable, structuredFace: true, readsTranscript: true, sideChats: true,
            readsContext: true, readsEdits: true, subagents: true, rewind: true, quickQuestion: true, deletes: true,
            usageLimits: true, modelCatalog: true, reportsRunSettings: true, displayName: "Claude")
    }

    /// Codex's bounded transcript, context and edit reads do not enable Chat, subagents or deletion.
    private static func codex(startable: Bool) -> HarnessCapabilities {
        HarnessCapabilities(
            hasHarness: true, startable: startable, structuredFace: false, readsTranscript: true, sideChats: false,
            readsContext: true, readsEdits: true, subagents: false, rewind: false, quickQuestion: false, deletes: false,
            usageLimits: true, modelCatalog: true, reportsRunSettings: false, displayName: "Codex")
    }

    @Test func claudeHasEverythingAndIsStartableWhereTheBuildSaysSo() {
        #expect(HarnessCapabilities.of(.claude, startable: Self.production) == Self.claude(startable: true))
        #expect(HarnessCapabilities.of(.claude, startable: Self.development) == Self.claude(startable: true))
        // A build that cannot start Claude keeps the rest: the sessions are listed and read, not started or resumed.
        #expect(HarnessCapabilities.of(.claude, startable: [.codex]) == Self.claude(startable: false))
    }

    @Test func codexIsStartableOnlyWhereTheBuildSaysSoAndReadsRecordedData() {
        #expect(HarnessCapabilities.of(.codex, startable: Self.production) == Self.codex(startable: true))
        #expect(HarnessCapabilities.of(.codex, startable: Self.development) == Self.codex(startable: true))
        #expect(HarnessCapabilities.of(.codex, startable: Self.claudeOnly) == Self.codex(startable: false))
    }

    @Test func aSyntheticSessionHasNothingInAnyBuild() {
        let nothing = HarnessCapabilities(
            hasHarness: false, startable: false, structuredFace: false, readsTranscript: false, sideChats: false,
            readsContext: false, readsEdits: false, subagents: false, rewind: false, quickQuestion: false, deletes: false,
            usageLimits: false, modelCatalog: false, reportsRunSettings: false, displayName: "Synthetic")
        #expect(HarnessCapabilities.of(.synthetic, startable: Self.production) == nothing)
        #expect(HarnessCapabilities.of(.synthetic, startable: Self.development) == nothing)
        #expect(HarnessCapabilities.of(.synthetic, startable: [.synthetic]) == nothing)
    }

    @Test func theIntrinsicAnswerIsTheTableWithNothingStartable() {
        #expect(HarnessCapabilities.intrinsic(of: .claude) == Self.claude(startable: false))
        #expect(HarnessCapabilities.intrinsic(of: .codex) == Self.codex(startable: false))
        #expect(SessionHarness.claude.capabilities == HarnessCapabilities.intrinsic(of: .claude))
        #expect(SessionHarness.codex.capabilities == HarnessCapabilities.intrinsic(of: .codex))
    }

    @Test func aPlainNewSessionStartsClaude() {
        #expect(ManagedSession.Provider.newSessionDefault == .claude)
    }
}
