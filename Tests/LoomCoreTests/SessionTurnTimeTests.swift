import Foundation
import Testing
@testable import LoomCore

/// Turn time belongs to the event state, so a lazy card or a slow frame consumer never starts its own stopwatch.
struct SessionTurnTimeTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000)
        func now() -> Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    }

    @Test func workingUpdatesAndApprovalsKeepTheTurnStartUntilCompletion() async {
        let clock = Clock()
        let hub = SessionEventHub(now: { clock.now() })
        let id = UUID()
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        let start = clock.now()
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == start)
        clock.advance(37)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working, pendingProviderWorkCount: 2)))
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .waitingForApproval)))
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .waitingForInput)))
        await hub.publish(sessionID: id, change: .markedRead)
        #expect(await hub.snapshot().sessions[id]?.activePhase == .inactive)
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == start, "Acknowledging a question does not restart the turn")
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == start)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .turnComplete)))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == nil)
        clock.advance(9)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == clock.now())
    }

    @Test func firstObservedApprovalStartsTheTurnButRunStartAndUnknownDoNot() async {
        let clock = Clock()
        let hub = SessionEventHub(now: { clock.now() })
        let id = UUID()
        await hub.publish(sessionID: id, change: .runStarted(UUID()))
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .unknown)))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == nil)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .waitingForApproval)))
        let start = clock.now()
        clock.advance(12)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == start)
    }

    @Test func aSlowSubscriberRecoversTheStartFromTheLatestFrame() async throws {
        let clock = Clock()
        let hub = SessionEventHub(now: { clock.now() })
        let id = UUID()
        var frames = await hub.subscribe().makeAsyncIterator()
        _ = await frames.next()
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        let start = clock.now()
        clock.advance(28)
        for index in 1...20 {
            await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working, pendingProviderWorkCount: index)))
        }
        let latest = try #require(await frames.next())
        #expect(latest.sessions[id]?.turnStartedAt == start)
    }

    @Test(arguments: [AgentActivity.atPrompt, .failed(nil), .sessionEnded(nil)])
    func aTurnEndingStateClearsTheTime(activity: AgentActivity) async {
        let hub = SessionEventHub()
        let id = UUID()
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt != nil)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: activity)))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == nil)
    }

    @Test func runBoundariesClearTheTimeAndALateOldRunCannotClearANewTurn() async {
        let hub = SessionEventHub()
        let id = UUID(), first = UUID(), second = UUID()
        await hub.publish(sessionID: id, change: .runStarted(first))
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt != nil)
        await hub.publish(sessionID: id, change: .runStarted(second))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == nil)
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        let start = await hub.snapshot().sessions[id]?.turnStartedAt
        #expect(start != nil)
        await hub.publish(sessionID: id, change: .runDetached(first))
        await hub.publish(sessionID: id, change: .runEnded(first, .requested))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == start)
        await hub.publish(sessionID: id, change: .runDetached(second))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == nil)
        let third = UUID()
        await hub.publish(sessionID: id, change: .runStarted(third))
        await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        await hub.publish(sessionID: id, change: .runEnded(third, .requested))
        #expect(await hub.snapshot().sessions[id]?.turnStartedAt == nil)
    }
}
