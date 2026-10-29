import Foundation
import Testing
@testable import LoomCore

private actor LaunchReturnWitness {
    private(set) var returned = false
    func mark() { returned = true }
}

@Suite(.serialized)
struct CodexLaunchCommitTests {
    @Test func aProvisionalNativeMatchDoesNotFinishAnUninstalledStart() async throws {
        let matcher = CodexLaunchMatcher()
        let reservation = await matcher.reserveNewLaunch(sessionID: UUID(), managedRunID: UUID(),
            workingDirectory: "/tmp/commit-owned", after: 0)
        let witness = LaunchReturnWitness()
        let waiting = Task {
            let result = try await matcher.waitForMatch(reservation, timeout: nil)
            await witness.mark()
            return result
        }
        let candidate = await matcher.receive(.event(sequence: 1, .threadStarted(.init(
            id: "owned-native", workingDirectory: "/tmp/commit-owned", originator: "codex-tui",
            source: "cli", ephemeral: false))))
        #expect(candidate != nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await witness.returned == false, "start must wait for durable identity adoption, not only a matching event")
        await matcher.cancel(reservation)
        do {
            _ = try await waiting.value
            Issue.record("An uninstalled/cancelled launch must not return a native identity")
        } catch { #expect(error is CodexLaunchMatchingError) }
    }

    @Test func onlyTheExactInstalledBindingCanFinishTheStart() async throws {
        let matcher = CodexLaunchMatcher()
        let reservation = await matcher.reserveNewLaunch(sessionID: UUID(), managedRunID: UUID(),
            workingDirectory: "/tmp/commit-owned", after: 0)
        _ = await matcher.receive(.event(sequence: 1, .threadStarted(.init(
            id: "owned-native", workingDirectory: "/tmp/commit-owned", originator: "codex-tui",
            source: "cli", ephemeral: false))))
        #expect(await matcher.commitMatched(CodexRunBinding(sessionID: UUID(),
            managedRunID: reservation.managedRunID, threadID: "owned-native", workingDirectory: "/tmp/commit-owned")) == false)
        #expect(await matcher.commitMatched(CodexRunBinding(sessionID: reservation.sessionID,
            managedRunID: reservation.managedRunID, threadID: "owned-native", workingDirectory: "/tmp/commit-owned")))
        #expect(try await matcher.waitForMatch(reservation) == "owned-native")
        #expect(await matcher.commitMatched(CodexRunBinding(sessionID: reservation.sessionID,
            managedRunID: reservation.managedRunID, threadID: "owned-native", workingDirectory: "/tmp/commit-owned")) == false)
    }
}
