import Foundation
import Testing
@testable import LoomCore

@Suite(.timeLimit(.minutes(1)))
struct HarnessRecheckTests {
    private actor Source: HarnessProbeSource {
        var calls = 0
        private var releaseFirst: CheckedContinuation<Void, Never>?
        private var started: [CheckedContinuation<Void, Never>] = []

        func read() async -> HarnessProbeAnswer? {
            calls += 1
            let index = calls
            if index == 1 {
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                    started.forEach { $0.resume() }
                    started = []
                }
            }
            return HarnessProbeAnswer(account: index == 1 ? HarnessAccount.none : .apiKey, windows: [])
        }

        func waitForFirst() async {
            if calls > 0 { return }
            await withCheckedContinuation { started.append($0) }
        }
        func release() { releaseFirst?.resume(); releaseFirst = nil }
    }

    @Test(arguments: [true, false])
    func explicitRecheckWaitsForOldHealthOrUsageThenReadsFreshHealth(oldHealth: Bool) async throws {
        let source = Source()
        let connections = HarnessConnections()
        let probe = HarnessProbe(connections: connections, sources: [.claude: source])
        let checker = HarnessHealthChecker(connections: connections, probe: probe, toolchain: { _ in
            ProviderToolchain(provider: .claude, executable: "/fake/claude",
                              capabilities: ProviderCapabilities(version: "2.1.300", help: ""), environment: [:])
        })
        let old = Task {
            if oldHealth { _ = await checker.check(.claude) }
            else { _ = await probe.ask(harness: .claude) }
        }
        await source.waitForFirst()
        let recheck = Task { await checker.checkAgain(.claude) }
        // Keep the old read in flight while the explicit check reaches the checker/probe's existing shared-task path.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await source.calls == 1, "Rechecking does not overlap a running child")
        await source.release()
        await old.value
        let fresh = await recheck.value
        #expect(await source.calls == 2, "One explicit check reads once after the old ask has ended")
        #expect(fresh.account == .apiKey && fresh.state == .ready, "The old signed-out answer cannot become the recheck result")
    }
}
