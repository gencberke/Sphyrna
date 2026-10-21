import Testing
@testable import LoomCore

/// R3: what each harness may do per build identity. The production identity starts Claude only (D-28, D-69 (5)); the
/// development one starts Claude and Codex. Nothing here starts a run.
struct HarnessCapabilitiesTests {
    private static let production: Set<ManagedSession.Provider> = [.claude]
    private static let development: Set<ManagedSession.Provider> = [.claude, .codex]

    @Test func claudeHasEverythingAndIsStartableWhereTheBuildSaysSo() {
        let full = HarnessCapabilities(hasHarness: true, startable: true, structuredFace: true, readsTranscript: true, sideChats: true)
        #expect(HarnessCapabilities.of(.claude, startable: Self.production) == full)
        #expect(HarnessCapabilities.of(.claude, startable: Self.development) == full)
        // A build that cannot start Claude keeps the rest: the sessions are listed and read, not started or resumed.
        #expect(HarnessCapabilities.of(.claude, startable: [.codex]) == HarnessCapabilities(
            hasHarness: true, startable: false, structuredFace: true, readsTranscript: true, sideChats: true))
    }

    @Test func codexIsStartableOnlyWhereTheBuildSaysSoAndHasNothingElse() {
        #expect(HarnessCapabilities.of(.codex, startable: Self.production) == HarnessCapabilities(
            hasHarness: true, startable: false, structuredFace: false, readsTranscript: false, sideChats: false))
        #expect(HarnessCapabilities.of(.codex, startable: Self.development) == HarnessCapabilities(
            hasHarness: true, startable: true, structuredFace: false, readsTranscript: false, sideChats: false))
    }

    @Test func aSyntheticSessionHasNothingInAnyBuild() {
        let nothing = HarnessCapabilities(hasHarness: false, startable: false, structuredFace: false, readsTranscript: false, sideChats: false)
        #expect(HarnessCapabilities.of(.synthetic, startable: Self.production) == nothing)
        #expect(HarnessCapabilities.of(.synthetic, startable: Self.development) == nothing)
        #expect(HarnessCapabilities.of(.synthetic, startable: [.synthetic]) == nothing)
    }
}
